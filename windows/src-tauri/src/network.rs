use super::*;
use std::io;
use std::net::{IpAddr, SocketAddr};

/// Configured origins retain the protocol and port, so permission for one service
/// cannot authorize another service on the same host (#29).
pub(crate) static EXTRA_ALLOWED_ORIGINS: LazyLock<RwLock<HashSet<String>>> =
    LazyLock::new(|| RwLock::new(HashSet::new()));

const BUILT_IN_HOST_SUFFIXES: &[&str] = &[
    "account.xiaomi.com",
    "api.io.mi.com",
    "miot-spec.org",
    // Public release metadata for the update check (#39); no credentials are sent.
    "api.github.com",
];

pub(crate) fn normalize_host(raw: &str) -> String {
    raw.trim()
        .trim_end_matches('.')
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_ascii_lowercase()
}

pub(crate) fn url_origin(url: &reqwest::Url) -> Option<String> {
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    let host = normalize_host(url.host_str()?);
    if host.is_empty() {
        return None;
    }
    let authority = if host.contains(':') {
        format!("[{host}]")
    } else {
        host
    };
    Some(format!(
        "{}://{}:{}", url.scheme(), authority, url.port_or_known_default()?
    ))
}

pub(crate) fn normalize_extra_origin(raw: &str) -> Option<String> {
    let url = reqwest::Url::parse(raw.trim()).ok()?;
    if url.path() != "/" || url.query().is_some() || url.fragment().is_some() {
        return None;
    }
    url_origin(&url)
}

pub(crate) fn check_url_allowed(url: &reqwest::Url, extra: &HashSet<String>) -> Result<(), String> {
    let origin = url_origin(url)
        .ok_or_else(|| "native_http 地址必须是无用户凭据的 http/https 地址".to_string())?;
    let host = normalize_host(url.host_str().unwrap_or_default());
    let built_in_host = BUILT_IN_HOST_SUFFIXES
        .iter()
        .any(|suffix| host == *suffix || host.ends_with(&format!(".{suffix}")));
    let allowed = if built_in_host {
        url.scheme() == "https" && url.port_or_known_default() == Some(443)
    } else {
        extra.contains(&origin)
    };
    if allowed {
        Ok(())
    } else {
        Err(format!("native_http 拒绝访问未授权来源：{origin}"))
    }
}

pub(crate) fn redirect_allowed(original_origin: &str, next: &reqwest::Url, extra: &HashSet<String>) -> bool {
    url_origin(next).as_deref() == Some(original_origin) && check_url_allowed(next, extra).is_ok()
}

pub(crate) fn allowed_origins_snapshot() -> Result<HashSet<String>, String> {
    EXTRA_ALLOWED_ORIGINS
        .read()
        .map(|origins| origins.clone())
        .map_err(|_| "origin allowlist unavailable".to_string())
}


#[derive(Serialize)]
pub(crate) struct NativeHttpResponse {
    pub(crate) status: u16,
    pub(crate) headers: HashMap<String, String>,
    pub(crate) body: String,
}

/// Formats a `reqwest::Error` with its full `std::error::Error::source()` chain and an explicit
/// timeout marker (#256). `reqwest` 0.12 stopped inlining `source()` into `Display`, so a 15-second
/// long-poll timeout formatted via `e.to_string()` alone becomes a bare
/// `error sending request for url (...)` and breaks timeout-retry detection in the frontend.
pub(crate) fn format_reqwest_error(err: &reqwest::Error) -> String {
    let mut detail = err.to_string();
    let mut source = std::error::Error::source(err);
    while let Some(cause) = source {
        let text = cause.to_string();
        if !text.is_empty() && !detail.contains(&text) {
            detail.push_str(": ");
            detail.push_str(&text);
        }
        source = cause.source();
    }
    if err.is_timeout() && !detail.to_ascii_lowercase().contains("timed out") && !detail.to_ascii_lowercase().contains("timeout") {
        detail.push_str(": operation timed out");
    }
    detail
}

pub(crate) const MIN_HTTP_TIMEOUT_MS: u64 = 500;
pub(crate) const MAX_HTTP_TIMEOUT_MS: u64 = 60_000;
pub(crate) const DEFAULT_HTTP_TIMEOUT_MS: u64 = 15_000;
pub(crate) const MAX_HTTP_RESPONSE_BYTES: usize = 16 * 1024 * 1024;

pub(crate) fn clamp_http_timeout_ms(timeout_ms: Option<u64>) -> u64 {
    timeout_ms
        .unwrap_or(DEFAULT_HTTP_TIMEOUT_MS)
        .clamp(MIN_HTTP_TIMEOUT_MS, MAX_HTTP_TIMEOUT_MS)
}

pub(crate) fn append_bounded_response_chunk(
    buf: &mut Vec<u8>,
    chunk: &[u8],
    max_bytes: usize,
) -> Result<(), String> {
    if buf.len().saturating_add(chunk.len()) > max_bytes {
        return Err(format!("native_http 响应体超过 {max_bytes} 字节上限"));
    }
    buf.extend_from_slice(chunk);
    Ok(())
}

struct HttpRedirectScope {
    follow: bool,
    allowed_origins: HashSet<String>,
    original_origin: String,
    ha_scope: Option<String>,
    address_policy: EndpointAddressPolicy,
}

