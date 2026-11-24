mod socket;

use futures_util::future::{select, Either};
use ring::digest::{digest, SHA256};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::future::{pending, Future};
use std::pin::pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::{mpsc, oneshot, watch, OwnedRwLockReadGuard, RwLock};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;
use tungstenite::Message;

use self::socket::Socket;
use crate::network_monitor::ReconnectBackoff;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HaSnapshot {
    areas: Value,
    devices: Value,
    entities: Value,
    states: Value,
}

#[derive(Deserialize)]
pub struct HaServiceCall {
    domain: String,
    service: String,
    entity_id: String,
    data: serde_json::Map<String, Value>,
}

const STALE: &str = "Home Assistant connection is disabled or has changed";
const CANCELLED: &str = "Home Assistant request cancelled";
const STILL_DRAINING: &str = "Home Assistant connection still draining";
const DRAIN_TIMEOUT: Duration = Duration::from_secs(7);
const CONNECT_TOTAL_TIMEOUT: Duration = Duration::from_secs(8);
const CONNECT_PER_ADDRESS_TIMEOUT: Duration = Duration::from_secs(5);

pub(crate) struct HaConnections {
    registration: Mutex<HaRegistration>,
    network_epoch: watch::Sender<u64>,
}

impl Default for HaConnections {
    fn default() -> Self {
        let (network_epoch, _) = watch::channel(0u64);
        Self {
            registration: Mutex::default(),
            network_epoch,
        }
    }
}

#[derive(Default)]
struct HaRegistration {
    generation: u64,
    current: Option<Arc<HaConnection>>,
}

struct HaConnection {
    generation: u64,
    scope: String,
    cancel: CancellationToken,
    tasks: Arc<RwLock<()>>,
    websocket: Mutex<Option<HaChannel>>,
    network_epoch: watch::Sender<u64>,
}

struct HaTask {
    cancel: CancellationToken,
    connection: Arc<HaConnection>,
    _running: OwnedRwLockReadGuard<()>,
}

impl HaConnections {
    /// Signals a network topology change or system resume so any active/handshaking
    /// WebSocket drops immediately and reconnect backoff resets to 0.
    pub(crate) fn handle_network_or_resume(&self) {
        self.network_epoch.send_modify(|epoch| {
            *epoch = epoch.wrapping_add(1);
        });
    }

    async fn configure(&self, scope: Option<String>) -> Result<u64, String> {
        self.configure_with_timeout(scope, DRAIN_TIMEOUT).await
    }

    async fn configure_with_timeout(
        &self,
        scope: Option<String>,
        drain_timeout: Duration,
    ) -> Result<u64, String> {
        let (generation, retiring) = {
            let mut state = self.registration.lock().map_err(|_| STALE)?;
            state.generation = state.generation.checked_add(1).ok_or(STALE)?;
            let generation = state.generation;
            if let Some(current) = &state.current {
                current.cancel.cancel();
            }
            (generation, state.current.clone())
        };
        if let Some(connection) = retiring {
            // Keep the retiring connection registered until its last task exits.
            // Concurrent configurations wait on the same connection up to `drain_timeout`.
            let _drained = tokio::time::timeout(drain_timeout, connection.tasks.write())
                .await
                .map_err(|_| STILL_DRAINING.to_string())?;
        }
        let mut state = self.registration.lock().map_err(|_| STALE)?;
        if state.generation == generation {
            let network_epoch = self.network_epoch.clone();
            state.current = scope.map(|scope| {
                Arc::new(HaConnection {
                    generation,
                    scope,
                    cancel: CancellationToken::new(),
                    tasks: Arc::default(),
                    websocket: Mutex::default(),
                    network_epoch,
                })
            });
        }
        Ok(generation)
    }

    fn acquire(&self, base_url: &str, generation: u64) -> Result<HaTask, String> {
        let scope = connection_scope(base_url)?;
        let state = self.registration.lock().map_err(|_| STALE)?;
        let current = state.current.as_ref().filter(|current| {
            state.generation == generation
                && current.generation == generation
                && current.scope == scope
        }).ok_or(STALE)?;
        Ok(HaTask {
            cancel: current.cancel.clone(),
            connection: current.clone(),
            _running: current.tasks.clone().try_read_owned().map_err(|_| STALE)?,
        })
    }
}

fn connection_scope(base_url: &str) -> Result<String, String> {
    let (_, path) = crate::network::parse_ha_endpoint_parts(base_url, false)?;
    let url = reqwest::Url::parse(base_url.trim()).map_err(|_| "Invalid Home Assistant URL")?;
    let prefix = path.strip_suffix("/api/websocket").ok_or("Invalid Home Assistant URL")?;
    Ok(format!("{}{}", url.origin().ascii_serialization(), prefix))
}

#[tauri::command]
pub(crate) async fn ha_set_connection(
    connections: tauri::State<'_, HaConnections>,
    base_url: Option<String>,
) -> Result<u64, String> {
    let scope = base_url.as_deref().map(connection_scope).transpose()?;
    connections.configure(scope).await
}

fn describe_connect_io_error(error: &std::io::Error) -> String {
    match error.kind() {
        std::io::ErrorKind::ConnectionRefused => "connection refused".into(),
        std::io::ErrorKind::ConnectionReset => "connection reset".into(),
        std::io::ErrorKind::ConnectionAborted => "connection aborted".into(),
        std::io::ErrorKind::TimedOut => "timed out".into(),
        std::io::ErrorKind::AddrNotAvailable => "address not available".into(),
        std::io::ErrorKind::PermissionDenied => "permission denied".into(),
        _ => error.to_string(),
    }
}

fn format_connect_failures(failures: &[(std::net::SocketAddr, String)], timed_out: bool) -> String {
    if failures.is_empty() {
        if timed_out {
            return "Home Assistant connection timed out".into();
        }
        return "Home Assistant connection failed: no resolved addresses".into();
    }
    let summary = failures
        .iter()
        .map(|(addr, reason)| format!("{addr} ({reason})"))
        .collect::<Vec<_>>()
        .join("; ");
    if timed_out {
        format!("Home Assistant connection timed out after trying {summary}")
    } else {
        format!("Home Assistant connection failed: {summary}")
    }
}

async fn connect_addresses_with_budget<A, F, Fut>(
    addresses: A,
    total_budget: Duration,
    per_address_timeout: Duration,
    mut dial: F,
) -> Result<tokio::net::TcpStream, String>
where
    A: IntoIterator<Item = std::net::SocketAddr>,
    F: FnMut(std::net::SocketAddr) -> Fut,
    Fut: Future<Output = std::io::Result<tokio::net::TcpStream>>,
{
    let deadline = tokio::time::Instant::now() + total_budget;
    let mut failures: Vec<(std::net::SocketAddr, String)> = Vec::new();
    let mut budget_exhausted = false;

    for address in addresses {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            budget_exhausted = true;
            break;
        }
        let attempt_timeout = remaining.min(per_address_timeout);
        match tokio::time::timeout(attempt_timeout, dial(address)).await {
            Ok(Ok(stream)) => return Ok(stream),
            Ok(Err(error)) => failures.push((address, describe_connect_io_error(&error))),
            Err(_) => {
                failures.push((address, "timed out".into()));
                if tokio::time::Instant::now() >= deadline {
                    budget_exhausted = true;
                    break;
                }
            }
        }
    }

    Err(format_connect_failures(&failures, budget_exhausted))
}

