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
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;
use tokio::sync::Mutex as AsyncMutex;

type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

const DEFAULT_PORT: u16 = 54321;
const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_millis(1200);
const DEFAULT_HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(1000);
const DEFAULT_HANDSHAKE_TTL: Duration = Duration::from_secs(120);
const DEFAULT_MAX_RETRIES: usize = 1;
const DEFAULT_MAX_UNCLAIMED_PROBES_PER_CANDIDATE: usize = 24;
const DEFAULT_MAX_TOTAL_UNCLAIMED_PROBES: usize = 64;
const DEFAULT_MAX_DISCOVERY_DURATION: Duration = Duration::from_millis(2500);
const DEFAULT_BROADCAST_TIMEOUT: Duration = Duration::from_millis(650);
const DEFAULT_DISCOVERY_CONCURRENCY: usize = 6;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MiIOBroadcastReply {
    pub(crate) source_ip: String,
    pub(crate) packet: Vec<u8>,
}

pub(crate) trait MiIOUdpTransport: Send + Sync {
    fn send(
        &self,
        packet: Vec<u8>,
        host: String,
        port: u16,
        timeout: Duration,
    ) -> BoxFuture<'_, Result<Vec<u8>, MiIOError>>;

    fn probe_broadcast(
        &self,
        packet: Vec<u8>,
        port: u16,
        timeout: Duration,
    ) -> BoxFuture<'_, Result<Vec<MiIOBroadcastReply>, MiIOError>>;

    fn shutdown(&self) -> BoxFuture<'_, ()>;
}

pub(crate) struct TokioMiIOUdpTransport {
    shut_down: AtomicBool,
}

impl Default for TokioMiIOUdpTransport {
    fn default() -> Self {
        Self { shut_down: AtomicBool::new(false) }
    }
}