// Reqwest polls its redirect middleware inside the request future. Scope the authorization
// to that future so concurrent requests can share a pool without sharing redirect permissions.
tokio::task_local! {
    static HTTP_REDIRECT_SCOPE: HttpRedirectScope;
}

static HTTP_CLIENT: LazyLock<Result<reqwest::Client, String>> = LazyLock::new(|| {
    reqwest::Client::builder()
        .no_proxy()
        .dns_resolver(std::sync::Arc::new(PolicyAwareResolver))
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            let allowed = HTTP_REDIRECT_SCOPE
                .try_with(|scope| {
                    scope.follow
                        && attempt.previous().len() < 5
                        && redirect_allowed(&scope.original_origin, attempt.url(), &scope.allowed_origins)
                        && scope.ha_scope.as_ref().is_none_or(|ha| in_ha_scope(attempt.url(), ha))
                })
                .unwrap_or(false);
            if allowed { attempt.follow() } else { attempt.stop() }
        }))
        .build()
        .map_err(|error| format_reqwest_error(&error))
});

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AddressClass {
    Public,
    Lan,
    Prohibited,
}

fn address_class(ip: IpAddr) -> AddressClass {
    match ip {
        IpAddr::V4(ip) => match ip.octets() {
            [0 | 127 | 224..=255, ..] => AddressClass::Prohibited,
            // Shared address space (100.64/10) includes Tailscale endpoints.
            [10, ..] | [172, 16..=31, ..] | [192, 168, ..] | [169, 254, ..]
            | [100, 64..=127, ..] => AddressClass::Lan,
            _ => AddressClass::Public,
        },
        IpAddr::V6(ip) => {
            if let Some(mapped) = ip.to_ipv4_mapped() {
                return address_class(mapped.into());
            }
            match ip.segments() {
                [0, 0, 0, 0, 0, 0, ..] | [0xfec0..=0xffff, ..] => AddressClass::Prohibited,
                [0xfc00..=0xfdff | 0xfe80..=0xfebf, ..] => AddressClass::Lan,
                _ => AddressClass::Public,
            }
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) struct EndpointAddressPolicy {
    requires_lan: bool,
    #[cfg(test)]
    fixture: Option<SocketAddr>,
}

impl EndpointAddressPolicy {
    pub(crate) fn for_endpoint(host: &str, _port: u16, scheme: &str) -> Self {
        let host = normalize_host(host);
        let local = host.parse::<IpAddr>().map_or_else(
            |_| is_local_network_host(&host),
            |ip| address_class(ip) == AddressClass::Lan,
        );
        Self {
            requires_lan: local && matches!(scheme, "http" | "ws"),
            #[cfg(test)]
            fixture: host.parse::<IpAddr>().ok().map(|ip| SocketAddr::new(ip, _port))
                .filter(|addr| LOOPBACK_FIXTURES.read().unwrap().contains(addr)),
        }
    }

    pub(crate) fn validate(self, addresses: impl IntoIterator<Item = SocketAddr>) -> io::Result<Vec<SocketAddr>> {
        let addresses: Vec<_> = addresses.into_iter().collect();
        if addresses.is_empty() {
            return Err(io::Error::new(io::ErrorKind::NotFound, "endpoint has no resolved addresses"));
        }
        for address in &addresses {
            #[cfg(test)]
            if self.fixture == Some(*address) {
                continue;
            }
            let class = address_class(address.ip());
            if class == AddressClass::Prohibited || (self.requires_lan && class == AddressClass::Public) {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "endpoint resolved to a prohibited IP address or a public IP for local plaintext traffic",
                ));
            }
        }
        Ok(addresses)
    }
}

struct PolicyAwareResolver;

impl reqwest::dns::Resolve for PolicyAwareResolver {
    fn resolve(&self, name: reqwest::dns::Name) -> reqwest::dns::Resolving {
        let policy = HTTP_REDIRECT_SCOPE.try_with(|scope| scope.address_policy);
        Box::pin(async move {
            let policy = policy.map_err(|_| {
                io::Error::new(io::ErrorKind::PermissionDenied, "missing endpoint address policy")
            })?;
            let addresses = tokio::net::lookup_host((name.as_str(), 0)).await?;
            Ok(Box::new(policy.validate(addresses)?.into_iter()) as reqwest::dns::Addrs)
        })
    }
}

fn in_ha_scope(url: &reqwest::Url, scope: &str) -> bool {
    let path = url.path().to_ascii_lowercase();
    let target = format!("{}{}", url.origin().ascii_serialization(), url.path());
    target.starts_with(&format!("{scope}/api/"))
        && url.fragment().is_none()
        && !["%2e", "%2f", "%5c"].iter().any(|&escape| path.contains(escape))
}

#[tauri::command]
pub(crate) async fn native_http(
    url: String,
    method: Option<String>,
    headers: Option<HashMap<String, String>>,
    body: Option<String>,
    follow_redirects: Option<bool>,
    timeout_ms: Option<u64>,
) -> Result<NativeHttpResponse, String> {
    native_http_with_scope(url, method, headers, body, follow_redirects, timeout_ms, None).await
}