impl HaTask {
    async fn http<T>(self, request: impl Future<Output = Result<T, String>>) -> Result<T, String> {
        self.cancel.run_until_cancelled(request).await.ok_or(CANCELLED)?
    }

    fn websocket(&self, url: String, token: &str) -> Result<mpsc::Sender<HaRequest>, String> {
        let mut session = self.connection.websocket.lock().map_err(|_| STALE)?;
        if self.cancel.is_cancelled() {
            return Err(CANCELLED.into());
        }
        let token_digest = digest(&SHA256, token.as_bytes());
        if let Some(channel) = session.as_ref() {
            if channel.token_digest.as_ref() != token_digest.as_ref() || channel.url != url {
                return Err(STALE.into());
            }
            return Ok(channel.sender.clone());
        }

        let worker = self.connection.tasks.clone().try_read_owned().map_err(|_| CANCELLED)?;
        let cancel = self.cancel.clone();
        let network_epoch = self.connection.network_epoch.subscribe();
        let (sender, receiver) = mpsc::channel(MAX_PENDING);
        let worker_url = url.clone();
        tauri::async_runtime::spawn(async move {
            let _running = worker;
            let _ = select(
                pin!(cancel.cancelled()),
                pin!(run_websocket(&worker_url, receiver, network_epoch)),
            )
            .await;
        });
        *session = Some(HaChannel { url, token_digest, sender: sender.clone() });
        Ok(sender)
    }
}

#[tauri::command]
pub(crate) async fn ha_http(
    connections: tauri::State<'_, HaConnections>,
    base_url: String,
    generation: u64,
    url: String,
    headers: Option<std::collections::HashMap<String, String>>,
    timeout_ms: Option<u64>,
) -> Result<crate::network::NativeHttpResponse, String> {
    let task = connections.acquire(&base_url, generation)?;
    let scope = connection_scope(&base_url)?;
    task.http(crate::network::native_http_with_scope(
        url, None, headers, None, None, timeout_ms, Some(scope),
    )).await
}

fn endpoint(base_url: &str, token: &str) -> Result<String, String> {
    if token.trim().is_empty() {
        return Err("Home Assistant token is required".into());
    }
    let (origin, ws_path) = crate::network::parse_ha_endpoint_parts(base_url, false)?;
    if !crate::allowed_origins_snapshot()?.contains(&origin) {
        return Err("Home Assistant endpoint has not been approved".into());
    }
    let mut url = reqwest::Url::parse(base_url.trim()).map_err(|_| "Invalid Home Assistant URL")?;
    let scheme = if url.scheme() == "https" { "wss" } else { "ws" };
    url.set_scheme(scheme)
        .map_err(|_| "Invalid Home Assistant URL")?;
    url.set_path(&ws_path);
    Ok(url.to_string())
}

const MAX_PENDING: usize = 32;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const CALL_TIMEOUT: Duration = Duration::from_secs(35);
const PING_INTERVAL: Duration = Duration::from_secs(25);
const PONG_TIMEOUT: Duration = Duration::from_secs(3);
const FAST_BACKOFF_WAIT_LIMIT: Duration = Duration::from_secs(10);
const REQUEST_TIMED_OUT: &str = "Home Assistant request timed out";
const PING_TIMED_OUT: &str = "Home Assistant ping timed out";
const NETWORK_CHANGED: &str = "Home Assistant network changed";
const BACKING_OFF: &str = "Home Assistant reconnect backing off";

#[derive(Clone, Copy)]
struct WebSocketTimings {
    ping_interval: Duration,
    pong_timeout: Duration,
    fast_backoff_wait_limit: Duration,
}

impl Default for WebSocketTimings {
    fn default() -> Self {
        Self {
            ping_interval: PING_INTERVAL,
            pong_timeout: PONG_TIMEOUT,
            fast_backoff_wait_limit: FAST_BACKOFF_WAIT_LIMIT,
        }
    }
}

fn jitter_unit_now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos() as f64
        / 1_000_000_000.0
}

struct HaChannel {
    url: String,
    token_digest: ring::digest::Digest,
    sender: mpsc::Sender<HaRequest>,
}

type Reply = oneshot::Sender<Result<Value, String>>;

struct HaRequest {
    packet: Value,
    token: String,
    reply: Reply,
}

struct InFlight {
    deadline: Instant,
    reply: Reply,
}

async fn authenticated(url: &str, token: &str) -> Result<Socket, String> {
    let parsed = reqwest::Url::parse(url).map_err(|_| "Invalid Home Assistant URL")?;
    let host = parsed.host_str().ok_or("Invalid Home Assistant host")?
        .trim_start_matches('[').trim_end_matches(']');
    let port = parsed.port_or_known_default().ok_or("Invalid Home Assistant port")?;
    let deadline = Instant::now() + CONNECT_TOTAL_TIMEOUT;
    let addresses = tokio::time::timeout_at(deadline, tokio::net::lookup_host((host, port)))
        .await
        .map_err(|_| "Home Assistant address lookup timed out")?
        .map_err(|_| "Home Assistant address lookup failed")?;
    let tcp = connect_addresses_with_budget(
        addresses,
        deadline.saturating_duration_since(Instant::now()),
        CONNECT_PER_ADDRESS_TIMEOUT,
        tokio::net::TcpStream::connect,
    ).await?;
    let tls_host = (parsed.scheme() == "wss").then_some(host);
    tokio::time::timeout(REQUEST_TIMEOUT, async {
        let mut socket = Socket::upgrade(url, tls_host, tcp).await?;
        if auth_packet(&mut socket).await?["type"] != "auth_required" {
            return Err("Home Assistant authentication handshake failed".into());
        }
        send_packet(&mut socket, json!({"type":"auth", "access_token":token})).await?;
        if auth_packet(&mut socket).await?["type"] != "auth_ok" {
            return Err("Home Assistant authentication rejected".into());
        }
        Ok(socket)
    }).await.map_err(|_| "Home Assistant handshake timed out")?
}

async fn auth_packet(socket: &mut Socket) -> Result<Value, String> {
    for _ in 0..64 {
        if let Message::Text(text) = socket.read().await? {
            return serde_json::from_str(&text).map_err(|_| "Invalid Home Assistant response".into());
        }
    }
    Err("Home Assistant sent too many control frames".into())
}

async fn send_packet(socket: &mut Socket, packet: Value) -> Result<(), String> {
    socket.send(Message::Text(packet.to_string().into())).await
}

enum ServeOutcome {
    Shutdown,
    Disconnected,
    NetworkReset,
}

async fn run_websocket(
    url: &str,
    requests: mpsc::Receiver<HaRequest>,
    network_epoch: watch::Receiver<u64>,
) {
    run_websocket_with_timings(url, requests, network_epoch, WebSocketTimings::default()).await;
}

