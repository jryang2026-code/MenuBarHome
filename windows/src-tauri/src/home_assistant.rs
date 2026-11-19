use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::future::Future;
use std::net::{Shutdown, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{OwnedRwLockReadGuard, RwLock};
use tokio_util::sync::CancellationToken;
use tungstenite::{client_tls, stream::MaybeTlsStream, Message, WebSocket};

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

#[derive(Default)]
pub(crate) struct HaConnections(Mutex<HaRegistration>);

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
}

struct HaTask {
    cancel: CancellationToken,
    _running: OwnedRwLockReadGuard<()>,
}

impl HaConnections {
    async fn configure(&self, scope: Option<String>, generation: u64) -> Result<(), String> {
        let retiring = {
            let mut state = self.0.lock().map_err(|_| STALE)?;
            if generation <= state.generation {
                return Err(STALE.into());
            }
            state.generation = generation;
            if let Some(current) = &state.current {
                current.cancel.cancel();
            }
            state.current.clone()
        };
        if let Some(connection) = retiring {
            // Keep the retiring connection registered until its last task exits.
            // Concurrent configurations wait on the same connection.
            let _drained = connection.tasks.write().await;
        }
        let mut state = self.0.lock().map_err(|_| STALE)?;
        if state.generation == generation {
            state.current = scope.map(|scope| {
                Arc::new(HaConnection {
                    generation,
                    scope,
                    cancel: CancellationToken::new(),
                    tasks: Arc::default(),
                })
            });
        }
        Ok(())
    }