pub(crate) async fn native_http_with_scope(
    url: String,
    method: Option<String>,
    headers: Option<HashMap<String, String>>,
    body: Option<String>,
    follow_redirects: Option<bool>,
    timeout_ms: Option<u64>,
    ha_scope: Option<String>,
) -> Result<NativeHttpResponse, String> {
    let allowed_origins = allowed_origins_snapshot()?;
    let parsed_url = reqwest::Url::parse(&url).map_err(|e| format!("native_http 地址无效：{e}"))?;
    check_url_allowed(&parsed_url, &allowed_origins)?;
    if ha_scope.as_ref().is_some_and(|scope| !in_ha_scope(&parsed_url, scope)) {
        return Err("Home Assistant HTTP request is outside the registered scope".into());
    }

    // Each origin has one address policy, including when a connection is reused.
    // Hyper skips the resolver for IP literals, so validate them before checkout.
    let host = normalize_host(parsed_url.host_str().expect("validated request host"));
    let port = parsed_url.port_or_known_default().expect("validated request port");
    let address_policy = EndpointAddressPolicy::for_endpoint(&host, port, parsed_url.scheme());
    if let Ok(ip) = host.parse::<IpAddr>() {
        address_policy.validate([SocketAddr::new(ip, port)]).map_err(|error| error.to_string())?;
    }
    let follow = follow_redirects.unwrap_or(true);
    let redirect_scope = HttpRedirectScope {
        follow,
        allowed_origins,
        original_origin: url_origin(&parsed_url).expect("validated request origin"),
        ha_scope,
        address_policy,
    };
    let client = HTTP_CLIENT.as_ref().map_err(Clone::clone)?;

    let verb = method.unwrap_or_else(|| "GET".to_string()).to_uppercase();
    let mut req = match verb.as_str() {
        "GET" => client.get(&url),
        "POST" => client.post(&url),
        "PUT" => client.put(&url),
        "PATCH" => client.patch(&url),
        "DELETE" => client.delete(&url),
        other => return Err(format!("native_http 不支持的方法：{other}")),
    };

    if let Some(hdrs) = headers {
        let mut map = HeaderMap::new();
        for (k, v) in hdrs {
            // Request framing is owned by reqwest; letting the frontend set these
            // could smuggle a second request past the URL allowlist.
            if matches!(
                k.to_ascii_lowercase().as_str(),
                "host" | "content-length" | "transfer-encoding" | "connection" | "upgrade"
            ) {
                continue;
            }
            if let (Ok(name), Ok(val)) = (HeaderName::from_str(&k), HeaderValue::from_str(&v)) {
                map.insert(name, val);
            }
        }
        req = req.headers(map);
    }

    if let Some(b) = body {
        req = req.body(b);
    }

    let req = req.timeout(Duration::from_millis(clamp_http_timeout_ms(timeout_ms)));
    let mut resp = HTTP_REDIRECT_SCOPE
        .scope(redirect_scope, req.send())
        .await
        .map_err(|e| format_reqwest_error(&e))?;
    let status = resp.status().as_u16();
    // A stopped redirect comes back as a 3xx here; surfacing it as an error is
    // clearer than handing the frontend a response from a host it may not use.
    if follow && resp.status().is_redirection() && status != 304 {
        return Err("native_http 拒绝跨来源或未授权重定向".to_string());
    }
    if resp
        .content_length()
        .is_some_and(|len| len > MAX_HTTP_RESPONSE_BYTES as u64)
    {
        return Err(format!(
            "native_http 响应体超过 {MAX_HTTP_RESPONSE_BYTES} 字节上限"
        ));
    }

    let mut out_headers: HashMap<String, String> = HashMap::new();
    for (name, val) in resp.headers().iter() {
        if let Ok(v_str) = val.to_str() {
            let key = name.as_str().to_lowercase();
            out_headers
                .entry(key)
                .and_modify(|existing| {
                    existing.push_str("; ");
                    existing.push_str(v_str);
                })
                .or_insert_with(|| v_str.to_string());
        }
    }

    let mut body_bytes = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(|e| format_reqwest_error(&e))? {
        append_bounded_response_chunk(&mut body_bytes, &chunk, MAX_HTTP_RESPONSE_BYTES)?;
    }
    let text = String::from_utf8_lossy(&body_bytes).into_owned();
    Ok(NativeHttpResponse {
        status,
        headers: out_headers,
        body: text,
    })
}

#[cfg(test)]
static LOOPBACK_FIXTURES: LazyLock<RwLock<HashSet<SocketAddr>>> = LazyLock::new(Default::default);

#[cfg(test)]
pub(crate) fn allow_loopback_fixture(listener: &std::net::TcpListener) -> impl Drop + use<> {
    struct Fixture(SocketAddr);
    impl Drop for Fixture {
        fn drop(&mut self) {
            LOOPBACK_FIXTURES.write().unwrap().remove(&self.0);
        }
    }
    let address = listener.local_addr().unwrap();
    assert!(address.ip().is_loopback());
    LOOPBACK_FIXTURES.write().unwrap().insert(address);
    Fixture(address)
}

pub(crate) fn origin_from_endpoint(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    };
    let url = reqwest::Url::parse(&with_scheme).ok()?;
    url_origin(&url)
}

