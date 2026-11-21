use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha224};
use std::net::IpAddr;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use url::Url;

use crate::dns::Resolver;
use crate::tls;
use crate::util::{http_get_over, read_http_head, BoxStream, HttpResponse, Target};

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct ProxyConfig {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub proto: String,
    #[serde(default)]
    pub host: String,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub cipher: String,
    #[serde(default)]
    pub uuid: String,
    #[serde(default)]
    pub sni: String,
    #[serde(default)]
    pub tls: bool,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub country: String,
    #[serde(default)]
    pub country_code: String,
    #[serde(default)]
    pub city: String,
    #[serde(default)]
    pub flag: String,
    #[serde(default)]
    pub latency: i64,
    #[serde(default)]
    pub speed: f64,
    #[serde(default)]
    pub encrypted: bool,
    #[serde(default)]
    pub anonymity: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub raw: String,
}

fn default_port() -> u16 {
    1080
}

impl ProxyConfig {
    pub fn endpoint(&self) -> String {
        if self.host.contains(':') {
            format!("[{}]:{}", self.host, self.port)
        } else {
            format!("{}:{}", self.host, self.port)
        }
    }

    pub fn is_encrypted(&self) -> bool {
        self.encrypted
            || matches!(
                self.proto.as_str(),
                "https" | "ss" | "trojan" | "hysteria2" | "vmess" | "vless"
            ) && (self.tls || self.proto != "vless")
    }
}

pub struct Dialer {
    pub resolver: std::sync::Arc<Resolver>,
    pub connect_timeout: Duration,
}

impl Dialer {
    pub fn new(resolver: std::sync::Arc<Resolver>) -> Self {
        Self { resolver, connect_timeout: Duration::from_secs(8) }
    }

    pub async fn tcp_connect(&self, host: &str, port: u16) -> Result<TcpStream> {
        let ips = self.resolver.resolve(host).await?;
        let mut last: Option<anyhow::Error> = None;
        for ip in ips {
            let addr = std::net::SocketAddr::new(ip, port);
            match tokio::time::timeout(self.connect_timeout, TcpStream::connect(addr)).await {
                Ok(Ok(stream)) => {
                    stream.set_nodelay(true).ok();
                    return Ok(stream);
                }
                Ok(Err(e)) => last = Some(e.into()),
                Err(e) => last = Some(e.into()),
            }
        }
        Err(last.unwrap_or_else(|| anyhow!("connect failed")))
    }

    pub async fn connect_direct(&self, target: &Target) -> Result<BoxStream> {
        match target {
            Target::Ip(ip, port) => {
                let addr = std::net::SocketAddr::new(*ip, *port);
                let stream =
                    tokio::time::timeout(self.connect_timeout, TcpStream::connect(addr)).await??;
                stream.set_nodelay(true).ok();
                Ok(Box::new(stream))
            }
            Target::Domain(host, port) => {
                let stream = self.tcp_connect(host, *port).await?;
                Ok(Box::new(stream))
            }
        }
    }

    /// Establish a connection to `target` through the given proxy chain.
    /// The first proxy is the entry hop, the last one is the exit hop.
    pub async fn dial_chain(&self, chain: &[ProxyConfig], target: &Target) -> Result<BoxStream> {
        if chain.is_empty() {
            return self.connect_direct(target).await;
        }
        let mut stream: Option<BoxStream> = None;
        for (idx, proxy) in chain.iter().enumerate() {
            let next_target = if idx + 1 < chain.len() {
                Target::domain(&chain[idx + 1].host, chain[idx + 1].port)
            } else {
                target.clone()
            };
            let is_last = idx + 1 == chain.len();
            if !is_last && proxy.proto == "ss" {
                bail!("Shadowsocks нельзя использовать как промежуточный узел цепочки");
            }
            stream = Some(self.establish(proxy, &next_target, stream).await.with_context(|| {
                format!("hop {} ({} {})", idx + 1, proxy.proto, proxy.endpoint())
            })?);
        }
        stream.ok_or_else(|| anyhow!("empty chain"))
    }

