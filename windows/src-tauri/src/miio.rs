//! Windows native local miIO UDP (port 54321) transport, session manager,
//! bounded discovery waves (#444), and Tauri command handlers.
//!
//! Mirrors `Sources/MijiaCore/MiCloud/LocalMiIOClient.swift` (ADR-0021).

use crate::miio_crypto::{
    clean_malformed_firmware_json, decode_header, decode_packet, encode_packet,
    hello_checksum_verdict, is_private_rfc1918_ipv4, validate_token, HelloChecksumVerdict,
    MiIOCommandError, MiIOError, MiIOPacketHeader, DEFAULT_MAX_BATCH_SIZE, HELLO_PACKET,
    MIIO_HEADER_SIZE,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;
use tokio::sync::Mutex as AsyncMutex;

type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

const MIIO_PORT: u16 = 54321;
const REQUEST_TIMEOUT: Duration = Duration::from_millis(1200);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(1000);
const HANDSHAKE_TTL: Duration = Duration::from_secs(120);
const MAX_RETRIES: usize = 1;
const MAX_UNCLAIMED_PROBES_PER_CANDIDATE: usize = 24;
const MAX_TOTAL_UNCLAIMED_PROBES: usize = 64;
const MAX_DISCOVERY_DURATION: Duration = Duration::from_millis(2500);
const DEFAULT_BROADCAST_TIMEOUT: Duration = Duration::from_millis(650);
const DISCOVERY_CONCURRENCY: usize = 6;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MiIOBroadcastReply { pub(crate) source_ip: String, pub(crate) packet: Vec<u8> }

pub(crate) trait MiIOUdpTransport: Send + Sync {
    fn send(&self, packet: Vec<u8>, host: String, port: u16, timeout: Duration) -> BoxFuture<'_, Result<Vec<u8>, MiIOError>>;
    fn probe_broadcast(&self, packet: Vec<u8>, port: u16, timeout: Duration) -> BoxFuture<'_, Result<Vec<MiIOBroadcastReply>, MiIOError>>;
    fn shutdown(&self) -> BoxFuture<'_, ()>;
}

#[derive(Default)]
pub(crate) struct TokioMiIOUdpTransport { shut_down: AtomicBool }

impl MiIOUdpTransport for TokioMiIOUdpTransport {
    fn send(&self, packet: Vec<u8>, host: String, port: u16, timeout: Duration) -> BoxFuture<'_, Result<Vec<u8>, MiIOError>> {
        Box::pin(async move {
            if self.shut_down.load(Ordering::Acquire) { return Err(MiIOError::ShutDown); }
            let trimmed = host.trim();
            if !is_private_rfc1918_ipv4(trimmed) { return Err(MiIOError::InvalidAddress(host)); }
            let ip: Ipv4Addr = trimmed.parse().map_err(|_| MiIOError::InvalidAddress(host.clone()))?;
            let sock = UdpSocket::bind(SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)))
                .await.map_err(|_| MiIOError::TransportUnavailable)?;
            sock.connect(SocketAddr::V4(SocketAddrV4::new(ip, port))).await.map_err(|_| MiIOError::SendFailed)?;
            match tokio::time::timeout(timeout, sock.send(&packet)).await {
                Ok(Ok(n)) if n == packet.len() => {}
                _ => return Err(MiIOError::SendFailed),
            }
            let mut buf = vec![0u8; u16::MAX as usize];
            match tokio::time::timeout(timeout, sock.recv(&mut buf)).await {
                Ok(Ok(0)) => Err(MiIOError::MalformedPacket),
                Ok(Ok(n)) => { buf.truncate(n); Ok(buf) }
                _ => Err(MiIOError::Timeout),
            }
        })
    }

    fn probe_broadcast(&self, packet: Vec<u8>, port: u16, timeout: Duration) -> BoxFuture<'_, Result<Vec<MiIOBroadcastReply>, MiIOError>> {
        Box::pin(async move {
            if self.shut_down.load(Ordering::Acquire) { return Err(MiIOError::ShutDown); }
            let sock = UdpSocket::bind(SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)))
                .await.map_err(|_| MiIOError::TransportUnavailable)?;
            sock.set_broadcast(true).map_err(|_| MiIOError::TransportUnavailable)?;
            if sock.send_to(&packet, SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::BROADCAST, port))).await.is_err() {
                return Ok(Vec::new());
            }
            let deadline = Instant::now() + timeout.max(Duration::from_millis(1));
            let (mut replies, mut seen, mut buf) = (Vec::new(), HashSet::new(), vec![0u8; 2048]);
            while let Some(rem) = deadline.checked_duration_since(Instant::now()).filter(|d| !d.is_zero()) {
                match tokio::time::timeout(rem, sock.recv_from(&mut buf)).await {
                    Ok(Ok((n, SocketAddr::V4(src)))) => {
                        let ip = src.ip().to_string();
                        if n >= MIIO_HEADER_SIZE && is_private_rfc1918_ipv4(&ip) && seen.insert(ip.clone()) {
                            replies.push(MiIOBroadcastReply { source_ip: ip, packet: buf[..n].to_vec() });
                        }
                    }
                    Ok(Ok(_)) => continue,
                    _ => break,
                }
            }
            Ok(replies)
        })
    }

    fn shutdown(&self) -> BoxFuture<'_, ()> {
        self.shut_down.store(true, Ordering::Release);
        Box::pin(async {})
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct HardwareDeviceId { unknown: u32, device_id: u32 }

impl HardwareDeviceId {
    fn matches(&self, h: &MiIOPacketHeader) -> bool {
        h.device_id == self.device_id && (if h.unknown == u32::MAX { 0 } else { h.unknown }) == self.unknown
    }
}

#[derive(Clone)]
struct DeviceSession {
    ip: String, token: [u8; 16], unknown: u32, device_id32: u32,
    base_stamp: u32, handshake_at: Instant, last_sent_stamp: Option<u32>,
}

impl DeviceSession {
    fn next_stamp(&mut self, now: Instant) -> u32 {
        let elapsed = now.checked_duration_since(self.handshake_at).map_or(0, |d| d.as_secs().min(u32::MAX as u64) as u32);
        let computed = self.base_stamp.wrapping_add(elapsed);
        let stamp = match self.last_sent_stamp { Some(p) if computed <= p => p.wrapping_add(1), _ => computed };
        self.last_sent_stamp = Some(stamp);
        stamp
    }
}

#[derive(Default)]
struct ClientInner {
    sessions: HashMap<String, DeviceSession>,
    known_hardware_ids: HashMap<String, HardwareDeviceId>,
    last_rtt_ms: HashMap<String, u64>,
    did_locks: HashMap<String, Arc<AsyncMutex<()>>>,
}