/// Validates a Home Assistant base URL (allowing reverse-proxy subpaths like `/hass` or `/ha/`)
/// and returns `(origin, websocket_path)` while rejecting credentials, query, fragment, and dot segments.
pub(crate) fn parse_ha_endpoint_parts(raw: &str, allow_schemeless: bool) -> Result<(String, String), String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("Invalid Home Assistant URL".into());
    }
    // A control character (`\t`, `\n`, `\0`) lets one string carry a second origin past a naive
    // check, and no name a person types contains one.
    if trimmed.chars().any(|c| c.is_control()) {
        return Err("Invalid Home Assistant URL".into());
    }
    if trimmed.contains('\\') {
        return Err("Invalid Home Assistant URL".into());
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_string()
    } else if allow_schemeless {
        format!("https://{trimmed}")
    } else {
        return Err("Invalid Home Assistant URL".into());
    };
    if let Some((_scheme, rest)) = with_scheme.split_once("://") {
        if let Some((_authority, raw_tail)) = rest.split_once('/') {
            let raw_path = raw_tail.split(['?', '#']).next().unwrap_or("");
            let raw_lower = raw_path.to_ascii_lowercase();
            if raw_path.contains('\\')
                || raw_lower.contains("%2e")
                || raw_lower.contains("%2f")
                || raw_lower.contains("%5c")
                || raw_path.split('/').any(|seg| seg == "." || seg == "..")
            {
                return Err("Home Assistant URL path is invalid".into());
            }
        }
    }
    let url = reqwest::Url::parse(&with_scheme).map_err(|_| "Invalid Home Assistant URL".to_string())?;
    if !url.username().is_empty() || url.password().is_some() {
        return Err("Home Assistant URL must not include credentials".into());
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err("Home Assistant URL must not include query or fragment".into());
    }
    let ws_path = ha_websocket_path(url.path())?;
    let origin = url_origin(&url).ok_or_else(|| "Home Assistant requires an HTTP or HTTPS origin".to_string())?;
    Ok((origin, ws_path))
}

pub(crate) fn ha_websocket_path(raw_path: &str) -> Result<String, String> {
    let lower = raw_path.to_ascii_lowercase();
    if raw_path.chars().any(|c| c.is_control())
        || raw_path.contains('\\')
        || lower.contains("%2e")
        || lower.contains("%2f")
        || lower.contains("%5c")
    {
        return Err("Home Assistant URL path is invalid".into());
    }
    for seg in raw_path.split('/') {
        if seg == "." || seg == ".." {
            return Err("Home Assistant URL path is invalid".into());
        }
    }
    let trimmed = raw_path.trim_end_matches('/');
    let mut prefix: Vec<&str> = trimmed.split('/').filter(|s| !s.is_empty()).collect();
    if prefix.ends_with(&["api", "websocket"]) {
        prefix.truncate(prefix.len() - 2);
    } else if prefix.last() == Some(&"api") {
        prefix.pop();
    }
    if prefix.is_empty() {
        Ok("/api/websocket".to_string())
    } else {
        Ok(format!("/{}/api/websocket", prefix.join("/")))
    }
}

fn service_origin(raw: &str, is_assistant: bool) -> Result<Option<String>, String> {
    if raw.trim().is_empty() {
        return Ok(None);
    }
    if !is_assistant {
        return parse_ha_endpoint_parts(raw, true)
            .map(|(origin, _)| Some(origin))
            .map_err(|_| format!("invalid configured endpoint: {raw}"));
    }
    origin_from_endpoint(raw)
        .map(Some)
        .ok_or_else(|| format!("invalid configured endpoint: {raw}"))
}

#[derive(Debug, Default)]
pub(crate) struct ServiceOrigins {
    /// Origin paired with whether its confirmation dialog needs the plaintext warning.
    pub(crate) origins: HashMap<String, bool>,
    /// A public plaintext AI origin refused before confirmation.
    pub(crate) rejected_assistant: Option<String>,
}

impl ServiceOrigins {
    fn rejection(&self) -> Option<String> {
        self.rejected_assistant
            .as_deref()
            .map(|origin| format!("AI 服务地址必须使用 https 或局域网地址：{origin}"))
    }
}

const LOCAL_HOST_SUFFIXES: &[&str] = &[".local", ".lan", ".home.arpa", ".internal"];

/// Native copy of `isLocalNetworkEndpoint`, so a compromised WebView cannot vouch for a public
/// host. Both sides are held to `Tests/Fixtures/local_network_endpoint_golden.json`.
pub(crate) fn is_local_network_host(host: &str) -> bool {
    if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() {
        let [a, b, ..] = ip.octets();
        return a == 127
            || a == 10
            || (a == 192 && b == 168)
            || (a == 169 && b == 254)
            || (a == 172 && (16..=31).contains(&b))
            || (a == 100 && (64..=127).contains(&b));
    }
    if let Ok(ip) = host.parse::<std::net::Ipv6Addr>() {
        let first = ip.segments()[0];
        return ip.is_loopback() || first & 0xfe00 == 0xfc00 || first & 0xffc0 == 0xfe80;
    }
    host == "localhost" || LOCAL_HOST_SUFFIXES.iter().any(|suffix| host.ends_with(suffix))
}