    fn acquire(&self, base_url: &str, generation: u64) -> Result<HaTask, String> {
        let scope = connection_scope(base_url)?;
        let state = self.0.lock().map_err(|_| STALE)?;
        let current = state.current.as_ref().filter(|current| {
            state.generation == generation
                && current.generation == generation
                && current.scope == scope
        }).ok_or(STALE)?;
        Ok(HaTask {
            cancel: current.cancel.clone(),
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
    generation: u64,
) -> Result<(), String> {
    let scope = base_url.as_deref().map(connection_scope).transpose()?;
    connections.configure(scope, generation).await
}

impl HaTask {
    async fn http<T>(self, request: impl Future<Output = Result<T, String>>) -> Result<T, String> {
        self.cancel.run_until_cancelled(request).await.ok_or(CANCELLED)?
    }

    async fn websocket<T: Send + 'static>(
        self,
        url: String,
        token: String,
        operation: impl FnOnce(&mut Socket, &CancellationToken) -> Result<T, String> + Send + 'static,
    ) -> Result<T, String> {
        let parsed = reqwest::Url::parse(&url).map_err(|_| "Invalid Home Assistant URL")?;
        let host = parsed
            .host_str()
            .ok_or("Invalid Home Assistant host")?
            .trim_start_matches('[')
            .trim_end_matches(']');
        let port = parsed.port_or_known_default().ok_or("Invalid Home Assistant port")?;
        let connect = tokio::net::TcpStream::connect((host, port));
        let stream = self
            .cancel
            .run_until_cancelled(tokio::time::timeout(Duration::from_secs(5), connect))
            .await
            .ok_or(CANCELLED)?
            .map_err(|_| "Home Assistant connection timed out")?
            .map_err(|_| "Home Assistant connection failed")?
            .into_std()
            .map_err(|_| "Home Assistant socket setup failed")?;
        stream
            .set_nonblocking(false)
            .and_then(|()| stream.set_read_timeout(Some(Duration::from_secs(10))))
            .and_then(|()| stream.set_write_timeout(Some(Duration::from_secs(10))))
            .map_err(|_| "Home Assistant socket setup failed")?;
        let interrupt = stream.try_clone().map_err(|_| "Home Assistant socket setup failed")?;

        // Own the task until the blocking reader has returned, even if the IPC waiter goes away.
        tauri::async_runtime::spawn(async move {
            let Self { cancel, _running } = self;
            let worker_cancel = cancel.clone();
            let mut worker = tauri::async_runtime::spawn_blocking(move || {
                if worker_cancel.is_cancelled() {
                    return Err(CANCELLED.into());
                }
                let mut socket = authenticated(&url, stream, &token, &worker_cancel)?;
                if worker_cancel.is_cancelled() {
                    return Err(CANCELLED.into());
                }
                let result = operation(&mut socket, &worker_cancel);
                let _ = socket.close(None);
                result
            });
            match cancel.run_until_cancelled(&mut worker).await {
                Some(result) => result.map_err(|_| "Home Assistant worker failed".to_string())?,
                None => {
                    let _ = interrupt.shutdown(Shutdown::Both);
                    let _ = worker.await;
                    Err(CANCELLED.into())
                }
            }
        }).await.map_err(|_| "Home Assistant worker failed".to_string())?
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

type Socket = WebSocket<MaybeTlsStream<TcpStream>>;

fn receive(socket: &mut Socket) -> Result<Value, String> {
    let deadline = Instant::now() + Duration::from_secs(15);
    for _ in 0..64 {
        if Instant::now() >= deadline {
            return Err("Home Assistant read timed out".into());
        }
        match socket
            .read()
            .map_err(|_| "Home Assistant connection failed")?
        {
            Message::Text(text) => {
                return serde_json::from_str(&text)
                    .map_err(|_| "Invalid Home Assistant response".into())
            }
            Message::Close(_) => return Err("Home Assistant disconnected".into()),
            _ => {}
        }
    }
    Err("Home Assistant sent too many control frames".into())
}

fn send(socket: &mut Socket, packet: Value) -> Result<(), String> {
    socket
        .send(Message::Text(packet.to_string().into()))
        .map_err(|_| "Home Assistant send failed".into())
}

fn authenticated(url: &str, stream: TcpStream, token: &str, cancel: &CancellationToken) -> Result<Socket, String> {
    let (mut socket, _) =
        client_tls(url, stream).map_err(|_| "Home Assistant handshake failed")?;
    if receive(&mut socket)?["type"] != "auth_required" {
        return Err("Home Assistant authentication handshake failed".into());
    }
    if cancel.is_cancelled() {
        return Err(CANCELLED.into());
    }
    send(&mut socket, json!({"type":"auth", "access_token": token}))?;
    if receive(&mut socket)?["type"] != "auth_ok" {
        return Err("Home Assistant authentication rejected".into());
    }
    Ok(socket)
}

fn request(socket: &mut Socket, cancel: &CancellationToken, id: u32, mut packet: Value) -> Result<Value, String> {
    if cancel.is_cancelled() {
        return Err(CANCELLED.into());
    }
    packet["id"] = json!(id);
    send(socket, packet)?;
    let deadline = Instant::now() + Duration::from_secs(15);
    for _ in 0..64 {
        if Instant::now() >= deadline {
            return Err("Home Assistant request timed out".into());
        }
        let response = receive(socket)?;
        if response["id"] != id {
            continue;
        }
        if response["type"] != "result" || response["success"] != true {
            return Err("Home Assistant request failed".into());
        }
        return Ok(response["result"].clone());
    }
    Err("Home Assistant response did not match request id".into())
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

fn snapshot(socket: &mut Socket, cancel: &CancellationToken) -> Result<HaSnapshot, String> {
    Ok(HaSnapshot {
        areas: request(socket, cancel, 1, json!({"type":"config/area_registry/list"}))?,
        devices: request(socket, cancel, 2, json!({"type":"config/device_registry/list"}))?,
        entities: request(socket, cancel, 3, json!({"type":"config/entity_registry/list"}))?,
        states: request(socket, cancel, 4, json!({"type":"get_states"}))?,
    })
}

fn execute(socket: &mut Socket, cancel: &CancellationToken, command: HaServiceCall) -> Result<(), String> {
    request(socket, cancel, 1, json!({
        "type":"call_service", "domain":command.domain, "service":command.service,
        "target":{"entity_id":command.entity_id}, "service_data":command.data
    }))?;
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
    task.websocket(endpoint(&base_url, &token)?, token, snapshot).await
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
    task.websocket(endpoint(&base_url, &token)?, token, move |socket, cancel| {
        execute(socket, cancel, command)
    }).await
}

#[cfg(test)]
mod tests {
    use super::*;
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
            connections.configure(Some(connection_scope(a).unwrap()), 1).await.unwrap();
            let task = connections.acquire("https://HOME.example:443/first/api/websocket/", 1).unwrap();
            assert!(connections.acquire(b, 1).is_err());

            let stop = {
                let connections = connections.clone();
                tauri::async_runtime::spawn(async move { connections.configure(None, 2).await })
            };
            tokio::time::timeout(Duration::from_secs(2), task.cancel.cancelled()).await.unwrap();
            assert!(connections.acquire(a, 1).is_err());

            let switch = connections.configure(Some(connection_scope(b).unwrap()), 3);
            let mut switch = std::pin::pin!(switch);
            std::future::poll_fn(|cx| {
                assert!(switch.as_mut().poll(cx).is_pending());
                std::task::Poll::Ready(())
            }).await;
            assert!(connections.acquire(b, 3).is_err());
            assert!(!stop.inner().is_finished());
            drop(task);
            switch.await.unwrap();
            stop.await.unwrap().unwrap();

            assert!(connections.acquire(b, 3).is_ok());
            assert!(connections.acquire(a, 3).is_err());
            assert!(connections.acquire(b, 1).is_err());
            assert!(connections.configure(Some(connection_scope(a).unwrap()), 2).await.is_err());
            assert!(connections.acquire(b, 3).is_ok());
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
                connections.configure(Some(connection_scope(&base).unwrap()), 1).await.unwrap();
                let task = connections.acquire(&base, 1).unwrap();
                let operation = tauri::async_runtime::spawn(task.websocket(
                    format!("{}/api/websocket", base.replacen("http:", "ws:", 1)),
                    "fixture-token".into(), snapshot,
                ));
                tokio::time::timeout(Duration::from_secs(2), ready).await.unwrap().unwrap();
                tokio::time::timeout(Duration::from_secs(2), connections.configure(None, 2))
                    .await.unwrap().unwrap();
                assert!(operation.await.unwrap().is_err());
                assert!(connections.acquire(&base, 1).is_err());
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
                connections.configure(Some(connection_scope(&base).unwrap()), 1).await.unwrap();
                let task = connections.acquire(&base, 1).unwrap();
                let operation = tauri::async_runtime::spawn(task.http(crate::network::native_http_with_scope(
                    format!("{base}/api/stream"), None, None, None, None, Some(10_000),
                    Some(connection_scope(&base).unwrap()),
                )));
                tokio::time::timeout(Duration::from_secs(2), ready).await.unwrap().unwrap();
                tokio::time::timeout(Duration::from_secs(2), connections.configure(None, 2))
                    .await.unwrap().unwrap();
                assert_eq!(operation.await.unwrap().err().as_deref(), Some(CANCELLED));
            });
            peer.join().unwrap();
            crate::EXTRA_ALLOWED_ORIGINS.write().unwrap().remove(&origin);
        }
    }

    #[test]
    fn controlled_websocket_auth_snapshot_and_service_smoke() {
        let _guard = crate::ORIGIN_TEST_LOCK.lock().unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base_url = format!("http://{}", listener.local_addr().unwrap());
        let origin = crate::normalize_extra_origin(&base_url).unwrap();
        crate::EXTRA_ALLOWED_ORIGINS
            .write()
            .unwrap()
            .insert(origin.clone());
        let fixture: Value =
            serde_json::from_str(include_str!("../../../Tests/Fixtures/ha_snapshot.json")).unwrap();
        let peer = std::thread::spawn(move || {
            let mut snapshots = 0;
            let mut services = 0;
            let mut handshakes = 0;
            for connection in 0..8 {
                let (stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(10)))
                    .unwrap();
                let mut socket = tungstenite::accept(stream).unwrap();
                socket
                    .send(Message::Text(
                        json!({"type":"auth_required","ha_version":"controlled-fixture"})
                            .to_string()
                            .into(),
                    ))
                    .unwrap();
                let auth: Value =
                    serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap();
                assert_eq!(auth["type"], "auth");
                assert_eq!(auth["access_token"], "controlled-native-token");
                handshakes += 1;
                if connection == 7 {
                    socket
                        .send(Message::Text(
                            json!({"type":"auth_invalid","message":"controlled-native-token"})
                                .to_string()
                                .into(),
                        ))
                        .unwrap();
                    continue;
                }
                socket
                    .send(Message::Text(json!({"type":"auth_ok"}).to_string().into()))
                    .unwrap();
                let requests = if connection < 5 { 4 } else { 1 };
                for index in 0..requests {
                    let packet: Value =
                        serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap();
                    let result = if connection < 5 {
                        let names = [
                            "config/area_registry/list",
                            "config/device_registry/list",
                            "config/entity_registry/list",
                            "get_states",
                        ];
                        assert_eq!(packet["type"], names[index]);
                        fixture[["areas", "devices", "entities", "states"][index]].clone()
                    } else {
                        assert_eq!(packet["type"], "call_service");
                        assert_eq!(packet["domain"], "light");
                        assert_eq!(packet["service"], "turn_off");
                        assert_eq!(packet["target"]["entity_id"], "light.study");
                        services += 1;
                        Value::Null
                    };
                    let response = if connection == 6 {
                        json!({"id":packet["id"],"type":"result","success":false,"error":{"message":"controlled-native-token"}})
                    } else {
                        json!({"id":packet["id"],"type":"result","success":true,"result":result})
                    };
                    socket
                        .send(Message::Text(response.to_string().into()))
                        .unwrap();
                }
                if connection < 5 {
                    snapshots += 1;
                }
            }
            (handshakes, snapshots, services)
        });
        let connections = HaConnections::default();
        let scope = connection_scope(&base_url).unwrap();
        tauri::async_runtime::block_on(connections.configure(Some(scope), 1)).unwrap();
        let url = endpoint(&base_url, "controlled-native-token").unwrap();
        let mut snapshot_ms = Vec::new();
        for _ in 0..5 {
            let start = std::time::Instant::now();
            let snapshot = tauri::async_runtime::block_on(connections.acquire(&base_url, 1).unwrap().websocket(
                url.clone(), "controlled-native-token".into(), snapshot,
            ))
            .unwrap();
            let serialized = serde_json::to_string(&snapshot).unwrap();
            assert!(!serialized.contains("controlled-native-token"));
            assert_eq!(snapshot.areas.as_array().unwrap().len(), 1);
            assert_eq!(snapshot.states.as_array().unwrap().len(), 6);
            snapshot_ms.push(start.elapsed().as_secs_f64() * 1000.0);
        }
        for fail in [false, true] {
            let command = HaServiceCall {
                domain: "light".into(),
                service: "turn_off".into(),
                entity_id: "light.study".into(),
                data: Default::default(),
            };
            let result = tauri::async_runtime::block_on(connections.acquire(&base_url, 1).unwrap().websocket(
                url.clone(), "controlled-native-token".into(), move |socket, cancel| execute(socket, cancel, command),
            ));
            assert_eq!(result.is_err(), fail);
            if let Err(error) = result {
                assert!(!error.contains("controlled-native-token"));
            }
        }
        let error =
            tauri::async_runtime::block_on(connections.acquire(&base_url, 1).unwrap().websocket(
                url, "controlled-native-token".into(), snapshot,
            ))
                .err()
                .unwrap();
        assert_eq!(error, "Home Assistant authentication rejected");
        assert_eq!(peer.join().unwrap(), (8, 5, 2));
        crate::EXTRA_ALLOWED_ORIGINS
            .write()
            .unwrap()
            .remove(&origin);
        println!("HA_SOCKET_SMOKE handshakes=8 snapshots=5 service_success=1 service_failure=1 auth_rejection=1 secret_leaks=0 snapshot_ms={snapshot_ms:?}");
    }
}
