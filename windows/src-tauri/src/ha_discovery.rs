//! Bounded, read-only LAN discovery for Home Assistant (`_home-assistant._tcp.local.` mDNS with
//! active RFC1918 `/24` port-8123 fallback when mDNS finds nothing).
//!
//! Sends a one-shot mDNS PTR query over UDP 5353 (with the QU bit set for unicast replies and an
//! optional multicast listener on port 5353 when bindable), parses responses with strict bounds
//! against malformed/looping DNS packets, and when mDNS yields nothing (for example Docker bridge
//! deployments on a NAS), falls back to resolving common `.local` HA hostnames and sweeping the
//! active private LAN `/24` subnet(s) on port 8123 with bounded concurrency. Returns de-duplicated
//! LAN candidates without mutating `EXTRA_ALLOWED_ORIGINS` or reading/sending any user credentials (#294).

use crate::miio_crypto::is_private_rfc1918_ipv4;
use crate::network::{normalize_host, parse_ha_endpoint_parts};
use futures_util::future::{join_all, select, Either};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::io;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, ToSocketAddrs};
use std::pin::pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;
use tokio::net::{TcpStream, UdpSocket};
use tokio::sync::Semaphore;
use tokio::time::{timeout_at, Instant};
use tokio_util::sync::CancellationToken;

pub(crate) const MDNS_MULTICAST_V4: Ipv4Addr = Ipv4Addr::new(224, 0, 0, 251);
pub(crate) const MDNS_PORT: u16 = 5353;
pub(crate) const HA_SERVICE_TYPE: &str = "_home-assistant._tcp.local";
const HA_SERVICE_SUFFIX: &str = "._home-assistant._tcp.local";
pub(crate) const HA_DEFAULT_PORT: u16 = 8123;
const COMMON_LAN_HOSTNAMES: &[&str] = &["homeassistant.local", "hassio.local", "hass.local"];

const DEFAULT_DISCOVERY_TIMEOUT_MS: u64 = 5000;
const MIN_DISCOVERY_TIMEOUT_MS: u64 = 200;
const MAX_DISCOVERY_TIMEOUT_MS: u64 = 8000;
const MDNS_PHASE_CAP: Duration = Duration::from_millis(1800);
const SETTLE_AFTER_FIRST_CANDIDATE: Duration = Duration::from_millis(600);
const RETRY_QUERY_DELAY: Duration = Duration::from_millis(750);
const LOOKUP_HOST_TIMEOUT: Duration = Duration::from_millis(250);
const TCP_PROBE_TIMEOUT: Duration = Duration::from_millis(450);
const HTTP_PROBE_TIMEOUT: Duration = Duration::from_millis(1200);
const MAX_TCP_SWEEP_CONCURRENCY: usize = 64;
const MAX_HTTP_PROBE_CONCURRENCY: usize = 16;
const MAX_SUBNET_SWEEPS: usize = 4;
const MAX_PROBE_BODY_BYTES: usize = 64 * 1024;
const MAX_FALLBACK_LOOKUPS: usize = 4;
static FALLBACK_LOOKUP_SLOTS: LazyLock<Arc<Semaphore>> =
    LazyLock::new(|| Arc::new(Semaphore::new(MAX_FALLBACK_LOOKUPS)));
static PROBE_HTTP_CLIENT: LazyLock<Result<reqwest::Client, String>> = LazyLock::new(|| {
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())
});

const MAX_DNS_PACKET_BYTES: usize = 8192;
const MAX_QUESTIONS_PER_PACKET: usize = 64;
const MAX_RECORDS_PER_PACKET: usize = 256;
const MAX_DNS_NAME_BYTES: usize = 255;
const MAX_DNS_LABELS: usize = 128;
const MAX_POINTER_HOPS: usize = 16;
const MAX_TXT_ENTRIES_PER_RECORD: usize = 64;
const MAX_DISCOVERED_INSTANCES: usize = 32;

const DNS_TYPE_A: u16 = 1;
const DNS_TYPE_PTR: u16 = 12;
const DNS_TYPE_TXT: u16 = 16;
const DNS_TYPE_SRV: u16 = 33;
const DNS_CLASS_IN: u16 = 1;
const MDNS_QU_CLASS_IN: u16 = 0x8001;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HaDiscoveredInstance {
    pub(crate) name: String,
    pub(crate) host: String,
    pub(crate) port: u16,
    pub(crate) base_url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) uuid: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum DnsParseError {
    PacketTooShort,
    PacketTooLarge,
    NotResponse,
    NonZeroRcode,
    TooManyRecords,
    Truncated,
    InvalidLabelType,
    InvalidPointer,
    PointerLoop,
    NameTooLong,
    InvalidUtf8,
    ControlChar,
}

#[derive(Default)]
pub(crate) struct HaDiscoveryState {
    active: Mutex<Option<(u64, CancellationToken)>>,
    next_id: AtomicU64,
}

impl HaDiscoveryState {
    fn register_new(&self) -> (u64, CancellationToken) {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        let token = CancellationToken::new();
        if let Ok(mut guard) = self.active.lock() {
            if let Some((_, prev)) = guard.take() {
                prev.cancel();
            }
            *guard = Some((id, token.clone()));
        }
        (id, token)
    }

    fn cancel_current(&self) {
        if let Ok(mut guard) = self.active.lock() {
            if let Some((_, active)) = guard.take() {
                active.cancel();
            }
        }
    }

    fn clear_if_matches(&self, id: u64) {
        if let Ok(mut guard) = self.active.lock() {
            if guard.as_ref().is_some_and(|(active_id, _)| *active_id == id) {
                *guard = None;
            }
        }
    }
}

struct DiscoveryRegistrationGuard<'a> {
    state: &'a HaDiscoveryState,
    id: u64,
}

impl Drop for DiscoveryRegistrationGuard<'_> {
    fn drop(&mut self) {
        self.state.clear_if_matches(self.id);
    }
}

#[derive(Default)]
struct PartialInstance {
    display_name: String,
    srv_port: Option<u16>,
    srv_target: Option<String>,
    txt: HashMap<String, String>,
    has_srv_or_txt: bool,
}

#[derive(Default)]
pub(crate) struct DiscoveryAccumulator {
    order: Vec<String>,
    instances: HashMap<String, PartialInstance>,
    a_records: HashMap<String, Vec<Ipv4Addr>>,
}

fn clean_txt_value(txt: &HashMap<String, String>, key: &str) -> Option<String> {
    txt.get(key)
        .map(|s| s.trim())
        .filter(|s| !s.is_empty() && !s.chars().any(|c| c.is_control()))
        .map(ToString::to_string)
}

impl DiscoveryAccumulator {
    fn ensure_instance(&mut self, display_name: &str) -> Option<&mut PartialInstance> {
        let key = display_name.to_ascii_lowercase();
        if !self.instances.contains_key(&key) {
            if self.instances.len() >= MAX_DISCOVERED_INSTANCES {
                return None;
            }
            self.order.push(key.clone());
            self.instances.insert(
                key.clone(),
                PartialInstance { display_name: display_name.to_string(), ..Default::default() },
            );
        }
        self.instances.get_mut(&key)
    }

    fn unresolved_local_targets(&self) -> Vec<(String, u16)> {
        let (mut seen, mut out) = (HashSet::new(), Vec::new());
        for key in &self.order {
            let Some(inst) = self.instances.get(key) else { continue };
            let Some(target) = inst.srv_target.as_deref() else { continue };
            if is_allowed_lan_discovery_host(target)
                && !is_private_rfc1918_ipv4(target)
                && !self.a_records.contains_key(target)
                && seen.insert(target.to_string())
            {
                out.push((target.to_string(), inst.srv_port.filter(|&p| p > 0).unwrap_or(8123)));
            }
        }
        out
    }