fn origin_is_local_network(origin: &str) -> bool {
    reqwest::Url::parse(origin)
        .ok()
        .and_then(|url| url.host_str().map(normalize_host))
        .is_some_and(|host| is_local_network_host(&host))
}

/// Configured origins paired with whether their dialog needs a plaintext warning.
///
/// A public plaintext AI endpoint is left out and remembered for rejection, so an
/// independently valid Home Assistant origin can still be authorized in the same save.
pub(crate) fn requested_service_origins(
    assistant_url: &str,
    ha_url: &str,
) -> Result<ServiceOrigins, String> {
    let mut requested = ServiceOrigins::default();
    for (raw, is_assistant) in [(assistant_url, true), (ha_url, false)] {
        let Some(origin) = service_origin(raw, is_assistant)? else {
            continue;
        };
        let plaintext_warning = origin.starts_with("http://") && !origin_is_local_network(&origin);
        if is_assistant && plaintext_warning {
            requested.rejected_assistant = Some(origin);
            continue;
        }
        requested
            .origins
            .entry(origin)
            .and_modify(|warning| *warning |= plaintext_warning)
            .or_insert(plaintext_warning);
    }
    Ok(requested)
}

pub(crate) fn read_origin_store(path: &std::path::Path) -> HashSet<String> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return HashSet::new();
    };
    let Ok(values) = serde_json::from_str::<Vec<String>>(&text) else {
        return HashSet::new();
    };
    values
        .into_iter()
        .filter_map(|value| normalize_extra_origin(&value))
        .collect()
}

pub(crate) fn write_origin_store(path: &std::path::Path, origins: &HashSet<String>) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("无法保存已授权来源：{error}"))?;
    }
    let mut values: Vec<&String> = origins.iter().collect();
    values.sort();
    let body = serde_json::to_string(&values).map_err(|error| error.to_string())?;
    std::fs::write(path, body).map_err(|error| format!("无法保存已授权来源：{error}"))
}

/// `%APPDATA%\MenuBarMijia`, the folder for the Windows-only state files.
#[cfg(not(test))]
pub(crate) fn app_state_dir() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("APPDATA")?;
    Some(std::path::PathBuf::from(base).join("MenuBarMijia"))
}

#[cfg(test)]
pub(crate) fn authorization_store_path() -> Option<std::path::PathBuf> {
    None
}

#[cfg(not(test))]
pub(crate) fn authorization_store_path() -> Option<std::path::PathBuf> {
    Some(app_state_dir()?.join("authorized-http-origins.json"))
}

pub(crate) fn store_authorized(origins: &HashSet<String>) -> Result<(), String> {
    if let Some(path) = authorization_store_path() {
        write_origin_store(&path, origins)?;
    }
    let mut guard = EXTRA_ALLOWED_ORIGINS
        .write()
        .map_err(|_| "origin allowlist unavailable".to_string())?;
    *guard = origins.clone();
    Ok(())
}

fn confirm_novel_origins(
    current: &HashSet<String>,
    requested: &ServiceOrigins,
    mut confirm: impl FnMut(&str, bool) -> bool,
) -> Result<HashSet<String>, String> {
    let mut novel: Vec<(&String, bool)> = requested
        .origins
        .iter()
        .filter(|(origin, _)| !current.contains(*origin))
        .map(|(origin, warning)| (origin, *warning))
        .collect();
    novel.sort_by(|left, right| left.0.cmp(right.0));
    for (origin, plaintext_warning) in novel {
        if !confirm(origin, plaintext_warning) {
            return Err(format!("未授权的网络来源：{origin}"));
        }
    }
    Ok(requested.origins.keys().cloned().collect())
}

pub(crate) fn decide_service_origins(
    current: &HashSet<String>,
    assistant_url: &str,
    ha_url: &str,
    confirm: impl FnMut(&str, bool) -> bool,
) -> Result<HashSet<String>, String> {
    let requested = requested_service_origins(
        assistant_url,
        ha_url,
    )?;
    let authorized = confirm_novel_origins(current, &requested, confirm)?;
    if let Some(message) = requested.rejection() {
        return Err(message);
    }
    Ok(authorized)
}

pub(crate) fn authorize_service_endpoints(
    assistant_url: &str,
    ha_url: &str,
    confirm: impl FnMut(&str, bool) -> bool,
) -> Result<(), String> {
    let current = allowed_origins_snapshot()?;
    let requested = requested_service_origins(
        assistant_url,
        ha_url,
    )?;
    let next = confirm_novel_origins(&current, &requested, confirm)?;
    store_authorized(&next)?;
    if let Some(message) = requested.rejection() {
        return Err(message);
    }
    Ok(())
}

/// Shown when a plain-http origin outside the local network would carry a token or key (#277).
pub(crate) const PLAINTEXT_WARNING: &str =
    "警告：这个地址使用明文 http，Home Assistant 令牌和 AI API Key 会以明文在网络上传输。";

pub(crate) fn confirmation_message(origin: &str, plaintext_warning: bool) -> String {
    let mut text = format!(
        "允许 MenuBarHome 连接这个地址吗？\n\n{origin}\n\n只有你在设置里填写的 Home Assistant 或 AI 服务地址才应该出现在这里。"
    );
    if plaintext_warning {
        text.push_str("\n\n");
        text.push_str(PLAINTEXT_WARNING);
    }
    text
}