async fn run_websocket_with_timings(
    url: &str,
    mut requests: mpsc::Receiver<HaRequest>,
    mut network_epoch: watch::Receiver<u64>,
    timings: WebSocketTimings,
) {
    let mut backoff = ReconnectBackoff::new(std::time::Instant::now());
    let mut seen_epoch = *network_epoch.borrow_and_update();

    loop {
        let first = {
            let next_req = pin!(requests.recv());
            let net_chg = pin!(network_epoch.changed());
            match select(next_req, net_chg).await {
                Either::Left((Some(req), _)) => req,
                Either::Left((None, _)) => return,
                Either::Right((Ok(()), _)) => {
                    seen_epoch = *network_epoch.borrow_and_update();
                    backoff.reset(std::time::Instant::now());
                    continue;
                }
                Either::Right((Err(_), _)) => return,
            }
        };

        if first.reply.is_closed() {
            continue;
        }
        if *network_epoch.borrow() != seen_epoch {
            seen_epoch = *network_epoch.borrow_and_update();
            backoff.reset(std::time::Instant::now());
        }

        let remaining = backoff.remaining(std::time::Instant::now());
        if remaining > timings.fast_backoff_wait_limit {
            // Away-from-home slow backoff (30s..300s): fail fast without dialing the network
            // until the backoff window expires or a network change resets it.
            let _ = first.reply.send(Err(BACKING_OFF.into()));
            continue;
        }
        if !remaining.is_zero() {
            let wake_at = Instant::from_std(backoff.ready_at());
            let woken_by_network = match select(
                pin!(tokio::time::sleep_until(wake_at)),
                pin!(network_epoch.changed()),
            )
            .await
            {
                Either::Left(_) => false,
                Either::Right((Ok(()), _)) => true,
                Either::Right((Err(_), _)) => return,
            };
            if woken_by_network {
                seen_epoch = *network_epoch.borrow_and_update();
                backoff.reset(std::time::Instant::now());
            }
        }
        if first.reply.is_closed() {
            continue;
        }

        let dial_outcome = {
            let auth = pin!(authenticated(url, &first.token));
            let net_chg = pin!(network_epoch.changed());
            match select(auth, net_chg).await {
                Either::Left((result, _)) => Some(result),
                Either::Right((Ok(()), _)) => {
                    seen_epoch = *network_epoch.borrow_and_update();
                    None
                }
                Either::Right((Err(_), _)) => return,
            }
        };

        match dial_outcome {
            None => {
                backoff.reset(std::time::Instant::now());
                let _ = first.reply.send(Err(NETWORK_CHANGED.into()));
            }
            Some(Ok(socket)) => {
                match serve_websocket(
                    socket,
                    first,
                    &mut requests,
                    &mut backoff,
                    &mut network_epoch,
                    &mut seen_epoch,
                    timings,
                )
                .await
                {
                    ServeOutcome::Shutdown => return,
                    ServeOutcome::NetworkReset => {
                        backoff.reset(std::time::Instant::now());
                    }
                    ServeOutcome::Disconnected => {
                        backoff.record_failure(std::time::Instant::now(), jitter_unit_now());
                    }
                }
            }
            Some(Err(error)) => {
                let _ = first.reply.send(Err(error));
                backoff.record_failure(std::time::Instant::now(), jitter_unit_now());
            }
        }
    }
}

async fn write_request(
    socket: &mut Socket,
    id: u64,
    mut request: HaRequest,
) -> Result<Option<InFlight>, String> {
    if request.reply.is_closed() {
        return Ok(None);
    }
    request.packet["id"] = json!(id);
    let deadline = Instant::now() + REQUEST_TIMEOUT;
    let result = tokio::time::timeout_at(deadline, send_packet(socket, request.packet)).await;
    let error = match result {
        Ok(Ok(())) => return Ok(Some(InFlight { deadline, reply: request.reply })),
        Ok(Err(error)) => error,
        Err(_) => REQUEST_TIMED_OUT.into(),
    };
    let _ = request.reply.send(Err(error.clone()));
    Err(error)
}

fn command_result(packet: Value) -> Option<(u64, Result<Value, String>)> {
    if packet["type"] != "result" {
        return None;
    }
    let id = packet["id"].as_u64()?;
    let result = if packet["success"] == true {
        Ok(packet["result"].clone())
    } else {
        Err("Home Assistant request failed".into())
    };
    Some((id, result))
}

#[derive(Clone, Copy)]
enum TimerAction {
    RequestTimedOut,
    SendPing,
    PongTimedOut,
}

enum SocketEvent {
    NetworkChanged(bool),
    Timer(TimerAction),
    Request(Option<HaRequest>),
    Message(Result<Message, String>),
}

async fn serve_websocket(
    mut socket: Socket,
    first: HaRequest,
    requests: &mut mpsc::Receiver<HaRequest>,
    backoff: &mut ReconnectBackoff,
    network_epoch: &mut watch::Receiver<u64>,
    seen_epoch: &mut u64,
    timings: WebSocketTimings,
) -> ServeOutcome {
    let mut outstanding = BTreeMap::new();
    let mut id = 1u64;
    let mut last_activity = Instant::now();
    let mut pending_ping: Option<(u64, Instant)> = None;

    match write_request(&mut socket, id, first).await {
        Ok(Some(sent)) => {
            outstanding.insert(id, sent);
        }
        Ok(None) => {}
        Err(_) => return ServeOutcome::Disconnected,
    }
    let (failure, outcome) = loop {
        let req_deadline = outstanding.first_key_value().map(|(_, sent)| sent.deadline);
        let (timer_at, timer_action) = match (req_deadline, pending_ping) {
            (Some(req_at), Some((_, pong_at))) if req_at <= pong_at => {
                (req_at, TimerAction::RequestTimedOut)
            }
            (_, Some((_, pong_at))) => (pong_at, TimerAction::PongTimedOut),
            (Some(req_at), None) if req_at <= last_activity + timings.ping_interval => {
                (req_at, TimerAction::RequestTimedOut)
            }
            (_, None) => (last_activity + timings.ping_interval, TimerAction::SendPing),
        };
        let can_accept = outstanding.len() < MAX_PENDING;
        let outgoing = async {
            if can_accept {
                requests.recv().await
            } else {
                pending::<Option<HaRequest>>().await
            }
        };
        let event = {
            let network = pin!(network_epoch.changed());
            let timer = pin!(tokio::time::sleep_until(timer_at));
            let outgoing = pin!(outgoing);
            let incoming = pin!(socket.read());
            let control = select(network, timer);
            let io = select(outgoing, incoming);
            match select(control, io).await {
                Either::Left((Either::Left((changed, _)), _)) => {
                    SocketEvent::NetworkChanged(changed.is_ok())
                }
                Either::Left((Either::Right(_), _)) => SocketEvent::Timer(timer_action),
                Either::Right((Either::Left((request, _)), _)) => SocketEvent::Request(request),
                Either::Right((Either::Right((message, _)), _)) => SocketEvent::Message(message),
            }
        };
        match event {
            SocketEvent::NetworkChanged(true) => {
                *seen_epoch = *network_epoch.borrow_and_update();
                break (NETWORK_CHANGED.to_string(), ServeOutcome::NetworkReset);
            }
            SocketEvent::NetworkChanged(false) => {
                break (CANCELLED.to_string(), ServeOutcome::Shutdown);
            }
            SocketEvent::Timer(TimerAction::RequestTimedOut) => {
                break (REQUEST_TIMED_OUT.to_string(), ServeOutcome::Disconnected);
            }
            SocketEvent::Timer(TimerAction::PongTimedOut) => {
                break (PING_TIMED_OUT.to_string(), ServeOutcome::Disconnected);
            }
            SocketEvent::Timer(TimerAction::SendPing) => {
                id += 1;
                let ping_id = id;
                let pong_deadline = Instant::now() + timings.pong_timeout;
                match tokio::time::timeout_at(
                    pong_deadline,
                    send_packet(&mut socket, json!({"id": ping_id, "type": "ping"})),
                )
                .await
                {
                    Ok(Ok(())) => {
                        pending_ping = Some((ping_id, pong_deadline));
                    }
                    Ok(Err(error)) => break (error, ServeOutcome::Disconnected),
                    Err(_) => break (PING_TIMED_OUT.to_string(), ServeOutcome::Disconnected),
                }
            }
            SocketEvent::Request(None) => return ServeOutcome::Shutdown,
            SocketEvent::Request(Some(request)) => {
                id += 1;
                match write_request(&mut socket, id, request).await {
                    Ok(Some(sent)) => {
                        outstanding.insert(id, sent);
                    }
                    Ok(None) => {}
                    Err(error) => break (error, ServeOutcome::Disconnected),
                }
            }
            SocketEvent::Message(Ok(Message::Text(text))) => {
                last_activity = Instant::now();
                let Ok(packet) = serde_json::from_str::<Value>(&text) else {
                    break ("Invalid Home Assistant response".into(), ServeOutcome::Disconnected);
                };
                if packet["type"] == "pong" {
                    if pending_ping.is_some_and(|(pid, _)| packet["id"].as_u64() == Some(pid)) {
                        pending_ping = None;
                    }
                    continue;
                }
                // Subscription events can be routed here without consuming command replies.
                if let Some((id, result)) = command_result(packet) {
                    if let Some(sent) = outstanding.remove(&id) {
                        backoff.reset(std::time::Instant::now());
                        let _ = sent.reply.send(result);
                    }
                }
            }
            SocketEvent::Message(Ok(Message::Pong(_))) => {
                last_activity = Instant::now();
            }
            SocketEvent::Message(Err(error)) => break (error, ServeOutcome::Disconnected),
            SocketEvent::Message(Ok(_)) => {}
        }
    };
    // Commands already written may have taken effect. Fail their callers without replaying them.
    for (_, sent) in outstanding {
        let _ = sent.reply.send(Err(failure.clone()));
    }
    outcome
}

