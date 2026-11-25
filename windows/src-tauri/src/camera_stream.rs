pub(crate) fn sanitize_camera_did(raw: &str) -> String {
    raw.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect()
}

pub(crate) fn normalized_camera_subdid(subdid: Option<&str>) -> Option<&str> {
    subdid.map(str::trim).filter(|s| !s.is_empty())
}

/// Stream key shared by go2rtc stream names and the local CS2 UDP relay table.
/// Standalone cameras keep `clean_did`; hub-backed battery sub-cameras use `{clean_did}_{clean_subdid}`
/// so two cameras behind the same indoor gateway never collide on streams or UDP relay ports.
pub(crate) fn camera_stream_key(did: &str, subdid: Option<&str>) -> String {
    let clean_did = sanitize_camera_did(did);
    let Some(raw_subdid) = normalized_camera_subdid(subdid) else {
        return clean_did;
    };
    let clean_subdid = sanitize_camera_did(raw_subdid);
    if clean_subdid.is_empty() || clean_did.is_empty() {
        return clean_did;
    }
    let combined = format!("{clean_did}_{clean_subdid}");
    if combined.len() <= 108 {
        combined
    } else {
        combined[..108].to_string()
    }
}

pub(crate) fn camera_channel_suffix(channel: u32) -> String {
    if channel == 0 {
        String::new()
    } else {
        format!("_c{channel}")
    }
}

pub(crate) fn camera_channel_stream_names(
    stream_key: &str,
    channel: u32,
) -> (String, String, String) {
    let suffix = camera_channel_suffix(channel);
    (
        format!("cam_raw_{stream_key}{suffix}"),
        format!("cam_h264_{stream_key}{suffix}"),
        format!("cam_mjpeg_{stream_key}{suffix}"),
    )
}

/// Every go2rtc stream name that could have been registered for `stream_key` across lens channels,
/// so switching lenses or stopping a bridge always tears down whichever channel was active.
pub(crate) fn all_camera_stream_names(stream_key: &str, extra_channel: u32) -> Vec<String> {
    let mut channels = vec![0u32, 1, 2, 3];
    if extra_channel > 3 {
        channels.push(extra_channel);
    }
    let mut names = Vec::with_capacity(channels.len() * 3);
    for ch in channels {
        let (raw, h264, mjpeg) = camera_channel_stream_names(stream_key, ch);
        names.push(raw);
        names.push(h264);
        names.push(mjpeg);
    }
    names
}

pub(crate) fn is_private_lan_ipv4(host: &str) -> bool {
    host.trim()
        .parse::<std::net::Ipv4Addr>()
        .is_ok_and(|ip| ip.is_private())
}

pub(crate) fn is_private_or_local_camera_host(raw_host: &str) -> bool {
    let trimmed = raw_host
        .trim()
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_ascii_lowercase();
    if trimmed.is_empty()
        || trimmed.chars().any(|c| c.is_control() || c.is_whitespace() || matches!(c, '/' | '@' | '?' | '#'))
    {
        return false;
    }
    if trimmed == "localhost"
        || trimmed == "::1"
        || trimmed.ends_with(".local")
        || trimmed.ends_with(".lan")
        || trimmed.ends_with(".home.arpa")
        || trimmed.ends_with(".internal")
    {
        return true;
    }
    if let Ok(ip) = trimmed.parse::<std::net::Ipv4Addr>() {
        let [a, b, ..] = ip.octets();
        return ip.is_private()
            || ip.is_loopback()
            || ip.is_link_local()
            || (a == 100 && (64..=127).contains(&b));
    }
    if let Ok(ip) = trimmed.parse::<std::net::Ipv6Addr>() {
        let seg0 = ip.segments()[0];
        return ip.is_loopback() || (seg0 & 0xfe00) == 0xfc00 || (seg0 & 0xffc0) == 0xfe80;
    }
    false
}

pub(crate) fn generic_camera_stream_names(camera_id: &str, profile: &str) -> (String, String) {
    let clean_id = sanitize_camera_did(camera_id);
    let suffix = if profile == "sub" { "sub" } else { "main" };
    (
        format!("cam_generic_raw_{clean_id}_{suffix}"),
        format!("cam_generic_mjpeg_{clean_id}_{suffix}"),
    )
}

