use anyhow::{anyhow, bail, Result};
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};

use crate::tls;
use crate::util::BoxStream;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DnsProtocol {
    Doh,
    Dot,
    Udp,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DnsSettings {
    #[serde(default = "default_proto")]
    pub protocol: DnsProtocol,
    #[serde(default = "default_server")]
    pub server: String,
    #[serde(default)]
    pub leak_protection: bool,
}

fn default_proto() -> DnsProtocol {
    DnsProtocol::Doh
}
fn default_server() -> String {
    "https://cloudflare-dns.com/dns-query".to_string()
}

impl Default for DnsSettings {
    fn default() -> Self {
        Self { protocol: DnsProtocol::Doh, server: default_server(), leak_protection: true }
    }
}

pub struct Resolver {
    settings: Mutex<DnsSettings>,
    cache: Mutex<HashMap<String, (Vec<IpAddr>, Instant)>>,
    client: reqwest::Client,
}

impl Resolver {
    pub fn new(settings: DnsSettings) -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(8))
            .user_agent("RustedProxy/1.0")
            .build()
            .expect("dns client");
        Self { settings: Mutex::new(settings), cache: Mutex::new(HashMap::new()), client }
    }

    pub fn update(&self, settings: DnsSettings) {
        *self.settings.lock().unwrap() = settings;
        self.cache.lock().unwrap().clear();
    }

    pub fn settings(&self) -> DnsSettings {
        self.settings.lock().unwrap().clone()
    }

    pub async fn resolve(&self, host: &str) -> Result<Vec<IpAddr>> {
        if let Ok(ip) = host.parse::<IpAddr>() {
            return Ok(vec![ip]);
        }
        if let Some((ips, at)) = self.cache.lock().unwrap().get(host) {
            if at.elapsed() < Duration::from_secs(300) && !ips.is_empty() {
                return Ok(ips.clone());
            }
        }
        let settings = self.settings();
        let primary = match settings.protocol {
            DnsProtocol::Doh => self.query_doh(host, &settings.server).await,
            DnsProtocol::Dot => self.query_dot(host, &settings.server).await,
            DnsProtocol::Udp => self.query_udp(host, &settings.server).await,
        };
        let ips = match primary {
            Ok(v) if !v.is_empty() => v,
            _ => {
                // Robustness fallback. With leak protection enabled every
                // fallback stays encrypted (DoH); plaintext DNS is only used
                // when the user explicitly opted out of leak protection.
                let mut fallback = self
                    .query_doh(host, "https://cloudflare-dns.com/dns-query")
                    .await
                    .unwrap_or_default();
                if fallback.is_empty() {
                    fallback = self
                        .query_doh(host, "https://dns.google/dns-query")
                        .await
                        .unwrap_or_default();
                }
                if fallback.is_empty() && !settings.leak_protection {
                    fallback = self
                        .query_udp(host, "1.1.1.1")
                        .await
                        .unwrap_or_default();
                }
                fallback
            }
        };
        if ips.is_empty() {
            bail!("DNS: no records for {host}");
        }
        self.cache.lock().unwrap().insert(host.to_string(), (ips.clone(), Instant::now()));
        Ok(ips)
    }

    pub async fn resolve_first(&self, host: &str) -> Result<IpAddr> {
        Ok(*self.resolve(host).await?.first().ok_or_else(|| anyhow!("no address"))?)
    }

    /// Resolves using exactly the configured transport, without any fallback.
    /// The settings screen uses this to prove that the chosen DNS works.
    pub async fn resolve_strict(&self, host: &str) -> Result<Vec<IpAddr>> {
        if let Ok(ip) = host.parse::<IpAddr>() {
            return Ok(vec![ip]);
        }
        let settings = self.settings();
        let ips = match settings.protocol {
            DnsProtocol::Doh => self.query_doh(host, &settings.server).await?,
            DnsProtocol::Dot => self.query_dot(host, &settings.server).await?,
            DnsProtocol::Udp => self.query_udp(host, &settings.server).await?,
        };
        if ips.is_empty() {
            bail!("DNS: no records for {host}");
        }
        Ok(ips)
    }

    async fn query_doh(&self, host: &str, server: &str) -> Result<Vec<IpAddr>> {
        let url = normalize_doh_url(server);
        let q = build_query(host, 1)?;
        let resp = self
            .client
            .post(&url)
            .header("content-type", "application/dns-message")
            .header("accept", "application/dns-message")
            .body(q)
            .send()
            .await?;
        if !resp.status().is_success() {
            bail!("DoH status {}", resp.status());
        }
        let body = resp.bytes().await?;
        let mut ips = parse_answers(&body)?;
        if ips.is_empty() {
            let q = build_query(host, 28)?;
            if let Ok(resp) = self
                .client
                .post(&url)
                .header("content-type", "application/dns-message")
                .body(q)
                .send()
                .await
            {
                if let Ok(body) = resp.bytes().await {
                    ips = parse_answers(&body).unwrap_or_default();
                }
            }
        }
        Ok(ips)
    }

    async fn query_dot(&self, host: &str, server: &str) -> Result<Vec<IpAddr>> {
        let target = server
            .trim_start_matches("tls://")
            .trim_start_matches("dot://")
            .trim_end_matches('/');
        let addr = if target.contains(':') {
            target.to_string()
        } else {
            format!("{target}:853")
        };
        let tcp = tokio::time::timeout(Duration::from_secs(6), TcpStream::connect(&addr)).await??;
        tcp.set_nodelay(true).ok();
        let stream: BoxStream = Box::new(tcp);
        let mut tls_stream = tls::wrap_dns(stream, target.split(':').next().unwrap_or(target)).await?;
        let q = build_query(host, 1)?;
        let mut framed = Vec::with_capacity(q.len() + 2);
        framed.extend_from_slice(&(q.len() as u16).to_be_bytes());
        framed.extend_from_slice(&q);
        tls_stream.write_all(&framed).await?;
        tls_stream.flush().await?;
        let mut len = [0u8; 2];
        tls_stream.read_exact(&mut len).await?;
        let n = u16::from_be_bytes(len) as usize;
        let mut body = vec![0u8; n];
        tls_stream.read_exact(&mut body).await?;
        parse_answers(&body)
    }

    async fn query_udp(&self, host: &str, server: &str) -> Result<Vec<IpAddr>> {
        let host_part = server
            .trim_start_matches("udp://")
            .split('/')
            .next()
            .unwrap_or(server);
        let addr = if host_part.contains(':') {
            host_part.to_string()
        } else {
            format!("{host_part}:53")
        };
        let sock = UdpSocket::bind("0.0.0.0:0").await?;
        sock.connect(&addr).await?;
        let q = build_query(host, 1)?;
        sock.send(&q).await?;
        let mut buf = vec![0u8; 4096];
        let n = tokio::time::timeout(Duration::from_secs(4), sock.recv(&mut buf)).await??;
        parse_answers(&buf[..n])
    }
}