pub(crate) struct MiIOClient {
    transport: Arc<dyn MiIOUdpTransport>,
    #[cfg(test)]
    wave_sleep_fn: Option<Arc<dyn Fn(Duration) -> BoxFuture<'static, ()> + Send + Sync>>,
    #[cfg(test)]
    on_probe_collected: Option<Arc<dyn Fn() + Send + Sync>>,
    next_request_id: AtomicU64,
    shut_down: AtomicBool,
    inner: Mutex<ClientInner>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOEndpointInput { pub(crate) did: String, pub(crate) ip: String, pub(crate) token: String }
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOPropKeyInput { pub(crate) did: String, pub(crate) siid: i64, pub(crate) piid: i64 }
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOPropWriteInput { pub(crate) did: String, pub(crate) siid: i64, pub(crate) piid: i64, pub(crate) value: Value }
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOActionCallInput { pub(crate) did: String, pub(crate) siid: i64, pub(crate) aiid: i64, pub(crate) inputs: Vec<Value> }
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIODiscoveryCandidateInput { pub(crate) did: String, pub(crate) token: String }

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOHandshakeOutput { pub(crate) device_id32: u32, pub(crate) device_stamp: u32, pub(crate) rtt_ms: Option<u64> }
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOPropValueOutput { pub(crate) did: String, pub(crate) siid: i64, pub(crate) piid: i64, pub(crate) value: Value }
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOGetPropsOutput { pub(crate) values: Vec<MiIOPropValueOutput>, pub(crate) rtt_ms: Option<u64> }
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOWriteOutput { pub(crate) rtt_ms: Option<u64> }
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOActionOutput { pub(crate) result: Value, pub(crate) rtt_ms: Option<u64> }

struct ParsedReply { source_ip: String, packet: Vec<u8>, header: MiIOPacketHeader }

#[derive(Clone)]
struct PreparedProbe {
    did: String, token: [u8; 16], source_ip: String, device_id: u32,
    resolved_unknown: u32, probe_stamp: u32, req_id: u64, probe_packet: Vec<u8>,
}

impl Default for MiIOClient {
    fn default() -> Self { Self::new(Arc::new(TokioMiIOUdpTransport::default())) }
}

impl MiIOClient {
    pub(crate) fn new(transport: Arc<dyn MiIOUdpTransport>) -> Self {
        Self {
            transport,
            #[cfg(test)]
            wave_sleep_fn: None,
            #[cfg(test)]
            on_probe_collected: None,
            next_request_id: AtomicU64::new(100),
            shut_down: AtomicBool::new(false),
            inner: Mutex::new(ClientInner::default()),
        }
    }

    fn lock_inner(&self) -> MutexGuard<'_, ClientInner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn allocate_request_id(&self) -> u64 {
        (self.next_request_id.fetch_add(1, Ordering::Relaxed) % 999_999_900) + 100
    }

    fn did_lock(&self, did: &str) -> Arc<AsyncMutex<()>> {
        self.lock_inner().did_locks.entry(did.to_string()).or_insert_with(|| Arc::new(AsyncMutex::new(()))).clone()
    }

    pub(crate) fn last_rtt_ms(&self, did: &str) -> Option<u64> {
        self.lock_inner().last_rtt_ms.get(did).copied()
    }

    pub(crate) async fn shutdown(&self) {
        if self.shut_down.swap(true, Ordering::AcqRel) { return; }
        {
            let mut g = self.lock_inner();
            g.sessions.clear(); g.known_hardware_ids.clear(); g.last_rtt_ms.clear(); g.did_locks.clear();
        }
        self.transport.shutdown().await;
    }

    fn validate_endpoint(ep: &MiIOEndpointInput) -> Result<([u8; 16], String), MiIOError> {
        let token = validate_token(&ep.token).ok_or(MiIOError::InvalidToken)?;
        let trimmed = ep.ip.trim();
        if !is_private_rfc1918_ipv4(trimmed) { return Err(MiIOError::InvalidAddress(ep.ip.clone())); }
        Ok((token, trimmed.to_string()))
    }

    pub(crate) async fn handshake(&self, ep: &MiIOEndpointInput) -> Result<MiIOHandshakeOutput, MiIOError> {
        let (token, host) = Self::validate_endpoint(ep)?;
        let lock = self.did_lock(&ep.did);
        let _g = lock.lock().await;
        let s = self.perform_handshake(&ep.did, &host, token).await?;
        Ok(MiIOHandshakeOutput { device_id32: s.device_id32, device_stamp: s.base_stamp, rtt_ms: self.last_rtt_ms(&ep.did) })
    }

    pub(crate) async fn get_props(&self, keys: &[MiIOPropKeyInput], ep: &MiIOEndpointInput) -> Result<MiIOGetPropsOutput, MiIOError> {
        if keys.is_empty() { return Ok(MiIOGetPropsOutput { values: Vec::new(), rtt_ms: self.last_rtt_ms(&ep.did) }); }
        let (token, host) = Self::validate_endpoint(ep)?;
        let lock = self.did_lock(&ep.did);
        let _g = lock.lock().await;
        let mut merged: HashMap<(String, i64, i64), Value> = HashMap::new();
        for chunk in keys.chunks(DEFAULT_MAX_BATCH_SIZE) {
            let params: Vec<Value> = chunk.iter().map(|k| json!({ "did": k.did, "siid": k.siid, "piid": k.piid })).collect();
            let result = self.send_with_retry(&ep.did, &host, token, "get_properties", Value::Array(params), true).await?;
            for item in parse_prop_values(&result, &ep.did) {
                merged.insert((item.did.clone(), item.siid, item.piid), item.value);
            }
        }
        let mut values: Vec<MiIOPropValueOutput> = merged.into_iter().map(|((did, siid, piid), value)| MiIOPropValueOutput { did, siid, piid, value }).collect();
        values.sort_by(|a, b| (&a.did, a.siid, a.piid).cmp(&(&b.did, b.siid, b.piid)));
        Ok(MiIOGetPropsOutput { values, rtt_ms: self.last_rtt_ms(&ep.did) })
    }

    pub(crate) async fn set_props(&self, writes: &[MiIOPropWriteInput], ep: &MiIOEndpointInput) -> Result<MiIOWriteOutput, MiIOError> {
        if writes.is_empty() { return Ok(MiIOWriteOutput { rtt_ms: self.last_rtt_ms(&ep.did) }); }
        let (token, host) = Self::validate_endpoint(ep).map_err(write_not_sent)?;
        let lock = self.did_lock(&ep.did);
        let _g = lock.lock().await;
        for (index, chunk) in writes.chunks(DEFAULT_MAX_BATCH_SIZE).enumerate() {
            let params: Vec<Value> = chunk.iter().map(|w| json!({ "did": w.did, "siid": w.siid, "piid": w.piid, "value": w.value })).collect();
            let acknowledgement = self.send_with_retry(&ep.did, &host, token, "set_properties", Value::Array(params), false).await
                .and_then(|result| check_property_acknowledgements(&result, chunk));
            if let Err(error) = acknowledgement {
                // Earlier chunks may already have changed the device, even if this chunk was never sent.
                if index > 0 || error == MiIOError::AmbiguousActionOutcome {
                    return Err(MiIOError::AmbiguousWriteOutcome);
                }
                return Err(error);
            }
        }
        Ok(MiIOWriteOutput { rtt_ms: self.last_rtt_ms(&ep.did) })
    }

