use anyhow::{anyhow, bail, Context, Result};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::watch;

use crate::dns::{DnsProtocol, DnsSettings, Resolver};
use crate::geo::{self, GeoInfo};
use crate::logbuf::LogBuffer;
use crate::proxy::{Dialer, ProxyConfig};
use crate::util::{is_private_ip, now_ms, BoxStream, Target};

pub static ADBLOCK: Lazy<HashSet<String>> = Lazy::new(|| load_domains(include_str!("../assets/adblock.txt")));
pub static BYPASS_RU: Lazy<HashSet<String>> = Lazy::new(|| load_domains(include_str!("../assets/bypass_ru.txt")));

fn load_domains(text: &str) -> HashSet<String> {
    let mut out = HashSet::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with('!') {
            continue;
        }
        let mut d = line.to_lowercase();
        if let Some(rest) = d.strip_prefix("*.") {
            d = rest.to_string();
        }
        if let Some(rest) = d.strip_prefix('.') {
            d = rest.to_string();
        }
        if let Some((d, _)) = d.split_once(' ') {
            d.to_string();
        }
        if d.len() > 2 && d.contains('.') && !d.contains('/') {
            out.insert(d);
        }
    }
    out
}

fn suffix_match(host: &str, set: &HashSet<String>) -> bool {
    let host = host.trim_end_matches('.').to_lowercase();
    if set.contains(&host) {
        return true;
    }
    let mut rest = host.as_str();
    while let Some(pos) = rest.find('.') {
        rest = &rest[pos + 1..];
        if rest.is_empty() {
            break;
        }
        if set.contains(rest) {
            return true;
        }
    }
    false
}

const PROXY_DOMAINS: &[&str] = &[
    "youtube.com", "youtu.be", "googlevideo.com", "ytimg.com", "ggpht.com", "youtube-nocookie.com",
    "discord.com", "discordapp.com", "discord.gg", "discord.media", "discordstatus.com",
    "instagram.com", "cdninstagram.com", "facebook.com", "fbcdn.net", "fb.com", "messenger.com",
    "x.com", "twitter.com", "twimg.com", "t.co",
    "tiktok.com", "tiktokcdn.com", "musical.ly",
    "netflix.com", "nflxvideo.net", "nflximg.net", "nflxext.com",
    "spotify.com", "scdn.co", "spotifycdn.com",
    "twitch.tv", "ttvnw.net", "jtvnw.net",
    "telegram.org", "t.me", "telegram.me", "tdesktop.com",
    "signal.org", "whatsapp.com", "whatsapp.net",
    "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "anthropic.com", "claude.ai",
    "reddit.com", "redd.it", "redditmedia.com", "redditstatic.com",
    "medium.com", "notion.so", "notion.site", "figma.com", "behance.net", "dribbble.com",
    "patreon.com", "soundcloud.com", "bandcamp.com", "vimeo.com", "dailymotion.com",
    "bbc.com", "bbc.co.uk", "cnn.com", "nytimes.com", "washingtonpost.com", "theguardian.com",
    "wikipedia.org", "wikimedia.org", "archive.org",
    "github.com", "githubusercontent.com", "githubassets.com", "gitlab.com",
    "docker.com", "docker.io", "npmjs.com", "pub.dev", "pypi.org", "crates.io",
    "steampowered.com", "steamstatic.com", "steamcommunity.com", "epicgames.com",
    "roblox.com", "rbxcdn.com", "minecraft.net",
];

pub fn is_blocked_service(host: &str) -> bool {
    let h = host.to_lowercase();
    PROXY_DOMAINS.iter().any(|d| h == *d || h.ends_with(&format!(".{d}")))
}

pub fn is_russian(host: &str) -> bool {
    let h = host.to_lowercase();
    if h.ends_with(".ru") || h.ends_with(".su") || h.ends_with(".рф") || h.ends_with(".by") || h.ends_with(".kz") {
        return true;
    }
    suffix_match(&h, &BYPASS_RU)
}

pub fn is_ad(host: &str) -> bool {
    suffix_match(host, &ADBLOCK)
}

fn domain_list_match(host: &str, domains: &[String]) -> bool {
    let h = host.trim_end_matches('.').to_lowercase();
    domains.iter().any(|raw| {
        let d = raw
            .trim()
            .trim_start_matches("*.")
            .trim_start_matches('.')
            .to_lowercase();
        !d.is_empty() && (h == d || h.ends_with(&format!(".{d}")))
    })
}