    async fn establish(
        &self,
        proxy: &ProxyConfig,
        target: &Target,
        base: Option<BoxStream>,
    ) -> Result<BoxStream> {
        let mut stream: BoxStream = match base {
            Some(s) => s,
            None => {
                let tcp = self.tcp_connect(&proxy.host, proxy.port).await?;
                Box::new(tcp)
            }
        };
        let proto = proxy.proto.to_lowercase();
        // Trojan and HTTPS proxies always speak TLS, no matter whether the
        // link carried an explicit flag. Only SS/HTTP/SOCKS/VLESS decide by
        // their own security setting.
        let need_tls = proxy.tls
            || matches!(proto.as_str(), "https" | "trojan")
            || (proto == "vless" && proxy.tls);
        if need_tls {
            // SNI drives routing on shared frontends, so prefer the link's
            // advertised name and fall back to the endpoint itself.
            let sni = if !proxy.sni.is_empty() {
                proxy.sni.clone()
            } else {
                proxy.host.clone()
            };
            // A user's own HTTPS proxy is expected to have a valid
            // certificate; free Trojan/VLESS nodes never do, and neither does
            // a bare-IP endpoint, so those skip chain validation.
            let verify = proto == "https" && proxy.host.parse::<IpAddr>().is_err();
            stream = if verify {
                tls::wrap(stream, &sni).await.with_context(|| format!("TLS to {sni}"))?
            } else {
                tls::wrap_insecure(stream, &sni)
                    .await
                    .with_context(|| format!("TLS to {sni}"))?
            };
        }
        match proto.as_str() {
            "socks5" => {
                socks5_handshake(&mut stream, proxy, target, self).await?;
                Ok(stream)
            }
            "socks4" | "socks4a" => {
                socks4_handshake(&mut stream, proxy, target).await?;
                Ok(stream)
            }
            "http" | "https" => {
                http_connect(&mut stream, proxy, target).await?;
                Ok(stream)
            }
            "ss" | "shadowsocks" => {
                let wrapped =
                    crate::ss::wrap(stream, &proxy.password, &proxy.cipher, target).await?;
                Ok(wrapped)
            }
            "trojan" => {
                trojan_handshake(&mut stream, proxy, target).await?;
                Ok(stream)
            }
            "vless" => {
                vless_handshake(&mut stream, proxy, target).await?;
                Ok(stream)
            }
            "vmess" => bail!("VMess не поддерживается этим ядром"),
            "hysteria2" | "hy2" => bail!("Hysteria2 требует QUIC и не поддерживается"),
            other => bail!("неизвестный протокол прокси: {other}"),
        }
    }

    /// HTTP GET through an arbitrary proxy chain.
    pub async fn http_get_via(
        &self,
        chain: &[ProxyConfig],
        url: &str,
        extra_headers: &str,
        max_body: usize,
        timeout: Duration,
    ) -> Result<HttpResponse> {
        let parsed = Url::parse(url).context("bad url")?;
        let host = parsed.host_str().ok_or_else(|| anyhow!("url without host"))?.to_string();
        let port = parsed.port_or_known_default().unwrap_or(443);
        let https = parsed.scheme() == "https";
        let mut path = parsed.path().to_string();
        if path.is_empty() {
            path = "/".to_string();
        }
        if let Some(q) = parsed.query() {
            path.push('?');
            path.push_str(q);
        }
        let host_header = if parsed.port().is_some() {
            format!("{host}:{port}")
        } else {
            host.clone()
        };
        let target = Target::domain(&host, port);
        let fut = async {
            let mut stream = self.dial_chain(chain, &target).await?;
            if https {
                stream = tls::wrap(stream, &host).await?;
            }
            http_get_over(stream, &host_header, &path, extra_headers, max_body).await
        };
        tokio::time::timeout(timeout, fut)
            .await
            .map_err(|_| anyhow!("timeout"))?
    }
}

async fn socks5_handshake(
    stream: &mut BoxStream,
    proxy: &ProxyConfig,
    target: &Target,
    _dialer: &Dialer,
) -> Result<()> {
    let auth = !proxy.username.is_empty() || !proxy.password.is_empty();
    if auth {
        stream.write_all(&[5, 2, 0, 2]).await?;
    } else {
        stream.write_all(&[5, 1, 0]).await?;
    }
    let mut resp = [0u8; 2];
    stream.read_exact(&mut resp).await?;
    if resp[0] != 5 {
        bail!("not a socks5 server");
    }
    if resp[1] == 2 {
        let u = proxy.username.as_bytes();
        let p = proxy.password.as_bytes();
        if u.len() > 255 || p.len() > 255 {
            bail!("socks5 credentials too long");
        }
        let mut req = vec![1, u.len() as u8];
        req.extend_from_slice(u);
        req.push(p.len() as u8);
        req.extend_from_slice(p);
        stream.write_all(&req).await?;
        let mut r = [0u8; 2];
        stream.read_exact(&mut r).await?;
        if r[1] != 0 {
            bail!("socks5 auth rejected");
        }
    } else if resp[1] != 0 {
        bail!("socks5: no acceptable auth method");
    }
    let mut req = vec![5u8, 1, 0];
    match target {
        Target::Domain(h, p) => {
            req.push(3);
            req.push(h.len() as u8);
            req.extend_from_slice(h.as_bytes());
            req.extend_from_slice(&p.to_be_bytes());
        }
        Target::Ip(IpAddr::V4(ip), p) => {
            req.push(1);
            req.extend_from_slice(&ip.octets());
            req.extend_from_slice(&p.to_be_bytes());
        }
        Target::Ip(IpAddr::V6(ip), p) => {
            req.push(4);
            req.extend_from_slice(&ip.octets());
            req.extend_from_slice(&p.to_be_bytes());
        }
    }
    stream.write_all(&req).await?;
    let mut head = [0u8; 4];
    stream.read_exact(&mut head).await?;
    if head[0] != 5 {
        bail!("socks5 bad reply");
    }
    if head[1] != 0 {
        bail!("socks5 connect error code {}", head[1]);
    }
    let consume = match head[3] {
        1 => 4 + 2,
        4 => 16 + 2,
        3 => {
            let mut l = [0u8; 1];
            stream.read_exact(&mut l).await?;
            l[0] as usize + 2
        }
        _ => bail!("socks5 bad address type"),
    };
    let mut skip = vec![0u8; consume];
    stream.read_exact(&mut skip).await?;
    Ok(())
}