#[cfg(test)]
pub(crate) fn user_confirms_origin(_origin: &str, _plaintext_warning: bool) -> bool {
    false
}

#[cfg(all(windows, not(test)))]
pub(crate) fn user_confirms_origin(origin: &str, plaintext_warning: bool) -> bool {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    let text = confirmation_message(origin, plaintext_warning);
    let text_wide: Vec<u16> = OsStr::new(&text).encode_wide().chain(std::iter::once(0)).collect();
    let title_wide: Vec<u16> = OsStr::new("MenuBarHome").encode_wide().chain(std::iter::once(0)).collect();
    #[link(name = "user32")]
    extern "system" {
        fn MessageBoxW(
            hwnd: *mut std::ffi::c_void,
            text: *const u16,
            caption: *const u16,
            utype: u32,
        ) -> i32;
    }
    const MB_YESNO: u32 = 0x0000_0004;
    const MB_ICONWARNING: u32 = 0x0000_0030;
    const MB_DEFBUTTON2: u32 = 0x0000_0100;
    const IDYES: i32 = 6;
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            text_wide.as_ptr(),
            title_wide.as_ptr(),
            MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2,
        ) == IDYES
    }
}

#[tauri::command]
pub(crate) fn set_service_endpoints(
    assistant_url: String,
    ha_url: String,
) -> Result<(), String> {
    authorize_service_endpoints(
        &assistant_url,
        &ha_url,
        user_confirms_origin,
    )
}

#[cfg(test)]
mod address_policy_tests {
    use super::*;
    use reqwest::dns::Resolve;

    #[test]
    fn classifies_ip_literals_and_ipv4_mapped_addresses() {
        for (raw, expected) in [
            ("0.0.0.0", AddressClass::Prohibited),
            ("0.1.2.3", AddressClass::Prohibited),
            ("127.255.0.1", AddressClass::Prohibited),
            ("::", AddressClass::Prohibited),
            ("::1", AddressClass::Prohibited),
            ("::ffff:127.0.0.1", AddressClass::Prohibited),
            ("169.254.1.2", AddressClass::Lan),
            ("::ffff:192.168.1.2", AddressClass::Lan),
            ("fe80::1", AddressClass::Lan),
            ("febf::1", AddressClass::Lan),
            ("fc00::1", AddressClass::Lan),
            ("fdff::1", AddressClass::Lan),
            ("100.64.0.1", AddressClass::Lan),
            ("100.127.255.255", AddressClass::Lan),
            ("100.128.0.1", AddressClass::Public),
            ("::ffff:8.8.8.8", AddressClass::Public),
            ("2001:4860::8888", AddressClass::Public),
        ] {
            assert_eq!(address_class(raw.parse().unwrap()), expected, "{raw}");
        }
    }

    #[test]
    fn validates_dns_answers_for_the_configured_host_and_scheme() {
        let lan = "192.168.1.2:8123".parse::<SocketAddr>().unwrap();
        for (host, scheme, other, allowed) in [
            ("cloud.example", "https", "100.64.0.1:8123", true),
            ("cloud.example", "http", "192.0.2.1:8123", true),
            ("cloud.example", "https", "127.0.0.1:8123", false),
            ("home.lan", "http", "192.0.2.1:8123", false),
            ("home.lan", "https", "192.0.2.1:8123", true),
            ("home.local", "ws", "192.0.2.1:8123", false),
            ("home.local", "wss", "192.0.2.1:8123", true),
            ("home.lan", "http", "[::ffff:127.0.0.1]:8123", false),
            ("192.168.1.2", "http", "192.0.2.1:8123", false),
        ] {
            let policy = EndpointAddressPolicy::for_endpoint(host, lan.port(), scheme);
            let addresses = [lan, other.parse().unwrap()];
            let result = policy.validate(addresses);
            if allowed {
                assert_eq!(result.unwrap(), addresses, "{scheme}://{host} with {other}");
            } else {
                assert_eq!(result.unwrap_err().kind(), io::ErrorKind::PermissionDenied, "{scheme}://{host} with {other}");
            }
        }
    }

    #[test]
    fn resolver_refuses_localhost_dns_under_a_public_scope() {
        let scope = HttpRedirectScope {
            follow: false,
            allowed_origins: HashSet::new(),
            original_origin: "https://cloud.example:443".into(),
            ha_scope: None,
            address_policy: EndpointAddressPolicy::for_endpoint("cloud.example", 443, "https"),
        };
        let result = tauri::async_runtime::block_on(HTTP_REDIRECT_SCOPE.scope(
            scope,
            async { PolicyAwareResolver.resolve("localhost".parse().unwrap()).await },
        ));
        let error = result.err().expect("loopback DNS answer was accepted");
        assert_eq!(
            error.downcast_ref::<io::Error>().unwrap().kind(),
            io::ErrorKind::PermissionDenied,
        );
    }
}

#[cfg(test)]
mod ha_scope_tests {
    use super::*;

    const OUTSIDE_SCOPE: &str = "Home Assistant HTTP request is outside the registered scope";