pub(crate) fn all_generic_camera_stream_names(camera_id: &str) -> Vec<String> {
    let (raw_main, mjpeg_main) = generic_camera_stream_names(camera_id, "main");
    let (raw_sub, mjpeg_sub) = generic_camera_stream_names(camera_id, "sub");
    vec![raw_main, mjpeg_main, raw_sub, mjpeg_sub]
}

fn format_camera_host(host: &str) -> String {
    let trimmed = host.trim().trim_start_matches('[').trim_end_matches(']');
    if trimmed.contains(':') {
        format!("[{trimmed}]")
    } else {
        trimmed.to_string()
    }
}

fn format_camera_userinfo(username: &str, password: &str) -> String {
    if username.is_empty() && password.is_empty() {
        String::new()
    } else if password.is_empty() {
        format!("{}@", urlencoding_simple(username))
    } else {
        format!(
            "{}:{}@",
            urlencoding_simple(username),
            urlencoding_simple(password)
        )
    }
}

/// Builds a read-only go2rtc source string for a generic camera (RTSP / ONVIF / ISAPI / Dahua / Tapo).
/// Mirrors `windows/src/core/genericCameras.ts:buildGenericCameraSourceUrl` and
/// `Tests/Fixtures/generic_camera_sources_golden.json`.
#[allow(clippy::too_many_arguments)]
pub(crate) fn build_generic_camera_source_url(
    kind: &str,
    host: &str,
    port: Option<u16>,
    path: Option<&str>,
    channel: Option<u32>,
    profile: &str,
    custom_source: Option<&str>,
    username: &str,
    password: &str,
) -> Result<String, String> {
    let trimmed_host = host.trim();
    if trimmed_host.is_empty()
        || trimmed_host
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || matches!(c, '/' | '@' | '?' | '#'))
    {
        return Err("无效的摄像机主机地址".to_string());
    }
    if let Some(custom) = custom_source.map(str::trim).filter(|s| !s.is_empty()) {
        if custom.chars().any(|c| c.is_control() || c.is_whitespace()) {
            return Err("自定义流地址不能包含空白或控制字符".to_string());
        }
        let lower = custom.to_ascii_lowercase();
        if !(lower.starts_with("rtsp://")
            || lower.starts_with("rtsps://")
            || lower.starts_with("onvif://")
            || lower.starts_with("tapo://"))
        {
            return Err("自定义流地址仅支持 rtsp/rtsps/onvif/tapo 协议".to_string());
        }
        let encoded_user = urlencoding_simple(username);
        let encoded_pass = urlencoding_simple(password);
        let rendered = custom
            .replace("{user}", &encoded_user)
            .replace("{pass}", &encoded_pass);
        return Ok(rendered);
    }

    let formatted_host = format_camera_host(trimmed_host);
    let userinfo = format_camera_userinfo(username, password);
    let ch = channel.unwrap_or(1).clamp(1, 256);
    let is_sub = profile == "sub";

    match kind {
        "rtsp" => {
            let p = port.unwrap_or(554);
            let clean_path = path.unwrap_or("").trim().trim_start_matches('/');
            if clean_path.chars().any(|c| c.is_control() || c.is_whitespace() || c == '#') {
                return Err("RTSP 路径包含非法字符".to_string());
            }
            let suffix = if clean_path.is_empty() {
                String::new()
            } else {
                format!("/{clean_path}")
            };
            Ok(format!("rtsp://{userinfo}{formatted_host}:{p}{suffix}#backchannel=0"))
        }
        "onvif" => {
            let p = port.unwrap_or(80);
            if is_sub {
                Ok(format!("onvif://{userinfo}{formatted_host}:{p}?subtype=1"))
            } else {
                Ok(format!("onvif://{userinfo}{formatted_host}:{p}"))
            }
        }
        "isapi" => {
            let p = port.unwrap_or(554);
            let stream_suffix = if is_sub { "02" } else { "01" };
            Ok(format!(
                "rtsp://{userinfo}{formatted_host}:{p}/Streaming/Channels/{ch}{stream_suffix}#backchannel=0"
            ))
        }
        "dahua" => {
            let p = port.unwrap_or(554);
            let subtype = if is_sub { 1 } else { 0 };
            Ok(format!(
                "rtsp://{userinfo}{formatted_host}:{p}/cam/realmonitor?channel={ch}&subtype={subtype}#backchannel=0"
            ))
        }
        "tapo" => {
            let pass_part = if password.is_empty() {
                String::new()
            } else {
                format!("{}@", urlencoding_simple(password))
            };
            let port_part = port.map(|p| format!(":{p}")).unwrap_or_default();
            if is_sub {
                Ok(format!("tapo://{pass_part}{formatted_host}{port_part}?subtype=sd"))
            } else {
                Ok(format!("tapo://{pass_part}{formatted_host}{port_part}"))
            }
        }
        other => Err(format!("不支持的通用摄像机协议：{other}")),
    }
}