async fn socks4_handshake(
    stream: &mut BoxStream,
    proxy: &ProxyConfig,
    target: &Target,
) -> Result<()> {
    let mut req = vec![4u8, 1];
    req.extend_from_slice(&target.port().to_be_bytes());
    match target {
        Target::Ip(IpAddr::V4(ip), _) => {
            req.extend_from_slice(&ip.octets());
            req.extend_from_slice(proxy.username.as_bytes());
            req.push(0);
        }
        _ => {
            req.extend_from_slice(&[0, 0, 0, 1]);
            req.extend_from_slice(proxy.username.as_bytes());
            req.push(0);
            req.extend_from_slice(target.host().as_bytes());
            req.push(0);
        }
    }
    stream.write_all(&req).await?;
    let mut resp = [0u8; 8];
    stream.read_exact(&mut resp).await?;
    if resp[0] != 0 || resp[1] != 90 {
        bail!("socks4 rejected");
    }
    Ok(())
}

async fn http_connect(stream: &mut BoxStream, proxy: &ProxyConfig, target: &Target) -> Result<()> {
    use base64::Engine;
    let mut headers = String::new();
    if !proxy.username.is_empty() || !proxy.password.is_empty() {
        let creds = format!("{}:{}", proxy.username, proxy.password);
        let encoded = base64::engine::general_purpose::STANDARD.encode(creds);
        headers.push_str(&format!("Proxy-Authorization: Basic {encoded}\r\n"));
    }
    let ep = target.display();
    let req = format!(
        "CONNECT {ep} HTTP/1.1\r\nHost: {ep}\r\nProxy-Connection: Keep-Alive\r\n{headers}\r\n"
    );
    stream.write_all(req.as_bytes()).await?;
    let head = read_http_head(stream).await?;
    let status = crate::util::http_status(&head).unwrap_or(0);
    if status != 200 {
        bail!("http proxy CONNECT status {status}");
    }
    Ok(())
}

async fn trojan_handshake(
    stream: &mut BoxStream,
    proxy: &ProxyConfig,
    target: &Target,
) -> Result<()> {
    let mut hasher = Sha224::new();
    hasher.update(proxy.password.as_bytes());
    let pass = hex::encode(hasher.finalize());
    let mut req = Vec::new();
    req.extend_from_slice(pass.as_bytes());
    req.extend_from_slice(b"\r\n");
    req.push(1); // CONNECT
    match target {
        Target::Domain(h, p) => {
            req.push(3);
            req.push(h.len() as u8);
            req.extend_from_slice(h.as_bytes());
            req.extend_from_slice(&p.to_be_bytes());
        }
        Target::Ip(IpAddr::V4(ip), p) => {
            req.push(1);
            req.extend_from_slice(&ip.octets());
            req.extend_from_slice(&p.to_be_bytes());
        }
        Target::Ip(IpAddr::V6(ip), p) => {
            req.push(4);
            req.extend_from_slice(&ip.octets());
            req.extend_from_slice(&p.to_be_bytes());
        }
    }
    req.extend_from_slice(b"\r\n");
    stream.write_all(&req).await?;
    Ok(())
}

async fn vless_handshake(
    stream: &mut BoxStream,
    proxy: &ProxyConfig,
    target: &Target,
) -> Result<()> {
    let uuid = proxy
        .uuid
        .parse::<uuid::Uuid>()
        .map_err(|_| anyhow!("VLESS: некорректный UUID"))?;
    let mut req = Vec::new();
    req.push(0);
    req.extend_from_slice(uuid.as_bytes());
    req.push(0); // no addons
    req.push(1); // TCP
    req.extend_from_slice(&target.port().to_be_bytes());
    match target {
        Target::Domain(h, _) => {
            req.push(2);
            req.push(h.len() as u8);
            req.extend_from_slice(h.as_bytes());
        }
        Target::Ip(IpAddr::V4(ip), _) => {
            req.push(1);
            req.extend_from_slice(&ip.octets());
        }
        Target::Ip(IpAddr::V6(ip), _) => {
            req.push(3);
            req.extend_from_slice(&ip.octets());
        }
    }
    stream.write_all(&req).await?;
    let mut resp = [0u8; 2];
    stream.read_exact(&mut resp).await?;
    if resp[1] != 0 {
        bail!("VLESS rejected the request");
    }
    Ok(())
}

/// Quick TCP reachability test through a chain.
pub async fn tcp_ping(chain: &[ProxyConfig], target: &Target, timeout: Duration) -> Result<u128> {
    let started = std::time::Instant::now();
    let resolver = std::sync::Arc::new(Resolver::new(Default::default()));
    let dialer = Dialer::new(resolver);
    tokio::time::timeout(timeout, dialer.dial_chain(chain, target))
        .await
        .map_err(|_| anyhow!("timeout"))??;
    Ok(started.elapsed().as_millis())
}