/// Modes are intentionally simple for the user:
/// * `full`  — "Полная работа": smart routing, RU bypass, DNS/DPI/adblock.
/// * `proxy` — "Только прокси": everything through the active proxy.
/// Legacy values (`smart`, `antidpi`, `vpn`) keep working after upgrades.
fn mode_proxy_all(mode: &str) -> bool {
    matches!(mode, "proxy" | "vpn")
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EngineSettings {
    #[serde(default = "d_mode")]
    pub mode: String,
    #[serde(default)]
    pub bypass_ru: bool,
    #[serde(default)]
    pub bypass_all: bool,
    #[serde(default)]
    pub bypass_domains: Vec<String>,
    #[serde(default)]
    pub lan_bypass: bool,
    #[serde(default)]
    pub adblock: bool,
    #[serde(default)]
    pub block_quic: bool,
    #[serde(default)]
    pub disable_ipv6: bool,
    #[serde(default)]
    pub dpi_bypass: bool,
    #[serde(default = "d_dpi_method")]
    pub dpi_method: String,
    #[serde(default = "d_frag")]
    pub frag_size: usize,
    #[serde(default)]
    pub kill_switch: bool,
    #[serde(default)]
    pub block_unencrypted: bool,
    #[serde(default)]
    pub auto_failover: bool,
    #[serde(default)]
    pub rotation_secs: u64,
    #[serde(default)]
    pub dns: DnsSettings,
    #[serde(default = "d_check_url")]
    pub check_url: String,
    #[serde(default = "d_mtu")]
    pub mtu: u16,
    #[serde(default)]
    pub udp_over_tcp: bool,
    #[serde(default)]
    pub ipv6_enabled: bool,
}

fn d_mode() -> String {
    "smart".into()
}
fn d_dpi_method() -> String {
    "split".into()
}
fn d_frag() -> usize {
    40
}
fn d_check_url() -> String {
    "https://cp.cloudflare.com/generate_204".into()
}
fn d_mtu() -> u16 {
    1400
}

impl Default for EngineSettings {
    fn default() -> Self {
        Self {
            mode: d_mode(),
            bypass_ru: true,
            bypass_all: false,
            bypass_domains: Vec::new(),
            lan_bypass: true,
            adblock: true,
            block_quic: true,
            disable_ipv6: true,
            dpi_bypass: true,
            dpi_method: d_dpi_method(),
            frag_size: 40,
            kill_switch: true,
            block_unencrypted: true,
            auto_failover: true,
            rotation_secs: 0,
            dns: DnsSettings::default(),
            check_url: d_check_url(),
            mtu: 1400,
            udp_over_tcp: false,
            ipv6_enabled: false,
        }
    }
}

#[derive(Deserialize)]
pub struct EngineConfig {
    #[serde(default = "d_port")]
    pub listen_port: u16,
    #[serde(default)]
    pub proxies: Vec<ProxyConfig>,
    #[serde(default)]
    pub chain: Vec<ProxyConfig>,
    #[serde(default)]
    pub settings: EngineSettings,
}

fn d_port() -> u16 {
    10808
}

#[derive(Default)]
pub struct Stats {
    pub up: AtomicU64,
    pub down: AtomicU64,
    pub conns: AtomicU32,
    pub total: AtomicU64,
}

pub struct Engine {
    pub running: AtomicBool,
    pub port: AtomicU16,
    pub settings: Mutex<EngineSettings>,
    pub chain: Mutex<Vec<ProxyConfig>>,
    pub pool: Mutex<Vec<ProxyConfig>>,
    pub resolver: Mutex<Option<Arc<Resolver>>>,
    pub dialer: Mutex<Option<Arc<Dialer>>>,
    pub stats: Stats,
    pub logs: LogBuffer,
    pub stop: Mutex<Option<watch::Sender<bool>>>,
    pub started_at: Mutex<Option<Instant>>,
    pub real_ip: Mutex<String>,
    pub exit_ip: Mutex<String>,
    pub exit_geo: Mutex<GeoInfo>,
    pub route_name: Mutex<String>,
    pub tun_running: AtomicBool,
}

pub static ENGINE: Lazy<Engine> = Lazy::new(|| Engine {
    running: AtomicBool::new(false),
    port: AtomicU16::new(0),
    settings: Mutex::new(EngineSettings::default()),
    chain: Mutex::new(Vec::new()),
    pool: Mutex::new(Vec::new()),
    resolver: Mutex::new(None),
    dialer: Mutex::new(None),
    stats: Stats::default(),
    logs: LogBuffer::new(800),
    stop: Mutex::new(None),
    started_at: Mutex::new(None),
    real_ip: Mutex::new(String::new()),
    exit_ip: Mutex::new(String::new()),
    exit_geo: Mutex::new(GeoInfo::default()),
    route_name: Mutex::new(String::new()),
    tun_running: AtomicBool::new(false),
});

impl Engine {
    pub fn log(&self, level: &str, msg: impl Into<String>) {
        self.logs.push(level, msg);
    }

    pub fn dialer(&self) -> Arc<Dialer> {
        self.dialer
            .lock()
            .unwrap()
            .clone()
            .unwrap_or_else(|| Arc::new(Dialer::new(Arc::new(Resolver::new(Default::default())))))
    }

    pub fn resolver(&self) -> Arc<Resolver> {
        self.resolver
            .lock()
            .unwrap()
            .clone()
            .unwrap_or_else(|| Arc::new(Resolver::new(Default::default())))
    }

    pub fn settings(&self) -> EngineSettings {
        self.settings.lock().unwrap().clone()
    }

    pub fn active_chain(&self) -> Vec<ProxyConfig> {
        self.chain.lock().unwrap().clone()
    }

    pub fn set_active(&self, proxy: ProxyConfig) {
        let mut chain = self.chain.lock().unwrap();
        if let Some(last) = chain.last_mut() {
            *last = proxy.clone();
        } else {
            chain.push(proxy.clone());
        }
        *self.route_name.lock().unwrap() = proxy.name.clone();
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }

    pub fn log_json(&self, level: &str, msg: impl Into<String>) {
        self.log(level, msg);
    }
}

fn route_label(proxy: Option<&ProxyConfig>, chained: bool) -> String {
    match proxy {
        Some(p) if !p.name.is_empty() => {
            if chained {
                format!("{} (multi-hop)", p.name)
            } else {
                p.name.clone()
            }
        }
        Some(p) => p.endpoint(),
        None => "DIRECT".into(),
    }
}

fn decide_route(settings: &EngineSettings, chain: &[ProxyConfig], host: Option<&str>, ip: Option<IpAddr>) -> &'static str {
    let host_lc = host.map(|h| h.trim_end_matches('.').to_lowercase());
    let host = host_lc.as_deref();

    if let Some(h) = host {
        if h == "localhost" || h.ends_with(".local") || h.ends_with(".lan") {
            return "direct";
        }
        if settings.adblock && is_ad(h) {
            return "block";
        }
    }
    if let Some(ip) = ip {
        if is_private_ip(ip) && settings.lan_bypass {
            return "direct";
        }
    }

    // "Только прокси" (and the legacy "vpn") sends everything through the
    // active proxy. "Полная работа" proxies the blocked-service list, every
    // explicitly selected domain, and — while "Обход блокировок РФ" is on —
    // any non-Russian host, so censorship is bypassed for every app and site
    // without having to maintain a complete list of blocked domains.
    let proxy_all = mode_proxy_all(&settings.mode);
    let matches_service = host
        .map(|h| {
            (settings.bypass_ru && is_blocked_service(h))
                || domain_list_match(h, &settings.bypass_domains)
        })
        .unwrap_or(false);
    let foreign = settings.bypass_ru
        && host.map(|h| !is_russian(h)).unwrap_or(false);
    let need_proxy = proxy_all || settings.bypass_all || matches_service || foreign;

    if !need_proxy {
        return "direct";
    }
    if chain.is_empty() {
        if proxy_all && settings.kill_switch {
            return "block";
        }
        return "direct";
    }
    if settings.block_unencrypted && chain.last().map(|p| !p.is_encrypted()).unwrap_or(false) {
        return "block";
    }
    "proxy"
}

