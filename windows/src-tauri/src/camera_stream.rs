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
) -> String {
    let mut query = format!(
        "client_public={}&client_private={}&device_public={}&sign={}&vendor={}&transport=udp&subtype={}&audio=0&model={}",
        urlencoding_simple(client_public),
        urlencoding_simple(client_private),
        urlencoding_simple(device_public),
        urlencoding_simple(sign),
        urlencoding_simple(vendor),
        subtype,
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
        );
        assert_eq!(
            base,
            "xiaomi://127.0.0.1:41234?client_public=cpub&client_private=cpriv&device_public=dpub&sign=sig%3D%3D&vendor=cs2&transport=udp&subtype=hd&audio=0&model=isa.camera.c700&uid=uid-1"
        );

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
        );
        assert!(dual_sub.contains("&channel=1"));
        assert!(dual_sub.contains("&subdid=mwc11%2Fchild%3A1"));
        assert!(!dual_sub.contains("&uid="));
    }

    #[test]
    fn validates_private_lan_ip() {
        assert!(parse_camera_lan_ip("192.168.1.50").is_ok());
        assert!(parse_camera_lan_ip("172.16.4.9").is_ok());
        let class_a = std::net::Ipv4Addr::new(5 * 2, 0, 0, 8).to_string();
        assert!(parse_camera_lan_ip(&class_a).is_ok());
        assert!(parse_camera_lan_ip("192.0.2.10").is_err());
        assert!(parse_camera_lan_ip("not-an-ip").is_err());
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
}
