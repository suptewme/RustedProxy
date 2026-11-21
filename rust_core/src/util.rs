use anyhow::{anyhow, Context, Result};
use rand::RngCore;
use std::net::IpAddr;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub trait AsyncStream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> AsyncStream for T {}
pub type BoxStream = Box<dyn AsyncStream>;

#[derive(Clone, Debug)]
pub enum Target {
    Domain(String, u16),
    Ip(IpAddr, u16),
}

impl Target {
    pub fn domain(host: &str, port: u16) -> Self {
        if let Ok(ip) = host.parse::<IpAddr>() {
            Target::Ip(ip, port)
        } else {
            Target::Domain(host.trim_matches(['[', ']']).to_string(), port)
        }
    }

    pub fn host(&self) -> String {
        match self {
            Target::Domain(h, _) => h.clone(),
            Target::Ip(ip, _) => ip.to_string(),
        }
    }

    pub fn port(&self) -> u16 {
        match self {
            Target::Domain(_, p) | Target::Ip(_, p) => *p,
        }
    }

    pub fn display(&self) -> String {
        match self {
            Target::Domain(h, p) => format!("{h}:{p}"),
            Target::Ip(IpAddr::V6(ip), p) => format!("[{ip}]:{p}"),
            Target::Ip(ip, p) => format!("{ip}:{p}"),
        }
    }
}

pub fn random_bytes(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    rand::thread_rng().fill_bytes(&mut buf);
    buf
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn is_private_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_documentation()
                || v4.octets()[0] == 0
                || (v4.octets()[0] == 100 && (64..128).contains(&v4.octets()[1]))
        }
        IpAddr::V6(v6) => v6.is_loopback() || v6.is_unique_local() || v6.is_unicast_link_local(),
    }
}

pub async fn read_http_head(s: &mut BoxStream) -> Result<Vec<u8>> {
    let mut buf = Vec::with_capacity(1024);
    let mut tmp = [0u8; 512];
    loop {
        let n = tokio::time::timeout(Duration::from_secs(10), s.read(&mut tmp))
            .await
            .context("http head timeout")??;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if buf.len() > 65536 {
            return Err(anyhow!("http head too large"));
        }
    }
    Ok(buf)
}

pub fn http_status(head: &[u8]) -> Option<u16> {
    let text = String::from_utf8_lossy(head);
    let line = text.lines().next()?;
    let mut parts = line.split_whitespace();
    let _ver = parts.next()?;
    parts.next()?.parse().ok()
}

pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub elapsed_ms: u128,
}

impl HttpResponse {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

/// Minimal HTTP/1.1 GET over an already established (optionally TLS) stream.
pub async fn http_get_over(
    mut stream: BoxStream,
    host: &str,
    path: &str,
    extra_headers: &str,
    max_body: usize,
) -> Result<HttpResponse> {
    let start = std::time::Instant::now();
    let req = format!(
        "GET {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: RustedProxy/1.0\r\nAccept: */*\r\nConnection: close\r\n{extra_headers}\r\n"
    );
    stream.write_all(req.as_bytes()).await?;
    stream.flush().await?;
    let head = read_http_head(&mut stream).await?;
    let (head, mut body) = match head.windows(4).position(|w| w == b"\r\n\r\n") {
        Some(pos) => (head[..pos + 4].to_vec(), head[pos + 4..].to_vec()),
        None => (head.clone(), Vec::new()),
    };
    let status = http_status(&head).ok_or_else(|| anyhow!("bad http response"))?;
    let mut headers = Vec::new();
    let text = String::from_utf8_lossy(&head);
    for line in text.lines().skip(1) {
        if let Some((k, v)) = line.split_once(':') {
            headers.push((k.trim().to_string(), v.trim().to_string()));
        }
    }
    let content_length = headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.parse::<usize>().ok());
    let chunked = headers
        .iter()
        .any(|(k, v)| k.eq_ignore_ascii_case("transfer-encoding") && v.to_lowercase().contains("chunked"));
    if status == 204 || status == 304 {
        return Ok(HttpResponse { status, headers, body: body.into_iter().take(max_body).collect(), elapsed_ms: start.elapsed().as_millis() });
    }
    if chunked {
        let mut raw = body;
        let mut tmp = [0u8; 8192];
        loop {
            match tokio::time::timeout(Duration::from_secs(8), stream.read(&mut tmp)).await {
                Ok(Ok(0)) | Err(_) => break,
                Ok(Ok(n)) => {
                    raw.extend_from_slice(&tmp[..n]);
                    if raw.len() > max_body * 2 + 65536 {
                        break;
                    }
                }
                Ok(Err(_)) => break,
            }
        }
        body = decode_chunked(&raw, max_body);
    } else {
        let want = content_length.unwrap_or(max_body).min(max_body);
        let mut tmp = [0u8; 8192];
        while body.len() < want {
            match tokio::time::timeout(Duration::from_secs(8), stream.read(&mut tmp)).await {
                Ok(Ok(0)) | Err(_) => break,
                Ok(Ok(n)) => body.extend_from_slice(&tmp[..n]),
                Ok(Err(_)) => break,
            }
        }
        body.truncate(want.min(max_body));
    }
    Ok(HttpResponse { status, headers, body, elapsed_ms: start.elapsed().as_millis() })
}