async fn direct_connect(engine: &Engine, target: &Target, settings: &EngineSettings) -> Result<BoxStream> {
    let dialer = engine.dialer();
    // With IPv6 disabled prefer an IPv4 address instead of letting the OS
    // pick a AAAA record that the upstream cannot reach.
    if settings.disable_ipv6 {
        if let Target::Domain(host, port) = target {
            if let Ok(ips) = dialer.resolver.resolve(host).await {
                if let Some(ip) = ips.into_iter().find(|ip| ip.is_ipv4()) {
                    return dialer.connect_direct(&Target::Ip(ip, *port)).await;
                }
            }
        }
    }
    dialer.connect_direct(target).await
}

async fn open_route(
    engine: &Engine,
    target: &Target,
    host_for_rules: Option<&str>,
) -> Result<(BoxStream, &'static str)> {
    let settings = engine.settings();
    let chain = engine.active_chain();
    let ip = match target {
        Target::Ip(ip, _) => Some(*ip),
        _ => None,
    };
    let route = decide_route(&settings, &chain, host_for_rules, ip);
    match route {
        "block" => bail!("blocked by routing rules"),
        "direct" => Ok((direct_connect(engine, target, &settings).await?, "direct")),
        _ => {
            let dialer = engine.dialer();
            match dialer.dial_chain(&chain, target).await {
                Ok(stream) => Ok((stream, "proxy")),
                Err(err) => {
                    // Automatic failover: a dead node in the chain should not
                    // take the whole tunnel down while a healthy saved node
                    // exists. The new node becomes the active route.
                    if !settings.auto_failover {
                        return Err(err);
                    }
                    let pool = engine.pool.lock().unwrap().clone();
                    for candidate in pool {
                        let already = chain.iter().any(|p| p.id == candidate.id);
                        if already {
                            continue;
                        }
                        if let Ok(stream) =
                            dialer.dial_chain(std::slice::from_ref(&candidate), target).await
                        {
                            engine.log(
                                "INFO",
                                format!(
                                    "failover → {}",
                                    if candidate.name.is_empty() {
                                        candidate.endpoint()
                                    } else {
                                        candidate.name.clone()
                                    }
                                ),
                            );
                            engine.set_active(candidate);
                            return Ok((stream, "proxy"));
                        }
                    }
                    Err(err)
                }
            }
        }
    }
}

struct ConnGuard;

impl ConnGuard {
    fn new(engine: &'static Engine) -> Self {
        engine.stats.conns.fetch_add(1, Ordering::SeqCst);
        engine.stats.total.fetch_add(1, Ordering::SeqCst);
        Self
    }
}

impl Drop for ConnGuard {
    fn drop(&mut self) {
        ENGINE.stats.conns.fetch_sub(1, Ordering::SeqCst);
    }
}

pub async fn accept_loop(engine: &'static Engine, listener: TcpListener, mut stop: watch::Receiver<bool>) {
    loop {
        tokio::select! {
            _ = stop.changed() => {
                if *stop.borrow() { break; }
            }
            accepted = listener.accept() => {
                match accepted {
                    Ok((sock, peer)) => {
                        let _ = sock.set_nodelay(true);
                        tokio::spawn(async move {
                            if let Err(e) = handle_client(engine, sock, peer).await {
                                let msg = e.to_string();
                                if !msg.contains("blocked by routing") {
                                    engine.log("WARN", format!("{peer} · {msg}"));
                                }
                            }
                        });
                    }
                    Err(e) => {
                        engine.log("WARN", format!("accept: {e}"));
                        tokio::time::sleep(Duration::from_millis(200)).await;
                    }
                }
            }
        }
    }
    engine.log("INFO", "SOCKS5/HTTP listener stopped");
}

async fn handle_client(engine: &'static Engine, sock: TcpStream, peer: SocketAddr) -> Result<()> {
    let mut first = [0u8; 1];
    let n = tokio::time::timeout(Duration::from_secs(20), sock.peek(&mut first)).await??;
    if n == 0 {
        return Ok(());
    }
    if first[0] == 0x05 {
        handle_socks5(engine, sock, peer).await
    } else {
        handle_http(engine, sock, peer).await
    }
}

