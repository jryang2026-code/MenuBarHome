use crate::network::{normalize_host, EndpointAddressPolicy};
use futures_util::future::{select, Either};
use std::pin::pin;
use reqwest::{header, Client, StatusCode, Url};
use std::net::SocketAddr;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinSet;
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;

const UPSTREAM_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_PLAYLIST_BYTES: usize = 1024 * 1024;

pub(super) struct HlsRelay {
    pub(super) port: u16,
    cancel: CancellationToken,
}

impl Drop for HlsRelay {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

pub(super) async fn start_relay(url: Url) -> Result<(HlsRelay, String), String> {
    let host = normalize_host(url.host_str().ok_or("HLS 流地址缺少主机名")?);
    let port = url.port_or_known_default().ok_or("HLS 流地址缺少端口")?;
    let addresses = timeout(Duration::from_secs(3), tokio::net::lookup_host((host.as_str(), port)))
        .await
        .map_err(|_| "解析 HLS 流地址超时")?
        .map_err(|_| "无法解析 HLS 流地址")?;
    start_pinned_relay(url, addresses.collect()).await
}

struct Source {
    origin: String,
    local_origin: String,
    token: String,
    policy: EndpointAddressPolicy,
    client: Client,
}

impl Source {
    fn local_url(&self, upstream: &Url) -> String {
        let path = upstream.path();
        let query = upstream.query().map_or(String::new(), |query| format!("?{query}"));
        format!("{}{}{path}{query}", self.local_origin, self.token)
    }

    fn allowed_url(&self, url: Url) -> Option<Url> {
        (url.origin().ascii_serialization() == self.origin
            && url.username().is_empty()
            && url.password().is_none()
            && url.fragment().is_none())
        .then_some(url)
    }

    fn rewrite_uri(&self, base: &Url, input: &str) -> Option<String> {
        self.allowed_url(base.join(input).ok()?).map(|url| self.local_url(&url))
    }