impl HaTask {
    async fn request(
        &self,
        sender: &mpsc::Sender<HaRequest>,
        token: &str,
        packet: Value,
    ) -> Result<Value, String> {
        let (reply, response) = oneshot::channel();
        let request = async {
            sender.send(HaRequest { packet, token: token.to_owned(), reply }).await
                .map_err(|_| CANCELLED)?;
            response.await.map_err(|_| CANCELLED)?
        };
        self.cancel.run_until_cancelled(tokio::time::timeout(CALL_TIMEOUT, request)).await
            .ok_or(CANCELLED)?
            .map_err(|_| REQUEST_TIMED_OUT)?
    }

    async fn snapshot(&self, url: String, token: &str) -> Result<HaSnapshot, String> {
        let sender = self.websocket(url, token)?;
        Ok(HaSnapshot {
            areas: self.request(&sender, token, json!({"type":"config/area_registry/list"})).await?,
            devices: self.request(&sender, token, json!({"type":"config/device_registry/list"})).await?,
            entities: self.request(&sender, token, json!({"type":"config/entity_registry/list"})).await?,
            states: self.request(&sender, token, json!({"type":"get_states"})).await?,
        })
    }

    async fn execute(&self, url: String, token: &str, command: HaServiceCall) -> Result<(), String> {
        let sender = self.websocket(url, token)?;
        self.request(&sender, token, json!({
            "type":"call_service", "domain":command.domain, "service":command.service,
            "target":{"entity_id":command.entity_id}, "service_data":command.data
        })).await?;
        Ok(())
    }
}

fn validate_call(command: &HaServiceCall) -> Result<(), String> {
    let allowed: &[(&str, &[&str])] = &[
        ("light", &["turn_on", "turn_off"]),
        (
            "climate",
            &[
                "set_hvac_mode",
                "set_temperature",
                "set_fan_mode",
                "set_swing_mode",
            ],
        ),
        (
            "cover",
            &[
                "open_cover",
                "close_cover",
                "stop_cover",
                "set_cover_position",
            ],
        ),
        (
            "fan",
            &[
                "turn_on",
                "turn_off",
                "set_percentage",
                "set_preset_mode",
                "oscillate",
            ],
        ),
        ("switch", &["turn_on", "turn_off"]),
        ("input_boolean", &["turn_on", "turn_off"]),
        ("button", &["press"]),
        ("camera", &["turn_on", "turn_off"]),
        ("select", &["select_option"]),
        ("number", &["set_value"]),
        (
            "humidifier",
            &["turn_on", "turn_off", "set_humidity", "set_mode"],
        ),
        (
            "water_heater",
            &[
                "turn_on",
                "turn_off",
                "set_temperature",
                "set_operation_mode",
            ],
        ),
        (
            "valve",
            &[
                "open_valve",
                "close_valve",
                "stop_valve",
                "set_valve_position",
            ],
        ),
        (
            "media_player",
            &[
                "turn_on",
                "turn_off",
                "media_play_pause",
                "volume_set",
                "volume_mute",
                "select_source",
            ],
        ),
        ("vacuum", &["start", "pause", "return_to_base"]),
        ("scene", &["turn_on"]),
        ("script", &["turn_on"]),
    ];
    if !allowed.iter().any(|(domain, services)| {
        *domain == command.domain && services.contains(&command.service.as_str())
    }) || !command
        .entity_id
        .starts_with(&format!("{}.", command.domain))
        || command.entity_id.len() <= command.domain.len() + 1
        || !command.entity_id.chars().all(|character| {
            character.is_ascii_alphanumeric() || character == '_' || character == '.'
        })
    {
        return Err("Home Assistant service is not allowed".into());
    }
    let keys: &[&str] = match (command.domain.as_str(), command.service.as_str()) {
        ("light", "turn_on") => &["brightness_pct", "color_temp_kelvin", "effect"],
        ("climate", "set_hvac_mode") => &["hvac_mode"],
        ("climate", "set_temperature") => &["temperature"],
        ("climate", "set_fan_mode") => &["fan_mode"],
        ("climate", "set_swing_mode") => &["swing_mode"],
        ("cover", "set_cover_position") => &["position"],
        ("fan", "set_percentage") => &["percentage"],
        ("fan", "set_preset_mode") => &["preset_mode"],
        ("fan", "oscillate") => &["oscillating"],
        ("select", "select_option") => &["option"],
        ("number", "set_value") => &["value"],
        ("humidifier", "set_humidity") => &["humidity"],
        ("humidifier", "set_mode") => &["mode"],
        ("water_heater", "set_temperature") => &["temperature"],
        ("water_heater", "set_operation_mode") => &["operation_mode"],
        ("valve", "set_valve_position") => &["position"],
        ("media_player", "volume_set") => &["volume_level"],
        ("media_player", "volume_mute") => &["is_volume_muted"],
        ("media_player", "select_source") => &["source"],
        _ => &[],
    };
    if command.data.keys().any(|key| !keys.contains(&key.as_str())) {
        return Err("Home Assistant service data is not allowed".into());
    }
    Ok(())
}