    pub(crate) async fn call_action(&self, call: &MiIOActionCallInput, ep: &MiIOEndpointInput) -> Result<MiIOActionOutput, MiIOError> {
        let (token, host) = Self::validate_endpoint(ep).map_err(write_not_sent)?;
        let lock = self.did_lock(&ep.did);
        let _g = lock.lock().await;
        let params = json!({ "did": call.did, "siid": call.siid, "aiid": call.aiid, "in": call.inputs });
        let result = self.send_with_retry(&ep.did, &host, token, "action", params, false).await?;
        check_action_acknowledgement(&result, call)?;
        Ok(MiIOActionOutput { result, rtt_ms: self.last_rtt_ms(&ep.did) })
    }

    pub(crate) async fn discover_endpoints(
        &self,
        candidates: &[MiIODiscoveryCandidateInput],
        broadcast_timeout: Option<Duration>,
        excluded_ips: &HashSet<String>,
        known_numeric_dids: &HashSet<u64>,
    ) -> Result<HashMap<String, String>, MiIOError> {
        if self.shut_down.load(Ordering::Acquire) { return Err(MiIOError::ShutDown); }
        let mut seen_dids = HashSet::new();
        let valid_candidates: Vec<(String, [u8; 16])> = candidates.iter().filter_map(|c| {
            (!c.did.is_empty() && seen_dids.insert(c.did.clone())).then(|| validate_token(&c.token).map(|t| (c.did.clone(), t))).flatten()
        }).collect();
        if valid_candidates.is_empty() { return Ok(HashMap::new()); }

        let bcast_timeout = broadcast_timeout.unwrap_or(DEFAULT_BROADCAST_TIMEOUT).min(MAX_DISCOVERY_DURATION);
        let replies = self.transport.probe_broadcast(HELLO_PACKET.to_vec(), MIIO_PORT, bcast_timeout).await?;
        if self.shut_down.load(Ordering::Acquire) { return Err(MiIOError::ShutDown); }

        let mut seen_ips = HashSet::new();
        let parsed_replies: Vec<ParsedReply> = replies.into_iter().filter_map(|r| {
            let ip = r.source_ip.trim().to_string();
            if ip == "255.255.255.255" || !is_private_rfc1918_ipv4(&ip) || !seen_ips.insert(ip.clone()) { return None; }
            let header = decode_header(&r.packet).ok()?;
            (header.device_id != 0 && header.device_id != u32::MAX).then_some(ParsedReply { source_ip: ip, packet: r.packet, header })
        }).collect();
        if parsed_replies.is_empty() { return Ok(HashMap::new()); }

        let candidate_did_set: HashSet<String> = valid_candidates.iter().map(|(d, _)| d.clone()).collect();
        let mut discovered = HashMap::new();
        let mut claimed_ips: HashSet<String> = excluded_ips.iter().map(|s| s.trim().to_string()).filter(|s| is_private_rfc1918_ipv4(s)).collect();
        let probe_budget = MAX_DISCOVERY_DURATION.saturating_sub(bcast_timeout).max(HANDSHAKE_TIMEOUT.min(MAX_DISCOVERY_DURATION));
        let discovery_deadline = Instant::now() + probe_budget;

        let known_hw = self.lock_inner().known_hardware_ids.clone();
        let has_unresolved_non_numeric = valid_candidates.iter().any(|(d, _)| d.parse::<u64>().is_err() && !known_hw.contains_key(d));
        let reserved_budget = if has_unresolved_non_numeric { HANDSHAKE_TIMEOUT.min(probe_budget / 2) } else { Duration::ZERO };
        let reserved_probes = if has_unresolved_non_numeric { (MAX_TOTAL_UNCLAIMED_PROBES / 4).max(1) } else { 0 };
        let matching_cap = MAX_TOTAL_UNCLAIMED_PROBES.saturating_sub(reserved_probes).max(1);
        let matching_deadline = discovery_deadline.checked_sub(reserved_budget).unwrap_or_else(Instant::now);

        let (mut matching_queues, mut matching_tried, mut matching_candidates) = (HashMap::new(), HashMap::new(), Vec::new());
        for (did, tok) in &valid_candidates {
            let matching: Vec<usize> = parsed_replies.iter().enumerate().filter(|(_, r)| {
                !claimed_ips.contains(&r.source_ip)
                    && hello_checksum_verdict(&r.packet, tok) != HelloChecksumVerdict::Mismatch
                    && (known_hw.get(did).is_some_and(|hw| hw.matches(&r.header))
                        || did.parse::<u64>().is_ok_and(|d64| {
                            r.header.device_id64() == d64 || ((r.header.unknown == 0 || r.header.unknown == u32::MAX) && (d64 as u32) == r.header.device_id)
                        }))
            }).map(|(i, _)| i).collect();
            if !matching.is_empty() {
                matching_candidates.push((did.clone(), *tok));
                matching_queues.insert(did.clone(), matching);
                matching_tried.insert(did.clone(), HashSet::new());
            }
        }

        let mut total_launched = 0usize;
        if !matching_candidates.is_empty() {
            total_launched += self.run_bounded_probe_waves(
                &matching_candidates, &parsed_replies, &matching_queues, &mut matching_tried,
                &mut discovered, &mut claimed_ips, matching_cap, matching_deadline,
            ).await?;
        }

        let unresolved: Vec<(String, [u8; 16])> = valid_candidates.iter()
            .filter(|(d, _)| !discovered.contains_key(d) && d.parse::<u64>().is_err() && !known_hw.contains_key(d))
            .cloned().collect();
        if unresolved.is_empty() || total_launched >= MAX_TOTAL_UNCLAIMED_PROBES { return Ok(discovered); }

        let mut all_known_numeric = known_numeric_dids.clone();
        all_known_numeric.extend(valid_candidates.iter().filter_map(|(d, _)| d.parse::<u64>().ok()));
        let known_low32: HashSet<u32> = all_known_numeric.iter().map(|&n| n as u32).collect();
        let non_candidate_hws: Vec<HardwareDeviceId> = known_hw.iter()
            .filter(|(d, _)| !candidate_did_set.contains(*d) || discovered.contains_key(*d))
            .map(|(_, &hw)| hw).collect();
        let unclaimed: Vec<usize> = parsed_replies.iter().enumerate()
            .filter(|(_, r)| !claimed_ips.contains(&r.source_ip) && !non_candidate_hws.iter().any(|hw| hw.matches(&r.header)))
            .map(|(i, _)| i).collect();
        if unclaimed.is_empty() { return Ok(discovered); }

        let is_known_numeric = |h: &MiIOPacketHeader| {
            all_known_numeric.contains(&h.device_id64()) || ((h.unknown == 0 || h.unknown == u32::MAX) && known_low32.contains(&h.device_id))
        };
        let (mut queues, mut tried) = (HashMap::new(), HashMap::new());
        for (did, tok) in &unresolved {
            let (mut t0, mut t1, mut t2) = (Vec::new(), Vec::new(), Vec::new());
            for &idx in &unclaimed {
                match hello_checksum_verdict(&parsed_replies[idx].packet, tok) {
                    HelloChecksumVerdict::Mismatch => continue,
                    HelloChecksumVerdict::Md5Match | HelloChecksumVerdict::TokenEcho => t0.push(idx),
                    HelloChecksumVerdict::Inconclusive => {
                        if !is_known_numeric(&parsed_replies[idx].header) { t1.push(idx); } else { t2.push(idx); }
                    }
                }
            }
            t0.extend(t1); t0.extend(t2); t0.truncate(MAX_UNCLAIMED_PROBES_PER_CANDIDATE);
            queues.insert(did.clone(), t0);
            tried.insert(did.clone(), HashSet::new());
        }

        let _ = self.run_bounded_probe_waves(
            &unresolved, &parsed_replies, &queues, &mut tried, &mut discovered, &mut claimed_ips,
            MAX_TOTAL_UNCLAIMED_PROBES - total_launched, discovery_deadline.max(Instant::now() + reserved_budget),
        ).await?;
        Ok(discovered)
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_bounded_probe_waves(
        &self,
        candidates: &[(String, [u8; 16])],
        replies: &[ParsedReply],
        queues_by_did: &HashMap<String, Vec<usize>>,
        tried_by_did: &mut HashMap<String, HashSet<String>>,
        discovered: &mut HashMap<String, String>,
        claimed_ips: &mut HashSet<String>,
        max_total_probes: usize,
        deadline: Instant,
    ) -> Result<usize, MiIOError> {
        let (mut total_launched, mut round_robin_start) = (0usize, 0usize);
        while total_launched < max_total_probes {
            if self.shut_down.load(Ordering::Acquire) { return Err(MiIOError::ShutDown); }
            let Some(wave_budget) = deadline.checked_duration_since(Instant::now()).filter(|d| !d.is_zero()) else { break; };

            let active: Vec<&(String, [u8; 16])> = candidates.iter().filter(|(did, _)| {
                !discovered.contains_key(did) && queues_by_did.get(did).is_some_and(|q| {
                    let tried = tried_by_did.get(did);
                    q.iter().any(|&i| !claimed_ips.contains(&replies[i].source_ip) && !tried.is_some_and(|t| t.contains(&replies[i].source_ip)))
                })
            }).collect();
            if active.is_empty() { break; }

            let batch_limit = DISCOVERY_CONCURRENCY.min(max_total_probes - total_launched);
            let (mut batch, mut in_flight_ips, mut stale) = (Vec::new(), HashSet::new(), 0usize);
            let mut cursor = round_robin_start % active.len();
            while batch.len() < batch_limit && stale < active.len() {
                let (did, tok) = active[cursor];
                cursor = (cursor + 1) % active.len();
                let queue = queues_by_did.get(did).map(Vec::as_slice).unwrap_or(&[]);
                let tried = tried_by_did.entry(did.clone()).or_default();
                if let Some(&idx) = queue.iter().find(|&&i| {
                    let ip = &replies[i].source_ip;
                    !claimed_ips.contains(ip) && !tried.contains(ip) && !in_flight_ips.contains(ip)
                }) {
                    let r = &replies[idx];
                    tried.insert(r.source_ip.clone());
                    in_flight_ips.insert(r.source_ip.clone());
                    if let Ok(p) = self.prepare_broadcast_probe(did, *tok, &r.source_ip, &r.header) {
                        batch.push(p); total_launched += 1; stale = 0; continue;
                    }
                }
                stale += 1;
            }
            round_robin_start = round_robin_start.wrapping_add(1);
            if batch.is_empty() { break; }

            let per_probe_timeout = HANDSHAKE_TIMEOUT.min(wave_budget);
            enum Outcome { Response(PreparedProbe, Vec<u8>, u64), NoMatch, Fatal(MiIOError), Deadline }
            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Outcome>();
            let mut handles = Vec::with_capacity(batch.len() + 1);
            let mut awaited = batch.len();
            for probe in batch {
                let (transport, tx_p) = (self.transport.clone(), tx.clone());
                handles.push(tauri::async_runtime::spawn(async move {
                    let start = Instant::now();
                    let out = match transport.send(probe.probe_packet.clone(), probe.source_ip.clone(), MIIO_PORT, per_probe_timeout).await {
                        Ok(resp) => Outcome::Response(probe, resp, start.elapsed().as_millis().max(1) as u64),
                        Err(e @ (MiIOError::ShutDown | MiIOError::LocalNetworkDenied)) => Outcome::Fatal(e),
                        Err(_) => Outcome::NoMatch,
                    };
                    let _ = tx_p.send(out);
                }));
            }
            let tx_d = tx.clone();
            #[cfg(test)]
            let sleep_fut: BoxFuture<'static, ()> = match &self.wave_sleep_fn {
                Some(f) => f(wave_budget),
                None => Box::pin(tokio::time::sleep(wave_budget)),
            };
            #[cfg(not(test))]
            let sleep_fut = tokio::time::sleep(wave_budget);
            handles.push(tauri::async_runtime::spawn(async move { sleep_fut.await; let _ = tx_d.send(Outcome::Deadline); }));
            drop(tx);

            // #444: Keep every validated reply collected before the wave deadline fires;
            // only unresolved probes are aborted when the wave budget expires.
            let mut collected = Vec::new();
            while awaited > 0 {
                let Some(outcome) = rx.recv().await else { break; };
                match outcome {
                    Outcome::Fatal(err) => { for h in &handles { h.abort(); } return Err(err); }
                    Outcome::Response(p, resp, rtt) => {
                        collected.push((p, resp, rtt));
                        awaited -= 1;
                        #[cfg(test)]
                        if let Some(cb) = &self.on_probe_collected { cb(); }
                    }
                    Outcome::NoMatch => awaited -= 1,
                    Outcome::Deadline => {
                        for h in &handles { h.abort(); }
                        while let Ok(extra) = rx.try_recv() {
                            if let Outcome::Response(p, resp, rtt) = extra { collected.push((p, resp, rtt)); }
                        }
                        break;
                    }
                }
            }
            for h in &handles { h.abort(); }
            if self.shut_down.load(Ordering::Acquire) { return Err(MiIOError::ShutDown); }
            for (probe, resp, rtt) in collected {
                if !discovered.contains_key(&probe.did) && !claimed_ips.contains(&probe.source_ip)
                    && self.accept_verified_broadcast_response(&probe, &resp, rtt)
                {
                    discovered.insert(probe.did, probe.source_ip.clone());
                    claimed_ips.insert(probe.source_ip);
                }
            }
        }
        Ok(total_launched)
    }