async fn handle_socks5(engine: &'static Engine, mut sock: TcpStream, peer: SocketAddr) -> Result<()> {
    let mut head = [0u8; 2];
    sock.read_exact(&mut head).await?;
    if head[0] != 5 {
        bail!("bad socks version");
    }
    let mut methods = vec![0u8; head[1] as usize];
    sock.read_exact(&mut methods).await?;
    if !methods.contains(&0) {
        sock.write_all(&[5, 0xFF]).await?;
        bail!("socks5: no supported auth method");
    }
    sock.write_all(&[5, 0]).await?;
    let mut req = [0u8; 4];
    sock.read_exact(&mut req).await?;
    if req[0] != 5 {
        bail!("bad socks request");
    }
    let cmd = req[1];
    let target = read_socks_target(&mut sock, req[3]).await?;
    match cmd {
        1 => {
            let _guard = ConnGuard::new(engine);
            let host = match &target {
                Target::Domain(h, _) => Some(h.as_str()),
                _ => None,
            };
            let (remote, route) = match open_route(engine, &target, host).await {
                Ok(v) => v,
                Err(e) => {
                    let code = if e.to_string().contains("blocked") { 2 } else { 5 };
                    let _ = sock.write_all(&[5, code, 0, 1, 0, 0, 0, 0, 0, 0]).await;
                    engine.log("BLOCK", format!("{peer} → {} · {e}", target.display()));
                    return Err(e);
                }
            };
            sock.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            let proxy = engine.active_chain().last().cloned();
            let chained = engine.active_chain().len() > 1;
            engine.log(
                if route == "proxy" { "PROXY" } else { "DIRECT" },
                format!("TCP {} → {}", target.display(), route_label(proxy.as_ref(), chained)),
            );
            let dpi = dpi_plan(engine, route);
            relay(engine, sock, remote, dpi).await;
            Ok(())
        }
        3 => handle_socks5_udp(engine, sock, peer).await,
        _ => {
            sock.write_all(&[5, 7, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            bail!("socks5: unsupported command {cmd}");
        }
    }
}

async fn read_socks_target(sock: &mut TcpStream, atyp: u8) -> Result<Target> {
    match atyp {
        1 => {
            let mut a = [0u8; 4];
            sock.read_exact(&mut a).await?;
            let port = read_port(sock).await?;
            Ok(Target::Ip(IpAddr::V4(Ipv4Addr::from(a)), port))
        }
        4 => {
            let mut a = [0u8; 16];
            sock.read_exact(&mut a).await?;
            let port = read_port(sock).await?;
            Ok(Target::Ip(IpAddr::V6(a.into()), port))
        }
        3 => {
            let mut len = [0u8; 1];
            sock.read_exact(&mut len).await?;
            let mut name = vec![0u8; len[0] as usize];
            sock.read_exact(&mut name).await?;
            let port = read_port(sock).await?;
            Ok(Target::Domain(String::from_utf8(name)?, port))
        }
        _ => bail!("socks5: bad address type"),
    }
}

async fn read_port(sock: &mut TcpStream) -> Result<u16> {
    let mut b = [0u8; 2];
    sock.read_exact(&mut b).await?;
    Ok(u16::from_be_bytes(b))
}

async fn handle_socks5_udp(engine: &'static Engine, mut control: TcpStream, peer: SocketAddr) -> Result<()> {
    let udp = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
    let local = udp.local_addr()?;
    let mut reply = vec![5u8, 0, 0, 1];
    reply.extend_from_slice(&[127, 0, 0, 1]);
    reply.extend_from_slice(&local.port().to_be_bytes());
    control.write_all(&reply).await?;
    let _ = &peer;
    engine.log("INFO", format!("UDP relay on 127.0.0.1:{}", local.port()));
    let client_addr: Arc<Mutex<Option<SocketAddr>>> = Arc::new(Mutex::new(None));
    let sessions: Arc<Mutex<HashMap<String, tokio::sync::mpsc::Sender<Vec<u8>>>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let mut buf = vec![0u8; 65535];
    let mut control_buf = [0u8; 1];
    loop {
        let (n, src) = tokio::select! {
            r = udp.recv_from(&mut buf) => r?,
            _ = control.read(&mut control_buf) => break,
        };
        {
            let mut known = client_addr.lock().unwrap();
            if known.is_none() {
                *known = Some(src);
            }
            if Some(src) != *known {
                continue; // responses are delivered by per-destination tasks
            }
        }
        if n < 4 {
            continue;
        }
        // RSV(2) FRAG(1) ATYP ADDR PORT DATA
        if buf[2] != 0 {
            continue;
        }
        let atyp = buf[3];
        let mut pos = 4usize;
        let target = match atyp {
            1 => {
                if n < pos + 4 + 2 { continue; }
                let ip = Ipv4Addr::new(buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]);
                pos += 4;
                let port = u16::from_be_bytes([buf[pos], buf[pos + 1]]);
                pos += 2;
                Target::Ip(IpAddr::V4(ip), port)
            }
            4 => {
                if n < pos + 16 + 2 { continue; }
                let mut a = [0u8; 16];
                a.copy_from_slice(&buf[pos..pos + 16]);
                pos += 16;
                let port = u16::from_be_bytes([buf[pos], buf[pos + 1]]);
                pos += 2;
                Target::Ip(IpAddr::V6(a.into()), port)
            }
            3 => {
                if n < pos + 1 { continue; }
                let l = buf[pos] as usize;
                pos += 1;
                if n < pos + l + 2 { continue; }
                let host = String::from_utf8_lossy(&buf[pos..pos + l]).to_string();
                pos += l;
                let port = u16::from_be_bytes([buf[pos], buf[pos + 1]]);
                pos += 2;
                Target::Domain(host, port)
            }
            _ => continue,
        };
        let payload = buf[pos..n].to_vec();
        let key = target.display();
        if engine.settings().block_quic && target.port() == 443 {
            engine.log("BLOCK", format!("QUIC UDP {key} (block QUIC)"));
            continue;
        }
        if let Some(host) = match &target { Target::Domain(h, _) => Some(h.clone()), _ => None } {
            if engine.settings().adblock && is_ad(&host) {
                engine.log("BLOCK", format!("UDP {key} (adblock)"));
                continue;
            }
        }
        let sender = {
            let mut map = sessions.lock().unwrap();
            match map.get(&key) {
                Some(tx) if !tx.is_closed() => Some(tx.clone()),
                _ => {
                    let (tx, rx) = tokio::sync::mpsc::channel::<Vec<u8>>(256);
                    map.insert(key.clone(), tx.clone());
                    let udp_out = udp.clone();
                    let client_addr = client_addr.clone();
                    let target2 = target.clone();
                    let key2 = key.clone();
                    let map2 = sessions.clone();
                    tokio::spawn(async move {
                        let _ = udp_session(udp_out, client_addr, target2, rx).await;
                        map2.lock().unwrap().remove(&key2);
                    });
                    Some(tx)
                }
            }
        };
        if let Some(tx) = sender {
            if tx.send(payload).await.is_err() {
                engine.log("WARN", format!("UDP session closed: {key}"));
            }
        }
    }
    Ok(())
}

async fn udp_session(
    client_udp: Arc<UdpSocket>,
    client_addr: Arc<Mutex<Option<SocketAddr>>>,
    target: Target,
    mut rx: tokio::sync::mpsc::Receiver<Vec<u8>>,
) -> Result<()> {
    let engine: &'static Engine = &ENGINE;
    let settings = engine.settings();
    let remote = match &target {
        Target::Ip(ip, port) => SocketAddr::new(*ip, *port),
        Target::Domain(h, port) => {
            let ip = engine.resolver().resolve_first(h).await?;
            SocketAddr::new(ip, *port)
        }
    };
    if remote.ip().is_ipv6() && !settings.ipv6_enabled {
        bail!("ipv6 disabled");
    }
    let sock = UdpSocket::bind(if remote.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" }).await?;
    sock.connect(remote).await?;
    let target_display = target.display();
    let mut buf = vec![0u8; 65535];
    let mut idle = tokio::time::interval(Duration::from_secs(30));
    idle.tick().await;
    loop {
        tokio::select! {
            data = rx.recv() => {
                match data {
                    Some(bytes) => {
                        sock.send(&bytes).await?;
                        engine.stats.up.fetch_add(bytes.len() as u64, Ordering::Relaxed);
                    }
                    None => break,
                }
            }
            n = sock.recv(&mut buf) => {
                let n = n?;
                let addr = client_addr.lock().unwrap().ok_or_else(|| anyhow!("no udp client"))?;
                let mut pkt = vec![0u8, 0, 0];
                match &target {
                    Target::Ip(IpAddr::V4(ip), port) => {
                        pkt[3] = 1;
                        pkt.extend_from_slice(&ip.octets());
                        pkt.extend_from_slice(&port.to_be_bytes());
                    }
                    Target::Ip(IpAddr::V6(ip), port) => {
                        pkt[3] = 4;
                        pkt.extend_from_slice(&ip.octets());
                        pkt.extend_from_slice(&port.to_be_bytes());
                    }
                    Target::Domain(h, port) => {
                        pkt[3] = 3;
                        pkt.push(h.len() as u8);
                        pkt.extend_from_slice(h.as_bytes());
                        pkt.extend_from_slice(&port.to_be_bytes());
                    }
                }
                pkt.extend_from_slice(&buf[..n]);
                client_udp.send_to(&pkt, addr).await?;
                engine.stats.down.fetch_add(n as u64, Ordering::Relaxed);
            }
            _ = idle.tick() => {
                engine.log("INFO", format!("UDP session idle: {target_display}"));
                break;
            }
        }
    }
    Ok(())
}

async fn handle_http(engine: &'static Engine, mut sock: TcpStream, peer: SocketAddr) -> Result<()> {
    let mut buf = Vec::with_capacity(2048);
    let mut tmp = [0u8; 1024];
    let header_end;
    loop {
        let n = tokio::time::timeout(Duration::from_secs(15), sock.read(&mut tmp)).await??;
        if n == 0 {
            bail!("http client closed");
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            header_end = pos + 4;
            break;
        }
        if buf.len() > 65536 {
            bail!("http header too large");
        }
    }
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut lines = head.lines();
    let request_line = lines.next().unwrap_or_default().to_string();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let uri = parts.next().unwrap_or("");
    if method.is_empty() || uri.is_empty() {
        let _ = sock.write_all(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n").await;
        bail!("bad http request");
    }
    if method.eq_ignore_ascii_case("CONNECT") {
        let (host, port) = crate::util::split_host_port(uri)?;
        let target = Target::domain(&host, port);
        let _guard = ConnGuard::new(engine);
        let (remote, route) = match open_route(engine, &target, Some(&host)).await {
            Ok(v) => v,
            Err(e) => {
                let status = if e.to_string().contains("blocked") { "403 Forbidden" } else { "502 Bad Gateway" };
                let _ = sock
                    .write_all(format!("HTTP/1.1 {status}\r\nConnection: close\r\n\r\n").as_bytes())
                    .await;
                engine.log("BLOCK", format!("CONNECT {host}:{port} · {e}"));
                return Err(e);
            }
        };
        sock.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n").await?;
        let proxy = engine.active_chain().last().cloned();
        let chained = engine.active_chain().len() > 1;
        engine.log(
            if route == "proxy" { "PROXY" } else { "DIRECT" },
            format!("CONNECT {host}:{port} → {}", route_label(proxy.as_ref(), chained)),
        );
        let dpi = dpi_plan(engine, route);
        relay(engine, sock, remote, dpi).await;
        return Ok(());
    }
    // Plain HTTP proxying (absolute-URI form).
    let parsed = url::Url::parse(uri)?;
    let host = parsed.host_str().ok_or_else(|| anyhow!("no host"))?.to_string();
    let port = parsed.port_or_known_default().unwrap_or(80);
    let mut path = parsed.path().to_string();
    if path.is_empty() {
        path = "/".into();
    }
    if let Some(q) = parsed.query() {
        path.push('?');
        path.push_str(q);
    }
    let target = Target::domain(&host, port);
    let _guard = ConnGuard::new(engine);
    let (mut remote, route) = open_route(engine, &target, Some(&host)).await?;
    let mut out = format!("{method} {path} HTTP/1.1\r\n");
    for line in lines {
        if line.to_lowercase().starts_with("proxy-connection") || line.is_empty() {
            continue;
        }
        out.push_str(line);
        out.push_str("\r\n");
    }
    out.push_str("\r\n");
    remote.write_all(out.as_bytes()).await?;
    if buf.len() > header_end {
        remote.write_all(&buf[header_end..]).await?;
    }
    engine.log(
        if route == "proxy" { "PROXY" } else { "DIRECT" },
        format!("HTTP {host}{path}"),
    );
    let dpi = dpi_plan(engine, route);
    relay(engine, sock, remote, dpi).await;
    let _ = peer;
    Ok(())
}

fn is_tls_hello(buf: &[u8]) -> bool {
    buf.len() > 3 && buf[0] == 0x16 && buf[1] == 0x03
}

/// Byte offset of the SNI host name inside a TLS ClientHello, relative to the
/// start of the record. Used by the "sni" DPI strategy so the host name never
/// travels in the same TCP segment as the record header.
fn sni_offset(buf: &[u8]) -> Option<usize> {
    if buf.len() < 45 || buf[0] != 0x16 || buf[5] != 0x01 {
        return None;
    }
    let mut p = 9 + 2 + 32; // TLS version + random
    let sid = *buf.get(p)? as usize;
    p = p.checked_add(1 + sid)?;
    let suites = u16::from_be_bytes([*buf.get(p)?, *buf.get(p + 1)?]) as usize;
    p = p.checked_add(2 + suites)?;
    let comp = *buf.get(p)? as usize;
    p = p.checked_add(1 + comp)?;
    let ext_len = u16::from_be_bytes([*buf.get(p)?, *buf.get(p + 1)?]) as usize;
    p = p.checked_add(2)?;
    let end = p.saturating_add(ext_len).min(buf.len());
    while p + 4 <= end {
        let kind = u16::from_be_bytes([buf[p], buf[p + 1]]);
        let len = u16::from_be_bytes([buf[p + 2], buf[p + 3]]) as usize;
        let data = p + 4;
        if kind == 0 {
            // server_name_list length (2) + name_type (1) + name length (2)
            let name = data + 5;
            if name < buf.len() {
                return Some(name);
            }
        }
        p = data.saturating_add(len);
    }
    None
}

fn split_points(len: usize, method: &str, frag: usize, sni: Option<usize>) -> Vec<usize> {
    let mut cuts = Vec::new();
    match method {
        "sni" => {
            if let Some(off) = sni {
                cuts.push(off);
            }
        }
        "byte" => {
            cuts.push(1);
            cuts.push(5.min(len));
        }
        _ => {
            let step = frag.max(1);
            let mut pos = step;
            while pos < len {
                cuts.push(pos);
                pos += step;
            }
        }
    }
    cuts.retain(|c| *c > 0 && *c < len);
    cuts.sort_unstable();
    cuts.dedup();
    cuts
}

/// Writes the first client chunk, optionally chopped into small segments so
/// that on-path DPI cannot match the TLS ClientHello in a single packet.
async fn write_hello<W>(rw: &mut W, chunk: &[u8], method: &str, frag: usize) -> bool
where
    W: tokio::io::AsyncWrite + Unpin,
{
    if !is_tls_hello(chunk) {
        return rw.write_all(chunk).await.is_ok();
    }
    let sni = if method == "sni" { sni_offset(chunk) } else { None };
    let cuts = split_points(chunk.len(), method, frag, sni);
    if cuts.is_empty() {
        return rw.write_all(chunk).await.is_ok();
    }
    let pause = if method == "byte" { 2 } else { 1 };
    let mut pos = 0;
    for cut in cuts.iter().copied().chain(std::iter::once(chunk.len())) {
        if cut <= pos {
            continue;
        }
        if rw.write_all(&chunk[pos..cut]).await.is_err() {
            return false;
        }
        let _ = rw.flush().await;
        pos = cut;
        tokio::time::sleep(Duration::from_millis(pause)).await;
    }
    true
}

/// Decides whether the TLS-fragmentation bypass applies to this connection.
fn dpi_plan(engine: &'static Engine, route: &str) -> Option<(String, usize)> {
    if route != "direct" {
        return None;
    }
    let settings = engine.settings();
    if !settings.dpi_bypass {
        return None;
    }
    let method = match settings.dpi_method.to_lowercase().as_str() {
        "sni" => "sni",
        "byte" => "byte",
        _ => "split",
    }
    .to_string();
    Some((method, settings.frag_size.clamp(8, 256)))
}

async fn relay(
    engine: &'static Engine,
    client: TcpStream,
    remote: BoxStream,
    dpi: Option<(String, usize)>,
) {
    let (mut cr, mut cw) = client.into_split();
    let (mut rr, mut rw) = tokio::io::split(remote);
    // The first client chunk is forwarded manually so that DPI evasion can
    // split the TLS ClientHello into small TCP segments.
    let mut initial = vec![0u8; 16384];
    let n = match tokio::time::timeout(Duration::from_secs(20), cr.read(&mut initial)).await {
        Ok(Ok(n)) => n,
        _ => 0,
    };
    if n == 0 {
        return;
    }
    let chunk = &initial[..n];
    let sent = match dpi {
        Some((method, frag)) => write_hello(&mut rw, chunk, &method, frag).await,
        None => rw.write_all(chunk).await.is_ok(),
    };
    if !sent {
        return;
    }
    engine.stats.up.fetch_add(n as u64, Ordering::Relaxed);

    let up_stat = &engine.stats.up as *const AtomicU64;
    let down_stat = &engine.stats.down as *const AtomicU64;
    // SAFETY: ENGINE is a 'static singleton; the counters outlive the tasks.
    let up_stat: &'static AtomicU64 = unsafe { &*up_stat };
    let down_stat: &'static AtomicU64 = unsafe { &*down_stat };

    let up = async move {
        let _ = crate::util::copy_counted(cr, rw, up_stat).await;
    };
    let down = async move {
        let _ = crate::util::copy_counted(rr, cw, down_stat).await;
    };
    tokio::select! {
        _ = up => {}
        _ = down => {}
    }
}

#[derive(Serialize)]
pub struct StatusView {
    pub running: bool,
    pub port: u16,
    pub mode: String,
    pub uptime: u64,
    pub up: u64,
    pub down: u64,
    pub conns: u32,
    pub total: u64,
    pub active: Option<ProxyConfig>,
    pub chain: Vec<ProxyConfig>,
    pub real_ip: String,
    pub exit_ip: String,
    pub exit_country: String,
    pub exit_city: String,
    pub exit_flag: String,
    pub log_seq: u64,
    pub tun: bool,
    pub dns: String,
    pub dpi: bool,
}

pub fn status() -> Value {
    let engine = &*ENGINE;
    let settings = engine.settings();
    let chain = engine.active_chain();
    let started = engine.started_at.lock().unwrap().map(|i| i.elapsed().as_secs()).unwrap_or(0);
    let geo = engine.exit_geo.lock().unwrap().clone();
    let view = StatusView {
        running: engine.is_running(),
        port: engine.port.load(Ordering::SeqCst),
        mode: settings.mode.clone(),
        uptime: started,
        up: engine.stats.up.load(Ordering::Relaxed),
        down: engine.stats.down.load(Ordering::Relaxed),
        conns: engine.stats.conns.load(Ordering::Relaxed),
        total: engine.stats.total.load(Ordering::Relaxed),
        active: chain.last().cloned(),
        chain,
        real_ip: engine.real_ip.lock().unwrap().clone(),
        exit_ip: engine.exit_ip.lock().unwrap().clone(),
        exit_country: geo.country.clone(),
        exit_city: geo.city.clone(),
        exit_flag: geo.flag.clone(),
        log_seq: engine.logs.head(),
        tun: engine.tun_running.load(Ordering::SeqCst),
        dns: format!("{:?}", settings.dns.protocol).to_uppercase(),
        dpi: settings.dpi_bypass,
    };
    serde_json::to_value(view).unwrap_or_else(|_| json!({"running": false}))
}

pub async fn start(config: EngineConfig) -> Result<Value> {
    let engine = &*ENGINE;
    stop().await;
    let port = if config.listen_port == 0 { 10808 } else { config.listen_port };
    let listener = TcpListener::bind(("127.0.0.1", port))
        .await
        .with_context(|| format!("не удалось занять порт {port}"))?;
    let resolver = Arc::new(Resolver::new(config.settings.dns.clone()));
    let dialer = Arc::new(Dialer::new(resolver.clone()));
    *engine.resolver.lock().unwrap() = Some(resolver);
    *engine.dialer.lock().unwrap() = Some(dialer);
    *engine.settings.lock().unwrap() = config.settings.clone();
    let mut chain = config.chain.clone();
    if chain.is_empty() {
        if let Some(first) = config.proxies.first() {
            chain.push(first.clone());
        }
    }
    *engine.chain.lock().unwrap() = chain;
    *engine.pool.lock().unwrap() = config.proxies.clone();
    let route_name = engine
        .active_chain()
        .last()
        .map(|p| p.name.clone())
        .unwrap_or_default();
    *engine.route_name.lock().unwrap() = route_name;
    engine.port.store(port, Ordering::SeqCst);
    *engine.started_at.lock().unwrap() = Some(Instant::now());
    engine.stats.up.store(0, Ordering::Relaxed);
    engine.stats.down.store(0, Ordering::Relaxed);
    engine.stats.total.store(0, Ordering::Relaxed);
    engine.running.store(true, Ordering::SeqCst);
    engine.log("INFO", format!("RustedProxy core started · mixed proxy 127.0.0.1:{port}"));
    engine.log(
        "INFO",
        format!(
            "mode={} dns={:?} chain={}",
            config.settings.mode,
            config.settings.dns.protocol,
            engine
                .active_chain()
                .iter()
                .map(|p| if p.name.is_empty() { p.endpoint() } else { p.name.clone() })
                .collect::<Vec<_>>()
                .join(" → ")
        ),
    );
    let (tx, rx) = watch::channel(false);
    *engine.stop.lock().unwrap() = Some(tx);
    tokio::spawn(accept_loop(engine, listener, rx));
    tokio::spawn(background_tasks());
    let _ = refresh_ips().await;
    Ok(status())
}

pub async fn stop() -> Value {
    let engine = &*ENGINE;
    if let Some(tx) = engine.stop.lock().unwrap().take() {
        let _ = tx.send(true);
    }
    if engine.running.swap(false, Ordering::SeqCst) {
        engine.log("INFO", "RustedProxy core stopped");
    }
    *engine.started_at.lock().unwrap() = None;
    engine.stats.up.store(0, Ordering::Relaxed);
    engine.stats.down.store(0, Ordering::Relaxed);
    engine.stats.conns.store(0, Ordering::Relaxed);
    serde_json::json!({"ok": true})
}

async fn background_tasks() {
    let engine = &*ENGINE;
    let mut last_health = Instant::now();
    loop {
        tokio::time::sleep(Duration::from_secs(5)).await;
        if !engine.is_running() {
            break;
        }
        let settings = engine.settings();
        if last_health.elapsed() > Duration::from_secs(45) {
            let _ = refresh_ips().await;
            last_health = Instant::now();
        }
        if settings.rotation_secs > 0 {
            let pool = engine.pool.lock().unwrap().clone();
            if pool.len() > 1 {
                let elapsed = engine.started_at.lock().unwrap().map(|i| i.elapsed().as_secs()).unwrap_or(0);
                if elapsed > 0 && elapsed % settings.rotation_secs < 5 {
                    let current = engine.active_chain().last().cloned();
                    let idx = current
                        .as_ref()
                        .and_then(|c| pool.iter().position(|p| p.id == c.id))
                        .unwrap_or(0);
                    let next = pool[(idx + 1) % pool.len()].clone();
                    engine.set_active(next.clone());
                    engine.log("INFO", format!("auto-rotation → {}", next.name));
                    let _ = refresh_ips().await;
                }
            }
        }
    }
}

/// Public IP echo services. Several are tried in order: RU mobile carriers
/// reset `api.ipify.org` often enough that a single mirror leaves the home
/// card stuck on "—".
const IP_URLS: &[&str] = &[
    "https://api.ipify.org",
    "https://icanhazip.com",
    "https://ifconfig.me/ip",
    "https://ipv4.icanhazip.com",
    "https://checkip.amazonaws.com",
    "https://ipinfo.io/ip",
    "https://api.myip.com",
];

async fn fetch_text(client: &reqwest::Client, urls: &[&str]) -> Option<String> {
    for url in urls {
        if let Ok(resp) = client.get(*url).send().await {
            if resp.status().is_success() {
                if let Ok(text) = resp.text().await {
                    let text = text.trim().to_string();
                    if text.parse::<IpAddr>().is_ok() {
                        return Some(text);
                    }
                    // api.myip.com answers with JSON: {"ip":"1.2.3.4",...}
                    if let Some(rest) = text.split("\"ip\"").nth(1) {
                        let candidate: String = rest
                            .trim_start_matches(|c: char| c == ':' || c == '"' || c.is_whitespace())
                            .chars()
                            .take_while(|c| c.is_ascii_hexdigit() || *c == '.' || *c == ':')
                            .collect();
                        if candidate.parse::<IpAddr>().is_ok() {
                            return Some(candidate);
                        }
                    }
                }
            }
        }
    }
    None
}

pub async fn refresh_ips() -> Result<()> {
    // Called from the periodic ticker, the connect path and the pull-to-refresh
    // button at once; serialise so a second run cannot overwrite a fresh IP
    // with "no answer".
    static IP_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    let _guard = IP_LOCK.try_lock();
    let engine = &*ENGINE;
    // Reuse one keep-alive client across runs: a fresh TLS handshake on every
    // 45 s tick was the main reason the echo services timed out on mobile.
    static IP_CLIENT: once_cell::sync::Lazy<Result<reqwest::Client, String>> = once_cell::sync::Lazy::new(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(6))
            .connect_timeout(Duration::from_secs(4))
            .user_agent("RustedProxy/1.0")
            .pool_idle_timeout(Duration::from_secs(90))
            .build()
            .map_err(|e| e.to_string())
    });
    let client = match &*IP_CLIENT {
        Ok(c) => c.clone(),
        Err(_) => reqwest::Client::builder()
            .timeout(Duration::from_secs(6))
            .user_agent("RustedProxy/1.0")
            .build()?,
    };
    if let Some(ip) = fetch_text(&client, IP_URLS).await {
        *engine.real_ip.lock().unwrap() = ip;
    }
    if engine.is_running() && !engine.active_chain().is_empty() {
        let port = engine.port.load(Ordering::SeqCst);
        let proxy = reqwest::Proxy::http(format!("http://127.0.0.1:{port}"))?;
        let proxied = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .proxy(proxy)
            .user_agent("RustedProxy/1.0")
            .build()?;
        if let Some(ip) = fetch_text(&proxied, IP_URLS).await {
            if ip.parse::<IpAddr>().is_ok() {
                let geo = geo::lookup_ip(&ip).unwrap_or_default();
                *engine.exit_ip.lock().unwrap() = ip;
                *engine.exit_geo.lock().unwrap() = geo;
            }
        }
    } else if let Some(ip) = {
        let ip = engine.real_ip.lock().unwrap().clone();
        if ip.is_empty() { None } else { Some(ip) }
    } {
        let geo = geo::lookup_ip(&ip).unwrap_or_default();
        *engine.exit_ip.lock().unwrap() = ip;
        *engine.exit_geo.lock().unwrap() = geo;
    }
    Ok(())
}

pub fn logs_since(after: u64) -> Value {
    let engine = &*ENGINE;
    let items = engine.logs.since(after);
    json!({"head": engine.logs.head(), "items": items})
}

pub async fn swap_route(index: usize) -> Result<Value> {
    let engine = &*ENGINE;
    let pool = engine.pool.lock().unwrap().clone();
    let Some(next) = pool.get(index).cloned() else {
        bail!("нет такого сервера");
    };
    engine.set_active(next.clone());
    engine.log("INFO", format!("route → {}", next.name));
    if engine.is_running() {
        let _ = refresh_ips().await;
    }
    Ok(status())
}

/// Test a single proxy by issuing a real HTTP request through it.
pub async fn check_proxy(p: &ProxyConfig, timeout_ms: u64, check_url: &str) -> Value {
    let resolver = Arc::new(Resolver::new(Default::default()));
    let dialer = Dialer::new(resolver);
    let chain = vec![p.clone()];
    let start = Instant::now();
    let result = dialer
        .http_get_via(
            &chain,
            check_url,
            "",
            65536,
            Duration::from_millis(timeout_ms.clamp(800, 20000)),
        )
        .await;
    match result {
        Ok(resp) if resp.status < 500 => {
            let latency = start.elapsed().as_millis() as i64;
            let mut geo = geo::lookup_ip(&p.host).unwrap_or_default();
            if geo.city.is_empty() {
                geo.city = String::new();
            }
            json!({
                "ok": true,
                "latency": latency,
                "status": resp.status,
                "country": geo.country,
                "country_code": geo.code,
                "city": geo.city,
                "flag": geo.flag,
            })
        }
        Ok(resp) => json!({"ok": false, "error": format!("HTTP {}", resp.status)}),
        Err(e) => json!({"ok": false, "error": e.to_string()}),
    }
}

pub fn settings_json() -> Value {
    serde_json::to_value(ENGINE.settings()).unwrap_or_default()
}

pub fn protocol_of(port: u16) -> &'static str {
    let _ = port;
    ""
}