    fn scope_result(url: &str, scope: &str) -> Result<(), String> {
        tauri::async_runtime::block_on(native_http_with_scope(
            url.to_string(),
            None,
            None,
            None,
            None,
            Some(2_000),
            Some(scope.to_string()),
        ))
        .map(|_| ())
    }

    /// Anything that is not inside `<origin>/<subpath>/api/` must be refused before a request is
    /// sent, so a WebView cannot reach the rest of the Home Assistant host through this command.
    #[test]
    fn requests_outside_the_registered_ha_scope_are_refused() {
        let _guard = crate::ORIGIN_TEST_LOCK.lock().unwrap();
        let origin = normalize_extra_origin("https://h").unwrap();
        EXTRA_ALLOWED_ORIGINS.write().unwrap().insert(origin.clone());
        for url in [
            // A sibling subpath that merely shares the character prefix (`/ha` vs `/hat`).
            "https://h/hat/api/x",
            // The origin root, i.e. Home Assistant installed without a reverse-proxy subpath.
            "https://h/api/x",
            // Percent-encoded dot segments must not walk out of the registered subpath.
            "https://h/ha/api/%2e%2e/x",
            "https://h/ha/api/%2E%2E/x",
            "https://h/ha/api/../x",
            // A fragment is not part of `url.path()`, so it must be refused explicitly.
            "https://h/ha/api/x#f",
        ] {
            assert_eq!(scope_result(url, "https://h/ha"), Err(OUTSIDE_SCOPE.into()), "{url}");
        }
        // The in-scope path itself still reaches the host; the redirect test below asserts that.
        EXTRA_ALLOWED_ORIGINS.write().unwrap().remove(&origin);
    }

    #[test]
    fn allowed_redirect_uses_reqwest_semantics_and_reuses_the_connection() {
        use std::io::{BufRead, BufReader, Read, Write};

        let _guard = crate::ORIGIN_TEST_LOCK.lock().unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let _fixture = crate::network::allow_loopback_fixture(&listener);
        let base = format!("http://{}", listener.local_addr().unwrap());
        let origin = normalize_extra_origin(&base).unwrap();
        EXTRA_ALLOWED_ORIGINS.write().unwrap().insert(origin.clone());
        let peer = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            let mut stream = BufReader::new(stream);
            for (request, response) in [
                ("POST /ha/api/start HTTP/1.1", "302 Found\r\nLocation: /ha/api/next"),
                ("GET /ha/api/next HTTP/1.1", "200 OK"),
                ("GET /ha/api/again HTTP/1.1", "200 OK"),
            ] {
                let mut line = String::new();
                stream.read_line(&mut line).unwrap();
                assert_eq!(line.trim_end(), request);
                loop {
                    line.clear();
                    assert!(stream.read_line(&mut line).unwrap() > 0);
                    if line == "\r\n" { break; }
                }
                if request.starts_with("POST") {
                    let mut body = [0; 4];
                    stream.read_exact(&mut body).unwrap();
                    assert_eq!(&body, b"data");
                }
                write!(stream.get_mut(), "HTTP/1.1 {response}\r\nContent-Length: 0\r\n\r\n").unwrap();
            }
        });
        let result = tauri::async_runtime::block_on(async {
            native_http_with_scope(
                format!("{base}/ha/api/start"), Some("POST".into()), None, Some("data".into()),
                None, Some(2_000), Some(format!("{base}/ha")),
            ).await?;
            native_http_with_scope(
                format!("{base}/ha/api/again"), None, None, None, Some(false), Some(2_000),
                Some(format!("{base}/ha")),
            ).await
        });
        EXTRA_ALLOWED_ORIGINS.write().unwrap().remove(&origin);
        peer.join().unwrap();
        assert_eq!(result.unwrap().status, 200);
    }

    /// A 302 that stays on the allowed origin but leaves the registered Home Assistant subpath must
    /// be stopped at the redirect policy, not followed with the caller's headers.
    #[test]
    fn redirect_outside_the_registered_ha_scope_is_stopped() {
        let _guard = crate::ORIGIN_TEST_LOCK.lock().unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let _fixture = crate::network::allow_loopback_fixture(&listener);
        let base = format!("http://{}", listener.local_addr().unwrap());
        let origin = normalize_extra_origin(&base).unwrap();
        EXTRA_ALLOWED_ORIGINS.write().unwrap().insert(origin.clone());
        let hijack = format!("{base}/api/hijack");
        let peer = std::thread::spawn(move || {
            use std::io::{BufRead, BufReader, Write};
            let (mut first, _) = listener.accept().unwrap();
            first.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
            {
                let mut reader = BufReader::new(&mut first);
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap_or(0) == 0 || header == "\r\n" {
                        break;
                    }
                }
            }
            write!(
                first,
                "HTTP/1.1 302 Found\r\nLocation: {hijack}\r\nContent-Length: 0\r\n\r\n"
            )
            .unwrap();
            // Reaching the second request would mean the redirect was followed outside the scope.
            listener.set_nonblocking(true).unwrap();
            let deadline = std::time::Instant::now() + Duration::from_secs(2);
            while std::time::Instant::now() < deadline {
                match listener.accept() {
                    Ok((mut second, _)) => {
                        let _ = second.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nleaked\n");
                        return true;
                    }
                    Err(ref error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(20));
                    }
                    Err(_) => break,
                }
            }
            false
        });
        let result = scope_result(&format!("{base}/ha/api/states"), &format!("{base}/ha"));
        assert_eq!(result, Err("native_http 拒绝跨来源或未授权重定向".into()));
        assert!(!peer.join().unwrap(), "a 302 leaving the registered scope must not be followed");
        EXTRA_ALLOWED_ORIGINS.write().unwrap().remove(&origin);
    }
}