    fn prepare_broadcast_probe(&self, did: &str, token: [u8; 16], source_ip: &str, h: &MiIOPacketHeader) -> Result<PreparedProbe, MiIOError> {
        let req_id = self.allocate_request_id();
        let resolved_unknown = if h.unknown == u32::MAX { 0 } else { h.unknown };
        let probe_stamp = h.stamp.wrapping_add(1);
        let payload = serde_json::to_vec(&json!({ "id": req_id, "method": "get_properties", "params": [{ "did": did, "siid": 1, "piid": 1 }] }))
            .map_err(|_| MiIOError::EncryptionFailed)?;
        let probe_packet = encode_packet(h.device_id, probe_stamp, &token, &payload, resolved_unknown)?;
        Ok(PreparedProbe { did: did.to_string(), token, source_ip: source_ip.to_string(), device_id: h.device_id, resolved_unknown, probe_stamp, req_id, probe_packet })
    }

    fn accept_verified_broadcast_response(&self, p: &PreparedProbe, resp_pkt: &[u8], rtt_ms: u64) -> bool {
        let Ok((hdr, pt)) = decode_packet(resp_pkt, &p.token) else { return false; };
        let Ok(raw) = String::from_utf8(pt) else { return false; };
        let Ok(decoded) = serde_json::from_str::<Value>(&clean_malformed_firmware_json(&raw)) else { return false; };
        if decoded.get("id").and_then(Value::as_u64) != Some(p.req_id) { return false; }
        let mut g = self.lock_inner();
        g.last_rtt_ms.insert(p.did.clone(), rtt_ms);
        g.known_hardware_ids.insert(p.did.clone(), HardwareDeviceId { unknown: p.resolved_unknown, device_id: p.device_id });
        g.sessions.insert(p.did.clone(), DeviceSession {
            ip: p.source_ip.clone(), token: p.token, unknown: p.resolved_unknown, device_id32: p.device_id,
            base_stamp: hdr.stamp, handshake_at: Instant::now(), last_sent_stamp: Some(p.probe_stamp),
        });
        true
    }