    pub(crate) fn build_instances<F>(&self, mut resolve_host: F) -> Vec<HaDiscoveredInstance>
    where
        F: FnMut(&str, u16) -> Option<Ipv4Addr>,
    {
        let (mut results, mut seen_urls) = (Vec::new(), HashSet::new());
        for key in &self.order {
            let Some(rec) = self.instances.get(key).filter(|r| r.has_srv_or_txt) else { continue };
            let srv_port = rec.srv_port.filter(|&p| p > 0).unwrap_or(8123);
            let valid_target = rec.srv_target.as_deref().map(normalize_dns_name).filter(|t| is_allowed_lan_discovery_host(t));
            let internal_url = rec.txt.get("internal_url").and_then(|raw| valid_lan_ha_url(raw));
            let base_url = rec.txt.get("base_url").and_then(|raw| valid_lan_ha_url(raw));
            let resolved_ip = valid_target.as_deref().and_then(|target| {
                if is_private_rfc1918_ipv4(target) {
                    return target.parse::<Ipv4Addr>().ok();
                }
                self.a_records.get(target).and_then(|ips| ips.first().copied()).or_else(|| resolve_host(target, srv_port))
            });
            let txt_prefers_https = rec
                .txt
                .get("https")
                .is_some_and(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "true" | "1" | "yes"));

            let chosen_url = if let Some(u) = internal_url.as_ref().filter(|u| u.starts_with("https://") || url_has_private_ipv4_host(u)) {
                Some(u.clone())
            } else if let Some(u) = base_url.as_ref().filter(|u| u.starts_with("https://") || url_has_private_ipv4_host(u)) {
                Some(u.clone())
            } else if txt_prefers_https {
                valid_target
                    .as_ref()
                    .and_then(|t| valid_lan_ha_url(&format!("https://{t}:{srv_port}")))
                    .or_else(|| resolved_ip.and_then(|ip| valid_lan_ha_url(&format!("https://{ip}:{srv_port}"))))
            } else if let Some(ip) = resolved_ip {
                valid_lan_ha_url(&format!("http://{ip}:{srv_port}"))
            } else {
                internal_url.or(base_url).or_else(|| valid_target.as_ref().and_then(|t| valid_lan_ha_url(&format!("http://{t}:{srv_port}"))))
            };

            let Some(final_url) = chosen_url else { continue };
            let Ok(parsed) = reqwest::Url::parse(&final_url) else { continue };
            let Some(host) = parsed.host_str().map(normalize_host) else { continue };
            let Some(port) = parsed.port_or_known_default() else { continue };
            if !seen_urls.insert(final_url.clone()) {
                continue;
            }
            let name = clean_txt_value(&rec.txt, "location_name")
                .or_else(|| {
                    let trimmed = rec.display_name.trim();
                    (!trimmed.is_empty()).then(|| trimmed.to_string())
                })
                .unwrap_or_else(|| "Home Assistant".to_string());

            results.push(HaDiscoveredInstance {
                name,
                host,
                port,
                base_url: final_url,
                version: clean_txt_value(&rec.txt, "version"),
                uuid: clean_txt_value(&rec.txt, "uuid"),
            });
        }
        results.sort_by_key(|item| !is_private_rfc1918_ipv4(&item.host));
        results
    }
}

pub(crate) fn normalize_dns_name(raw: &str) -> String {
    raw.trim().trim_end_matches('.').to_ascii_lowercase()
}

pub(crate) fn is_allowed_lan_discovery_host(raw: &str) -> bool {
    let host = normalize_dns_name(raw);
    if host.is_empty()
        || host == "localhost"
        || host == "localhost.local"
        || host.contains(['@', ':', '[', ']', '\\'])
        || host.chars().any(|c| c.is_control())
    {
        return false;
    }
    if is_private_rfc1918_ipv4(&host) {
        return true;
    }
    let Some(stem) = host.strip_suffix(".local").filter(|s| !s.is_empty() && *s != "localhost") else {
        return false;
    };
    stem.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && label.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            && !label.starts_with('-')
            && !label.ends_with('-')
    })
}

pub(crate) fn valid_lan_ha_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.chars().any(|c| c.is_control()) || trimmed.contains('\\') {
        return None;
    }
    let parsed = reqwest::Url::parse(trimmed).ok()?;
    if !matches!(parsed.scheme(), "http" | "https")
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return None;
    }
    let host = parsed.host_str().filter(|h| is_allowed_lan_discovery_host(h))?;
    let normalized_host = normalize_host(host);
    let port_suffix = parsed.port().map(|p| format!(":{p}")).unwrap_or_default();
    let path = parsed.path().trim_end_matches('/');
    let candidate = if path.is_empty() || path == "/" {
        format!("{}://{}{}", parsed.scheme(), normalized_host, port_suffix)
    } else {
        format!("{}://{}{}{}", parsed.scheme(), normalized_host, port_suffix, path)
    };
    parse_ha_endpoint_parts(&candidate, false).ok()?;
    Some(candidate)
}

fn url_has_private_ipv4_host(url: &str) -> bool {
    reqwest::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(normalize_host))
        .is_some_and(|host| is_private_rfc1918_ipv4(&host))
}

fn instance_display_from_service_name(raw_name: &str) -> Option<String> {
    let trimmed = raw_name.trim().trim_end_matches('.');
    let prefix_len = trimmed.to_ascii_lowercase().strip_suffix(HA_SERVICE_SUFFIX)?.len();
    let instance = trimmed.get(..prefix_len)?.trim();
    (!instance.is_empty() && !instance.chars().any(|c| c.is_control())).then(|| instance.to_string())
}