impl MiIOUdpTransport for TokioMiIOUdpTransport {
    fn send(
        &self,
        packet: Vec<u8>,
        host: String,
        port: u16,
        timeout: Duration,
    ) -> BoxFuture<'_, Result<Vec<u8>, MiIOError>> {
        Box::pin(async move {
            if self.shut_down.load(Ordering::Acquire) {
                return Err(MiIOError::ShutDown);
            }
            let trimmed = host.trim();
            if !is_private_rfc1918_ipv4(trimmed) {
                return Err(MiIOError::InvalidAddress(host));
            }
            let ip: Ipv4Addr = trimmed
                .parse()
                .map_err(|_| MiIOError::InvalidAddress(host.clone()))?;
            let target = SocketAddr::V4(SocketAddrV4::new(ip, port));

            let socket = UdpSocket::bind(SocketAddr::V4(SocketAddrV4::new(
                Ipv4Addr::UNSPECIFIED,
                0,
            )))
            .await
            .map_err(|_| MiIOError::TransportUnavailable)?;
            socket.connect(target).await.map_err(|_| MiIOError::SendFailed)?;

            match tokio::time::timeout(timeout, socket.send(&packet)).await {
                Ok(Ok(n)) if n == packet.len() => {}
                Ok(Ok(_)) | Ok(Err(_)) | Err(_) => return Err(MiIOError::SendFailed),
            }

            let mut buf = vec![0u8; 4096];
            match tokio::time::timeout(timeout, socket.recv(&mut buf)).await {
                Ok(Ok(0)) => Err(MiIOError::MalformedPacket),
                Ok(Ok(n)) => {
                    buf.truncate(n);
                    Ok(buf)
                }
                Ok(Err(_)) | Err(_) => Err(MiIOError::Timeout),
            }
        })
    }

    fn probe_broadcast(
        &self,
        packet: Vec<u8>,
        port: u16,
        timeout: Duration,
    ) -> BoxFuture<'_, Result<Vec<MiIOBroadcastReply>, MiIOError>> {
        Box::pin(async move {
            if self.shut_down.load(Ordering::Acquire) {
                return Err(MiIOError::ShutDown);
            }
            let socket = UdpSocket::bind(SocketAddr::V4(SocketAddrV4::new(
                Ipv4Addr::UNSPECIFIED,
                0,
            )))
            .await
            .map_err(|_| MiIOError::TransportUnavailable)?;
            socket
                .set_broadcast(true)
                .map_err(|_| MiIOError::TransportUnavailable)?;

            let target = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::BROADCAST, port));
            if socket.send_to(&packet, target).await.is_err() {
                return Ok(Vec::new());
            }

            let deadline = Instant::now() + timeout.max(Duration::from_millis(1));
            let mut replies = Vec::new();
            let mut seen_sources = HashSet::new();
            let mut buf = vec![0u8; 2048];
            loop {
                let Some(rem) = deadline.checked_duration_since(Instant::now()) else {
                    break;
                };
                if rem.is_zero() {
                    break;
                }
                match tokio::time::timeout(rem, socket.recv_from(&mut buf)).await {
                    Ok(Ok((n, SocketAddr::V4(src)))) => {
                        let ip = src.ip().to_string();
                        if n >= MIIO_HEADER_SIZE
                            && is_private_rfc1918_ipv4(&ip)
                            && seen_sources.insert(ip.clone())
                        {
                            replies.push(MiIOBroadcastReply {
                                source_ip: ip,
                                packet: buf[..n].to_vec(),
                            });
                        }
                    }
                    Ok(Ok(_)) => continue,
                    Ok(Err(_)) | Err(_) => break,
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
struct HardwareDeviceId {
    unknown: u32,
    device_id: u32,
}

impl HardwareDeviceId {
    fn matches(&self, header: &MiIOPacketHeader) -> bool {
        let header_unknown = if header.unknown == u32::MAX { 0 } else { header.unknown };
        header.device_id == self.device_id && header_unknown == self.unknown
    }
}

#[derive(Debug, Clone)]
struct DeviceSession {
    ip: String,
    token: [u8; 16],
    unknown: u32,
    device_id32: u32,
    base_stamp: u32,
    handshake_at: Instant,
    last_sent_stamp: Option<u32>,
}

impl DeviceSession {
    fn next_stamp(&mut self, now: Instant) -> u32 {
        let elapsed = now
            .checked_duration_since(self.handshake_at)
            .map(|d| d.as_secs().min(u32::MAX as u64) as u32)
            .unwrap_or(0);
        let computed = self.base_stamp.wrapping_add(elapsed);
        let stamp = match self.last_sent_stamp {
            Some(prev) if computed <= prev => prev.wrapping_add(1),
            _ => computed,
        };
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
    port: u16,
    request_timeout: Duration,
    handshake_timeout: Duration,
    max_retries: usize,
    handshake_ttl: Duration,
    max_batch_size: usize,
    max_unclaimed_probes_per_candidate: usize,
    max_total_unclaimed_probes: usize,
    max_discovery_duration: Duration,
    discovery_concurrency: usize,
    now_fn: Arc<dyn Fn() -> Instant + Send + Sync>,
    wave_sleep_fn: Arc<dyn Fn(Duration) -> BoxFuture<'static, ()> + Send + Sync>,
    #[cfg(test)]
    on_probe_collected: Option<Arc<dyn Fn() + Send + Sync>>,
    next_request_id: AtomicU64,
    shut_down: AtomicBool,
    inner: Mutex<ClientInner>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOEndpointInput {
    pub(crate) did: String,
    pub(crate) ip: String,
    pub(crate) token: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOPropKeyInput {
    pub(crate) did: String,
    pub(crate) siid: i64,
    pub(crate) piid: i64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOPropWriteInput {
    pub(crate) did: String,
    pub(crate) siid: i64,
    pub(crate) piid: i64,
    pub(crate) value: Value,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOActionCallInput {
    pub(crate) did: String,
    pub(crate) siid: i64,
    pub(crate) aiid: i64,
    pub(crate) inputs: Vec<Value>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIODiscoveryCandidateInput {
    pub(crate) did: String,
    pub(crate) token: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOHandshakeOutput {
    pub(crate) device_id32: u32,
    pub(crate) device_stamp: u32,
    pub(crate) rtt_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOPropValueOutput {
    pub(crate) did: String,
    pub(crate) siid: i64,
    pub(crate) piid: i64,
    pub(crate) value: Value,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOGetPropsOutput {
    pub(crate) values: Vec<MiIOPropValueOutput>,
    pub(crate) rtt_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOWriteOutput {
    pub(crate) rtt_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOActionOutput {
    pub(crate) result: Value,
    pub(crate) rtt_ms: Option<u64>,
}

struct ParsedReply {
    source_ip: String,
    packet: Vec<u8>,
    header: MiIOPacketHeader,
}

#[derive(Clone)]
struct PreparedProbe {
    did: String,
    token: [u8; 16],
    source_ip: String,
    header: MiIOPacketHeader,
    resolved_unknown: u32,
    probe_stamp: u32,
    req_id: u64,
    probe_packet: Vec<u8>,
}

impl Default for MiIOClient {
    fn default() -> Self {
        Self::new(Arc::new(TokioMiIOUdpTransport::default()))
    }
}

impl MiIOClient {
    pub(crate) fn new(transport: Arc<dyn MiIOUdpTransport>) -> Self {
        Self {
            transport,
            port: DEFAULT_PORT,
            request_timeout: DEFAULT_REQUEST_TIMEOUT,
            handshake_timeout: DEFAULT_HANDSHAKE_TIMEOUT,
            max_retries: DEFAULT_MAX_RETRIES,
            handshake_ttl: DEFAULT_HANDSHAKE_TTL,
            max_batch_size: DEFAULT_MAX_BATCH_SIZE,
            max_unclaimed_probes_per_candidate: DEFAULT_MAX_UNCLAIMED_PROBES_PER_CANDIDATE,
            max_total_unclaimed_probes: DEFAULT_MAX_TOTAL_UNCLAIMED_PROBES,
            max_discovery_duration: DEFAULT_MAX_DISCOVERY_DURATION,
            discovery_concurrency: DEFAULT_DISCOVERY_CONCURRENCY,
            now_fn: Arc::new(Instant::now),
            wave_sleep_fn: Arc::new(|d| Box::pin(tokio::time::sleep(d))),
            #[cfg(test)]
            on_probe_collected: None,
            next_request_id: AtomicU64::new(100),
            shut_down: AtomicBool::new(false),
            inner: Mutex::new(ClientInner::default()),
        }
    }

    fn now(&self) -> Instant {
        (self.now_fn)()
    }

    fn allocate_request_id(&self) -> u64 {
        let prev = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let id = (prev % 999_999_900) + 100;
        id
    }

    fn did_lock(&self, did: &str) -> Arc<AsyncMutex<()>> {
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        guard
            .did_locks
            .entry(did.to_string())
            .or_insert_with(|| Arc::new(AsyncMutex::new(())))
            .clone()
    }

    pub(crate) fn last_rtt_ms(&self, did: &str) -> Option<u64> {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .last_rtt_ms
            .get(did)
            .copied()
    }

    pub(crate) async fn shutdown(&self) {
        if self.shut_down.swap(true, Ordering::AcqRel) {
            return;
        }
        {
            let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            guard.sessions.clear();
            guard.known_hardware_ids.clear();
            guard.last_rtt_ms.clear();
            guard.did_locks.clear();
        }
        self.transport.shutdown().await;
    }

    pub(crate) async fn handshake(
        &self,
        endpoint: &MiIOEndpointInput,
    ) -> Result<MiIOHandshakeOutput, MiIOError> {
        let token = validate_token(&endpoint.token).ok_or(MiIOError::InvalidToken)?;
        let host = validated_host(&endpoint.ip)?;
        let lock = self.did_lock(&endpoint.did);
        let _guard = lock.lock().await;
        let session = self.perform_handshake(&endpoint.did, &host, token).await?;
        Ok(MiIOHandshakeOutput {
            device_id32: session.device_id32,
            device_stamp: session.base_stamp,
            rtt_ms: self.last_rtt_ms(&endpoint.did),
        })
    }

    pub(crate) async fn get_props(
        &self,
        keys: &[MiIOPropKeyInput],
        endpoint: &MiIOEndpointInput,
    ) -> Result<MiIOGetPropsOutput, MiIOError> {
        if keys.is_empty() {
            return Ok(MiIOGetPropsOutput { values: Vec::new(), rtt_ms: self.last_rtt_ms(&endpoint.did) });
        }
        let token = validate_token(&endpoint.token).ok_or(MiIOError::InvalidToken)?;
        let host = validated_host(&endpoint.ip)?;
        let lock = self.did_lock(&endpoint.did);
        let _guard = lock.lock().await;

        let mut merged: HashMap<(String, i64, i64), Value> = HashMap::new();
        for chunk in keys.chunks(self.max_batch_size.max(1)) {
            let params: Vec<Value> = chunk
                .iter()
                .map(|k| json!({ "did": k.did, "siid": k.siid, "piid": k.piid }))
                .collect();
            let result = self
                .send_with_retry(&endpoint.did, &host, token, "get_properties", Value::Array(params), true)
                .await?;
            for item in parse_prop_values(&result, &endpoint.did) {
                merged.insert((item.did.clone(), item.siid, item.piid), item.value);
            }
        }
        let mut values: Vec<MiIOPropValueOutput> = merged
            .into_iter()
            .map(|((did, siid, piid), value)| MiIOPropValueOutput { did, siid, piid, value })
            .collect();
        values.sort_by(|a, b| (&a.did, a.siid, a.piid).cmp(&(&b.did, b.siid, b.piid)));
        Ok(MiIOGetPropsOutput { values, rtt_ms: self.last_rtt_ms(&endpoint.did) })
    }

    pub(crate) async fn set_props(
        &self,
        writes: &[MiIOPropWriteInput],
        endpoint: &MiIOEndpointInput,
    ) -> Result<MiIOWriteOutput, MiIOError> {
        if writes.is_empty() {
            return Ok(MiIOWriteOutput { rtt_ms: self.last_rtt_ms(&endpoint.did) });
        }
        let token = validate_token(&endpoint.token).ok_or(MiIOError::InvalidToken)?;
        let host = validated_host(&endpoint.ip)?;
        let lock = self.did_lock(&endpoint.did);
        let _guard = lock.lock().await;

        for chunk in writes.chunks(self.max_batch_size.max(1)) {
            let params: Vec<Value> = chunk
                .iter()
                .map(|w| json!({ "did": w.did, "siid": w.siid, "piid": w.piid, "value": w.value }))
                .collect();
            let result = self
                .send_with_retry(&endpoint.did, &host, token, "set_properties", Value::Array(params), true)
                .await?;
            check_write_codes(result.as_array().map(Vec::as_slice).unwrap_or(&[]))?;
        }
        Ok(MiIOWriteOutput { rtt_ms: self.last_rtt_ms(&endpoint.did) })
    }

    pub(crate) async fn call_action(
        &self,
        call: &MiIOActionCallInput,
        endpoint: &MiIOEndpointInput,
    ) -> Result<MiIOActionOutput, MiIOError> {
        let token = validate_token(&endpoint.token).ok_or(MiIOError::InvalidToken)?;
        let host = validated_host(&endpoint.ip)?;
        let lock = self.did_lock(&endpoint.did);
        let _guard = lock.lock().await;

        let params = json!({
            "did": call.did,
            "siid": call.siid,
            "aiid": call.aiid,
            "in": call.inputs,
        });
        let result = self
            .send_with_retry(&endpoint.did, &host, token, "action", params, false)
            .await?;
        if let Some(items) = result.as_array() {
            check_write_codes(items)?;
        } else {
            check_write_codes(std::slice::from_ref(&result))?;
        }
        Ok(MiIOActionOutput { result, rtt_ms: self.last_rtt_ms(&endpoint.did) })
    }

    pub(crate) async fn discover_endpoints(
        &self,
        candidates: &[MiIODiscoveryCandidateInput],
        broadcast_timeout: Option<Duration>,
        excluded_ips: &HashSet<String>,
        known_numeric_dids: &HashSet<u64>,
    ) -> Result<HashMap<String, String>, MiIOError> {
        if self.shut_down.load(Ordering::Acquire) {
            return Err(MiIOError::ShutDown);
        }
        let mut valid_candidates: Vec<(String, [u8; 16])> = Vec::new();
        let mut seen_dids = HashSet::new();
        for c in candidates {
            if !c.did.is_empty() && seen_dids.insert(c.did.clone()) {
                if let Some(tok) = validate_token(&c.token) {
                    valid_candidates.push((c.did.clone(), tok));
                }
            }
        }
        if valid_candidates.is_empty() {
            return Ok(HashMap::new());
        }

        let bcast_timeout = broadcast_timeout
            .unwrap_or(DEFAULT_BROADCAST_TIMEOUT)
            .min(self.max_discovery_duration);
        let replies = self
            .transport
            .probe_broadcast(HELLO_PACKET.to_vec(), self.port, bcast_timeout)
            .await?;
        if self.shut_down.load(Ordering::Acquire) {
            return Err(MiIOError::ShutDown);
        }

        let mut parsed_replies = Vec::new();
        let mut seen_reply_ips = HashSet::new();
        for reply in replies {
            let ip = reply.source_ip.trim().to_string();
            if ip == "255.255.255.255"
                || !is_private_rfc1918_ipv4(&ip)
                || !seen_reply_ips.insert(ip.clone())
            {
                continue;
            }
            if let Ok(header) = decode_header(&reply.packet) {
                if header.device_id != 0 && header.device_id != u32::MAX {
                    parsed_replies.push(ParsedReply { source_ip: ip, packet: reply.packet, header });
                }
            }
        }
        if parsed_replies.is_empty() {
            return Ok(HashMap::new());
        }

        let candidate_did_set: HashSet<String> =
            valid_candidates.iter().map(|(d, _)| d.clone()).collect();
        let mut discovered: HashMap<String, String> = HashMap::new();
        let mut claimed_ips: HashSet<String> = excluded_ips
            .iter()
            .map(|s| s.trim().to_string())
            .filter(|s| is_private_rfc1918_ipv4(s))
            .collect();

        let probe_budget = self
            .max_discovery_duration
            .saturating_sub(bcast_timeout)
            .max(self.handshake_timeout.min(self.max_discovery_duration));
        let discovery_deadline = self.now() + probe_budget;

        let known_hw_snapshot = {
            self.inner
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .known_hardware_ids
                .clone()
        };
        let has_unresolved_non_numeric = valid_candidates
            .iter()
            .any(|(did, _)| did.parse::<u64>().is_err() && !known_hw_snapshot.contains_key(did));
        let reserved_non_numeric_budget = if has_unresolved_non_numeric {
            self.handshake_timeout.min(probe_budget / 2)
        } else {
            Duration::ZERO
        };
        let reserved_non_numeric_probes = if has_unresolved_non_numeric {
            (self.max_total_unclaimed_probes / 4).max(1)
        } else {
            0
        };
        let matching_probe_cap = self
            .max_total_unclaimed_probes
            .saturating_sub(reserved_non_numeric_probes)
            .max(1);
        let matching_deadline = discovery_deadline
            .checked_sub(reserved_non_numeric_budget)
            .unwrap_or_else(|| self.now());

        let mut matching_queues: HashMap<String, Vec<usize>> = HashMap::new();
        let mut matching_tried: HashMap<String, HashSet<String>> = HashMap::new();
        let mut matching_candidates = Vec::new();
        for (did, tok) in &valid_candidates {
            let matching: Vec<usize> = parsed_replies
                .iter()
                .enumerate()
                .filter(|(_, r)| {
                    if claimed_ips.contains(&r.source_ip) {
                        return false;
                    }
                    if hello_checksum_verdict(&r.packet, tok) == HelloChecksumVerdict::Mismatch {
                        return false;
                    }
                    if let Some(hw) = known_hw_snapshot.get(did) {
                        if hw.matches(&r.header) {
                            return true;
                        }
                    }
                    let Ok(did64) = did.parse::<u64>() else {
                        return false;
                    };
                    r.header.device_id64() == did64
                        || ((r.header.unknown == 0 || r.header.unknown == u32::MAX)
                            && (did64 as u32) == r.header.device_id)
                })
                .map(|(i, _)| i)
                .collect();
            if !matching.is_empty() {
                matching_candidates.push((did.clone(), *tok));
                matching_queues.insert(did.clone(), matching);
                matching_tried.insert(did.clone(), HashSet::new());
            }
        }

        let mut total_probes_launched = 0usize;
        if !matching_candidates.is_empty() {
            total_probes_launched += self
                .run_bounded_probe_waves(
                    &matching_candidates,
                    &parsed_replies,
                    &matching_queues,
                    &mut matching_tried,
                    &mut discovered,
                    &mut claimed_ips,
                    matching_probe_cap,
                    matching_deadline,
                )
                .await?;
        }

        let unresolved: Vec<(String, [u8; 16])> = valid_candidates
            .iter()
            .filter(|(did, _)| {
                !discovered.contains_key(did)
                    && did.parse::<u64>().is_err()
                    && !known_hw_snapshot.contains_key(did)
            })
            .cloned()
            .collect();
        if unresolved.is_empty() || total_probes_launched >= self.max_total_unclaimed_probes {
            return Ok(discovered);
        }

        let mut all_known_numeric: HashSet<u64> = known_numeric_dids.clone();
        for (did, _) in &valid_candidates {
            if let Ok(n) = did.parse::<u64>() {
                all_known_numeric.insert(n);
            }
        }
        let known_numeric_low32: HashSet<u32> =
            all_known_numeric.iter().map(|&n| n as u32).collect();
        let non_candidate_hws: Vec<HardwareDeviceId> = known_hw_snapshot
            .iter()
            .filter(|(did, _)| !candidate_did_set.contains(*did) || discovered.contains_key(*did))
            .map(|(_, &hw)| hw)
            .collect();
        let unclaimed_indices: Vec<usize> = parsed_replies
            .iter()
            .enumerate()
            .filter(|(_, r)| {
                !claimed_ips.contains(&r.source_ip)
                    && !non_candidate_hws.iter().any(|hw| hw.matches(&r.header))
            })
            .map(|(i, _)| i)
            .collect();
        if unclaimed_indices.is_empty() {
            return Ok(discovered);
        }

        let matches_known_numeric = |header: &MiIOPacketHeader| -> bool {
            if all_known_numeric.contains(&header.device_id64()) {
                return true;
            }
            if header.unknown == 0 || header.unknown == u32::MAX {
                return known_numeric_low32.contains(&header.device_id);
            }
            false
        };

        let mut queues: HashMap<String, Vec<usize>> = HashMap::new();
        let mut tried: HashMap<String, HashSet<String>> = HashMap::new();
        for (did, tok) in &unresolved {
            let (mut tier0, mut tier1, mut tier2) = (Vec::new(), Vec::new(), Vec::new());
            for &idx in &unclaimed_indices {
                let reply = &parsed_replies[idx];
                match hello_checksum_verdict(&reply.packet, tok) {
                    HelloChecksumVerdict::Mismatch => continue,
                    HelloChecksumVerdict::Md5Match | HelloChecksumVerdict::TokenEcho => {
                        tier0.push(idx)
                    }
                    HelloChecksumVerdict::Inconclusive => {
                        if !matches_known_numeric(&reply.header) {
                            tier1.push(idx);
                        } else {
                            tier2.push(idx);
                        }
                    }
                }
            }
            let mut combined = tier0;
            combined.extend(tier1);
            combined.extend(tier2);
            combined.truncate(self.max_unclaimed_probes_per_candidate);
            queues.insert(did.clone(), combined);
            tried.insert(did.clone(), HashSet::new());
        }

        let non_numeric_deadline = discovery_deadline.max(self.now() + reserved_non_numeric_budget);
        let _ = self
            .run_bounded_probe_waves(
                &unresolved,
                &parsed_replies,
                &queues,
                &mut tried,
                &mut discovered,
                &mut claimed_ips,
                self.max_total_unclaimed_probes - total_probes_launched,
                non_numeric_deadline,
            )
            .await?;

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
        let mut total_launched = 0usize;
        let mut round_robin_start = 0usize;

        while total_launched < max_total_probes {
            if self.shut_down.load(Ordering::Acquire) {
                return Err(MiIOError::ShutDown);
            }
            let Some(wave_budget) = deadline.checked_duration_since(self.now()) else {
                break;
            };
            if wave_budget.is_zero() {
                break;
            }

            let active: Vec<&(String, [u8; 16])> = candidates
                .iter()
                .filter(|(did, _)| {
                    if discovered.contains_key(did) {
                        return false;
                    }
                    let Some(q) = queues_by_did.get(did) else {
                        return false;
                    };
                    let tried = tried_by_did.get(did);
                    q.iter().any(|&idx| {
                        let ip = &replies[idx].source_ip;
                        !claimed_ips.contains(ip) && !tried.is_some_and(|t| t.contains(ip))
                    })
                })
                .collect();
            if active.is_empty() {
                break;
            }

            let batch_limit = self.discovery_concurrency.min(max_total_probes - total_launched);
            let mut batch: Vec<PreparedProbe> = Vec::new();
            let mut in_flight_ips = HashSet::new();
            let mut passes_without_progress = 0usize;
            let mut cursor = round_robin_start % active.len();

            while batch.len() < batch_limit && passes_without_progress < active.len() {
                let (did, tok) = active[cursor];
                cursor = (cursor + 1) % active.len();
                let queue = queues_by_did.get(did).map(Vec::as_slice).unwrap_or(&[]);
                let tried = tried_by_did.entry(did.clone()).or_default();
                if let Some(&reply_idx) = queue.iter().find(|&&idx| {
                    let ip = &replies[idx].source_ip;
                    !claimed_ips.contains(ip) && !tried.contains(ip) && !in_flight_ips.contains(ip)
                }) {
                    let reply = &replies[reply_idx];
                    tried.insert(reply.source_ip.clone());
                    in_flight_ips.insert(reply.source_ip.clone());
                    if let Ok(prepared) = self.prepare_broadcast_probe(
                        did,
                        *tok,
                        &reply.source_ip,
                        &reply.header,
                    ) {
                        batch.push(prepared);
                        total_launched += 1;
                        passes_without_progress = 0;
                        continue;
                    }
                }
                passes_without_progress += 1;
            }
            round_robin_start = round_robin_start.wrapping_add(1);
            if batch.is_empty() {
                break;
            }

            let per_probe_timeout = self.handshake_timeout.min(wave_budget);
            enum ProbeOutcome {
                Response(PreparedProbe, Vec<u8>, u64),
                NoMatch,
                Fatal(MiIOError),
                DeadlineReached,
            }

            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<ProbeOutcome>();
            let mut handles = Vec::with_capacity(batch.len() + 1);
            let mut awaited_probes = batch.len();
            for probe in batch {
                let transport = self.transport.clone();
                let port = self.port;
                let tx_probe = tx.clone();
                handles.push(tauri::async_runtime::spawn(async move {
                    let start = Instant::now();
                    let outcome = match transport
                        .send(
                            probe.probe_packet.clone(),
                            probe.source_ip.clone(),
                            port,
                            per_probe_timeout,
                        )
                        .await
                    {
                        Ok(resp) => {
                            let rtt = start.elapsed().as_millis().max(1) as u64;
                            ProbeOutcome::Response(probe, resp, rtt)
                        }
                        Err(err @ (MiIOError::ShutDown | MiIOError::LocalNetworkDenied)) => {
                            ProbeOutcome::Fatal(err)
                        }
                        Err(_) => ProbeOutcome::NoMatch,
                    };
                    let _ = tx_probe.send(outcome);
                }));
            }
            let wave_sleep = (self.wave_sleep_fn)(wave_budget);
            let tx_deadline = tx.clone();
            handles.push(tauri::async_runtime::spawn(async move {
                wave_sleep.await;
                let _ = tx_deadline.send(ProbeOutcome::DeadlineReached);
            }));
            drop(tx);

            // #444: Keep every validated reply collected before the wave deadline fires;
            // only unresolved probes are aborted when the wave budget expires.
            let mut collected = Vec::new();
            while awaited_probes > 0 {
                let Some(outcome) = rx.recv().await else {
                    break;
                };
                match outcome {
                    ProbeOutcome::Fatal(err) => {
                        for h in &handles {
                            h.abort();
                        }
                        return Err(err);
                    }
                    ProbeOutcome::Response(probe, resp, rtt) => {
                        collected.push(ProbeOutcome::Response(probe, resp, rtt));
                        awaited_probes -= 1;
                        #[cfg(test)]
                        if let Some(cb) = &self.on_probe_collected {
                            cb();
                        }
                    }
                    ProbeOutcome::NoMatch => {
                        awaited_probes -= 1;
                    }
                    ProbeOutcome::DeadlineReached => {
                        for h in &handles {
                            h.abort();
                        }
                        while let Ok(extra) = rx.try_recv() {
                            if let ProbeOutcome::Response(probe, resp, rtt) = extra {
                                collected.push(ProbeOutcome::Response(probe, resp, rtt));
                            }
                        }
                        break;
                    }
                }
            }
            for h in &handles {
                h.abort();
            }

            if self.shut_down.load(Ordering::Acquire) {
                return Err(MiIOError::ShutDown);
            }
            for outcome in collected {
                if let ProbeOutcome::Response(probe, response_packet, rtt_ms) = outcome {
                    if !discovered.contains_key(&probe.did)
                        && !claimed_ips.contains(&probe.source_ip)
                        && self.accept_verified_broadcast_response(&probe, &response_packet, rtt_ms)
                    {
                        discovered.insert(probe.did, probe.source_ip.clone());
                        claimed_ips.insert(probe.source_ip);
                    }
                }
            }
        }
        Ok(total_launched)
    }

    fn prepare_broadcast_probe(
        &self,
        did: &str,
        token: [u8; 16],
        source_ip: &str,
        header: &MiIOPacketHeader,
    ) -> Result<PreparedProbe, MiIOError> {
        let req_id = self.allocate_request_id();
        let resolved_unknown = if header.unknown == u32::MAX { 0 } else { header.unknown };
        let probe_stamp = header.stamp.wrapping_add(1);
        let rpc = json!({
            "id": req_id,
            "method": "get_properties",
            "params": [{ "did": did, "siid": 1, "piid": 1 }],
        });
        let payload = serde_json::to_vec(&rpc).map_err(|_| MiIOError::EncryptionFailed)?;
        let probe_packet =
            encode_packet(header.device_id, probe_stamp, &token, &payload, resolved_unknown)?;
        Ok(PreparedProbe {
            did: did.to_string(),
            token,
            source_ip: source_ip.to_string(),
            header: header.clone(),
            resolved_unknown,
            probe_stamp,
            req_id,
            probe_packet,
        })
    }

    fn accept_verified_broadcast_response(
        &self,
        probe: &PreparedProbe,
        response_packet: &[u8],
        rtt_ms: u64,
    ) -> bool {
        let Ok((resp_header, plaintext)) = decode_packet(response_packet, &probe.token) else {
            return false;
        };
        let Ok(raw_text) = String::from_utf8(plaintext) else {
            return false;
        };
        let cleaned = clean_malformed_firmware_json(&raw_text);
        let Ok(decoded) = serde_json::from_str::<Value>(&cleaned) else {
            return false;
        };
        if decoded.get("id").and_then(Value::as_u64) != Some(probe.req_id) {
            return false;
        }
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        guard.last_rtt_ms.insert(probe.did.clone(), rtt_ms);
        guard.known_hardware_ids.insert(
            probe.did.clone(),
            HardwareDeviceId {
                unknown: probe.resolved_unknown,
                device_id: probe.header.device_id,
            },
        );
        guard.sessions.insert(
            probe.did.clone(),
            DeviceSession {
                ip: probe.source_ip.clone(),
                token: probe.token,
                unknown: probe.resolved_unknown,
                device_id32: probe.header.device_id,
                base_stamp: resp_header.stamp,
                handshake_at: self.now(),
                last_sent_stamp: Some(probe.probe_stamp),
            },
        );
        true
    }

    async fn ensure_session(
        &self,
        did: &str,
        host: &str,
        token: [u8; 16],
    ) -> Result<DeviceSession, MiIOError> {
        let now = self.now();
        {
            let guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(existing) = guard.sessions.get(did) {
                if existing.ip == host
                    && existing.token == token
                    && now
                        .checked_duration_since(existing.handshake_at)
                        .is_some_and(|age| age < self.handshake_ttl)
                {
                    return Ok(existing.clone());
                }
            }
        }
        self.perform_handshake(did, host, token).await
    }

    async fn perform_handshake(
        &self,
        did: &str,
        host: &str,
        token: [u8; 16],
    ) -> Result<DeviceSession, MiIOError> {
        if self.shut_down.load(Ordering::Acquire) {
            return Err(MiIOError::ShutDown);
        }
        let start = Instant::now();
        let response = self
            .transport
            .send(HELLO_PACKET.to_vec(), host.to_string(), self.port, self.handshake_timeout)
            .await
            .map_err(|err| {
                if err.proves_packet_crossed_permission_boundary() {
                    MiIOError::HandshakeFailed
                } else {
                    err
                }
            })?;
        if self.shut_down.load(Ordering::Acquire) {
            return Err(MiIOError::ShutDown);
        }
        let rtt = start.elapsed().as_millis().max(1) as u64;
        let header = decode_header(&response)?;
        let (resolved_unknown, device_id32) = if header.device_id != 0 && header.device_id != u32::MAX
        {
            (
                if header.unknown == u32::MAX { 0 } else { header.unknown },
                header.device_id,
            )
        } else if let Ok(did32) = did.parse::<u32>() {
            (0, did32)
        } else if let Ok(did64) = did.parse::<u64>() {
            ((did64 >> 32) as u32, did64 as u32)
        } else {
            let known = self
                .inner
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .known_hardware_ids
                .get(did)
                .copied();
            match known {
                Some(hw) => (hw.unknown, hw.device_id),
                None => return Err(MiIOError::UnsupportedNonNumericDeviceId),
            }
        };

        let session = DeviceSession {
            ip: host.to_string(),
            token,
            unknown: resolved_unknown,
            device_id32,
            base_stamp: header.stamp,
            handshake_at: self.now(),
            last_sent_stamp: None,
        };
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        guard.last_rtt_ms.insert(did.to_string(), rtt);
        guard.sessions.insert(did.to_string(), session.clone());
        Ok(session)
    }

    async fn send_with_retry(
        &self,
        did: &str,
        host: &str,
        token: [u8; 16],
        method: &str,
        params: Value,
        allow_post_send_retry: bool,
    ) -> Result<Value, MiIOError> {
        let mut last_err = MiIOError::Timeout;
        for attempt in 0..=self.max_retries {
            if self.shut_down.load(Ordering::Acquire) {
                return Err(MiIOError::ShutDown);
            }
            match self
                .send_once(did, host, token, method, &params, allow_post_send_retry)
                .await
            {
                Ok(val) => return Ok(val),
                Err(err) => {
                    self.inner
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .sessions
                        .remove(did);
                    let retryable = err.is_retryable() && attempt < self.max_retries;
                    last_err = err;
                    if !retryable {
                        return Err(last_err);
                    }
                }
            }
        }
        Err(last_err)
    }

    async fn send_once(
        &self,
        did: &str,
        host: &str,
        token: [u8; 16],
        method: &str,
        params: &Value,
        allow_post_send_retry: bool,
    ) -> Result<Value, MiIOError> {
        let mut session = self.ensure_session(did, host, token).await?;
        let stamp = session.next_stamp(self.now());
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .sessions
            .insert(did.to_string(), session.clone());

        let req_id = self.allocate_request_id();
        let rpc = json!({ "id": req_id, "method": method, "params": params });
        let payload = serde_json::to_vec(&rpc).map_err(|_| MiIOError::EncryptionFailed)?;
        let packet = encode_packet(session.device_id32, stamp, &token, &payload, session.unknown)?;

        let send_start = Instant::now();
        let response_res = self
            .transport
            .send(packet, host.to_string(), self.port, self.request_timeout)
            .await;

        let json: Value = match response_res.and_then(|resp| {
            let rtt = send_start.elapsed().as_millis().max(1) as u64;
            if !self.shut_down.load(Ordering::Acquire) {
                self.inner
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .last_rtt_ms
                    .insert(did.to_string(), rtt);
            }
            let (_, plaintext) = decode_packet(&resp, &token)?;
            let raw_text = String::from_utf8(plaintext).map_err(|_| MiIOError::MalformedPacket)?;
            let cleaned = clean_malformed_firmware_json(&raw_text);
            if cleaned.is_empty() {
                return Err(MiIOError::MalformedPacket);
            }
            serde_json::from_str::<Value>(&cleaned).map_err(|_| MiIOError::MalformedPacket)
        }) {
            Ok(val) => val,
            Err(err) => {
                if err == MiIOError::LocalNetworkDenied {
                    self.inner
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .sessions
                        .remove(did);
                }
                if !allow_post_send_retry {
                    if matches!(
                        err,
                        MiIOError::TransportUnavailable
                            | MiIOError::LocalNetworkDenied
                            | MiIOError::SendFailed
                            | MiIOError::ShutDown
                    ) {
                        return Err(err);
                    }
                    self.inner
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .sessions
                        .remove(did);
                    return Err(MiIOError::AmbiguousActionOutcome);
                }
                return Err(err);
            }
        };

        if let Some(resp_id) = json.get("id").and_then(Value::as_u64) {
            if resp_id != req_id {
                if !allow_post_send_retry {
                    self.inner
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .sessions
                        .remove(did);
                    return Err(MiIOError::AmbiguousActionOutcome);
                }
                return Err(MiIOError::MalformedPacket);
            }
        }

        if !self.shut_down.load(Ordering::Acquire) {
            self.inner
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .known_hardware_ids
                .insert(
                    did.to_string(),
                    HardwareDeviceId {
                        unknown: session.unknown,
                        device_id: session.device_id32,
                    },
                );
        }

        if let Some(err_obj) = json.get("error").and_then(Value::as_object) {
            let code = err_obj.get("code").and_then(Value::as_i64).unwrap_or(-1);
            let message = err_obj
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("device error")
                .to_string();
            return Err(MiIOError::DeviceError { code, message });
        }

        Ok(json.get("result").cloned().unwrap_or(Value::Null))
    }
}

fn validated_host(ip: &str) -> Result<String, MiIOError> {
    let trimmed = ip.trim();
    if !is_private_rfc1918_ipv4(trimmed) {
        return Err(MiIOError::InvalidAddress(ip.to_string()));
    }
    Ok(trimmed.to_string())
}

fn parse_prop_values(result: &Value, default_did: &str) -> Vec<MiIOPropValueOutput> {
    let Some(items) = result.as_array() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for item in items {
        let Some(obj) = item.as_object() else {
            continue;
        };
        let did = match obj.get("did") {
            Some(Value::String(s)) if !s.is_empty() => s.clone(),
            Some(Value::Number(n)) => n.to_string(),
            _ => default_did.to_string(),
        };
        let Some(siid) = obj.get("siid").and_then(Value::as_i64) else {
            continue;
        };
        let Some(piid) = obj.get("piid").and_then(Value::as_i64) else {
            continue;
        };
        if let Some(code) = obj.get("code").and_then(Value::as_i64) {
            if code != 0 {
                continue;
            }
        }
        let Some(value) = obj.get("value") else {
            continue;
        };
        if value.is_null() {
            continue;
        }
        out.push(MiIOPropValueOutput { did, siid, piid, value: value.clone() });
    }
    out
}

fn check_write_codes(items: &[Value]) -> Result<(), MiIOError> {
    for item in items {
        let code = item.get("code").and_then(Value::as_i64).unwrap_or(0);
        if code < 0 {
            return Err(MiIOError::DeviceError {
                code,
                message: "Device did not respond or is offline".to_string(),
            });
        }
    }
    Ok(())
}

// MARK: - Tauri State & Commands

pub(crate) struct MiIOState {
    client: Arc<MiIOClient>,
}

impl Default for MiIOState {
    fn default() -> Self {
        Self { client: Arc::new(MiIOClient::default()) }
    }
}

#[tauri::command]
pub(crate) async fn miio_handshake(
    state: tauri::State<'_, MiIOState>,
    endpoint: MiIOEndpointInput,
) -> Result<MiIOHandshakeOutput, MiIOCommandError> {
    state
        .client
        .handshake(&endpoint)
        .await
        .map_err(|e| e.to_command_error())
}

#[tauri::command]
pub(crate) async fn miio_get_props(
    state: tauri::State<'_, MiIOState>,
    keys: Vec<MiIOPropKeyInput>,
    endpoint: MiIOEndpointInput,
) -> Result<MiIOGetPropsOutput, MiIOCommandError> {
    state
        .client
        .get_props(&keys, &endpoint)
        .await
        .map_err(|e| e.to_command_error())
}

#[tauri::command]
pub(crate) async fn miio_set_props(
    state: tauri::State<'_, MiIOState>,
    writes: Vec<MiIOPropWriteInput>,
    endpoint: MiIOEndpointInput,
) -> Result<MiIOWriteOutput, MiIOCommandError> {
    state
        .client
        .set_props(&writes, &endpoint)
        .await
        .map_err(|e| e.to_command_error())
}

#[tauri::command]
pub(crate) async fn miio_call_action(
    state: tauri::State<'_, MiIOState>,
    call: MiIOActionCallInput,
    endpoint: MiIOEndpointInput,
) -> Result<MiIOActionOutput, MiIOCommandError> {
    state
        .client
        .call_action(&call, &endpoint)
        .await
        .map_err(|e| e.to_command_error())
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
    let numeric: HashSet<u64> = known_numeric_dids
        .unwrap_or_default()
        .into_iter()
        .filter_map(|s| s.parse::<u64>().ok())
        .collect();
    let timeout = broadcast_timeout_ms.map(Duration::from_millis);
    state
        .client
        .discover_endpoints(&candidates, timeout, &excluded, &numeric)
        .await
        .map_err(|e| e.to_command_error())
}

#[tauri::command]
pub(crate) async fn miio_shutdown(state: tauri::State<'_, MiIOState>) -> Result<(), String> {
    state.client.shutdown().await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::miio_crypto::derive_key_and_iv;

    fn hex_decode(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    fn hex_encode(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn golden_corpus_matches_rust_implementation() {
        let raw = include_str!("../../../Tests/Fixtures/miio_protocol_golden.json");
        let doc: Value = serde_json::from_str(raw).expect("valid golden json");

        assert_eq!(hex_encode(&HELLO_PACKET), doc["helloPacket"].as_str().unwrap());

        for vec in doc["packetVectors"].as_array().unwrap() {
            let name = vec["name"].as_str().unwrap();
            let token = validate_token(vec["token"].as_str().unwrap()).expect(name);
            let (key, iv) = derive_key_and_iv(&token);
            assert_eq!(hex_encode(&key), vec["key"].as_str().unwrap(), "{name} key");
            assert_eq!(hex_encode(&iv), vec["iv"].as_str().unwrap(), "{name} iv");

            let device_id = vec["deviceId"].as_u64().unwrap() as u32;
            let stamp = vec["stamp"].as_u64().unwrap() as u32;
            let unknown = vec["unknown"].as_u64().unwrap() as u32;
            let payload = vec["payload"].as_str().unwrap().as_bytes();
            let encoded = encode_packet(device_id, stamp, &token, payload, unknown).expect(name);
            assert_eq!(hex_encode(&encoded), vec["packet"].as_str().unwrap(), "{name} encode");

            let (hdr, decoded) = decode_packet(&encoded, &token).expect(name);
            assert_eq!(hdr.device_id, device_id, "{name} device_id");
            assert_eq!(hdr.stamp, stamp, "{name} stamp");
            assert_eq!(hdr.unknown, unknown, "{name} unknown");
            assert_eq!(hex_encode(&hdr.checksum), vec["checksum"].as_str().unwrap(), "{name} checksum");
            assert_eq!(decoded, payload, "{name} decode");

            let mut tampered = encoded.clone();
            tampered[16] ^= 0xFF;
            assert_eq!(decode_packet(&tampered, &token).unwrap_err(), MiIOError::ChecksumMismatch);
        }

        for case in doc["helloChecksumCases"].as_array().unwrap() {
            let token = validate_token(case["token"].as_str().unwrap()).unwrap();
            let packet = hex_decode(case["packet"].as_str().unwrap());
            let expected = match case["verdict"].as_str().unwrap() {
                "md5Match" => HelloChecksumVerdict::Md5Match,
                "tokenEcho" => HelloChecksumVerdict::TokenEcho,
                "inconclusive" => HelloChecksumVerdict::Inconclusive,
                "mismatch" => HelloChecksumVerdict::Mismatch,
                other => panic!("unexpected verdict: {other}"),
            };
            assert_eq!(hello_checksum_verdict(&packet, &token), expected);
        }

        for case in doc["tokenCases"].as_array().unwrap() {
            let raw = case["raw"].as_str().unwrap();
            let valid = case["valid"].as_bool().unwrap();
            assert_eq!(validate_token(raw).is_some(), valid, "token case: {raw}");
        }

        for case in doc["privateIpCases"].as_array().unwrap() {
            let ip = case["ip"].as_str().unwrap();
            let valid = case["valid"].as_bool().unwrap();
            assert_eq!(is_private_rfc1918_ipv4(ip), valid, "ip case: {ip}");
        }

        for case in doc["malformedJsonCases"].as_array().unwrap() {
            let input = case["input"].as_str().unwrap();
            let expected = case["expected"].as_str().unwrap();
            assert_eq!(clean_malformed_firmware_json(input), expected);
        }
    }

    struct MockTransport {
        send_fn: Box<dyn Fn(Vec<u8>, String, u16, Duration) -> BoxFuture<'static, Result<Vec<u8>, MiIOError>> + Send + Sync>,
        bcast_fn: Box<dyn Fn(Vec<u8>, u16, Duration) -> BoxFuture<'static, Result<Vec<MiIOBroadcastReply>, MiIOError>> + Send + Sync>,
    }

    impl MiIOUdpTransport for MockTransport {
        fn send(&self, packet: Vec<u8>, host: String, port: u16, timeout: Duration) -> BoxFuture<'_, Result<Vec<u8>, MiIOError>> {
            (self.send_fn)(packet, host, port, timeout)
        }
        fn probe_broadcast(&self, packet: Vec<u8>, port: u16, timeout: Duration) -> BoxFuture<'_, Result<Vec<MiIOBroadcastReply>, MiIOError>> {
            (self.bcast_fn)(packet, port, timeout)
        }
        fn shutdown(&self) -> BoxFuture<'_, ()> {
            Box::pin(async {})
        }
    }

    fn make_hello_reply(device_id: u32, stamp: u32, token: &[u8; 16]) -> Vec<u8> {
        encode_packet(device_id, stamp, token, &[], 0).unwrap()
    }

    #[test]
    fn rejects_non_private_endpoints_and_never_leaks_token() {
        let token_hex = "0123456789abcdef0123456789abcdef";
        let client = MiIOClient::default();
        for bad_ip in ["8.8.8.8", "127.0.0.1", "169.254.1.2", "device.lan"] {
            let ep = MiIOEndpointInput {
                did: "1001".into(),
                ip: bad_ip.into(),
                token: token_hex.into(),
            };
            let err = tauri::async_runtime::block_on(client.handshake(&ep)).unwrap_err();
            assert_eq!(err.code(), "invalid_address");
            assert!(!err.to_string().contains(token_hex));
        }
    }

    #[test]
    fn action_post_send_timeout_returns_ambiguous_without_retry() {
        let token_hex = "0123456789abcdef0123456789abcdef";
        let token = validate_token(token_hex).unwrap();
        let sends = Arc::new(AtomicU64::new(0));
        let sends_clone = sends.clone();
        let transport = Arc::new(MockTransport {
            send_fn: Box::new(move |pkt, _host, _port, _timeout| {
                let count = sends_clone.fetch_add(1, Ordering::SeqCst);
                Box::pin(async move {
                    if pkt == HELLO_PACKET {
                        return Ok(make_hello_reply(1001, 50, &token));
                    }
                    assert_eq!(count, 1, "action must not be retried after send");
                    Err(MiIOError::Timeout)
                })
            }),
            bcast_fn: Box::new(|_, _, _| Box::pin(async { Ok(vec![]) })),
        });
        let client = MiIOClient::new(transport);
        let ep = MiIOEndpointInput {
            did: "1001".into(),
            ip: "192.168.1.20".into(),
            token: token_hex.into(),
        };
        let call = MiIOActionCallInput { did: "1001".into(), siid: 2, aiid: 1, inputs: vec![] };
        let err = tauri::async_runtime::block_on(client.call_action(&call, &ep)).unwrap_err();
        assert_eq!(err, MiIOError::AmbiguousActionOutcome);
        assert_eq!(sends.load(Ordering::SeqCst), 2); // 1 HELLO + 1 action, no retry
    }

    #[test]
    fn discovery_keeps_validated_replies_when_wave_times_out_444() {
        let token_a_hex = "0123456789abcdef0123456789abcdef";
        let token_b_hex = "deadbeefcafebabe1122334455667788";
        let token_a = validate_token(token_a_hex).unwrap();
        let token_b = validate_token(token_b_hex).unwrap();
        let fast_collected = Arc::new(tokio::sync::Notify::new());
        let fast_collected_cb = fast_collected.clone();

        let transport = Arc::new(MockTransport {
            send_fn: Box::new(move |pkt, host, _port, _timeout| {
                Box::pin(async move {
                    if host == "192.168.1.10" {
                        let (hdr, pt) = decode_packet(&pkt, &token_a).unwrap();
                        let req: Value = serde_json::from_slice(&pt).unwrap();
                        let resp = json!({ "id": req["id"], "result": [] });
                        let out = encode_packet(
                            hdr.device_id,
                            hdr.stamp + 1,
                            &token_a,
                            &serde_json::to_vec(&resp).unwrap(),
                            0,
                        )
                        .unwrap();
                        return Ok(out);
                    }
                    // Slow peer hangs past wave deadline; pending forever until aborted.
                    std::future::pending::<Result<Vec<u8>, MiIOError>>().await
                })
            }),
            bcast_fn: Box::new(move |_, _, _| {
                let r1 = MiIOBroadcastReply {
                    source_ip: "192.168.1.10".into(),
                    packet: make_hello_reply(1001, 10, &token_a),
                };
                let r2 = MiIOBroadcastReply {
                    source_ip: "192.168.1.11".into(),
                    packet: make_hello_reply(2002, 10, &token_b),
                };
                Box::pin(async move { Ok(vec![r1, r2]) })
            }),
        });

        let mut client = MiIOClient::new(transport);
        client.on_probe_collected = Some(Arc::new(move || fast_collected_cb.notify_one()));
        client.wave_sleep_fn = Arc::new(move |_| {
            let notify = fast_collected.clone();
            Box::pin(async move {
                notify.notified().await;
            })
        });

        let discovered = tauri::async_runtime::block_on(client.discover_endpoints(
            &[
                MiIODiscoveryCandidateInput { did: "1001".into(), token: token_a_hex.into() },
                MiIODiscoveryCandidateInput { did: "2002".into(), token: token_b_hex.into() },
            ],
            Some(Duration::from_millis(10)),
            &HashSet::new(),
            &HashSet::new(),
        ))
        .unwrap();

        assert_eq!(discovered.get("1001").map(String::as_str), Some("192.168.1.10"));
        assert!(!discovered.contains_key("2002"));
    }
}