fn decode_chunked(raw: &[u8], max: usize) -> Vec<u8> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    while pos < raw.len() {
        let Some(end) = raw[pos..].windows(2).position(|w| w == b"\r\n") else { break };
        let line = String::from_utf8_lossy(&raw[pos..pos + end]).to_string();
        let size = usize::from_str_radix(line.trim().split(';').next().unwrap_or("0"), 16).unwrap_or(0);
        pos += end + 2;
        if size == 0 {
            break;
        }
        if pos + size > raw.len() {
            break;
        }
        out.extend_from_slice(&raw[pos..pos + size]);
        pos += size + 2;
        if out.len() >= max {
            break;
        }
    }
    out.truncate(max);
    out
}

pub async fn copy_counted<R, W>(mut r: R, mut w: W, counter: &std::sync::atomic::AtomicU64) -> std::io::Result<u64>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut buf = vec![0u8; 32 * 1024];
    let mut total = 0u64;
    loop {
        let n = r.read(&mut buf).await?;
        if n == 0 {
            let _ = w.shutdown().await;
            return Ok(total);
        }
        w.write_all(&buf[..n]).await?;
        total += n as u64;
        counter.fetch_add(n as u64, std::sync::atomic::Ordering::Relaxed);
    }
}

pub fn split_host_port(s: &str) -> Result<(String, u16)> {
    let s = s.trim();
    if let Some(rest) = s.strip_prefix('[') {
        let (host, tail) = rest.split_once(']').ok_or_else(|| anyhow!("bad ipv6 address"))?;
        let port = tail.trim_start_matches(':').parse::<u16>().context("bad port")?;
        return Ok((host.to_string(), port));
    }
    let (host, port) = s.rsplit_once(':').ok_or_else(|| anyhow!("missing port"))?;
    Ok((host.to_string(), port.parse::<u16>().context("bad port")?))
}

pub fn socket_addr_string(ip: IpAddr, port: u16) -> String {
    match ip {
        IpAddr::V4(v4) => format!("{v4}:{port}"),
        IpAddr::V6(v6) => format!("[{v6}]:{port}"),
    }
}

pub fn normalize_host(input: &str) -> String {
    input
        .trim()
        .trim_start_matches("http://")
        .trim_start_matches("https://")
        .split('/')
        .next()
        .unwrap_or(input)
        .to_string()
}

pub fn base64_decode_maybe(s: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    let cleaned: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    let engine = base64::engine::general_purpose::STANDARD;
    engine.decode(&cleaned).ok().or_else(|| {
        base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(cleaned.trim_end_matches('='))
            .ok()
    })
}

pub fn url_decode(s: &str) -> String {
    percent_encoding::percent_decode_str(s).decode_utf8_lossy().to_string()
}