pub(crate) fn build_mdns_query(name: &str, qtype: u16, unicast_response: bool) -> Option<Vec<u8>> {
    let trimmed = name.trim().trim_end_matches('.');
    if trimmed.is_empty() {
        return None;
    }
    let mut packet = vec![0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
    for label in trimmed.split('.') {
        let bytes = label.as_bytes();
        if bytes.is_empty() || bytes.len() > 63 {
            return None;
        }
        packet.push(bytes.len() as u8);
        packet.extend_from_slice(bytes);
    }
    packet.push(0x00);
    packet.extend_from_slice(&qtype.to_be_bytes());
    let qclass = if unicast_response { MDNS_QU_CLASS_IN } else { DNS_CLASS_IN };
    packet.extend_from_slice(&qclass.to_be_bytes());
    Some(packet)
}

pub(crate) fn read_dns_name(packet: &[u8], start: usize) -> Result<(String, usize), DnsParseError> {
    let (mut pos, mut end_pos, mut hops, mut total_bytes) = (start, None, 0usize, 0usize);
    let (mut labels, mut visited_ptrs) = (Vec::new(), Vec::new());

    loop {
        if pos >= packet.len() {
            return Err(DnsParseError::Truncated);
        }
        let len_byte = packet[pos];
        if len_byte == 0 {
            if end_pos.is_none() {
                end_pos = Some(pos + 1);
            }
            break;
        }
        match len_byte & 0xC0 {
            0xC0 => {
                if pos + 1 >= packet.len() {
                    return Err(DnsParseError::Truncated);
                }
                let ptr = (((len_byte & 0x3F) as usize) << 8) | (packet[pos + 1] as usize);
                if ptr >= packet.len() {
                    return Err(DnsParseError::InvalidPointer);
                }
                if hops >= MAX_POINTER_HOPS || visited_ptrs.contains(&ptr) || ptr == pos {
                    return Err(DnsParseError::PointerLoop);
                }
                visited_ptrs.push(ptr);
                hops += 1;
                if end_pos.is_none() {
                    end_pos = Some(pos + 2);
                }
                pos = ptr;
            }
            0x00 => {
                let label_len = len_byte as usize;
                let label_start = pos + 1;
                let label_end = label_start.checked_add(label_len).ok_or(DnsParseError::Truncated)?;
                if label_end > packet.len() {
                    return Err(DnsParseError::Truncated);
                }
                total_bytes = total_bytes.checked_add(label_len + 1).ok_or(DnsParseError::NameTooLong)?;
                if total_bytes > MAX_DNS_NAME_BYTES || labels.len() >= MAX_DNS_LABELS {
                    return Err(DnsParseError::NameTooLong);
                }
                let label = std::str::from_utf8(&packet[label_start..label_end]).map_err(|_| DnsParseError::InvalidUtf8)?;
                if label.chars().any(|c| c.is_control()) {
                    return Err(DnsParseError::ControlChar);
                }
                labels.push(label.to_string());
                pos = label_end;
            }
            _ => return Err(DnsParseError::InvalidLabelType),
        }
    }
    Ok((labels.join("."), end_pos.unwrap_or(pos)))
}

pub(crate) fn parse_txt_rdata(rdata: &[u8]) -> Result<HashMap<String, String>, DnsParseError> {
    let (mut out, mut pos, mut entries) = (HashMap::new(), 0usize, 0usize);
    while pos < rdata.len() {
        let len = rdata[pos] as usize;
        pos += 1;
        let end = pos.checked_add(len).ok_or(DnsParseError::Truncated)?;
        if end > rdata.len() {
            return Err(DnsParseError::Truncated);
        }
        entries += 1;
        if entries > MAX_TXT_ENTRIES_PER_RECORD {
            break;
        }
        if let Ok(text) = std::str::from_utf8(&rdata[pos..end]) {
            if !text.chars().any(|c| c.is_control()) {
                if let Some((key, val)) = text.split_once('=') {
                    let clean_key = key.trim().to_ascii_lowercase();
                    if !clean_key.is_empty() {
                        out.insert(clean_key, val.trim().to_string());
                    }
                }
            }
        }
        pos = end;
    }
    Ok(out)
}

pub(crate) fn parse_mdns_response_into(packet: &[u8], acc: &mut DiscoveryAccumulator) -> Result<(), DnsParseError> {
    if packet.len() < 12 {
        return Err(DnsParseError::PacketTooShort);
    }
    if packet.len() > MAX_DNS_PACKET_BYTES {
        return Err(DnsParseError::PacketTooLarge);
    }
    let flags = u16::from_be_bytes([packet[2], packet[3]]);
    if (flags & 0x8000) == 0 {
        return Err(DnsParseError::NotResponse);
    }
    if (flags & 0x000F) != 0 {
        return Err(DnsParseError::NonZeroRcode);
    }
    let qdcount = u16::from_be_bytes([packet[4], packet[5]]) as usize;
    let total_rrs = (u16::from_be_bytes([packet[6], packet[7]]) as usize)
        .checked_add(u16::from_be_bytes([packet[8], packet[9]]) as usize)
        .and_then(|n| n.checked_add(u16::from_be_bytes([packet[10], packet[11]]) as usize))
        .ok_or(DnsParseError::TooManyRecords)?;
    if qdcount > MAX_QUESTIONS_PER_PACKET || total_rrs > MAX_RECORDS_PER_PACKET {
        return Err(DnsParseError::TooManyRecords);
    }

    let mut pos = 12usize;
    for _ in 0..qdcount {
        let (_, next_pos) = read_dns_name(packet, pos)?;
        pos = next_pos.checked_add(4).ok_or(DnsParseError::Truncated)?;
        if pos > packet.len() {
            return Err(DnsParseError::Truncated);
        }
    }

    for _ in 0..total_rrs {
        let (rr_name, next_pos) = read_dns_name(packet, pos)?;
        let rdata_start = next_pos.checked_add(10).ok_or(DnsParseError::Truncated)?;
        if rdata_start > packet.len() {
            return Err(DnsParseError::Truncated);
        }
        let rtype = u16::from_be_bytes([packet[next_pos], packet[next_pos + 1]]);
        let rclass = u16::from_be_bytes([packet[next_pos + 2], packet[next_pos + 3]]) & 0x7FFF;
        let rdlength = u16::from_be_bytes([packet[next_pos + 8], packet[next_pos + 9]]) as usize;
        let rdata_end = rdata_start.checked_add(rdlength).ok_or(DnsParseError::Truncated)?;
        if rdata_end > packet.len() {
            return Err(DnsParseError::Truncated);
        }

        if rclass == DNS_CLASS_IN {
            match rtype {
                DNS_TYPE_PTR if normalize_dns_name(&rr_name) == HA_SERVICE_TYPE => {
                    let (target_name, _) = read_dns_name(packet, rdata_start)?;
                    if let Some(display_name) = instance_display_from_service_name(&target_name) {
                        let _ = acc.ensure_instance(&display_name);
                    }
                }
                DNS_TYPE_SRV => {
                    if let Some(display_name) = instance_display_from_service_name(&rr_name) {
                        if rdlength < 6 {
                            return Err(DnsParseError::Truncated);
                        }
                        let port = u16::from_be_bytes([packet[rdata_start + 4], packet[rdata_start + 5]]);
                        let (target, _) = read_dns_name(packet, rdata_start + 6)?;
                        let norm_target = normalize_dns_name(&target);
                        if let Some(inst) = acc.ensure_instance(&display_name) {
                            inst.srv_port = Some(port);
                            if !norm_target.is_empty() {
                                inst.srv_target = Some(norm_target);
                            }
                            inst.has_srv_or_txt = true;
                        }
                    }
                }
                DNS_TYPE_TXT => {
                    if let Some(display_name) = instance_display_from_service_name(&rr_name) {
                        let parsed = parse_txt_rdata(&packet[rdata_start..rdata_end])?;
                        if let Some(inst) = acc.ensure_instance(&display_name) {
                            inst.txt.extend(parsed);
                            inst.has_srv_or_txt = true;
                        }
                    }
                }
                DNS_TYPE_A if rdlength == 4 => {
                    let ip = Ipv4Addr::new(
                        packet[rdata_start],
                        packet[rdata_start + 1],
                        packet[rdata_start + 2],
                        packet[rdata_start + 3],
                    );
                    if is_private_rfc1918_ipv4(&ip.to_string()) {
                        let host_key = normalize_dns_name(&rr_name);
                        if !host_key.is_empty() {
                            let list = acc.a_records.entry(host_key).or_default();
                            if !list.contains(&ip) {
                                list.push(ip);
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        pos = rdata_end;
    }
    Ok(())
}

#[cfg(windows)]
fn bind_reusable_mdns_socket(port: u16) -> io::Result<std::net::UdpSocket> {
    use std::mem::size_of;
    use std::os::windows::io::{FromRawSocket, OwnedSocket};
    use windows_sys::Win32::Networking::WinSock::{
        bind, setsockopt, WSAGetLastError, WSASocketW, AF_INET, IN_ADDR, IN_ADDR_0, INVALID_SOCKET,
        IPPROTO_UDP, SOCKADDR_IN, SOCKET_ERROR, SOCK_DGRAM, SOL_SOCKET, SO_REUSEADDR,
        WSA_FLAG_NO_HANDLE_INHERIT, WSA_FLAG_OVERLAPPED,
    };

    // The ephemeral Tokio UDP socket initializes Winsock before this listener is opened.
    let raw = unsafe {
        WSASocketW(
            i32::from(AF_INET), SOCK_DGRAM, IPPROTO_UDP, std::ptr::null(), 0,
            WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT,
        )
    };
    if raw == INVALID_SOCKET {
        return Err(io::Error::from_raw_os_error(unsafe { WSAGetLastError() }));
    }
    // Take ownership immediately so every failure path closes the socket.
    let owned = unsafe { OwnedSocket::from_raw_socket(raw as _) };
    let reuse: i32 = 1;
    let addr = SOCKADDR_IN {
        sin_family: AF_INET,
        sin_port: port.to_be(),
        sin_addr: IN_ADDR { S_un: IN_ADDR_0 { S_addr: 0 } },
        sin_zero: [0; 8],
    };
    if unsafe {
        setsockopt(raw, SOL_SOCKET, SO_REUSEADDR, (&reuse as *const i32).cast(), size_of::<i32>() as i32)
    } == SOCKET_ERROR
        || unsafe { bind(raw, (&addr as *const SOCKADDR_IN).cast(), size_of::<SOCKADDR_IN>() as i32) }
            == SOCKET_ERROR
    {
        return Err(io::Error::from_raw_os_error(unsafe { WSAGetLastError() }));
    }
    Ok(owned.into())
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn bind_reusable_mdns_socket(port: u16) -> io::Result<std::net::UdpSocket> {
    use std::ffi::{c_int, c_void};
    use std::mem::size_of;
    use std::os::fd::{FromRawFd, OwnedFd};

    unsafe extern "C" {
        fn socket(domain: c_int, kind: c_int, protocol: c_int) -> c_int;
        fn setsockopt(fd: c_int, level: c_int, opt: c_int, val: *const c_void, len: u32) -> c_int;
        #[cfg(target_os = "macos")]
        fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
        fn bind(fd: c_int, addr: *const c_void, len: u32) -> c_int;
    }

    const AF_INET: c_int = 2;
    #[cfg(target_os = "linux")]
    const SOCK_DGRAM: c_int = 2 | 0x80000; // SOCK_CLOEXEC
    #[cfg(target_os = "macos")]
    const SOCK_DGRAM: c_int = 2;
    #[cfg(target_os = "linux")]
    let (family, level, option) = ((AF_INET as u16).to_ne_bytes(), 1, 2); // SOL_SOCKET, SO_REUSEADDR
    #[cfg(target_os = "macos")]
    let (family, level, option) = ([16, AF_INET as u8], 0xffff, 0x0004); // SOL_SOCKET, SO_REUSEADDR

    let raw = unsafe { socket(AF_INET, SOCK_DGRAM, 0) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    let owned = unsafe { OwnedFd::from_raw_fd(raw) };
    #[cfg(target_os = "macos")]
    if unsafe { fcntl(raw, 2, 1 as c_int) } < 0 { // F_SETFD, FD_CLOEXEC
        return Err(io::Error::last_os_error());
    }
    let reuse: c_int = 1;
    let set_reuse = |opt| unsafe {
        setsockopt(raw, level, opt, (&reuse as *const c_int).cast(), size_of::<c_int>() as u32)
    };
    if set_reuse(option) != 0 {
        return Err(io::Error::last_os_error());
    }
    #[cfg(target_os = "macos")]
    if set_reuse(0x0200) != 0 { // SO_REUSEPORT permits multiple wildcard mDNS listeners on Darwin.
        return Err(io::Error::last_os_error());
    }
    #[repr(C)]
    struct SockAddrIn {
        family: [u8; 2],
        port: [u8; 2],
        addr: u32,
        zero: [u8; 8],
    }
    let addr = SockAddrIn { family, port: port.to_be_bytes(), addr: 0, zero: [0; 8] };
    if unsafe { bind(raw, (&addr as *const SockAddrIn).cast(), size_of::<SockAddrIn>() as u32) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(owned.into())
}

#[cfg(not(any(windows, target_os = "linux", target_os = "macos")))]
fn bind_reusable_mdns_socket(port: u16) -> io::Result<std::net::UdpSocket> {
    std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, port))
}

fn try_bind_multicast_5353() -> Option<UdpSocket> {
    let std_sock = bind_reusable_mdns_socket(MDNS_PORT).ok()?;
    std_sock.set_nonblocking(true).ok()?;
    std_sock.join_multicast_v4(&MDNS_MULTICAST_V4, &Ipv4Addr::UNSPECIFIED).ok()?;
    UdpSocket::from_std(std_sock).ok()
}

async fn resolve_lan_ipv4_fallback(host: String, port: u16) -> Option<Ipv4Addr> {
    let slot = FALLBACK_LOOKUP_SLOTS.clone().try_acquire_owned().ok()?;
    tokio::task::spawn_blocking(move || {
        // An OS lookup cannot be cancelled. Keep its slot until it actually finishes.
        let _slot = slot;
        (host.as_str(), port).to_socket_addrs().ok()?.find_map(|addr| match addr {
            SocketAddr::V4(v4) if is_private_rfc1918_ipv4(&v4.ip().to_string()) => Some(*v4.ip()),
            _ => None,
        })
    }).await.ok()?
}

async fn fallback_addresses<F, Fut>(
    targets: Vec<(String, u16)>,
    deadline: Instant,
    resolve: F,
) -> HashMap<String, Ipv4Addr>
where
    F: Fn(String, u16) -> Fut,
    Fut: std::future::Future<Output = Option<Ipv4Addr>>,
{
    let deadline = deadline.min(Instant::now() + LOOKUP_HOST_TIMEOUT);
    if deadline <= Instant::now() {
        return HashMap::new();
    }
    join_all(targets.into_iter().take(MAX_FALLBACK_LOOKUPS).map(|(target, port)| {
        let lookup = resolve(target.clone(), port);
        async move { timeout_at(deadline, lookup).await.ok().flatten().map(|ip| (target, ip)) }
    }))
    .await
    .into_iter()
    .flatten()
    .collect()
}

pub(crate) fn subnet_candidate_ips(interfaces: &[(Ipv4Addr, u8)], max_subnets: usize) -> Vec<Ipv4Addr> {
    if max_subnets == 0 { return Vec::new(); }
    let (mut seen_subnets, mut seen_ips, mut out) = (HashSet::new(), HashSet::new(), Vec::new());
    for &(ip, prefix_len) in interfaces {
        if !is_private_rfc1918_ipv4(&ip.to_string()) { continue; }
        let effective_prefix = if prefix_len == 0 || prefix_len > 32 { 24 } else { prefix_len.max(24) };
        if effective_prefix >= 31 { continue; }
        let mask = !0u32 << (32 - effective_prefix);
        let network = u32::from(ip) & mask;
        let broadcast = network | !mask;
        if broadcast <= network.saturating_add(1) || seen_subnets.contains(&(network, mask)) { continue; }
        if seen_subnets.len() >= max_subnets { break; }
        seen_subnets.insert((network, mask));
        for host_u32 in (network + 1)..broadcast {
            let candidate = Ipv4Addr::from(host_u32);
            let octets = candidate.octets();
            if octets[3] != 0 && octets[3] != 255
                && is_private_rfc1918_ipv4(&candidate.to_string())
                && seen_ips.insert(candidate)
            {
                out.push(candidate);
            }
        }
    }
    out
}

#[cfg(windows)]
fn active_lan_ipv4_interfaces() -> Vec<(Ipv4Addr, u8)> {
    use windows_sys::Win32::Foundation::NO_ERROR;
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        FreeMibTable, GetIpForwardTable2, GetUnicastIpAddressTable, MIB_IPFORWARD_TABLE2,
        MIB_UNICASTIPADDRESS_TABLE,
    };
    use windows_sys::Win32::Networking::WinSock::AF_INET;
    const IP_DAD_STATE_PREFERRED: i32 = 4;

    let mut default_luid: Option<(u32, u64)> = None;
    let mut route_table: *mut MIB_IPFORWARD_TABLE2 = std::ptr::null_mut();
    if unsafe { GetIpForwardTable2(AF_INET, &mut route_table) } == NO_ERROR && !route_table.is_null() {
        unsafe {
            for row in std::slice::from_raw_parts((*route_table).Table.as_ptr(), (*route_table).NumEntries as usize) {
                if row.DestinationPrefix.PrefixLength == 0 && row.InterfaceLuid.Value != 0 {
                    let cand = (row.Metric, row.InterfaceLuid.Value);
                    if default_luid.is_none_or(|best| cand < best) { default_luid = Some(cand); }
                }
            }
            FreeMibTable(route_table.cast());
        }
    }
    let preferred_luid = default_luid.map(|(_, luid)| luid);
    let mut unicast_table: *mut MIB_UNICASTIPADDRESS_TABLE = std::ptr::null_mut();
    if unsafe { GetUnicastIpAddressTable(AF_INET, &mut unicast_table) } != NO_ERROR || unicast_table.is_null() {
        return Vec::new();
    }
    let mut entries: Vec<(u8, u64, Ipv4Addr, u8)> = Vec::new();
    unsafe {
        for row in std::slice::from_raw_parts((*unicast_table).Table.as_ptr(), (*unicast_table).NumEntries as usize) {
            if row.DadState != IP_DAD_STATE_PREFERRED || row.Address.si_family != AF_INET { continue; }
            let ip = Ipv4Addr::from(row.Address.Ipv4.sin_addr.S_un.S_addr.to_ne_bytes());
            if ip.is_loopback() || ip.is_link_local() || ip.is_multicast() || !is_private_rfc1918_ipv4(&ip.to_string()) { continue; }
            let luid = row.InterfaceLuid.Value;
            entries.push((u8::from(preferred_luid != Some(luid)), luid, ip, row.OnLinkPrefixLength));
        }
        FreeMibTable(unicast_table.cast());
    }
    entries.sort_by_key(|(priority, luid, ip, _)| (*priority, *luid, *ip));
    entries.into_iter().map(|(_, _, ip, prefix)| (ip, prefix)).collect()
}

#[cfg(not(windows))]
fn active_lan_ipv4_interfaces() -> Vec<(Ipv4Addr, u8)> { Vec::new() }

pub(crate) fn is_home_assistant_manifest(body: &[u8]) -> bool {
    if body.is_empty() { return false; }
    if let Ok(serde_json::Value::Object(map)) = serde_json::from_slice::<serde_json::Value>(body) {
        let has_ha = |k: &str| map.get(k).and_then(|v| v.as_str()).is_some_and(|s| s.to_ascii_lowercase().contains("home assistant"));
        if has_ha("name") || has_ha("short_name") { return true; }
        if map.get("start_url").and_then(|v| v.as_str()) == Some("/?homescreen=1")
            && map.get("icons").and_then(|v| v.as_array()).is_some_and(|icons| {
                icons.iter().any(|item| item.get("src").and_then(|s| s.as_str()).is_some_and(|s| s.contains("/static/icons/")))
            })
        {
            return true;
        }
    }
    std::str::from_utf8(body).is_ok_and(|t| t.contains("io.homeassistant") || t.contains("\"Home Assistant\""))
}

pub(crate) fn is_home_assistant_auth_providers(status: u16, body: &[u8]) -> bool {
    if !(200..300).contains(&status) || body.is_empty() { return false; }
    let Ok(serde_json::Value::Array(items)) = serde_json::from_slice::<serde_json::Value>(body) else { return false; };
    items.iter().any(|item| {
        let Some(obj) = item.as_object() else { return false };
        match obj.get("type").and_then(|v| v.as_str()).map(|s| s.trim().to_ascii_lowercase()).as_deref() {
            Some("homeassistant") => true,
            Some("trusted_networks") => obj.get("name").and_then(|v| v.as_str()).is_some_and(|s| s.to_ascii_lowercase().contains("home assistant")),
            _ => false,
        }
    })
}

pub(crate) fn is_home_assistant_api_response(status: u16, headers: &HashMap<String, String>, body: &[u8]) -> bool {
    if (200..300).contains(&status) {
        if let Ok(serde_json::Value::Object(map)) = serde_json::from_slice::<serde_json::Value>(body) {
            if map.get("message").and_then(|v| v.as_str()).is_some_and(|m| m.trim() == "API running.") { return true; }
        }
    }
    if status != 401 { return false; }
    let body_text = std::str::from_utf8(body).unwrap_or("").trim();
    let body_lower = body_text.to_ascii_lowercase();
    if body_text != "401: Unauthorized" && !body_lower.contains("home assistant") { return false; }
    if body_lower.contains("home assistant") { return true; }
    headers.iter().any(|(k, v)| {
        let (lk, lv) = (k.to_ascii_lowercase(), v.to_ascii_lowercase());
        (lk == "server" && (lv.contains("aiohttp") || lv.contains("home assistant")))
            || (lk == "www-authenticate" && lv.contains("home assistant"))
            || lk.starts_with("x-ha-") || lk.contains("home-assistant")
    })
}

async fn fetch_probe_response(
    client: &reqwest::Client, url: &str, deadline: Instant,
) -> Option<(u16, HashMap<String, String>, Vec<u8>)> {
    let now = Instant::now();
    let remaining = deadline.saturating_duration_since(now);
    if remaining.is_zero() { return None; }
    let req_timeout = remaining.min(HTTP_PROBE_TIMEOUT);
    let mut resp = timeout_at(now + req_timeout, client.get(url).timeout(req_timeout).send()).await.ok()?.ok()?;
    let status = resp.status().as_u16();
    let headers = resp.headers().iter()
        .filter_map(|(n, v)| v.to_str().ok().map(|s| (n.as_str().to_ascii_lowercase(), s.to_string())))
        .collect();
    let mut body = Vec::new();
    while let Ok(Ok(Some(chunk))) = timeout_at(deadline, resp.chunk()).await {
        let take = MAX_PROBE_BODY_BYTES.saturating_sub(body.len()).min(chunk.len());
        body.extend_from_slice(&chunk[..take]);
        if body.len() >= MAX_PROBE_BODY_BYTES { break; }
    }
    Some((status, headers, body))
}

pub(crate) async fn probe_ha_http_on_addr(client: &reqwest::Client, addr: SocketAddr, deadline: Instant) -> bool {
    let base = format!("http://{addr}");
    let Some((ms, _, mb)) = fetch_probe_response(client, &format!("{base}/manifest.json"), deadline).await else { return false; };
    if (200..300).contains(&ms) && is_home_assistant_manifest(&mb) { return true; }
    if let Some((s, _, b)) = fetch_probe_response(client, &format!("{base}/auth/providers"), deadline).await {
        if is_home_assistant_auth_providers(s, &b) { return true; }
    }
    if let Some((s, h, b)) = fetch_probe_response(client, &format!("{base}/api/"), deadline).await {
        if is_home_assistant_api_response(s, &h, &b) { return true; }
    }
    false
}

async fn sweep_open_tcp_port(ips: Vec<Ipv4Addr>, port: u16, deadline: Instant) -> Vec<Ipv4Addr> {
    if ips.is_empty() || Instant::now() >= deadline { return Vec::new(); }
    let sem = Arc::new(Semaphore::new(MAX_TCP_SWEEP_CONCURRENCY));
    join_all(ips.into_iter().map(|ip| {
        let sem = Arc::clone(&sem);
        async move {
            let Ok(Ok(_permit)) = timeout_at(deadline, sem.acquire_owned()).await else { return None; };
            let now = Instant::now();
            let remaining = deadline.saturating_duration_since(now);
            if remaining.is_zero() { return None; }
            let addr = SocketAddr::V4(SocketAddrV4::new(ip, port));
            matches!(timeout_at(now + remaining.min(TCP_PROBE_TIMEOUT), TcpStream::connect(addr)).await, Ok(Ok(_))).then_some(ip)
        }
    })).await.into_iter().flatten().collect()
}

async fn run_http_fallback_discovery(deadline: Instant) -> Vec<HaDiscoveredInstance> {
    if Instant::now() >= deadline { return Vec::new(); }
    let Ok(client) = PROBE_HTTP_CLIENT.as_ref() else { return Vec::new(); };
    let common_targets = COMMON_LAN_HOSTNAMES.iter().map(|h| ((*h).to_string(), HA_DEFAULT_PORT)).collect();
    let resolved_common = fallback_addresses(common_targets, deadline, resolve_lan_ipv4_fallback).await;
    let interfaces = timeout_at(deadline, tokio::task::spawn_blocking(active_lan_ipv4_interfaces))
        .await.ok().and_then(|r| r.ok()).unwrap_or_default();

    let (mut seen_ips, mut candidates) = (HashSet::new(), Vec::new());
    for host in COMMON_LAN_HOSTNAMES {
        if let Some(&ip) = resolved_common.get(*host) {
            if is_private_rfc1918_ipv4(&ip.to_string()) && seen_ips.insert(ip) { candidates.push(ip); }
        }
    }
    for ip in subnet_candidate_ips(&interfaces, MAX_SUBNET_SWEEPS) {
        if seen_ips.insert(ip) { candidates.push(ip); }
    }
    let open_ips = sweep_open_tcp_port(candidates, HA_DEFAULT_PORT, deadline).await;
    if open_ips.is_empty() || Instant::now() >= deadline { return Vec::new(); }

    let sem = Arc::new(Semaphore::new(MAX_HTTP_PROBE_CONCURRENCY));
    join_all(open_ips.into_iter().take(MAX_DISCOVERED_INSTANCES).map(|ip| {
        let sem = Arc::clone(&sem);
        async move {
            let Ok(Ok(_permit)) = timeout_at(deadline, sem.acquire_owned()).await else { return None; };
            let host = ip.to_string();
            let base_url = valid_lan_ha_url(&format!("http://{host}:{HA_DEFAULT_PORT}"))?;
            let addr = SocketAddr::V4(SocketAddrV4::new(ip, HA_DEFAULT_PORT));
            probe_ha_http_on_addr(client, addr, deadline).await.then(|| HaDiscoveredInstance {
                name: "Home Assistant".to_string(), host, port: HA_DEFAULT_PORT, base_url, version: None, uuid: None,
            })
        }
    })).await.into_iter().flatten().collect()
}

async fn run_mdns_discovery(timeout: Duration, cancel: CancellationToken) -> Result<Vec<HaDiscoveredInstance>, String> {
    cancel
        .run_until_cancelled(run_mdns_discovery_inner(timeout))
        .await
        .ok_or_else(|| "Home Assistant discovery cancelled".to_string())?
}

async fn run_mdns_discovery_inner(timeout: Duration) -> Result<Vec<HaDiscoveredInstance>, String> {
    let start = Instant::now();
    let overall_deadline = start + timeout;
    let mdns_deadline = if timeout > MDNS_PHASE_CAP { start + MDNS_PHASE_CAP } else { overall_deadline };
    let query = build_mdns_query(HA_SERVICE_TYPE, DNS_TYPE_PTR, true)
        .ok_or_else(|| "Failed to build mDNS discovery query".to_string())?;
    let mcast_dest = SocketAddr::V4(SocketAddrV4::new(MDNS_MULTICAST_V4, MDNS_PORT));

    let ephemeral = timeout_at(
        mdns_deadline,
        UdpSocket::bind(SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0))),
    )
        .await
        .map_err(|_| "局域网发现超时")?
        .map_err(|e| format!("无法创建局域网发现套接字：{e}"))?;
    let _ = ephemeral.set_multicast_loop_v4(true);
    let mcast_listener = try_bind_multicast_5353();

    if !matches!(timeout_at(mdns_deadline, ephemeral.send_to(&query, mcast_dest)).await, Ok(Ok(_))) {
        return Ok(run_http_fallback_discovery(overall_deadline).await);
    }

    let mut active_deadline = mdns_deadline;
    let mut retry_deadline = Some(start + RETRY_QUERY_DELAY.min(timeout));
    let mut settled_once = false;
    let mut queried_targets: HashSet<String> = HashSet::new();
    let mut acc = DiscoveryAccumulator::default();
    let mut buf_ephemeral = vec![0u8; MAX_DNS_PACKET_BYTES];
    let mut buf_mcast = vec![0u8; MAX_DNS_PACKET_BYTES];

    loop {
        let now = Instant::now();
        if now >= active_deadline {
            break;
        }
        let next_wake = retry_deadline.map_or(active_deadline, |r| r.min(active_deadline));
        let wait_for = next_wake.saturating_duration_since(now);

        let packet_len = match &mcast_listener {
            Some(mcast) => {
                let eph_fut = pin!(ephemeral.recv_from(&mut buf_ephemeral));
                let mcast_fut = pin!(mcast.recv_from(&mut buf_mcast));
                match tokio::time::timeout(wait_for, select(eph_fut, mcast_fut)).await {
                    Ok(Either::Left((Ok((n, _)), _))) => Some((true, n)),
                    Ok(Either::Right((Ok((n, _)), _))) => Some((false, n)),
                    _ => None,
                }
            }
            None => match tokio::time::timeout(wait_for, ephemeral.recv_from(&mut buf_ephemeral)).await {
                Ok(Ok((n, _))) => Some((true, n)),
                _ => None,
            },
        };

        if let Some((from_ephemeral, n)) = packet_len {
            let slice = if from_ephemeral { &buf_ephemeral[..n] } else { &buf_mcast[..n] };
            let _ = parse_mdns_response_into(slice, &mut acc);
        } else if let Some(retry_at) = retry_deadline.filter(|&at| Instant::now() >= at) {
            let _ = retry_at;
            retry_deadline = None;
            let _ = timeout_at(active_deadline, ephemeral.send_to(&query, mcast_dest)).await;
        }

        let unresolved = acc.unresolved_local_targets();
        if !unresolved.is_empty() {
            let fallback_budget = LOOKUP_HOST_TIMEOUT.min(timeout / 2);
            active_deadline = active_deadline.min(mdns_deadline - fallback_budget);
        }
        for (target, _) in unresolved {
            if queried_targets.len() >= MAX_DISCOVERED_INSTANCES {
                break;
            }
            if queried_targets.insert(target.clone()) {
                if let Some(a_query) = build_mdns_query(&target, DNS_TYPE_A, true) {
                    let _ = timeout_at(active_deadline, ephemeral.send_to(&a_query, mcast_dest)).await;
                }
            }
        }

        if !settled_once && !acc.build_instances(|_, _| None).is_empty() {
            settled_once = true;
            active_deadline = active_deadline.min(Instant::now() + SETTLE_AFTER_FIRST_CANDIDATE);
        }
    }

    let fallback_ips =
        fallback_addresses(acc.unresolved_local_targets(), mdns_deadline, resolve_lan_ipv4_fallback).await;
    let mdns_instances = acc.build_instances(|host, _| fallback_ips.get(host).copied());
    if !mdns_instances.is_empty() {
        return Ok(mdns_instances);
    }
    Ok(run_http_fallback_discovery(overall_deadline).await)
}

#[tauri::command]
pub(crate) async fn discover_home_assistant(
    state: tauri::State<'_, HaDiscoveryState>,
    timeout_ms: Option<u64>,
) -> Result<Vec<HaDiscoveredInstance>, String> {
    let clamped_ms = timeout_ms
        .unwrap_or(DEFAULT_DISCOVERY_TIMEOUT_MS)
        .clamp(MIN_DISCOVERY_TIMEOUT_MS, MAX_DISCOVERY_TIMEOUT_MS);
    let (id, cancel) = state.register_new();
    let _guard = DiscoveryRegistrationGuard { state: &state, id };
    run_mdns_discovery(Duration::from_millis(clamped_ms), cancel).await
}

#[tauri::command]
pub(crate) fn cancel_ha_discovery(state: tauri::State<'_, HaDiscoveryState>) -> Result<(), String> {
    state.cancel_current();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(any(windows, target_os = "linux", target_os = "macos"))]
    #[test]
    fn multicast_socket_allows_two_listeners_on_one_port() {
        let _init = std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).unwrap();
        let first = bind_reusable_mdns_socket(0).unwrap();
        let port = first.local_addr().unwrap().port();
        let second = bind_reusable_mdns_socket(port).unwrap();
        assert_eq!(second.local_addr().unwrap().port(), port);
    }

    #[test]
    fn fallback_starts_at_most_four_resolutions() {
        tauri::async_runtime::block_on(async {
            let targets = (0..MAX_DISCOVERED_INSTANCES)
                .map(|i| (format!("ha-{i}.local"), 8123))
                .collect();
            let calls = AtomicU64::new(0);
            let resolved = fallback_addresses(targets, Instant::now() + LOOKUP_HOST_TIMEOUT, |_, _| {
                calls.fetch_add(1, Ordering::Relaxed);
                std::future::ready(Some(Ipv4Addr::new(192, 168, 1, 2)))
            }).await;
            assert_eq!(calls.load(Ordering::Relaxed), 4);
            assert_eq!(resolved.len(), 4);
        });
    }

    #[test]
    fn fallback_respects_the_overall_deadline() {
        tauri::async_runtime::block_on(async {
            let targets = vec![("ha.local".into(), 8123)];
            let expired = fallback_addresses(targets.clone(), Instant::now(), |_, _| -> std::future::Ready<Option<Ipv4Addr>> {
                panic!("expired budget must not start a resolver")
            }).await;
            assert!(expired.is_empty());

            let deadline = Instant::now() + Duration::from_millis(10);
            let resolved = tokio::time::timeout(
                Duration::from_millis(100),
                fallback_addresses(targets, deadline, |_, _| std::future::pending()),
            ).await.expect("fallback must use the caller's shorter deadline");
            assert!(resolved.is_empty());
        });
    }

    fn encode_dns_name(name: &str) -> Vec<u8> {
        let mut out = Vec::new();
        for label in name.trim_end_matches('.').split('.').filter(|l| !l.is_empty()) {
            let bytes = label.as_bytes();
            out.push(bytes.len() as u8);
            out.extend_from_slice(bytes);
        }
        out.push(0);
        out
    }

    fn build_rr(name: &[u8], rtype: u16, rclass: u16, rdata: &[u8]) -> Vec<u8> {
        let mut rr = Vec::new();
        rr.extend_from_slice(name);
        rr.extend_from_slice(&rtype.to_be_bytes());
        rr.extend_from_slice(&rclass.to_be_bytes());
        rr.extend_from_slice(&120u32.to_be_bytes());
        rr.extend_from_slice(&(rdata.len() as u16).to_be_bytes());
        rr.extend_from_slice(rdata);
        rr
    }

    fn build_txt_rdata(entries: &[&str]) -> Vec<u8> {
        entries.iter().fold(Vec::new(), |mut out, e| {
            out.push(e.len() as u8);
            out.extend_from_slice(e.as_bytes());
            out
        })
    }

    fn build_response_packet(answers: &[Vec<u8>], additionals: &[Vec<u8>]) -> Vec<u8> {
        let mut pkt = Vec::new();
        pkt.extend_from_slice(&[0x00, 0x00, 0x84, 0x00, 0x00, 0x00]);
        pkt.extend_from_slice(&(answers.len() as u16).to_be_bytes());
        pkt.extend_from_slice(&0u16.to_be_bytes());
        pkt.extend_from_slice(&(additionals.len() as u16).to_be_bytes());
        for rr in answers.iter().chain(additionals.iter()) {
            pkt.extend_from_slice(rr);
        }
        pkt
    }

    #[test]
    fn parses_mdns_ptr_srv_txt_a_and_deduplicates_candidates() {
        let inst_name = "Home._home-assistant._tcp.local";
        let ptr = build_rr(&encode_dns_name(HA_SERVICE_TYPE), DNS_TYPE_PTR, DNS_CLASS_IN, &encode_dns_name(inst_name));
        let mut srv_rdata = vec![0, 0, 0, 0, 0x1f, 0xbb]; // port 8123
        srv_rdata.extend_from_slice(&encode_dns_name("homeassistant.local"));
        let srv = build_rr(&encode_dns_name(inst_name), DNS_TYPE_SRV, 0x8001, &srv_rdata);
        let txt = build_rr(
            &encode_dns_name(inst_name),
            DNS_TYPE_TXT,
            0x8001,
            &build_txt_rdata(&[
                "location_name=My Smart Home",
                "version=2026.2.1",
                "uuid=ha-uuid-1",
                "internal_url=http://192.168.1.50:8123",
            ]),
        );
        let a_rec = build_rr(&encode_dns_name("homeassistant.local"), DNS_TYPE_A, 0x8001, &[192, 168, 1, 50]);

        let pkt1 = build_response_packet(&[ptr.clone()], &[srv.clone(), txt.clone(), a_rec]);
        let pkt2 = build_response_packet(&[ptr], &[srv, txt]);

        let mut acc = DiscoveryAccumulator::default();
        parse_mdns_response_into(&pkt1, &mut acc).expect("valid packet 1");
        parse_mdns_response_into(&pkt2, &mut acc).expect("duplicate packet 2");

        assert_eq!(
            acc.build_instances(|_, _| None),
            vec![HaDiscoveredInstance {
                name: "My Smart Home".to_string(),
                host: "192.168.1.50".to_string(),
                port: 8123,
                base_url: "http://192.168.1.50:8123".to_string(),
                version: Some("2026.2.1".to_string()),
                uuid: Some("ha-uuid-1".to_string()),
            }]
        );
    }

    #[test]
    fn preserves_https_when_advertised_and_rejects_public_or_spoofed_urls() {
        let inst_https = "Studio._home-assistant._tcp.local";
        let inst_spoof = "Evil._home-assistant._tcp.local";
        let txt_https = build_rr(
            &encode_dns_name(inst_https),
            DNS_TYPE_TXT,
            DNS_CLASS_IN,
            &build_txt_rdata(&["location_name=Studio HA", "internal_url=https://studio-ha.local:8443/"]),
        );
        let mut rdata = vec![0, 0, 0, 0, 0x20, 0xfb]; // port 8443
        rdata.extend_from_slice(&encode_dns_name("studio-ha.local"));
        let srv_https = build_rr(&encode_dns_name(inst_https), DNS_TYPE_SRV, DNS_CLASS_IN, &rdata);
        let a_https = build_rr(&encode_dns_name("studio-ha.local"), DNS_TYPE_A, DNS_CLASS_IN, &[192, 168, 10, 42]);
        let txt_spoof = build_rr(
            &encode_dns_name(inst_spoof),
            DNS_TYPE_TXT,
            DNS_CLASS_IN,
            &build_txt_rdata(&["location_name=Spoof", "internal_url=https://evil.example.com:8123", "base_url=http://8.8.8.8:8123"]),
        );

        let mut acc = DiscoveryAccumulator::default();
        parse_mdns_response_into(&build_response_packet(&[txt_https, srv_https, txt_spoof], &[a_https]), &mut acc).unwrap();
        let found = acc.build_instances(|_, _| None);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].base_url, "https://studio-ha.local:8443");
        assert_eq!(found[0].host, "studio-ha.local");
        assert_eq!(found[0].port, 8443);
    }

    #[test]
    fn resolves_compressed_dns_names_and_rejects_malformed_packets() {
        let mut pkt = vec![0x00, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01];
        let ptr_name_offset = pkt.len();
        pkt.extend_from_slice(&encode_dns_name(HA_SERVICE_TYPE));
        pkt.extend_from_slice(&[0, 12, 0, 1, 0, 0, 0, 120]);
        let inst_label = b"Living";
        pkt.extend_from_slice(&((1 + inst_label.len() + 2) as u16).to_be_bytes());
        let inst_offset = pkt.len();
        pkt.push(inst_label.len() as u8);
        pkt.extend_from_slice(inst_label);
        pkt.extend_from_slice(&(0xC000u16 | ptr_name_offset as u16).to_be_bytes());

        pkt.extend_from_slice(&(0xC000u16 | inst_offset as u16).to_be_bytes());
        pkt.extend_from_slice(&[0, 33, 0, 1, 0, 0, 0, 120]);
        let target_bytes = encode_dns_name("ha-box.local");
        pkt.extend_from_slice(&((6 + target_bytes.len()) as u16).to_be_bytes());
        pkt.extend_from_slice(&[0, 0, 0, 0, 0x1f, 0xbb]);
        pkt.extend_from_slice(&target_bytes);

        let mut acc = DiscoveryAccumulator::default();
        parse_mdns_response_into(&pkt, &mut acc).expect("compressed name parses");
        let found = acc.build_instances(|host, _| (host == "ha-box.local").then_some(Ipv4Addr::new(172, 16, 0, 25)));
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].name, "Living");
        assert_eq!(found[0].base_url, "http://172.16.0.25:8123");

        assert_eq!(parse_mdns_response_into(&[0, 1, 2], &mut DiscoveryAccumulator::default()), Err(DnsParseError::PacketTooShort));
        assert_eq!(parse_mdns_response_into(&vec![0u8; MAX_DNS_PACKET_BYTES + 1], &mut DiscoveryAccumulator::default()), Err(DnsParseError::PacketTooLarge));

        let mut loop_pkt = vec![0x00, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00];
        loop_pkt.extend_from_slice(&[0xC0, 0x0C, 0x00, 0x0C, 0x00, 0x01, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00]);
        assert_eq!(parse_mdns_response_into(&loop_pkt, &mut DiscoveryAccumulator::default()), Err(DnsParseError::PointerLoop));

        let mut oob_pkt = vec![0x00, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00];
        oob_pkt.extend_from_slice(&[0xC0, 0xFF]);
        assert_eq!(parse_mdns_response_into(&oob_pkt, &mut DiscoveryAccumulator::default()), Err(DnsParseError::InvalidPointer));

        let dos_pkt = vec![0x00, 0x00, 0x84, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00];
        assert_eq!(parse_mdns_response_into(&dos_pkt, &mut DiscoveryAccumulator::default()), Err(DnsParseError::TooManyRecords));

        let mut bad_label = vec![0x00, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00];
        bad_label.extend_from_slice(&[0x40, 0x00]);
        assert_eq!(parse_mdns_response_into(&bad_label, &mut DiscoveryAccumulator::default()), Err(DnsParseError::InvalidLabelType));

        assert_eq!(parse_txt_rdata(&[10, b'a', b'b']), Err(DnsParseError::Truncated));
    }

    #[test]
    fn query_builder_and_cancel_work() {
        let query = build_mdns_query(HA_SERVICE_TYPE, DNS_TYPE_PTR, true).expect("valid query");
        assert_eq!(&query[0..6], &[0x00, 0x00, 0x00, 0x00, 0x00, 0x01]);
        assert_eq!(&query[query.len() - 4..], &[0x00, 12, 0x80, 0x01]);
        assert!(build_mdns_query("", DNS_TYPE_PTR, true).is_none());

        let state = HaDiscoveryState::default();
        let (id, cancel) = state.register_new();
        state.cancel_current();
        assert!(cancel.is_cancelled());
        let res = tauri::async_runtime::block_on(run_mdns_discovery(Duration::from_millis(2000), cancel));
        assert_eq!(res, Err("Home Assistant discovery cancelled".to_string()));
        state.clear_if_matches(id);
    }

    #[test]
    fn subnet_candidates_clamp_deduplicate_and_filter_non_rfc1918() {
        let interfaces = vec![
            (Ipv4Addr::new(169, 254, 72, 197), 16), // link-local -> ignored
            (Ipv4Addr::new(127, 0, 0, 1), 8),       // loopback -> ignored
            (Ipv4Addr::new(203, 0, 113, 10), 24),   // public -> ignored
            (Ipv4Addr::new(192, 168, 1, 181), 16),  // /16 clamped to 192.168.1.0/24
            (Ipv4Addr::new(192, 168, 1, 107), 24),  // duplicate /24 -> deduplicated
            (Ipv4Addr::new(192, 168, 64, 1), 29),   // narrower /29 -> .1..=.6
        ];
        let hosts = subnet_candidate_ips(&interfaces, 4);
        assert_eq!(hosts.len(), 254 + 6);
        assert_eq!(hosts.first(), Some(&Ipv4Addr::new(192, 168, 1, 1)));
        assert!(hosts.contains(&Ipv4Addr::new(192, 168, 1, 4)));
        assert!(!hosts.contains(&Ipv4Addr::new(192, 168, 1, 0)));
        assert!(!hosts.contains(&Ipv4Addr::new(192, 168, 1, 255)));
        assert_eq!(&hosts[hosts.len() - 6..], &(1..=6).map(|i| Ipv4Addr::new(192, 168, 64, i)).collect::<Vec<_>>()[..]);

        let capped = subnet_candidate_ips(
            &[(Ipv4Addr::new(172, 16, 1, 5), 30), (Ipv4Addr::new(172, 16, 2, 5), 30), (Ipv4Addr::new(172, 16, 3, 5), 30)],
            2,
        );
        assert_eq!(capped, vec![Ipv4Addr::new(172, 16, 1, 5), Ipv4Addr::new(172, 16, 1, 6), Ipv4Addr::new(172, 16, 2, 5), Ipv4Addr::new(172, 16, 2, 6)]);
    }

    #[test]
    fn recognizes_ha_manifest_auth_providers_and_api_signatures() {
        assert!(is_home_assistant_manifest(br#"{"name":"Home Assistant","short_name":"Home Assistant"}"#));
        assert!(is_home_assistant_manifest(br#"{"name":"My Smart Home","start_url":"/?homescreen=1","icons":[{"src":"/static/icons/favicon-192x192.png"}]}"#));
        assert!(!is_home_assistant_manifest(br#"{"name":"Synology DiskStation"}"#));
        assert!(is_home_assistant_auth_providers(200, br#"[{"name":"Home Assistant Local","id":null,"type":"homeassistant"}]"#));
        assert!(!is_home_assistant_auth_providers(200, br#"[{"name":"OIDC","type":"oidc"}]"#));
        assert!(!is_home_assistant_auth_providers(404, br#"[{"name":"Home Assistant Local","type":"homeassistant"}]"#));

        let aiohttp_headers = HashMap::from([("server".to_string(), "Python/3.13 aiohttp/3.11.11".to_string())]);
        let nginx_headers = HashMap::from([("server".to_string(), "nginx/1.26.0".to_string())]);
        assert!(is_home_assistant_api_response(401, &aiohttp_headers, b"401: Unauthorized"));
        assert!(is_home_assistant_api_response(200, &HashMap::new(), br#"{"message":"API running."}"#));
        assert!(!is_home_assistant_api_response(401, &nginx_headers, b"401: Unauthorized"));
        assert!(!is_home_assistant_api_response(401, &aiohttp_headers, b"Forbidden"));
    }

    #[test]
    fn http_probe_recognizes_fallback_api_and_rejects_non_ha_server() {
        use std::io::{Read, Write};
        fn spawn_mock_server(handler: fn(&str) -> &'static str, count: usize) -> (SocketAddr, std::thread::JoinHandle<()>) {
            let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
            let addr = listener.local_addr().unwrap();
            let handle = std::thread::spawn(move || {
                for _ in 0..count {
                    let Ok((mut stream, _)) = listener.accept() else { break };
                    let mut buf = [0u8; 1024];
                    let n = stream.read(&mut buf).unwrap_or(0);
                    let path = std::str::from_utf8(&buf[..n]).unwrap_or("").split_whitespace().nth(1).unwrap_or("/");
                    let _ = stream.write_all(handler(path).as_bytes());
                }
            });
            (addr, handle)
        }
        let client = reqwest::Client::builder().no_proxy().redirect(reqwest::redirect::Policy::none()).build().unwrap();
        let (ha_addr, ha_handle) = spawn_mock_server(|path| match path {
            "/api/" => "HTTP/1.1 401 Unauthorized\r\nServer: Python/3.13 aiohttp/3.11\r\nContent-Length: 17\r\nConnection: close\r\n\r\n401: Unauthorized",
            _ => "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        }, 3);
        assert!(tauri::async_runtime::block_on(probe_ha_http_on_addr(&client, ha_addr, Instant::now() + Duration::from_secs(3))));
        let _ = ha_handle.join();

        let (other_addr, other_handle) = spawn_mock_server(|_| "HTTP/1.1 401 Unauthorized\r\nServer: nginx/1.26.0\r\nContent-Length: 17\r\nConnection: close\r\n\r\n401: Unauthorized", 3);
        assert!(!tauri::async_runtime::block_on(probe_ha_http_on_addr(&client, other_addr, Instant::now() + Duration::from_secs(3))));
        let _ = other_handle.join();
    }
}