fn normalize_doh_url(server: &str) -> String {
    let s = server.trim();
    if s.starts_with("http://") || s.starts_with("https://") {
        s.to_string()
    } else if s == "1.1.1.1" || s == "1.0.0.1" {
        "https://cloudflare-dns.com/dns-query".to_string()
    } else if s == "8.8.8.8" || s == "8.8.4.4" {
        "https://dns.google/dns-query".to_string()
    } else if s == "9.9.9.9" {
        "https://dns.quad9.net/dns-query".to_string()
    } else {
        format!("https://{s}/dns-query")
    }
}

fn encode_name(name: &str, out: &mut Vec<u8>) -> Result<()> {
    for label in name.trim_end_matches('.').split('.') {
        if label.len() > 63 || label.is_empty() {
            bail!("invalid dns name");
        }
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0);
    Ok(())
}

pub fn build_query(name: &str, qtype: u16) -> Result<Vec<u8>> {
    let id: u16 = rand::thread_rng().gen();
    let mut out = Vec::with_capacity(64);
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&0x0100u16.to_be_bytes()); // RD
    out.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT
    out.extend_from_slice(&0u16.to_be_bytes());
    out.extend_from_slice(&0u16.to_be_bytes());
    out.extend_from_slice(&0u16.to_be_bytes());
    encode_name(name, &mut out)?;
    out.extend_from_slice(&qtype.to_be_bytes());
    out.extend_from_slice(&1u16.to_be_bytes());
    Ok(out)
}

pub fn parse_answers(data: &[u8]) -> Result<Vec<IpAddr>> {
    if data.len() < 12 {
        bail!("short dns response");
    }
    let rcode = data[3] & 0x0F;
    if rcode != 0 {
        bail!("dns rcode {rcode}");
    }
    let ancount = u16::from_be_bytes([data[6], data[7]]) as usize;
    let qdcount = u16::from_be_bytes([data[4], data[5]]) as usize;
    let mut pos = 12usize;
    for _ in 0..qdcount {
        pos = skip_name(data, pos)?;
        pos += 4;
    }
    let mut out = Vec::new();
    for _ in 0..ancount {
        pos = skip_name(data, pos)?;
        if pos + 10 > data.len() {
            break;
        }
        let rtype = u16::from_be_bytes([data[pos], data[pos + 1]]);
        let rdlen = u16::from_be_bytes([data[pos + 8], data[pos + 9]]) as usize;
        pos += 10;
        if pos + rdlen > data.len() {
            break;
        }
        match rtype {
            1 if rdlen == 4 => {
                out.push(IpAddr::V4(Ipv4Addr::new(data[pos], data[pos + 1], data[pos + 2], data[pos + 3])))
            }
            28 if rdlen == 16 => {
                let mut b = [0u8; 16];
                b.copy_from_slice(&data[pos..pos + 16]);
                out.push(IpAddr::V6(Ipv6Addr::from(b)));
            }
            _ => {}
        }
        pos += rdlen;
    }
    Ok(out)
}

fn skip_name(data: &[u8], mut pos: usize) -> Result<usize> {
    loop {
        if pos >= data.len() {
            bail!("bad dns name");
        }
        let len = data[pos];
        if len == 0 {
            return Ok(pos + 1);
        }
        if len & 0xC0 == 0xC0 {
            return Ok(pos + 2);
        }
        pos += 1 + len as usize;
    }
}

pub fn parse_server_ip(server: &str) -> Option<SocketAddr> {
    let cleaned = server
        .trim_start_matches("udp://")
        .trim_start_matches("tls://")
        .trim_start_matches("https://")
        .split('/')
        .next()?;
    if let Ok(sa) = cleaned.parse::<SocketAddr>() {
        return Some(sa);
    }
    if let Ok(ip) = cleaned.parse::<IpAddr>() {
        return Some(SocketAddr::new(ip, 53));
    }
    None
}