    async fn ensure_session(&self, did: &str, host: &str, token: [u8; 16]) -> Result<DeviceSession, MiIOError> {
        let now = Instant::now();
        if let Some(s) = self.lock_inner().sessions.get(did) {
            if s.ip == host && s.token == token && now.checked_duration_since(s.handshake_at).is_some_and(|age| age < HANDSHAKE_TTL) {
                return Ok(s.clone());
            }
        }
        self.perform_handshake(did, host, token).await
    }

    async fn perform_handshake(&self, did: &str, host: &str, token: [u8; 16]) -> Result<DeviceSession, MiIOError> {
        if self.shut_down.load(Ordering::Acquire) { return Err(MiIOError::ShutDown); }
        let start = Instant::now();
        let resp = self.transport.send(HELLO_PACKET.to_vec(), host.to_string(), MIIO_PORT, HANDSHAKE_TIMEOUT).await
            .map_err(|e| if e.proves_packet_crossed_permission_boundary() { MiIOError::HandshakeFailed } else { e })?;
        if self.shut_down.load(Ordering::Acquire) { return Err(MiIOError::ShutDown); }
        let rtt = start.elapsed().as_millis().max(1) as u64;
        let hdr = decode_header(&resp)?;
        let (unknown, device_id32) = if hdr.device_id != 0 && hdr.device_id != u32::MAX {
            (if hdr.unknown == u32::MAX { 0 } else { hdr.unknown }, hdr.device_id)
        } else if let Ok(d32) = did.parse::<u32>() { (0, d32) }
        else if let Ok(d64) = did.parse::<u64>() { ((d64 >> 32) as u32, d64 as u32) }
        else if let Some(hw) = self.lock_inner().known_hardware_ids.get(did).copied() { (hw.unknown, hw.device_id) }
        else { return Err(MiIOError::UnsupportedNonNumericDeviceId); };

        let session = DeviceSession {
            ip: host.to_string(), token, unknown, device_id32,
            base_stamp: hdr.stamp, handshake_at: Instant::now(), last_sent_stamp: None,
        };
        let mut g = self.lock_inner();
        g.last_rtt_ms.insert(did.to_string(), rtt);
        g.sessions.insert(did.to_string(), session.clone());
        Ok(session)
    }

    async fn send_with_retry(&self, did: &str, host: &str, token: [u8; 16], method: &str, params: Value, allow_post_send_retry: bool) -> Result<Value, MiIOError> {
        let mut last_err = MiIOError::Timeout;
        for attempt in 0..=MAX_RETRIES {
            if self.shut_down.load(Ordering::Acquire) { return Err(MiIOError::ShutDown); }
            match self.send_once(did, host, token, method, &params, allow_post_send_retry).await {
                Ok(val) => return Ok(val),
                Err(err) => {
                    self.lock_inner().sessions.remove(did);
                    let retryable = err.is_retryable() && attempt < MAX_RETRIES;
                    last_err = err;
                    if !retryable { return Err(last_err); }
                }
            }
        }
        Err(last_err)
    }

    async fn send_once(&self, did: &str, host: &str, token: [u8; 16], method: &str, params: &Value, allow_post_send_retry: bool) -> Result<Value, MiIOError> {
        let pre_send_error = |error| {
            if allow_post_send_retry { error } else { write_not_sent(error) }
        };
        let mut session = self.ensure_session(did, host, token).await.map_err(pre_send_error)?;
        let stamp = session.next_stamp(Instant::now());
        self.lock_inner().sessions.insert(did.to_string(), session.clone());

        let req_id = self.allocate_request_id();
        let payload = serde_json::to_vec(&json!({ "id": req_id, "method": method, "params": params })).map_err(|_| pre_send_error(MiIOError::EncryptionFailed))?;
        let packet = encode_packet(session.device_id32, stamp, &token, &payload, session.unknown)
            .map_err(pre_send_error)?;
        let send_start = Instant::now();
        let json: Value = match self.transport.send(packet, host.to_string(), MIIO_PORT, REQUEST_TIMEOUT).await.and_then(|resp| {
            let rtt = send_start.elapsed().as_millis().max(1) as u64;
            if !self.shut_down.load(Ordering::Acquire) { self.lock_inner().last_rtt_ms.insert(did.to_string(), rtt); }
            let (_, pt) = decode_packet(&resp, &token)?;
            let raw = String::from_utf8(pt).map_err(|_| MiIOError::MalformedPacket)?;
            let cleaned = clean_malformed_firmware_json(&raw);
            if cleaned.is_empty() { return Err(MiIOError::MalformedPacket); }
            serde_json::from_str::<Value>(&cleaned).map_err(|_| MiIOError::MalformedPacket)
        }) {
            Ok(val) => val,
            Err(err) => {
                if err == MiIOError::LocalNetworkDenied { self.lock_inner().sessions.remove(did); }
                if !allow_post_send_retry {
                    if matches!(err, MiIOError::TransportUnavailable | MiIOError::LocalNetworkDenied | MiIOError::SendFailed | MiIOError::ShutDown) {
                        return Err(write_not_sent(err));
                    }
                    self.lock_inner().sessions.remove(did);
                    return Err(MiIOError::AmbiguousActionOutcome);
                }
                return Err(err);
            }
        };

        if json.get("id").and_then(Value::as_u64) != Some(req_id) {
            if !allow_post_send_retry {
                self.lock_inner().sessions.remove(did);
                return Err(MiIOError::AmbiguousActionOutcome);
            }
            return Err(MiIOError::MalformedPacket);
        }
        if !self.shut_down.load(Ordering::Acquire) {
            self.lock_inner().known_hardware_ids.insert(did.to_string(), HardwareDeviceId { unknown: session.unknown, device_id: session.device_id32 });
        }
        if let Some(err_obj) = json.get("error").and_then(Value::as_object) {
            let code = err_obj.get("code").and_then(Value::as_i64).unwrap_or(-1);
            return Err(device_rejected(code));
        }
        Ok(json.get("result").cloned().unwrap_or(Value::Null))
    }
}