/// Strips embedded `user:pass@` or `pass@` credentials from camera URLs before logging or error display.
pub(crate) fn redact_camera_credentials(input: &str) -> String {
    let mut result = input.to_string();
    for scheme in ["rtsp://", "rtsps://", "onvif://", "tapo://", "http://", "https://"] {
        let mut search_from = 0;
        while let Some(rel_idx) = result[search_from..].find(scheme) {
            let start = search_from + rel_idx + scheme.len();
            let tail = &result[start..];
            let end_authority = tail
                .find(|c: char| matches!(c, '/' | '?' | '#' | ' ' | '\t' | '\n' | '\r'))
                .unwrap_or(tail.len());
            if let Some(at_pos) = tail[..end_authority].rfind('@') {
                result.replace_range(start..start + at_pos + 1, "***@");
                search_from = start + 4;
            } else {
                search_from = start + end_authority;
            }
        }
    }
    result
}

pub(crate) fn parse_camera_lan_ip(local_ip: &str) -> Result<std::net::Ipv4Addr, String> {
    let cam_ip: std::net::Ipv4Addr = local_ip
        .trim()
        .parse()
        .map_err(|_| format!("无效的局域网摄像机 IP：{local_ip}"))?;
    if !cam_ip.is_private() && !cam_ip.is_loopback() {
        return Err("仅允许局域网私有 IP 地址直连摄像机".to_string());
    }
    Ok(cam_ip)
}

pub(crate) fn urlencoding_simple(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// go2rtc `subtype` for a Xiaomi MISS stream (#97). `max` is numeric subtype 3, which
/// several 4K models require; `None` keeps the historical `hd` default.
pub(crate) fn xiaomi_camera_subtype(quality: Option<&str>) -> Result<&'static str, String> {
    match quality.unwrap_or("hd") {
        "auto" => Ok("auto"),
        "sd" => Ok("sd"),
        "hd" => Ok("hd"),
        "max" => Ok("3"),
        other => Err(format!("不支持的摄像机画质：{other}")),
    }
}

pub(crate) fn build_xiaomi_camera_url(
    relay_port: u16,
    client_public: &str,
    client_private: &str,
    device_public: &str,
    sign: &str,
    vendor: &str,
    subtype: &str,
    model: &str,
    uid: Option<&str>,
    channel: u32,
    subdid: Option<&str>,
    audio_enabled: bool,
) -> String {
    let audio_flag = if audio_enabled { "1" } else { "0" };
    let mut query = format!(
        "client_public={}&client_private={}&device_public={}&sign={}&vendor={}&transport=udp&subtype={}&audio={}&model={}",
        urlencoding_simple(client_public),
        urlencoding_simple(client_private),
        urlencoding_simple(device_public),
        urlencoding_simple(sign),
        urlencoding_simple(vendor),
        subtype,
        audio_flag,
        urlencoding_simple(model)
    );
    if let Some(u) = uid.filter(|s| !s.is_empty()) {
        query.push_str(&format!("&uid={}", urlencoding_simple(u)));
    }
    if channel > 0 {
        query.push_str(&format!("&channel={channel}"));
    }
    if let Some(sub) = normalized_camera_subdid(subdid) {
        query.push_str(&format!("&subdid={}", urlencoding_simple(sub)));
    }
    format!("xiaomi://127.0.0.1:{relay_port}?{query}")
}