#[tauri::command]
pub(crate) async fn ha_snapshot(
    connections: tauri::State<'_, HaConnections>,
    base_url: String,
    generation: u64,
    token: String,
) -> Result<HaSnapshot, String> {
    let task = connections.acquire(&base_url, generation)?;
    task.snapshot(endpoint(&base_url, &token)?, &token).await
}

#[tauri::command]
pub(crate) async fn ha_execute(
    connections: tauri::State<'_, HaConnections>,
    base_url: String,
    generation: u64,
    token: String,
    command: HaServiceCall,
) -> Result<(), String> {
    let task = connections.acquire(&base_url, generation)?;
    validate_call(&command)?;
    task.execute(endpoint(&base_url, &token)?, &token, command).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpStream;
    use tungstenite::WebSocket;
    #[test]
    fn rejects_missing_tokens_and_non_http_origins() {
        assert!(endpoint("http://localhost:8123", "").is_err());
        assert!(endpoint("file:///tmp/ha", "example").is_err());
        assert!(endpoint("ws://localhost:8123", "example").is_err());
        assert!(endpoint("http://localhost:8123", "example").is_err());
    }
    #[test]
    fn restricts_service_commands_and_target_overrides() {
        let mut call = HaServiceCall {
            domain: "light".into(),
            service: "turn_on".into(),
            entity_id: "light.study".into(),
            data: Default::default(),
        };
        assert!(validate_call(&call).is_ok());
        call.service = "delete".into();
        assert!(validate_call(&call).is_err());
        call.service = "turn_on".into();
        call.data.insert("entity_id".into(), json!("all"));
        assert!(validate_call(&call).is_err());
    }

    #[test]
    fn allows_number_set_value_for_fridge_targets() {
        let mut call = HaServiceCall {
            domain: "number".into(),
            service: "set_value".into(),
            entity_id: "number.fridge_target_temperature_p_3".into(),
            data: Default::default(),
        };
        call.data.insert("value".into(), json!(4));
        assert!(validate_call(&call).is_ok());
        call.data.insert("entity_id".into(), json!("all"));
        assert!(validate_call(&call).is_err());
    }

    #[test]
    fn allows_media_player_volume_set_for_speakers() {
        let mut call = HaServiceCall {
            domain: "media_player".into(),
            service: "volume_set".into(),
            entity_id: "media_player.living_room_speaker".into(),
            data: Default::default(),
        };
        call.data.insert("volume_level".into(), json!(0.5));
        assert!(validate_call(&call).is_ok());
        call.data.insert("entity_id".into(), json!("all"));
        assert!(validate_call(&call).is_err());
    }

    #[test]
    fn allows_cover_and_climate_swing_services_and_rejects_extra_keys() {
        let mut swing = HaServiceCall {
            domain: "climate".into(),
            service: "set_swing_mode".into(),
            entity_id: "climate.living_room_ac".into(),
            data: Default::default(),
        };
        swing.data.insert("swing_mode".into(), json!("vertical"));
        assert!(validate_call(&swing).is_ok());
        swing.data.insert("entity_id".into(), json!("all"));
        assert!(validate_call(&swing).is_err());

        for service in ["open_cover", "close_cover", "stop_cover"] {
            let mut motor = HaServiceCall {
                domain: "cover".into(),
                service: service.into(),
                entity_id: "cover.living_room_curtain".into(),
                data: Default::default(),
            };
            assert!(validate_call(&motor).is_ok());
            motor.data.insert("position".into(), json!(50));
            assert!(validate_call(&motor).is_err());
        }

        let mut pos = HaServiceCall {
            domain: "cover".into(),
            service: "set_cover_position".into(),
            entity_id: "cover.living_room_curtain".into(),
            data: Default::default(),
        };
        pos.data.insert("position".into(), json!(45));
        assert!(validate_call(&pos).is_ok());
        pos.data.insert("tilt_position".into(), json!(20));
        assert!(validate_call(&pos).is_err());
    }

    #[test]
    fn allows_subpath_websocket_endpoints_once_origin_is_authorized() {
        let _guard = crate::ORIGIN_TEST_LOCK.lock().unwrap();
        let origins = [
            crate::normalize_extra_origin("https://home.example.com").unwrap(),
            crate::normalize_extra_origin("http://192.168.1.8:8123").unwrap(),
        ];
        for origin in &origins {
            crate::EXTRA_ALLOWED_ORIGINS
                .write()
                .unwrap()
                .insert(origin.clone());
        }
        assert_eq!(
            endpoint("https://home.example.com/hass", "tok").unwrap(),
            "wss://home.example.com/hass/api/websocket"
        );
        assert_eq!(
            endpoint("https://home.example.com/hass/api/", "tok").unwrap(),
            "wss://home.example.com/hass/api/websocket"
        );
        assert_eq!(
            endpoint("http://192.168.1.8:8123/ha/", "tok").unwrap(),
            "ws://192.168.1.8:8123/ha/api/websocket"
        );
        assert!(endpoint("https://home.example.com/hass?token=abc", "tok").is_err());
        assert!(endpoint("https://home.example.com/hass#frag", "tok").is_err());
        assert!(endpoint("https://user:pw@home.example.com/hass", "tok").is_err());
        assert!(endpoint("https://unapproved.example.com/hass", "tok").is_err());
        for origin in &origins {
            crate::EXTRA_ALLOWED_ORIGINS.write().unwrap().remove(origin);
        }
    }

    #[test]
    fn allows_humidifier_water_heater_valve_media_player_input_boolean_and_blocks_lock() {
        let valid_cases: &[(&str, &str, &str, Option<(&str, Value)>)] = &[
            ("humidifier", "turn_on", "humidifier.living", None),
            ("humidifier", "turn_off", "humidifier.living", None),
            ("humidifier", "set_humidity", "humidifier.living", Some(("humidity", json!(55)))),
            ("humidifier", "set_mode", "humidifier.living", Some(("mode", json!("sleep")))),
            ("water_heater", "turn_on", "water_heater.boiler", None),
            ("water_heater", "turn_off", "water_heater.boiler", None),
            ("water_heater", "set_temperature", "water_heater.boiler", Some(("temperature", json!(56)))),
            ("water_heater", "set_operation_mode", "water_heater.boiler", Some(("operation_mode", json!("eco")))),
            ("valve", "open_valve", "valve.water_main", None),
            ("valve", "close_valve", "valve.water_main", None),
            ("valve", "stop_valve", "valve.water_main", None),
            ("valve", "set_valve_position", "valve.water_main", Some(("position", json!(50)))),
            ("media_player", "turn_on", "media_player.speaker", None),
            ("media_player", "turn_off", "media_player.speaker", None),
            ("media_player", "media_play_pause", "media_player.speaker", None),
            ("media_player", "volume_mute", "media_player.speaker", Some(("is_volume_muted", json!(true)))),
            ("media_player", "select_source", "media_player.speaker", Some(("source", json!("HDMI 1")))),
            ("input_boolean", "turn_on", "input_boolean.guest_mode", None),
            ("input_boolean", "turn_off", "input_boolean.guest_mode", None),
        ];
        for (domain, service, entity_id, payload) in valid_cases {
            let mut call = HaServiceCall {
                domain: (*domain).into(),
                service: (*service).into(),
                entity_id: (*entity_id).into(),
                data: Default::default(),
            };
            if let Some((k, v)) = payload {
                call.data.insert((*k).into(), v.clone());
            }
            assert!(validate_call(&call).is_ok(), "{domain}.{service}");
            call.data.insert("unexpected".into(), json!(1));
            assert!(validate_call(&call).is_err(), "{domain}.{service} rejected unexpected key");
        }

        // Locks stay strictly read-only per ADR-0001.
        for lock_service in ["unlock", "lock", "open"] {
            let lock_call = HaServiceCall {
                domain: "lock".into(),
                service: lock_service.into(),
                entity_id: "lock.front_door".into(),
                data: Default::default(),
            };
            assert!(validate_call(&lock_call).is_err(), "lock.{lock_service} must be blocked");
        }
    }

    #[test]
    fn registration_rejects_old_scope_and_generation_until_drain_finishes() {
        tauri::async_runtime::block_on(async {
            let a = "https://home.example/first";
            let b = "https://home.example/second";
            let connections = Arc::new(HaConnections::default());
            assert!(connections.acquire(a, 1).is_err());
            let gen1 = connections.configure(Some(connection_scope(a).unwrap())).await.unwrap();
            assert_eq!(gen1, 1);
            let task = connections.acquire("https://HOME.example:443/first/api/websocket/", gen1).unwrap();
            assert!(connections.acquire(b, gen1).is_err());

            let stop = {
                let connections = connections.clone();
                tauri::async_runtime::spawn(async move { connections.configure(None).await })
            };
            tokio::time::timeout(Duration::from_secs(2), task.cancel.cancelled()).await.unwrap();
            assert!(connections.acquire(a, gen1).is_err());

            let switch = connections.configure(Some(connection_scope(b).unwrap()));
            let mut switch = std::pin::pin!(switch);
            std::future::poll_fn(|cx| {
                assert!(switch.as_mut().poll(cx).is_pending());
                std::task::Poll::Ready(())
            }).await;
            assert!(connections.acquire(b, 3).is_err());
            assert!(!stop.inner().is_finished());
            drop(task);
            let gen3 = switch.await.unwrap();
            let gen2 = stop.await.unwrap().unwrap();
            assert!(gen2 > gen1 && gen3 > gen2);

            assert!(connections.acquire(b, gen3).is_ok());
            assert!(connections.acquire(a, gen3).is_err());
            assert!(connections.acquire(b, gen1).is_err());
            assert!(connections.acquire(b, gen2).is_err());
            let gen4 = connections.configure(Some(connection_scope(b).unwrap())).await.unwrap();
            assert!(gen4 > gen3);
            assert!(connections.acquire(b, gen3).is_err());
            assert!(connections.acquire(b, gen4).is_ok());
        });
    }

    #[test]
    fn configure_times_out_with_still_draining_when_worker_blocks() {
        tauri::async_runtime::block_on(async {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let connections = Arc::new(HaConnections::default());
            let gen1 = connections
                .configure_with_timeout(Some(connection_scope(&base).unwrap()), Duration::from_secs(2))
                .await
                .unwrap();
            let task = connections.acquire(&base, gen1).unwrap();
            let (release_tx, release_rx) = tokio::sync::oneshot::channel::<()>();
            let (started_tx, started_rx) = tokio::sync::oneshot::channel::<()>();

            // Simulate a worker that holds the `HaTask` read guard even after cancellation.
            let stuck_worker = tauri::async_runtime::spawn(async move {
                let _task = task;
                let _ = started_tx.send(());
                let _ = release_rx.await;
            });
            tokio::time::timeout(Duration::from_secs(2), started_rx)
                .await
                .unwrap()
                .unwrap();

            let err = connections
                .configure_with_timeout(None, Duration::from_millis(60))
                .await
                .unwrap_err();
            assert_eq!(err, STILL_DRAINING);
            assert!(connections.acquire(&base, gen1).is_err());

            // Once the blocked worker exits, a subsequent configure drains and succeeds cleanly.
            let _ = release_tx.send(());
            stuck_worker.await.unwrap();
            let next_base = "https://home.example/recovered";
            let gen3 = connections
                .configure_with_timeout(
                    Some(connection_scope(next_base).unwrap()),
                    Duration::from_secs(2),
                )
                .await
                .unwrap();
            assert!(gen3 > gen1);
            assert!(connections.acquire(next_base, gen3).is_ok());
        });
    }

    #[test]
    fn multi_address_connect_aggregates_failures_and_enforces_total_budget() {
        tauri::async_runtime::block_on(async {
            let addrs: [std::net::SocketAddr; 3] = [
                "127.0.0.1:1".parse().unwrap(),
                "127.0.0.1:2".parse().unwrap(),
                "127.0.0.1:3".parse().unwrap(),
            ];
            let err = connect_addresses_with_budget(
                addrs,
                Duration::from_secs(2),
                Duration::from_secs(1),
                |addr| async move {
                    match addr.port() {
                        1 => Err(std::io::Error::new(
                            std::io::ErrorKind::ConnectionRefused,
                            "refused",
                        )),
                        2 => Err(std::io::Error::new(
                            std::io::ErrorKind::ConnectionReset,
                            "reset",
                        )),
                        _ => Err(std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "timed out",
                        )),
                    }
                },
            )
            .await
            .unwrap_err();
            assert!(err.contains("127.0.0.1:1 (connection refused)"), "unexpected err: {err}");
            assert!(err.contains("127.0.0.1:2 (connection reset)"), "unexpected err: {err}");
            assert!(err.contains("127.0.0.1:3 (timed out)"), "unexpected err: {err}");

            // Total budget stops serial fallback before exhausting every slow address.
            let slow_addrs: [std::net::SocketAddr; 4] = [
                "127.0.0.1:11".parse().unwrap(),
                "127.0.0.1:12".parse().unwrap(),
                "127.0.0.1:13".parse().unwrap(),
                "127.0.0.1:14".parse().unwrap(),
            ];
            let attempts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
            let attempts_clone = attempts.clone();
            let started = Instant::now();
            let budget_err = connect_addresses_with_budget(
                slow_addrs,
                Duration::from_millis(90),
                Duration::from_millis(60),
                move |_addr| {
                    let attempts = attempts_clone.clone();
                    async move {
                        attempts.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        tokio::time::sleep(Duration::from_secs(1)).await;
                        Err(std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "slow",
                        ))
                    }
                },
            )
            .await
            .unwrap_err();
            assert!(
                started.elapsed() < Duration::from_secs(1),
                "total budget took too long: {:?}",
                started.elapsed()
            );
            assert!(
                attempts.load(std::sync::atomic::Ordering::SeqCst) < slow_addrs.len(),
                "expected total budget to stop before all {} addresses",
                slow_addrs.len()
            );
            assert!(
                budget_err.contains("timed out"),
                "expected timeout diagnostic, got: {budget_err}"
            );

            // Falls back past a refused address to a reachable loopback listener.
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let live_addr = listener.local_addr().unwrap();
            let failed_addr: std::net::SocketAddr = "127.0.0.1:1".parse().unwrap();
            let stream = connect_addresses_with_budget(
                [failed_addr, live_addr],
                Duration::from_secs(2),
                Duration::from_secs(1),
                move |addr| async move {
                    if addr == failed_addr {
                        Err(std::io::Error::new(
                            std::io::ErrorKind::ConnectionRefused,
                            "refused",
                        ))
                    } else {
                        tokio::net::TcpStream::connect(addr).await
                    }
                },
            )
            .await
            .unwrap();
            assert_eq!(stream.peer_addr().unwrap(), live_addr);
        });
    }

    #[test]
    fn cancellation_wakes_upgrade_and_websocket_read_and_joins_worker() {
        for complete_upgrade in [false, true] {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let (waiting, ready) = tokio::sync::oneshot::channel();
            let peer = std::thread::spawn(move || {
                use std::io::Read;
                let (mut stream, _) = listener.accept().unwrap();
                stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
                if complete_upgrade {
                    let mut socket = tungstenite::accept(stream).unwrap();
                    send_fixture(&mut socket, "auth_required");
                    assert!(socket.read().unwrap().is_text());
                    send_fixture(&mut socket, "auth_ok");
                    assert!(socket.read().unwrap().is_text()); // Snapshot's first request.
                    waiting.send(()).unwrap();
                    assert!(socket.read().is_err());
                } else {
                    // Leave the WebSocket upgrade pending after receiving its HTTP headers.
                    let mut byte = [0];
                    let mut headers = Vec::new();
                    while !headers.ends_with(b"\r\n\r\n") {
                        stream.read_exact(&mut byte).unwrap();
                        headers.push(byte[0]);
                    }
                    waiting.send(()).unwrap();
                    assert_peer_disconnected(stream.read(&mut byte));
                }
            });
            tauri::async_runtime::block_on(async {
                let connections = HaConnections::default();
                let gen1 = connections.configure(Some(connection_scope(&base).unwrap())).await.unwrap();
                let task = connections.acquire(&base, gen1).unwrap();
                let url = format!("{}/api/websocket", base.replacen("http:", "ws:", 1));
                let operation = tauri::async_runtime::spawn(async move {
                    task.snapshot(url, "fixture-token").await
                });
                tokio::time::timeout(Duration::from_secs(2), ready).await.unwrap().unwrap();
                tokio::time::timeout(Duration::from_secs(2), connections.configure(None))
                    .await.unwrap().unwrap();
                assert!(operation.await.unwrap().is_err());
                assert!(connections.acquire(&base, gen1).is_err());
            });
            peer.join().unwrap();
        }
    }

    fn assert_peer_disconnected(read: std::io::Result<usize>) {
        match read {
            Ok(0) => (),
            Err(ref error) if matches!(error.kind(), std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted) => (),
            _ => panic!("expected cancelled connection to close, got {read:?}"),
        }
    }

    fn send_fixture(socket: &mut WebSocket<TcpStream>, packet_type: &str) {
        socket.send(Message::Text(json!({"type":packet_type}).to_string().into())).unwrap();
    }

    #[test]
    fn cancellation_closes_http_request_and_streaming_response_body() {
        let _guard = crate::ORIGIN_TEST_LOCK.lock().unwrap();
        for send_headers in [false, true] {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let origin = crate::normalize_extra_origin(&base).unwrap();
            crate::EXTRA_ALLOWED_ORIGINS.write().unwrap().insert(origin.clone());
            let (waiting, ready) = tokio::sync::oneshot::channel();
            let peer = std::thread::spawn(move || {
                use std::io::{BufRead, BufReader, Read, Write};
                let (mut socket, _) = listener.accept().unwrap();
                socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
                let mut request = BufReader::new(&mut socket);
                loop {
                    let mut header = String::new();
                    assert!(request.read_line(&mut header).unwrap() > 0);
                    if header == "\r\n" {
                        break;
                    }
                }
                if send_headers {
                    // Start an SSE body, leaving it open after the first event.
                    socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n9\r\ndata: 1\n\n\r\n").unwrap();
                }
                waiting.send(()).unwrap();
                assert_peer_disconnected(socket.read(&mut [0]));
            });
            tauri::async_runtime::block_on(async {
                let connections = HaConnections::default();
                let gen1 = connections.configure(Some(connection_scope(&base).unwrap())).await.unwrap();
                let task = connections.acquire(&base, gen1).unwrap();
                let operation = tauri::async_runtime::spawn(task.http(crate::network::native_http_with_scope(
                    format!("{base}/api/stream"), None, None, None, None, Some(10_000),
                    Some(connection_scope(&base).unwrap()),
                )));
                tokio::time::timeout(Duration::from_secs(2), ready).await.unwrap().unwrap();
                tokio::time::timeout(Duration::from_secs(2), connections.configure(None))
                    .await.unwrap().unwrap();
                assert_eq!(operation.await.unwrap().err().as_deref(), Some(CANCELLED));
            });
            peer.join().unwrap();
            crate::EXTRA_ALLOWED_ORIGINS.write().unwrap().remove(&origin);
        }
    }

    #[test]
    fn command_results_ignore_events_and_keep_server_errors_private() {
        assert!(command_result(json!({"id":1,"type":"event"})).is_none());
        assert!(command_result(json!({"id":"1","type":"result"})).is_none());
        assert_eq!(
            command_result(json!({"id":1,"type":"result","success":false,
                "error":{"message":"fixture-token"}})),
            Some((1, Err("Home Assistant request failed".into())))
        );
    }

    fn fixture_request(socket: &mut WebSocket<TcpStream>) -> Value {
        serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap()
    }

    fn fixture_socket(listener: &std::net::TcpListener, token: &str) -> WebSocket<TcpStream> {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(4))).unwrap();
        let mut socket = tungstenite::accept(stream).unwrap();
        send_fixture(&mut socket, "auth_required");
        let auth = fixture_request(&mut socket);
        assert_eq!(auth["type"], "auth");
        assert!(auth["access_token"] == token, "unexpected fixture credential");
        socket
    }

    fn fixture_result(socket: &mut WebSocket<TcpStream>, id: &Value, value: Value) {
        socket.send(Message::Text(
            json!({"id":id, "type":"result", "success":true, "result":value}).to_string().into(),
        )).unwrap();
    }

    #[test]
    fn persistent_websocket_routes_reordered_replies_and_reconnects_without_replaying() {
        const TOKEN: &str = "fixture-token";
        const ROTATED: &str = "rotated-fixture-token";
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let base = format!("http://{address}");
        let url = format!("ws://{address}/api/websocket");
        let fixture: Value =
            serde_json::from_str(include_str!("../../../Tests/Fixtures/ha_snapshot.json")).unwrap();
        let peer = std::thread::spawn(move || {
            let mut first = fixture_socket(&listener, TOKEN);
            send_fixture(&mut first, "auth_ok");
            let one = fixture_request(&mut first);
            let two = fixture_request(&mut first);
            let (call, area) = if one["type"] == "call_service" { (one, two) } else { (two, one) };
            assert_eq!(call["target"]["entity_id"], "light.study");
            assert_eq!(area["type"], "config/area_registry/list");
            assert_ne!(call["id"], area["id"]);
            let (one, one_result, two, two_result) = if call["id"].as_u64() < area["id"].as_u64() {
                (call, Value::Null, area, fixture["areas"].clone())
            } else {
                (area, fixture["areas"].clone(), call, Value::Null)
            };
            fixture_result(&mut first, &two["id"], two_result);
            fixture_result(&mut first, &one["id"], one_result);
            for (name, key) in [
                ("config/device_registry/list", "devices"),
                ("config/entity_registry/list", "entities"),
                ("get_states", "states"),
            ] {
                let packet = fixture_request(&mut first);
                assert_eq!(packet["type"], name);
                fixture_result(&mut first, &packet["id"], fixture[key].clone());
            }
            assert_eq!(fixture_request(&mut first)["target"]["entity_id"], "light.dropped");
            drop(first);

            let mut second = fixture_socket(&listener, TOKEN);
            send_fixture(&mut second, "auth_ok");
            let packet = fixture_request(&mut second);
            assert_eq!(packet["target"]["entity_id"], "light.after_drop");
            fixture_result(&mut second, &packet["id"], Value::Null);
            assert!(second.read().is_err());

            let mut rotated = fixture_socket(&listener, ROTATED);
            rotated.send(Message::Text(
                json!({"type":"auth_invalid","message":ROTATED}).to_string().into(),
            )).unwrap();
        });
        let command = |entity: &str| HaServiceCall {
            domain: "light".into(),
            service: "turn_off".into(),
            entity_id: entity.into(),
            data: Default::default(),
        };
        tauri::async_runtime::block_on(async {
            let connections = HaConnections::default();
            let scope = connection_scope(&base).unwrap();
            let generation = connections.configure(Some(scope.clone())).await.unwrap();
            let (snapshot, control) = futures_util::future::join(
                async {
                    connections.acquire(&base, generation).unwrap().snapshot(url.clone(), TOKEN).await
                },
                async {
                    connections.acquire(&base, generation).unwrap()
                        .execute(url.clone(), TOKEN, command("light.study")).await
                },
            ).await;
            assert_eq!(snapshot.unwrap().states.as_array().unwrap().len(), 6);
            assert!(control.is_ok());

            let task = connections.acquire(&base, generation).unwrap();
            assert!(task.execute(url.clone(), TOKEN, command("light.dropped")).await.is_err());
            task.execute(url.clone(), TOKEN, command("light.after_drop")).await.unwrap();
            drop(task);

            let generation = connections.configure(Some(scope)).await.unwrap();
            let error = connections.acquire(&base, generation).unwrap()
                .execute(url, ROTATED, command("light.study")).await.unwrap_err();
            assert_eq!(error, "Home Assistant authentication rejected");
            connections.configure(None).await.unwrap();
        });
        peer.join().unwrap();
    }

    #[test]
    fn network_change_drops_idle_websocket_immediately_and_reestablishes_on_next_request() {
        const TOKEN: &str = "fixture-token";
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let base = format!("http://{address}");
        let url = format!("ws://{address}/api/websocket");
        let (first_dropped_tx, first_dropped_rx) = tokio::sync::oneshot::channel();
        let peer = std::thread::spawn(move || {
            let mut first = fixture_socket(&listener, TOKEN);
            send_fixture(&mut first, "auth_ok");
            let req = fixture_request(&mut first);
            fixture_result(&mut first, &req["id"], Value::Null);
            // Expect the client to drop this socket promptly on network change.
            assert!(first.read().is_err());
            let _ = first_dropped_tx.send(());

            let mut second = fixture_socket(&listener, TOKEN);
            send_fixture(&mut second, "auth_ok");
            let req2 = fixture_request(&mut second);
            fixture_result(&mut second, &req2["id"], Value::Null);
            let _ = second.read();
        });

        let command = |entity: &str| HaServiceCall {
            domain: "light".into(),
            service: "turn_off".into(),
            entity_id: entity.into(),
            data: Default::default(),
        };
        tauri::async_runtime::block_on(async {
            let connections = HaConnections::default();
            let scope = connection_scope(&base).unwrap();
            let generation = connections.configure(Some(scope)).await.unwrap();
            let task = connections.acquire(&base, generation).unwrap();
            task.execute(url.clone(), TOKEN, command("light.before")).await.unwrap();

            // Trigger network change; idle socket must drop immediately without waiting for timeout.
            connections.handle_network_or_resume();
            tokio::time::timeout(Duration::from_secs(2), first_dropped_rx)
                .await
                .unwrap()
                .unwrap();

            // Next request re-establishes immediately (0ms backoff after network reset).
            let started = Instant::now();
            task.execute(url, TOKEN, command("light.after")).await.unwrap();
            assert!(
                started.elapsed() < Duration::from_secs(2),
                "re-establish after network change took too long: {:?}",
                started.elapsed()
            );
            drop(task);
            connections.configure(None).await.unwrap();
        });
        peer.join().unwrap();
    }

    #[test]
    fn ping_pong_liveness_drops_dead_socket_when_pong_times_out() {
        const TOKEN: &str = "fixture-token";
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let url = format!("ws://{address}/api/websocket");
        let (closed_tx, closed_rx) = tokio::sync::oneshot::channel();
        let peer = std::thread::spawn(move || {
            let mut sock = fixture_socket(&listener, TOKEN);
            send_fixture(&mut sock, "auth_ok");
            let first = fixture_request(&mut sock);
            fixture_result(&mut sock, &first["id"], Value::Null);

            // Expect a ping packet; intentionally withhold the pong to simulate a half-open socket.
            let ping = fixture_request(&mut sock);
            assert_eq!(ping["type"], "ping");
            assert!(ping["id"].as_u64().is_some());
            assert!(sock.read().is_err());
            let _ = closed_tx.send(());
        });

        tauri::async_runtime::block_on(async {
            let (tx, rx) = mpsc::channel(4);
            let (_epoch_tx, epoch_rx) = watch::channel(0u64);
            let timings = WebSocketTimings {
                ping_interval: Duration::from_millis(80),
                pong_timeout: Duration::from_millis(120),
                fast_backoff_wait_limit: Duration::from_secs(10),
            };
            let worker = tauri::async_runtime::spawn(async move {
                run_websocket_with_timings(&url, rx, epoch_rx, timings).await;
            });

            let (reply_tx, reply_rx) = oneshot::channel();
            tx.send(HaRequest {
                packet: json!({"type": "get_states"}),
                token: TOKEN.into(),
                reply: reply_tx,
            })
            .await
            .unwrap();
            assert!(reply_rx.await.unwrap().is_ok());

            // Dead socket must be detected and dropped well within 2 seconds.
            tokio::time::timeout(Duration::from_secs(2), closed_rx)
                .await
                .unwrap()
                .unwrap();

            drop(tx);
            worker.await.unwrap();
        });
        peer.join().unwrap();
    }
}