fn parse_prop_values(result: &Value, default_did: &str) -> Vec<MiIOPropValueOutput> {
    let Some(items) = result.as_array() else { return Vec::new(); };
    items.iter().filter_map(|item| {
        let obj = item.as_object()?;
        let did = match obj.get("did") {
            Some(Value::String(s)) if !s.is_empty() => s.clone(),
            Some(Value::Number(n)) => n.to_string(),
            _ => default_did.to_string(),
        };
        let (siid, piid) = (obj.get("siid")?.as_i64()?, obj.get("piid")?.as_i64()?);
        if obj.get("code").and_then(Value::as_i64).is_some_and(|c| c != 0) { return None; }
        let value = obj.get("value").filter(|v| !v.is_null())?.clone();
        Some(MiIOPropValueOutput { did, siid, piid, value })
    }).collect()
}

fn write_not_sent(error: MiIOError) -> MiIOError {
    if error == MiIOError::ShutDown {
        error
    } else {
        MiIOError::WriteNotSent(Box::new(error))
    }
}

fn device_rejected(code: i64) -> MiIOError {
    MiIOError::DeviceError { code, message: "Device rejected the local request".into() }
}

fn check_property_acknowledgements(result: &Value, writes: &[MiIOPropWriteInput]) -> Result<(), MiIOError> {
    let unknown = MiIOError::AmbiguousWriteOutcome;
    let items = result.as_array().filter(|items| !items.is_empty() && items.len() == writes.len())
        .ok_or(unknown.clone())?;
    let mut acknowledged = HashSet::new();
    let mut rejection = None;
    let mut accepted = false;
    for (index, item) in items.iter().enumerate() {
        let code = item.get("code").and_then(Value::as_i64).ok_or(unknown.clone())?;
        let matched = match (item.get("siid"), item.get("piid")) {
            (Some(siid), Some(piid)) => writes.iter().position(|write| {
                Some(write.siid) == siid.as_i64() && Some(write.piid) == piid.as_i64()
                    && ack_did_matches(item, &write.did)
            }).ok_or(unknown.clone())?,
            (None, None) if ack_did_matches(item, &writes[index].did) => index,
            _ => return Err(unknown),
        };
        if !acknowledged.insert(matched) { return Err(unknown); }
        if code < 0 { rejection.get_or_insert(code); } else { accepted = true; }
    }
    match rejection {
        Some(_) if accepted => Err(unknown),
        Some(code) => Err(device_rejected(code)),
        None => Ok(()),
    }
}

fn ack_did_matches(item: &Value, did: &str) -> bool {
    match item.get("did") {
        None => true,
        Some(Value::String(value)) => value == did,
        Some(Value::Number(value)) => value.to_string() == did,
        _ => false,
    }
}

fn check_action_acknowledgement(result: &Value, call: &MiIOActionCallInput) -> Result<(), MiIOError> {
    let unknown = MiIOError::AmbiguousActionOutcome;
    let item = match result.as_array() {
        Some(items) if items.len() == 1 => &items[0],
        Some(_) => return Err(unknown),
        None => result,
    };
    let fields = item.as_object().ok_or(unknown.clone())?;
    if !ack_did_matches(item, &call.did)
        || fields.get("siid").is_some_and(|siid| siid.as_i64() != Some(call.siid))
        || fields.get("aiid").is_some_and(|aiid| aiid.as_i64() != Some(call.aiid))
    {
        return Err(unknown);
    }
    match fields.get("code") {
        Some(code) => match code.as_i64() {
            Some(code) if code < 0 => Err(device_rejected(code)),
            Some(_) => Ok(()),
            None => Err(unknown),
        },
        None if fields.get("out").and_then(Value::as_array).is_some_and(|out| !out.is_empty())
            || contains_stream_url(item) => Ok(()),
        None => Err(unknown),
    }
}