pub(crate) fn validate_hls_stream_url(hls_url: &str) -> Result<reqwest::Url, String> {
    let trimmed = hls_url.trim();
    if trimmed.contains('#') || trimmed.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err("HLS 流地址不能包含 # 片段或控制字符".to_string());
    }
    let parsed = reqwest::Url::parse(trimmed).map_err(|_| "无效的 HLS 流地址".to_string())?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err("HLS 流地址必须使用 http 或 https 协议".to_string());
    }
    if parsed.host_str().map_or(true, str::is_empty) {
        return Err("HLS 流地址缺少有效主机名".to_string());
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err("HLS 流地址不允许内嵌用户名或密码".to_string());
    }
    if parsed.fragment().is_some() {
        return Err("HLS 流地址不能包含 # 片段".to_string());
    }
    Ok(parsed)
}

pub(crate) fn check_hls_stream_url_allowed(
    url: &reqwest::Url,
    extra_origins: &std::collections::HashSet<String>,
) -> Result<(), String> {
    if crate::network::check_url_allowed(url, extra_origins).is_ok() {
        return Ok(());
    }
    if matches!(url.scheme(), "http" | "https")
        && url.username().is_empty()
        && url.password().is_none()
        && url.host_str().is_some_and(is_private_lan_ipv4)
    {
        return Ok(());
    }
    let origin = crate::network::url_origin(url).unwrap_or_else(|| url.as_str().to_string());
    Err(format!("HLS 流地址不在允许的局域网或已授权服务范围内：{origin}"))
}

/// Accepts a UDP datagram on the loopback CS2 relay only from the bound `go2rtc` socket, or binds
/// (or rebinds after >=750 ms of client silence) on a valid 4-byte-header CS2 `LAN_SEARCH`
/// (`0xF1 0x30 <be16 len>`). Stray/non-CS2 local packets and active-stream hijack attempts from
/// other local ports are dropped before they can clobber `go2rtc_addr` or `cmd_gate`.
pub(crate) fn cs2_relay_accepts_client_packet(
    pkt: &[u8],
    src: std::net::SocketAddr,
    bound_client: Option<(std::net::SocketAddr, std::time::Instant)>,
    now: std::time::Instant,
) -> bool {
    if !src.ip().is_loopback() || pkt.len() < 4 || pkt[0] != 0xF1 {
        return false;
    }
    match bound_client {
        Some((addr, _)) if addr == src => true,
        None => {
            pkt[1] == 0x30
                && 4 + usize::from(u16::from_be_bytes([pkt[2], pkt[3]])) == pkt.len()
        }
        Some((_, last_seen)) => {
            pkt[1] == 0x30
                && 4 + usize::from(u16::from_be_bytes([pkt[2], pkt[3]])) == pkt.len()
                && now.saturating_duration_since(last_seen)
                    >= std::time::Duration::from_millis(750)
        }
    }
}

pub(crate) fn is_go2rtc_stream_name(src: &str) -> bool {
    !src.is_empty()
        && src.len() <= 128
        && src
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
}

/// Builds a loopback go2rtc stream URL for `/api/stream.mp4`, `/api/stream.m3u8`, or
/// `/api/stream.mjpeg`. Muted previews include `&audio=0` so audio is never requested
/// until the user opts into listen-only playback (#445, P1-2).
pub(crate) fn build_go2rtc_http_stream_url(
    api_listen: &str,
    path: &str,
    src: &str,
    audio_enabled: bool,
) -> Result<String, String> {
    if !is_go2rtc_stream_name(src) {
        return Err("无效的摄像机流名称".to_string());
    }
    if !super::is_acceptable_go2rtc_listen(api_listen) {
        return Err("本地流媒体地址无效".to_string());
    }
    let normalized_path = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    };
    let encoded = urlencoding_simple(src);
    let query = match normalized_path.as_str() {
        "/api/stream.mp4" => {
            if audio_enabled {
                format!("src={encoded}&mp4=all")
            } else {
                format!("src={encoded}&mp4&audio=0")
            }
        }
        "/api/stream.m3u8" => {
            if audio_enabled {
                format!("src={encoded}")
            } else {
                format!("src={encoded}&video=all&audio=0")
            }
        }
        "/api/stream.mjpeg" => format!("src={encoded}"),
        _ => return Err("不支持的 go2rtc 流端点".to_string()),
    };
    Ok(format!("http://{api_listen}{normalized_path}?{query}"))
}