    fn rewrite_playlist(&self, url: &Url, text: &str) -> Option<String> {
        let mut out = String::new();
        for line in text.lines() {
            let mut line = line.trim();
            if line.starts_with('#') {
                // HLS tags use quoted URI attributes for keys, maps, and alternate renditions.
                while let Some((prefix, rest)) = line.split_once("URI=\"") {
                    let (uri, rest) = rest.split_once('"')?;
                    out.push_str(prefix);
                    out.push_str("URI=\"");
                    out.push_str(&self.rewrite_uri(url, uri)?);
                    out.push('"');
                    line = rest;
                }
                out.push_str(line);
            } else if !line.is_empty() {
                out.push_str(&self.rewrite_uri(url, line)?);
            }
            out.push('\n');
        }
        Some(out)
    }
}

async fn start_pinned_relay(url: Url, addresses: Vec<SocketAddr>) -> Result<(HlsRelay, String), String> {
    use ring::rand::SecureRandom;
    let host = url.host_str().ok_or("HLS 流地址缺少主机名")?;
    let port = url.port_or_known_default().ok_or("HLS 流地址缺少端口")?;
    let policy = EndpointAddressPolicy::for_endpoint(host, port, url.scheme());
    let addresses = policy.validate(addresses).map_err(|_| "HLS 流地址不符合网络策略")?;
    let origin = url.origin().ascii_serialization();
    let mut random = [0; 16];
    ring::rand::SystemRandom::new().fill(&mut random).map_err(|_| "无法创建 HLS 会话")?;
    let token = random.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    // Keep the original URL for the HTTP Host and TLS server name. Only DNS is overridden.
    let client = Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .resolve_to_addrs(host, &addresses)
        .connect_timeout(UPSTREAM_TIMEOUT)
        .read_timeout(UPSTREAM_TIMEOUT)
        .build()
        .map_err(|_| "无法创建 HLS 连接")?;
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.map_err(|_| "无法创建 HLS 本地转发")?;
    let addr = listener.local_addr().map_err(|_| "无法读取 HLS 本地转发端口")?;
    let source = std::sync::Arc::new(Source {
        origin,
        local_origin: format!("http://{addr}/"),
        token,
        policy,
        client,
    });
    let local_url = source.local_url(&url);
    let relay = HlsRelay { port: addr.port(), cancel: CancellationToken::new() };
    let cancel = relay.cancel.clone();
    tauri::async_runtime::spawn(async move {
        cancel.run_until_cancelled(async {
            let mut requests = JoinSet::new();
            loop {
                if requests.len() == 8 {
                    requests.join_next().await;
                    continue;
                }
                let incoming = if requests.is_empty() {
                    listener.accept().await
                } else {
                    match select(pin!(listener.accept()), pin!(requests.join_next())).await {
                        Either::Left((incoming, _)) => incoming,
                        Either::Right(_) => continue,
                    }
                };
                let Ok((stream, _)) = incoming else { break };
                let source = source.clone();
                requests.spawn(async move {
                    let _ = serve(stream, &source).await;
                });
            }
        }).await;
    });
    Ok((relay, local_url))
}

async fn serve(mut stream: TcpStream, source: &Source) -> Option<()> {
    let (target, range) = timeout(Duration::from_secs(2), read_request(&mut stream)).await.ok()??;
    let path = target.strip_prefix('/')?.strip_prefix(&source.token)?;
    if !path.starts_with('/') {
        return None;
    }
    let url = source.allowed_url(Url::parse(&format!("{}{}", source.origin, path)).ok()?)?;
    source.policy.check_loopback_port().ok()?;
    let mut request = source.client.get(url.clone());
    if let Some(range) = range {
        request = request.header(header::RANGE, range);
    }
    let mut response = request.send().await.ok()?;
    let status = response.status();
    let mut head = format!("HTTP/1.1 {} {}\r\nConnection: close\r\n", status.as_u16(), status.canonical_reason().unwrap_or(""));
    if status.is_redirection() && status != StatusCode::NOT_MODIFIED {
        let location = response.headers().get(header::LOCATION)?.to_str().ok()?;
        let location = source.rewrite_uri(&url, location)?;
        head.push_str(&format!("Location: {location}\r\nContent-Length: 0\r\n\r\n"));
        write(&mut stream, head.as_bytes()).await?;
        return Some(());
    }

    let mut first = Vec::new();
    while first.len() < 10 {
        let Some(chunk) = response.chunk().await.ok()? else { break };
        first.extend_from_slice(&chunk);
    }
    if first.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&first).starts_with(b"#EXTM3U") {
        while let Some(chunk) = response.chunk().await.ok()? {
            if first.len() + chunk.len() > MAX_PLAYLIST_BYTES {
                return None;
            }
            first.extend_from_slice(&chunk);
        }
        if first.len() > MAX_PLAYLIST_BYTES {
            return None;
        }
        let playlist = std::str::from_utf8(&first).ok()?.trim_start_matches('\u{feff}');
        let body = source.rewrite_playlist(&url, playlist)?;
        head.push_str(&format!("Content-Type: application/vnd.apple.mpegurl\r\nContent-Length: {}\r\n\r\n", body.len()));
        write(&mut stream, head.as_bytes()).await?;
        return write(&mut stream, body.as_bytes()).await;
    }
    for name in [header::CONTENT_TYPE, header::CONTENT_LENGTH, header::CONTENT_RANGE, header::ACCEPT_RANGES] {
        if let Some(value) = response.headers().get(&name).and_then(|value| value.to_str().ok()) {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
    }
    head.push_str("\r\n");
    write(&mut stream, head.as_bytes()).await?;
    write(&mut stream, &first).await?;
    while let Some(chunk) = response.chunk().await.ok()? {
        write(&mut stream, &chunk).await?;
    }
    Some(())
}

async fn write(stream: &mut TcpStream, bytes: &[u8]) -> Option<()> {
    timeout(UPSTREAM_TIMEOUT, stream.write_all(bytes)).await.ok()?.ok()
}

async fn read_request(stream: &mut TcpStream) -> Option<(String, Option<String>)> {
    use tokio::io::AsyncReadExt;
    let mut reader = BufReader::new(stream).take(16 * 1024);
    let mut line = String::new();
    reader.read_line(&mut line).await.ok()?;
    let target = line.trim_end_matches("\r\n").strip_prefix("GET ")?.strip_suffix(" HTTP/1.1")?.to_owned();
    if target.bytes().any(|c| !c.is_ascii_graphic()) {
        return None;
    }
    let mut range = None;
    loop {
        line.clear();
        if reader.read_line(&mut line).await.ok()? == 0 {
            return None;
        }
        if line == "\r\n" {
            return Some((target, range));
        }
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("range") {
                range = Some(value.trim().to_owned());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_policy_rejects_prohibited_literals_and_dns_answers() {
        tauri::async_runtime::block_on(async {
            for url in [
                "http://169.254.169.254/live.m3u8",
                "https://[64:ff9b::7f00:1]/live.m3u8",
            ] {
                assert!(start_relay(Url::parse(url).unwrap()).await.is_err());
            }
            let url = Url::parse("https://ha.local/live.m3u8").unwrap();
            let addrs = vec!["192.168.1.2:443".parse().unwrap(), "[::1]:443".parse().unwrap()];
            assert!(start_pinned_relay(url, addrs).await.is_err());
        });
    }

    #[test]
    fn relay_preserves_upstream_host_and_rewrites_playlist_targets() {
        tauri::async_runtime::block_on(async {
            let upstream = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
            let port = upstream.local_addr().unwrap().port();
            let url = Url::parse(&format!("http://localhost:{port}/api/hls/live.m3u8?fixture=1")).unwrap();
            let (_relay, local_url) = start_relay(url).await.unwrap();
            let server = tokio::spawn(async move {
                for response in [
                    "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"/key\"\nsegment.ts\n",
                    "#EXTM3U\nhttp://127.0.0.1:9/segment.ts\n",
                ] {
                    let (mut peer, _) = upstream.accept().await.unwrap();
                    let mut reader = BufReader::new(&mut peer);
                    let mut line = String::new();
                    reader.read_line(&mut line).await.unwrap();
                    assert_eq!(line, "GET /api/hls/live.m3u8?fixture=1 HTTP/1.1\r\n");
                    let mut saw_host = false;
                    loop {
                        line.clear();
                        assert!(reader.read_line(&mut line).await.unwrap() > 0);
                        if line == "\r\n" { break; }
                        saw_host |= line.eq_ignore_ascii_case(&format!("Host: localhost:{port}\r\n"));
                    }
                    assert!(saw_host);
                    peer.write_all(format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}",
                        response.len(),
                    ).as_bytes()).await.unwrap();
                }
            });
            let client = Client::builder().no_proxy().timeout(Duration::from_secs(5)).build().unwrap();
            let body = client.get(&local_url).send().await.unwrap().text().await.unwrap();
            let relay_base = local_url.split("/api/hls/").next().unwrap();
            assert!(body.contains(&format!("URI=\"{relay_base}/key\"")));
            assert!(body.contains(&format!("{relay_base}/api/hls/segment.ts")));
            assert!(client.get(&local_url).send().await.is_err());
            server.await.unwrap();
        });
    }
}