fn contains_stream_url(value: &Value) -> bool {
    match value {
        Value::String(value) => {
            let value = value.trim();
            value.split_once("://").is_some_and(|(scheme, _)| {
                (scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https"))
                    && reqwest::Url::parse(value).is_ok_and(|url| url.has_host())
            })
        }
        Value::Array(items) => items.iter().any(contains_stream_url),
        Value::Object(fields) => fields.values().any(contains_stream_url),
        _ => false,
    }
}

// MARK: - Tauri State & Commands

#[derive(Default)]
pub(crate) struct MiIOState { client: Arc<MiIOClient> }

#[tauri::command]
pub(crate) async fn miio_handshake(state: tauri::State<'_, MiIOState>, endpoint: MiIOEndpointInput) -> Result<MiIOHandshakeOutput, MiIOCommandError> {
    state.client.handshake(&endpoint).await.map_err(|e| e.to_command_error())
}
#[tauri::command]
pub(crate) async fn miio_get_props(state: tauri::State<'_, MiIOState>, keys: Vec<MiIOPropKeyInput>, endpoint: MiIOEndpointInput) -> Result<MiIOGetPropsOutput, MiIOCommandError> {
    state.client.get_props(&keys, &endpoint).await.map_err(|e| e.to_command_error())
}
#[tauri::command]
pub(crate) async fn miio_set_props(state: tauri::State<'_, MiIOState>, writes: Vec<MiIOPropWriteInput>, endpoint: MiIOEndpointInput) -> Result<MiIOWriteOutput, MiIOCommandError> {
    state.client.set_props(&writes, &endpoint).await.map_err(|e| e.to_command_error())
}
#[tauri::command]
pub(crate) async fn miio_call_action(state: tauri::State<'_, MiIOState>, call: MiIOActionCallInput, endpoint: MiIOEndpointInput) -> Result<MiIOActionOutput, MiIOCommandError> {
    state.client.call_action(&call, &endpoint).await.map_err(|e| e.to_command_error())
}
#[tauri::command]
pub(crate) async fn miio_discover(
    state: tauri::State<'_, MiIOState>,
    candidates: Vec<MiIODiscoveryCandidateInput>,
    broadcast_timeout_ms: Option<u64>,
    excluded_ips: Option<Vec<String>>,
    known_numeric_dids: Option<Vec<String>>,
) -> Result<HashMap<String, String>, MiIOCommandError> {
    let excluded: HashSet<String> = excluded_ips.unwrap_or_default().into_iter().collect();
    let numeric: HashSet<u64> = known_numeric_dids.unwrap_or_default().into_iter().filter_map(|s| s.parse().ok()).collect();
    state.client.discover_endpoints(&candidates, broadcast_timeout_ms.map(Duration::from_millis), &excluded, &numeric).await.map_err(|e| e.to_command_error())
}
#[tauri::command]
pub(crate) async fn miio_shutdown(state: tauri::State<'_, MiIOState>) -> Result<(), String> {
    state.client.shutdown().await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct MockTransport {
        send_fn: Box<dyn Fn(Vec<u8>, String, u16, Duration) -> BoxFuture<'static, Result<Vec<u8>, MiIOError>> + Send + Sync>,
        bcast_fn: Box<dyn Fn(Vec<u8>, u16, Duration) -> BoxFuture<'static, Result<Vec<MiIOBroadcastReply>, MiIOError>> + Send + Sync>,
    }

    impl MiIOUdpTransport for MockTransport {
        fn send(&self, p: Vec<u8>, h: String, port: u16, t: Duration) -> BoxFuture<'_, Result<Vec<u8>, MiIOError>> { (self.send_fn)(p, h, port, t) }
        fn probe_broadcast(&self, p: Vec<u8>, port: u16, t: Duration) -> BoxFuture<'_, Result<Vec<MiIOBroadcastReply>, MiIOError>> { (self.bcast_fn)(p, port, t) }
        fn shutdown(&self) -> BoxFuture<'_, ()> { Box::pin(async {}) }
    }

    fn hello_reply(device_id: u32, stamp: u32, token: &[u8; 16]) -> Vec<u8> {
        encode_packet(device_id, stamp, token, &[], 0).unwrap()
    }

    #[test]
    fn rejects_non_private_endpoints_and_never_leaks_token() {
        let tok = "0123456789abcdef0123456789abcdef";
        let client = MiIOClient::default();
        for bad_ip in ["8.8.8.8", "127.0.0.1", "169.254.1.2", "device.lan"] {
            let ep = MiIOEndpointInput { did: "1001".into(), ip: bad_ip.into(), token: tok.into() };
            let err = tauri::async_runtime::block_on(client.handshake(&ep)).unwrap_err();
            assert_eq!(err.code(), "invalid_address");
            assert!(!err.to_string().contains(tok));
        }
    }

    #[test]
    fn action_post_send_timeout_returns_ambiguous_without_retry() {
        let tok_hex = "0123456789abcdef0123456789abcdef";
        let tok = validate_token(tok_hex).unwrap();
        let sends = Arc::new(AtomicU64::new(0));
        let sends_c = sends.clone();
        let client = MiIOClient::new(Arc::new(MockTransport {
            send_fn: Box::new(move |pkt, _, _, _| {
                let n = sends_c.fetch_add(1, Ordering::SeqCst);
                Box::pin(async move {
                    if pkt == HELLO_PACKET { return Ok(hello_reply(1001, 50, &tok)); }
                    assert_eq!(n, 1, "action must not be retried after send");
                    Err(MiIOError::Timeout)
                })
            }),
            bcast_fn: Box::new(|_, _, _| Box::pin(async { Ok(vec![]) })),
        }));
        let ep = MiIOEndpointInput { did: "1001".into(), ip: "192.168.1.20".into(), token: tok_hex.into() };
        let call = MiIOActionCallInput { did: "1001".into(), siid: 2, aiid: 1, inputs: vec![] };
        assert_eq!(tauri::async_runtime::block_on(client.call_action(&call, &ep)).unwrap_err(), MiIOError::AmbiguousActionOutcome);
        assert_eq!(sends.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn missing_or_nonnumeric_response_id_is_rejected() {
        let tok_hex = "0123456789abcdef0123456789abcdef";
        let tok = validate_token(tok_hex).unwrap();
        let client = MiIOClient::new(Arc::new(MockTransport {
            send_fn: Box::new(move |pkt, _, _, _| {
                Box::pin(async move {
                    if pkt == HELLO_PACKET { return Ok(hello_reply(1001, 50, &tok)); }
                    let (hdr, _) = decode_packet(&pkt, &tok).unwrap();
                    let resp = serde_json::to_vec(&json!({ "id": null, "result": [{ "code": 0 }] })).unwrap();
                    Ok(encode_packet(hdr.device_id, hdr.stamp + 1, &tok, &resp, 0).unwrap())
                })
            }),
            bcast_fn: Box::new(|_, _, _| Box::pin(async { Ok(vec![]) })),
        }));
        let ep = MiIOEndpointInput { did: "1001".into(), ip: "192.168.1.20".into(), token: tok_hex.into() };
        assert_eq!(tauri::async_runtime::block_on(client.call_action(&MiIOActionCallInput { did: "1001".into(), siid: 2, aiid: 1, inputs: vec![] }, &ep)).unwrap_err(), MiIOError::AmbiguousActionOutcome);
        assert_eq!(tauri::async_runtime::block_on(client.get_props(&[MiIOPropKeyInput { did: "1001".into(), siid: 2, piid: 1 }], &ep)).unwrap_err(), MiIOError::MalformedPacket);
    }

    #[test]
    fn property_writes_need_one_explicit_code_per_requested_property() {
        let writes = [1, 2].map(|piid| MiIOPropWriteInput {
            did: "1001".into(), siid: 2, piid, value: json!(true),
        });
        for result in [
            Value::Null,
            json!({}),
            json!([]),
            json!([{ "code": 0 }]),
            json!([{ "code": 0 }, {}]),
            json!([{ "code": 0 }, { "code": 0.5 }]),
            json!([{ "code": 0 }, { "code": -1 }]),
            json!([{ "siid": 2, "piid": 1, "code": 0 }, { "siid": 2, "piid": 1, "code": 0 }]),
            json!([{ "siid": 2, "piid": 1, "code": 0 }, { "did": "other", "siid": 2, "piid": 2, "code": 0 }]),
        ] {
            assert_eq!(check_property_acknowledgements(&result, &writes), Err(MiIOError::AmbiguousWriteOutcome));
        }
        assert_eq!(check_property_acknowledgements(&json!([{ "code": -1 }, { "code": -2 }]), &writes), Err(device_rejected(-1)));
        assert_eq!(check_property_acknowledgements(&json!([
            { "did": 1001, "siid": 2, "piid": 2, "code": 0 },
            { "did": "1001", "siid": 2, "piid": 1, "code": 1 },
        ]), &writes), Ok(()));
    }

    #[test]
    fn actions_require_explicit_code_or_output() {
        let call = MiIOActionCallInput { did: "1001".into(), siid: 2, aiid: 1, inputs: vec![] };
        for result in [Value::Null, json!([]), json!({}), json!([{}]), json!({ "out": [] }),
            json!({ "code": null, "out": [1] }), json!({ "code": 0.5 }),
            json!({ "message": "offline http://device/stream" }), json!({ "aiid": 2, "code": 0 })] {
            assert_eq!(check_action_acknowledgement(&result, &call), Err(MiIOError::AmbiguousActionOutcome));
        }
        for result in [json!({ "code": 0 }), json!([{ "code": 0 }]), json!({ "out": [1] }),
            json!({ "out": { "url": "https://device/stream" } })] {
            assert_eq!(check_action_acknowledgement(&result, &call), Ok(()));
        }
        assert_eq!(check_action_acknowledgement(&json!({ "code": -1, "out": [1] }), &call), Err(device_rejected(-1)));
    }

    #[test]
    fn property_timeout_after_send_is_not_retried() {
        let token = "0123456789abcdef0123456789abcdef";
        let tok = validate_token(token).unwrap();
        let sends = Arc::new(AtomicU64::new(0));
        let sends_c = sends.clone();
        let client = MiIOClient::new(Arc::new(MockTransport {
            send_fn: Box::new(move |packet, _, _, _| {
                sends_c.fetch_add(1, Ordering::SeqCst);
                Box::pin(async move {
                    if packet == HELLO_PACKET { return Ok(hello_reply(1001, 50, &tok)); }
                    Err(MiIOError::Timeout)
                })
            }),
            bcast_fn: Box::new(|_, _, _| Box::pin(async { Ok(vec![]) })),
        }));
        let endpoint = MiIOEndpointInput { did: "1001".into(), ip: "192.168.1.20".into(), token: token.into() };
        let writes = [MiIOPropWriteInput { did: "1001".into(), siid: 2, piid: 1, value: json!(true) }];
        assert_eq!(tauri::async_runtime::block_on(client.set_props(&writes, &endpoint)).unwrap_err(), MiIOError::AmbiguousWriteOutcome);
        assert_eq!(sends.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn later_chunk_send_failure_cannot_replay_an_acknowledged_chunk() {
        let token = "0123456789abcdef0123456789abcdef";
        let tok = validate_token(token).unwrap();
        let sends = AtomicU64::new(0);
        let client = MiIOClient::new(Arc::new(MockTransport {
            send_fn: Box::new(move |packet, _, _, _| {
                let n = sends.fetch_add(1, Ordering::SeqCst);
                Box::pin(async move {
                    if packet == HELLO_PACKET { return Ok(hello_reply(1001, 50, &tok)); }
                    if n > 1 { return Err(MiIOError::SendFailed); }
                    let (hdr, payload) = decode_packet(&packet, &tok).unwrap();
                    let req: Value = serde_json::from_slice(&payload).unwrap();
                    let rows = vec![json!({ "code": 0 }); DEFAULT_MAX_BATCH_SIZE];
                    let reply = serde_json::to_vec(&json!({ "id": req["id"], "result": rows })).unwrap();
                    encode_packet(hdr.device_id, hdr.stamp + 1, &tok, &reply, 0)
                })
            }),
            bcast_fn: Box::new(|_, _, _| Box::pin(async { Ok(vec![]) })),
        }));
        let endpoint = MiIOEndpointInput { did: "1001".into(), ip: "192.168.1.20".into(), token: token.into() };
        let writes: Vec<_> = (1..=DEFAULT_MAX_BATCH_SIZE as i64 + 1).map(|piid| MiIOPropWriteInput {
            did: "1001".into(), siid: 2, piid, value: json!(true),
        }).collect();
        assert_eq!(tauri::async_runtime::block_on(client.set_props(&writes, &endpoint)).unwrap_err(), MiIOError::AmbiguousWriteOutcome);
    }

    #[test]
    fn handshake_timeout_is_a_write_not_sent() {
        let client = MiIOClient::new(Arc::new(MockTransport {
            send_fn: Box::new(move |packet, _, _, _| {
                assert_eq!(packet, HELLO_PACKET);
                Box::pin(async { Err(MiIOError::Timeout) })
            }),
            bcast_fn: Box::new(|_, _, _| Box::pin(async { Ok(vec![]) })),
        }));
        let endpoint = MiIOEndpointInput {
            did: "1001".into(), ip: "192.168.1.20".into(), token: "0123456789abcdef0123456789abcdef".into(),
        };
        let call = MiIOActionCallInput { did: "1001".into(), siid: 2, aiid: 1, inputs: vec![] };
        let error = tauri::async_runtime::block_on(client.call_action(&call, &endpoint)).unwrap_err();
        assert_eq!(error.to_command_error().code, "write_not_sent");
    }

    #[test]
    fn discovery_keeps_validated_replies_when_wave_times_out_444() {
        let (tok_a_hex, tok_b_hex) = ("0123456789abcdef0123456789abcdef", "deadbeefcafebabe1122334455667788");
        let (tok_a, tok_b) = (validate_token(tok_a_hex).unwrap(), validate_token(tok_b_hex).unwrap());
        let fast_collected = Arc::new(tokio::sync::Notify::new());
        let fast_cb = fast_collected.clone();
        let mut client = MiIOClient::new(Arc::new(MockTransport {
            send_fn: Box::new(move |pkt, host, _, _| {
                Box::pin(async move {
                    if host == "192.168.1.10" {
                        let (hdr, pt) = decode_packet(&pkt, &tok_a).unwrap();
                        let req: Value = serde_json::from_slice(&pt).unwrap();
                        let resp = serde_json::to_vec(&json!({ "id": req["id"], "result": [] })).unwrap();
                        return Ok(encode_packet(hdr.device_id, hdr.stamp + 1, &tok_a, &resp, 0).unwrap());
                    }
                    std::future::pending::<Result<Vec<u8>, MiIOError>>().await
                })
            }),
            bcast_fn: Box::new(move |_, _, _| {
                let r1 = MiIOBroadcastReply { source_ip: "192.168.1.10".into(), packet: hello_reply(1001, 10, &tok_a) };
                let r2 = MiIOBroadcastReply { source_ip: "192.168.1.11".into(), packet: hello_reply(2002, 10, &tok_b) };
                Box::pin(async move { Ok(vec![r1, r2]) })
            }),
        }));
        client.on_probe_collected = Some(Arc::new(move || fast_cb.notify_one()));
        client.wave_sleep_fn = Some(Arc::new(move |_| {
            let n = fast_collected.clone();
            Box::pin(async move { n.notified().await; })
        }));
        let discovered = tauri::async_runtime::block_on(client.discover_endpoints(
            &[
                MiIODiscoveryCandidateInput { did: "1001".into(), token: tok_a_hex.into() },
                MiIODiscoveryCandidateInput { did: "2002".into(), token: tok_b_hex.into() },
            ],
            Some(Duration::from_millis(10)),
            &HashSet::new(),
            &HashSet::new(),
        )).unwrap();
        assert_eq!(discovered.get("1001").map(String::as_str), Some("192.168.1.10"));
        assert!(!discovered.contains_key("2002"));
    }
}