#[tauri::command(rename = "stop_xiaomi_camera_bridge")]
pub(crate) async fn stop_xiaomi_camera_bridge_ipc(
    did: String,
    channel: Option<u32>,
    subdid: Option<String>,
) -> Result<(), String> {
    super::stop_xiaomi_camera_bridge_with_opts(did, channel.unwrap_or(0), subdid).await
}

#[doc(hidden)]
macro_rules! __tauri_command_name_stop_xiaomi_camera_bridge {
    () => {
        "stop_xiaomi_camera_bridge"
    };
}

#[doc(hidden)]
macro_rules! __cmd__stop_xiaomi_camera_bridge {
    ($_path:path, $invoke:ident) => {
        $crate::camera::camera_stream::__cmd__stop_xiaomi_camera_bridge_ipc!(
            $crate::camera::camera_stream::stop_xiaomi_camera_bridge_ipc,
            $invoke
        )
    };
}

pub(crate) use {
    __cmd__stop_xiaomi_camera_bridge, __tauri_command_name_stop_xiaomi_camera_bridge,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_key_and_channel_suffix_follow_dual_lens_and_subdid_conventions() {
        assert_eq!(camera_stream_key("cam-1", None), "cam1");
        assert_eq!(camera_stream_key("cam-1", Some("   ")), "cam1");
        assert_eq!(
            camera_stream_key("hub-100", Some("sub.cam-200")),
            "hub100_subcam200"
        );

        let (raw0, h264_0, mjpeg0) = camera_channel_stream_names("cam1", 0);
        assert_eq!(raw0, "cam_raw_cam1");
        assert_eq!(h264_0, "cam_h264_cam1");
        assert_eq!(mjpeg0, "cam_mjpeg_cam1");
        assert!(is_go2rtc_stream_name(&mjpeg0));

        let (raw1, h264_1, mjpeg1) = camera_channel_stream_names("hub100_subcam200", 1);
        assert_eq!(raw1, "cam_raw_hub100_subcam200_c1");
        assert_eq!(h264_1, "cam_h264_hub100_subcam200_c1");
        assert_eq!(mjpeg1, "cam_mjpeg_hub100_subcam200_c1");
        assert!(is_go2rtc_stream_name(&mjpeg1));
    }

    #[test]
    fn build_xiaomi_camera_url_encodes_optional_channel_and_subdid() {
        let base = build_xiaomi_camera_url(
            41234,
            "cpub",
            "cpriv",
            "dpub",
            "sig==",
            "cs2",
            "hd",
            "isa.camera.c700",
            Some("uid-1"),
            0,
            None,
            false,
        );
        assert_eq!(
            base,
            "xiaomi://127.0.0.1:41234?client_public=cpub&client_private=cpriv&device_public=dpub&sign=sig%3D%3D&vendor=cs2&transport=udp&subtype=hd&audio=0&model=isa.camera.c700&uid=uid-1"
        );

        let listen_only = build_xiaomi_camera_url(
            41234,
            "cpub",
            "cpriv",
            "dpub",
            "sig==",
            "cs2",
            "hd",
            "isa.camera.c700",
            Some("uid-1"),
            0,
            None,
            true,
        );
        assert!(listen_only.contains("&audio=1&"));
        assert!(!listen_only.contains("audio=0"));

        let dual_sub = build_xiaomi_camera_url(
            41235,
            "cpub",
            "cpriv",
            "dpub",
            "sig",
            "cs2",
            "3",
            "mxiang.camera.mwc10",
            None,
            1,
            Some("mwc11/child:1"),
            false,
        );
        assert!(dual_sub.contains("&channel=1"));
        assert!(dual_sub.contains("&subdid=mwc11%2Fchild%3A1"));
        assert!(!dual_sub.contains("&uid="));
    }

    #[test]
    fn build_go2rtc_http_stream_url_sets_audio_0_only_when_muted() {
        let mp4_muted = build_go2rtc_http_stream_url(
            "127.0.0.1:43123",
            "/api/stream.mp4",
            "cam_raw_1",
            false,
        )
        .expect("muted mp4 url");
        assert_eq!(
            mp4_muted,
            "http://127.0.0.1:43123/api/stream.mp4?src=cam_raw_1&mp4&audio=0"
        );

        let mp4_listen = build_go2rtc_http_stream_url(
            "127.0.0.1:43123",
            "/api/stream.mp4",
            "cam_raw_1",
            true,
        )
        .expect("listen-only mp4 url");
        assert_eq!(
            mp4_listen,
            "http://127.0.0.1:43123/api/stream.mp4?src=cam_raw_1&mp4=all"
        );

        let hls_muted = build_go2rtc_http_stream_url(
            "127.0.0.1:43123",
            "/api/stream.m3u8",
            "cam_raw_1",
            false,
        )
        .expect("muted hls url");
        assert_eq!(
            hls_muted,
            "http://127.0.0.1:43123/api/stream.m3u8?src=cam_raw_1&video=all&audio=0"
        );

        let hls_listen = build_go2rtc_http_stream_url(
            "127.0.0.1:43123",
            "/api/stream.m3u8",
            "cam_raw_1",
            true,
        )
        .expect("listen-only hls url");
        assert_eq!(
            hls_listen,
            "http://127.0.0.1:43123/api/stream.m3u8?src=cam_raw_1"
        );

        assert!(build_go2rtc_http_stream_url("127.0.0.1:1984", "/api/stream.mp4", "cam_raw_1", false).is_err());
    }

    #[test]
    fn validates_private_lan_ip() {
        assert!(parse_camera_lan_ip("192.168.1.50").is_ok());
        assert!(parse_camera_lan_ip("172.16.4.9").is_ok());
        let class_a = std::net::Ipv4Addr::new(5 * 2, 0, 0, 8).to_string();
        assert!(parse_camera_lan_ip(&class_a).is_ok());
        assert!(parse_camera_lan_ip("192.0.2.10").is_err());
        assert!(parse_camera_lan_ip("not-an-ip").is_err());

        assert!(is_private_lan_ipv4("192.168.1.50"));
        assert!(is_private_lan_ipv4("172.16.4.9"));
        assert!(!is_private_lan_ipv4("127.0.0.1"));
        assert!(!is_private_lan_ipv4("169.254.169.254"));
        assert!(!is_private_lan_ipv4("192.0.2.10"));
        assert!(!is_private_lan_ipv4("localhost"));
    }

    #[test]
    fn hls_stream_allowlist_permits_private_lan_and_authorized_origins_only() {
        let mut authorized = std::collections::HashSet::new();
        authorized.insert("https://ha.example.com:8443".to_string());

        for allowed in [
            "http://192.168.1.50:8080/live/index.m3u8",
            "https://172.16.4.9/live/index.m3u8",
            "https://ha.example.com:8443/api/hls/master_playlist.m3u8",
            "https://api.io.mi.com/app/v2/camera/hls.m3u8",
        ] {
            let parsed = validate_hls_stream_url(allowed).expect("valid syntax");
            assert!(
                check_hls_stream_url_allowed(&parsed, &authorized).is_ok(),
                "{allowed}"
            );
        }

        for rejected in [
            "http://127.0.0.1:1984/api/stream.m3u8",
            "http://localhost:8123/api/hls/master.m3u8",
            "http://169.254.169.254/latest/meta-data/",
            "http://192.0.2.10:8123/api/hls/master.m3u8",
            "https://cam.example.com/live/index.m3u8",
            "http://ha.example.com:8443/api/hls/master.m3u8",
        ] {
            let parsed = validate_hls_stream_url(rejected).expect("valid syntax");
            assert!(
                check_hls_stream_url_allowed(&parsed, &authorized).is_err(),
                "{rejected}"
            );
        }
    }

    #[test]
    fn cs2_relay_binds_loopback_handshake_and_blocks_active_hijack() {
        let client_a: std::net::SocketAddr = "127.0.0.1:51000".parse().expect("client a");
        let client_b: std::net::SocketAddr = "127.0.0.1:52000".parse().expect("client b");
        let non_loopback: std::net::SocketAddr = "192.0.2.10:51000".parse().expect("lan");
        let t0 = std::time::Instant::now();
        let lan_search = [0xF1u8, 0x30, 0x00, 0x00];
        let drw_ack = [0xF1u8, 0xD1, 0x00, 0x06, 0xD1, 0x00, 0x00, 0x01, 0x00, 0x01];

        assert!(!cs2_relay_accepts_client_packet(&lan_search, non_loopback, None, t0));
        assert!(!cs2_relay_accepts_client_packet(&[0xF1, 0x30], client_a, None, t0));
        assert!(!cs2_relay_accepts_client_packet(&[0x00, 0x30, 0x00, 0x00], client_a, None, t0));
        assert!(!cs2_relay_accepts_client_packet(&drw_ack, client_a, None, t0));
        assert!(cs2_relay_accepts_client_packet(&lan_search, client_a, None, t0));

        let bound = Some((client_a, t0));
        let t_active = t0 + std::time::Duration::from_millis(200);
        assert!(cs2_relay_accepts_client_packet(&drw_ack, client_a, bound, t_active));
        assert!(!cs2_relay_accepts_client_packet(&drw_ack, client_b, bound, t_active));
        assert!(!cs2_relay_accepts_client_packet(&lan_search, client_b, bound, t_active));

        let t_idle = t0 + std::time::Duration::from_millis(800);
        assert!(!cs2_relay_accepts_client_packet(&drw_ack, client_b, bound, t_idle));
        assert!(!cs2_relay_accepts_client_packet(
            &[0xF1, 0x30, 0x00, 0x04],
            client_b,
            bound,
            t_idle
        ));
        assert!(cs2_relay_accepts_client_packet(&lan_search, client_b, bound, t_idle));
    }

    #[test]
    fn generic_camera_source_urls_match_contract_and_encode_special_chars() {
        assert_eq!(
            build_generic_camera_source_url(
                "rtsp",
                "cam-garage.local",
                Some(8554),
                Some("live/ch0"),
                None,
                "main",
                None,
                "admin@home",
                "p@ss:w/ord#1?% &+!",
            )
            .expect("rtsp url"),
            "rtsp://admin%40home:p%40ss%3Aw%2Ford%231%3F%25%20%26%2B%21@cam-garage.local:8554/live/ch0#backchannel=0"
        );
        assert_eq!(
            build_generic_camera_source_url("onvif", "192.168.1.60", None, None, None, "sub", None, "u", "p")
                .expect("onvif sub"),
            "onvif://u:p@192.168.1.60:80?subtype=1"
        );
        assert_eq!(
            build_generic_camera_source_url("isapi", "192.168.1.70", None, None, Some(3), "sub", None, "admin", "hik#1")
                .expect("isapi sub"),
            "rtsp://admin:hik%231@192.168.1.70:554/Streaming/Channels/302#backchannel=0"
        );
        assert_eq!(
            build_generic_camera_source_url("dahua", "192.168.1.80", None, None, Some(2), "main", None, "nvr", "a/b")
                .expect("dahua main"),
            "rtsp://nvr:a%2Fb@192.168.1.80:554/cam/realmonitor?channel=2&subtype=0#backchannel=0"
        );
        assert_eq!(
            build_generic_camera_source_url("tapo", "192.168.1.90", None, None, None, "main", None, "ignored", "tp@ss#1")
                .expect("tapo main"),
            "tapo://tp%40ss%231@192.168.1.90"
        );
        assert_eq!(
            build_generic_camera_source_url("tapo", "192.168.1.90", None, None, None, "sub", None, "ignored", "tp@ss#1")
                .expect("tapo sub"),
            "tapo://tp%40ss%231@192.168.1.90?subtype=sd"
        );
    }

    #[test]
    fn generic_camera_host_policy_and_credential_redaction() {
        assert!(is_private_or_local_camera_host("192.168.1.50"));
        assert!(is_private_or_local_camera_host("cam-front.local"));
        let class_a = std::net::Ipv4Addr::new(5 * 2, 0, 0, 12).to_string();
        assert!(is_private_or_local_camera_host(&class_a));
        assert!(!is_private_or_local_camera_host("8.8.8.8"));
        assert!(!is_private_or_local_camera_host("camera.example.com"));

        assert_eq!(
            redact_camera_credentials("failed rtsp://admin:s3cr3t@192.168.1.50:554/stream1"),
            "failed rtsp://***@192.168.1.50:554/stream1"
        );
        assert_eq!(
            redact_camera_credentials("tapo://my%23pass@192.168.1.90?subtype=sd"),
            "tapo://***@192.168.1.90?subtype=sd"
        );
    }
}