#[cfg(test)]
mod subpath_tests {
    use super::*;

    #[test]
    fn ha_subpath_urls_normalize_origin_and_websocket_path_while_rejecting_unsafe_components() {
        assert_eq!(
            parse_ha_endpoint_parts("https://home.example.com/hass", false).unwrap(),
            ("https://home.example.com:443".to_string(), "/hass/api/websocket".to_string())
        );
        assert_eq!(
            parse_ha_endpoint_parts("http://192.168.1.8:8123/ha/", false).unwrap(),
            ("http://192.168.1.8:8123".to_string(), "/ha/api/websocket".to_string())
        );
        assert_eq!(
            parse_ha_endpoint_parts("https://home.example.com/hass/api/", false).unwrap(),
            ("https://home.example.com:443".to_string(), "/hass/api/websocket".to_string())
        );
        assert_eq!(
            parse_ha_endpoint_parts("http://192.0.2.10:8123/", false).unwrap(),
            ("http://192.0.2.10:8123".to_string(), "/api/websocket".to_string())
        );

        // A control character is never part of a URL a person types, so it is refused instead of
        // letting one string carry a second origin.
        assert_eq!(
            ha_websocket_path("/hass/api").unwrap(),
            "/hass/api/websocket".to_string()
        );
        // #292 N4: the two-segment suffix is stripped directly, not only through
        // `parse_ha_endpoint_parts`, and only as a complete trailing pair.
        assert_eq!(
            ha_websocket_path("/hass/api/websocket").unwrap(),
            "/hass/api/websocket".to_string()
        );
        assert_eq!(
            ha_websocket_path("/hass/api/websocket/").unwrap(),
            "/hass/api/websocket".to_string()
        );
        assert_eq!(
            ha_websocket_path("/api/websocket").unwrap(),
            "/api/websocket".to_string()
        );
        assert_eq!(
            ha_websocket_path("/api/websocket/api").unwrap(),
            "/api/websocket/api/websocket".to_string()
        );
        assert!(ha_websocket_path("/hass/tab\there").is_err());
        assert!(ha_websocket_path("/hass/new\nline").is_err());
        assert!(ha_websocket_path("/ha\0ss").is_err());
        for control in [
            "https://home.example.com/hass\t/api",
            "https://home.example.com/ha\nss",
            "http://192.168.1.8:8123/\r\nha",
        ] {
            assert!(parse_ha_endpoint_parts(control, false).is_err(), "{control:?}");
            assert!(requested_service_origins("", control).is_err(), "{control:?}");
        }
        // Only the real `/api` suffix is stripped: a reverse proxy whose subpath is `/API` keeps it.
        assert_eq!(
            ha_websocket_path("/hass/API").unwrap(),
            "/hass/API/api/websocket".to_string()
        );
        assert_eq!(
            parse_ha_endpoint_parts("https://home.example.com/hass/API", false).unwrap(),
            (
                "https://home.example.com:443".to_string(),
                "/hass/API/api/websocket".to_string()
            )
        );

        let requested = requested_service_origins("", "https://home.example.com/hass/").unwrap();
        assert_eq!(requested.origins.get("https://home.example.com:443"), Some(&false));

        let lan_requested = requested_service_origins("", "http://192.168.1.8:8123/ha/").unwrap();
        assert_eq!(lan_requested.origins.get("http://192.168.1.8:8123"), Some(&false));

        for invalid in [
            "https://home.example.com/hass?token=secret",
            "https://home.example.com/hass#frag",
            "https://user:pass@home.example.com/hass",
            "https://home.example.com/hass/../admin",
            "https://home.example.com/hass/%2e%2e/admin",
        ] {
            assert!(parse_ha_endpoint_parts(invalid, false).is_err(), "{invalid}");
            assert!(requested_service_origins("", invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn http_timeout_clamps_to_safe_bounds_and_response_chunks_enforce_16_mib_cap() {
        assert_eq!(clamp_http_timeout_ms(None), 15_000);
        assert_eq!(clamp_http_timeout_ms(Some(0)), 500);
        assert_eq!(clamp_http_timeout_ms(Some(100)), 500);
        assert_eq!(clamp_http_timeout_ms(Some(45_000)), 45_000);
        assert_eq!(clamp_http_timeout_ms(Some(120_000)), 60_000);
        assert_eq!(clamp_http_timeout_ms(Some(u64::MAX)), 60_000);
        assert_eq!(MAX_HTTP_RESPONSE_BYTES, 16 * 1024 * 1024);

        let mut buf = Vec::new();
        assert!(append_bounded_response_chunk(&mut buf, b"hello ", 10).is_ok());
        assert!(append_bounded_response_chunk(&mut buf, b"world", 10).is_err());
        assert_eq!(&buf, b"hello ");
    }
}