pub fn mode_allows_udp(mode: &str) -> bool {
    mode_proxy_all(mode)
}

pub fn dns_protocol_name(p: &DnsProtocol) -> &'static str {
    match p {
        DnsProtocol::Doh => "DoH",
        DnsProtocol::Dot => "DoT",
        DnsProtocol::Udp => "UDP",
    }
}

#[allow(dead_code)]
fn _unused() {
    let _ = now_ms();
    let _ = mode_allows_udp("");
    let _ = is_russian("");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn proxy() -> ProxyConfig {
        ProxyConfig::default()
    }

    fn settings(mode: &str) -> EngineSettings {
        EngineSettings {
            mode: mode.to_string(),
            block_unencrypted: false,
            ..EngineSettings::default()
        }
    }

    #[test]
    fn full_mode_proxies_foreign_and_blocked_hosts() {
        let chain = vec![proxy()];
        let s = settings("full");
        assert_eq!(
            decide_route(&s, &chain, Some("www.youtube.com"), None),
            "proxy"
        );
        // Any non-Russian host is proxied so that RF blocks are bypassed even
        // for services that are missing from the bundled list.
        assert_eq!(
            decide_route(&s, &chain, Some("example.com"), None),
            "proxy"
        );
        // Russian hosts stay direct in "Полная работа".
        assert_eq!(decide_route(&s, &chain, Some("yandex.ru"), None), "direct");
    }

    #[test]
    fn disabling_ru_bypass_keeps_foreign_traffic_direct() {
        let chain = vec![proxy()];
        let mut s = settings("full");
        s.bypass_ru = false;
        assert_eq!(
            decide_route(&s, &chain, Some("example.com"), None),
            "direct"
        );
        // The built-in list still protects known blocked services.
        assert_eq!(
            decide_route(&s, &chain, Some("www.youtube.com"), None),
            "direct"
        );
    }

    #[test]
    fn proxy_mode_proxies_everything() {
        let chain = vec![proxy()];
        let s = settings("proxy");
        assert_eq!(
            decide_route(&s, &chain, Some("example.com"), None),
            "proxy"
        );
        assert_eq!(decide_route(&s, &chain, Some("yandex.ru"), None), "proxy");
        assert_eq!(decide_route(&s, &chain, Some("localhost"), None), "direct");
    }

    #[test]
    fn bypass_all_routes_everything_through_proxy() {
        let chain = vec![proxy()];
        let mut s = settings("full");
        s.bypass_all = true;
        assert_eq!(
            decide_route(&s, &chain, Some("example.org"), None),
            "proxy"
        );
        assert_eq!(decide_route(&s, &chain, Some("yandex.ru"), None), "proxy");
    }

    #[test]
    fn custom_bypass_domains_are_honoured() {
        let chain = vec![proxy()];
        let mut s = settings("full");
        s.bypass_ru = false;
        s.bypass_domains = vec!["example.net".into()];
        assert_eq!(
            decide_route(&s, &chain, Some("cdn.example.net"), None),
            "proxy"
        );
        assert_eq!(
            decide_route(&s, &chain, Some("notexample.net"), None),
            "direct"
        );
    }

    #[test]
    fn ads_are_blocked_before_routing() {
        let mut s = settings("proxy");
        s.adblock = true;
        // The bundled adblock list contains doubleclick.net.
        assert_eq!(
            decide_route(&s, &[], Some("ad.doubleclick.net"), None),
            "block"
        );
    }

    #[test]
    fn empty_chain_falls_back_to_direct_in_full_mode() {
        let s = settings("full");
        assert_eq!(
            decide_route(&s, &[], Some("www.youtube.com"), None),
            "direct"
        );
    }
}

