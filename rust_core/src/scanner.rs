use anyhow::{Context, Result};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::Semaphore;

use crate::engine;
use crate::links;
use crate::proxy::{Dialer, ProxyConfig};
use crate::{dns::Resolver, geo};
use crate::RUNTIME;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ScanSource {
    pub url: String,
    #[serde(default)]
    pub proto: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ScanConfig {
    #[serde(default = "d_mode")]
    pub mode: String,
    #[serde(default)]
    pub sources: Vec<ScanSource>,
    #[serde(default = "d_workers")]
    pub workers: usize,
    #[serde(default = "d_timeout")]
    pub timeout_ms: u64,
    #[serde(default = "d_url")]
    pub check_url: String,
    #[serde(default = "d_true")]
    pub speed_check: bool,
    #[serde(default)]
    pub service_check: bool,
    #[serde(default = "d_true")]
    pub anonymity_check: bool,
    #[serde(default = "d_max")]
    pub max_candidates: usize,
    #[serde(default = "d_all")]
    pub protocol_filter: String,
    #[serde(default)]
    pub require_encrypted: bool,
}

fn d_mode() -> String {
    "public".into()
}
fn d_workers() -> usize {
    200
}
fn d_timeout() -> u64 {
    4000
}
fn d_url() -> String {
    "https://cp.cloudflare.com/generate_204".into()
}
fn d_true() -> bool {
    true
}
fn d_max() -> usize {
    1200
}
fn d_all() -> String {
    "all".into()
}

impl Default for ScanConfig {
    fn default() -> Self {
        Self {
            mode: d_mode(),
            sources: Vec::new(),
            workers: d_workers(),
            timeout_ms: d_timeout(),
            check_url: d_url(),
            speed_check: true,
            service_check: false,
            anonymity_check: true,
            max_candidates: d_max(),
            protocol_filter: d_all(),
            require_encrypted: false,
        }
    }
}

pub fn default_sources(mode: &str) -> Vec<ScanSource> {
    let mut out = Vec::new();
    if mode == "keys" {
        // Only lists whose payload this core can actually dial. Pure-VMess
        // subscriptions are rejected at parse time (0 nodes), so sources are
        // picked where Shadowsocks / Trojan / VLESS dominate.
        // `parse_many` transparently base64-decodes whole subscription bodies.
        for (url, proto) in [
            ("https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/v2ray.txt", ""),
            ("https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/sub_merge.txt", ""),
            ("https://raw.githubusercontent.com/roosterkid/openproxylist/main/V2RAY_RAW.txt", ""),
            ("https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub", ""),
            ("https://raw.githubusercontent.com/ripaojiedian/freenode/main/sub", ""),
        ] {
            out.push(ScanSource { url: url.into(), proto: proto.into() });
        }
        return out;
    }
    for (url, proto) in [
        ("https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks5.txt", "socks5"),
        ("https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt", "http"),
        ("https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks4.txt", "socks4"),
        ("https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/socks5.txt", "socks5"),
        ("https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt", "http"),
        ("https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/all/data.txt", ""),
        ("https://api.proxyscrape.com/v2/?request=displayproxies&protocol=socks5", "socks5"),
        ("https://api.proxyscrape.com/v2/?request=displayproxies&protocol=http", "http"),
        ("https://www.proxy-list.download/api/v1/get?type=socks5", "socks5"),
        ("https://www.proxy-list.download/api/v1/get?type=socks4", "socks4"),
    ] {
        out.push(ScanSource { url: url.into(), proto: proto.into() });
    }
    out
}

pub struct ScanState {
    pub running: AtomicBool,
    pub cancel: AtomicBool,
    pub checked: AtomicUsize,
    pub total: AtomicUsize,
    pub skipped: AtomicUsize,
    pub found: Mutex<Vec<Value>>,
    pub phase: Mutex<String>,
    pub errors: Mutex<Vec<String>>,
    pub started: Mutex<Option<Instant>>,
    pub source_stats: Mutex<Vec<Value>>,
}

pub static SCAN: Lazy<ScanState> = Lazy::new(|| ScanState {
    running: AtomicBool::new(false),
    cancel: AtomicBool::new(false),
    checked: AtomicUsize::new(0),
    total: AtomicUsize::new(0),
    skipped: AtomicUsize::new(0),
    found: Mutex::new(Vec::new()),
    phase: Mutex::new("idle".into()),
    errors: Mutex::new(Vec::new()),
    started: Mutex::new(None),
    source_stats: Mutex::new(Vec::new()),
});

fn set_phase(p: &str) {
    *SCAN.phase.lock().unwrap() = p.to_string();
}

pub fn poll() -> Value {
    let found = SCAN.found.lock().unwrap().clone();
    let errors = SCAN.errors.lock().unwrap().clone();
    let started = SCAN.started.lock().unwrap().map(|i| i.elapsed().as_secs()).unwrap_or(0);
    json!({
        "running": SCAN.running.load(Ordering::SeqCst),
        "phase": SCAN.phase.lock().unwrap().clone(),
        "checked": SCAN.checked.load(Ordering::SeqCst),
        "total": SCAN.total.load(Ordering::SeqCst),
        "skipped": SCAN.skipped.load(Ordering::SeqCst),
        "found": found,
        "errors": errors,
        "elapsed": started,
        "sources": *SCAN.source_stats.lock().unwrap(),
    })
}

pub fn stop() {
    SCAN.cancel.store(true, Ordering::SeqCst);
}

pub fn start(cfg: ScanConfig) {
    if SCAN.running.swap(true, Ordering::SeqCst) {
        return;
    }
    SCAN.cancel.store(false, Ordering::SeqCst);
    SCAN.checked.store(0, Ordering::SeqCst);
    SCAN.total.store(0, Ordering::SeqCst);
    SCAN.skipped.store(0, Ordering::SeqCst);
    SCAN.found.lock().unwrap().clear();
    SCAN.errors.lock().unwrap().clear();
    SCAN.source_stats.lock().unwrap().clear();
    *SCAN.started.lock().unwrap() = Some(Instant::now());
    set_phase("fetching");
    let engine_ref: &'static engine::Engine = &engine::ENGINE;
    engine_ref.log("INFO", format!("scanner started · mode={} workers={}", cfg.mode, cfg.workers));
    // Must be spawned through the shared runtime: `scanner::start` is invoked
    // straight from a Dart FFI thread where no tokio reactor exists, and
    // `tokio::spawn` there aborts the process.
    crate::RUNTIME.spawn(async move {
        if let Err(e) = run(cfg).await {
            SCAN.errors.lock().unwrap().push(e.to_string());
            engine_ref.log("ERROR", format!("scanner: {e}"));
        }
        set_phase("done");
        SCAN.running.store(false, Ordering::SeqCst);
        let found = SCAN.found.lock().unwrap().len();
        let checked = SCAN.checked.load(Ordering::SeqCst);
        engine_ref.log("INFO", format!("scanner finished · checked {checked} · found {found}"));
    });
}

struct Candidate {
    proxy: ProxyConfig,
    source: String,
}

async fn fetch_source(client: &reqwest::Client, src: &ScanSource) -> Result<(String, String)> {
    let resp = client
        .get(&src.url)
        .timeout(Duration::from_secs(25))
        .send()
        .await
        .with_context(|| format!("fetch {}", src.url))?;
    if !resp.status().is_success() {
        anyhow::bail!("HTTP {} for {}", resp.status(), src.url);
    }
    let text = resp.text().await?;
    Ok((text, src.proto.clone()))
}

fn is_supported(proto: &str) -> bool {
    matches!(proto, "socks5" | "socks4" | "http" | "https" | "ss" | "trojan" | "vless")
}

async fn run(cfg: ScanConfig) -> Result<()> {
    let sources = if cfg.sources.is_empty() {
        default_sources(&cfg.mode)
    } else {
        cfg.sources.clone()
    };
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .user_agent("RustedProxy/1.0")
        .gzip(true)
        .build()?;
    set_phase("fetching");
    let mut handles = Vec::new();
    for src in sources.clone() {
        let client = client.clone();
        handles.push((src.clone(), tokio::spawn(async move { fetch_source(&client, &src).await })));
    }
    let mut candidates: Vec<Candidate> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut skipped = 0usize;
    for (src, handle) in handles {
        if SCAN.cancel.load(Ordering::SeqCst) {
            break;
        }
        match handle.await {
            Ok(Ok((text, proto))) => {
                let report = links::parse_many(&text, if proto.is_empty() { "socks5" } else { &proto });
                let mut taken = 0usize;
                for mut p in report.proxies {
                    if !is_supported(&p.proto) {
                        skipped += 1;
                        continue;
                    }
                    if cfg.protocol_filter != "all" && !cfg.protocol_filter.is_empty() {
                        let f = cfg.protocol_filter.to_lowercase();
                        if !p.proto.to_lowercase().contains(&f) {
                            skipped += 1;
                            continue;
                        }
                    }
                    if cfg.require_encrypted && !p.is_encrypted() {
                        skipped += 1;
                        continue;
                    }
                    if p.id.is_empty() {
                        p.id = format!("{}-{}-{}", p.proto, p.host, p.port);
                    }
                    let key = format!("{}|{}|{}", p.proto, p.host, p.port);
                    if seen.insert(key) {
                        taken += 1;
                        candidates.push(Candidate { proxy: p, source: src.url.clone() });
                    }
                }
                SCAN.source_stats
                    .lock()
                    .unwrap()
                    .push(json!({"url": src.url, "count": taken, "skipped": report.skipped}));
            }
            Ok(Err(e)) => {
                SCAN.errors.lock().unwrap().push(format!("{}: {}", src.url, e));
            }
            Err(e) => {
                SCAN.errors.lock().unwrap().push(format!("{}: {}", src.url, e));
            }
        }
    }
    SCAN.skipped.store(skipped + SCAN.skipped.load(Ordering::SeqCst), Ordering::SeqCst);
    // Poorly maintained lists often start with dead entries; shuffle so the
    // scan samples the whole list instead of only the head.
    use rand::seq::SliceRandom;
    candidates.shuffle(&mut rand::thread_rng());
    candidates.truncate(cfg.max_candidates.clamp(50, 6000));
    SCAN.total.store(candidates.len(), Ordering::SeqCst);
    set_phase("checking");
    if candidates.is_empty() {
        return Ok(());
    }

    let sem = Arc::new(Semaphore::new(cfg.workers.clamp(8, 500)));
    let resolver = Arc::new(Resolver::new(Default::default()));
    let anonymity_budget = Arc::new(AtomicUsize::new(60));
    let speed_budget = Arc::new(AtomicUsize::new(30));
    let service_budget = Arc::new(AtomicUsize::new(24));

    // Track every spawned probe so a slow one (geo, speed, service checks)
    // cannot get cut off when the fast ones finish: that made the list show
    // only the 13 quickest results out of a much larger pool.
    let mut probes = Vec::with_capacity(candidates.len());
    for cand in candidates {
        if SCAN.cancel.load(Ordering::SeqCst) {
            break;
        }
        let sem = sem.clone();
        let cfg = cfg.clone();
        let resolver = resolver.clone();
        let anon_budget = anonymity_budget.clone();
        let speed_budget = speed_budget.clone();
        let service_budget = service_budget.clone();
        probes.push(tokio::spawn(async move {
            let _permit = sem.acquire_owned().await;
            if SCAN.cancel.load(Ordering::SeqCst) {
                return;
            }
            let result = check_one(&cand, &cfg, resolver, &anon_budget, &speed_budget, &service_budget).await;
            SCAN.checked.fetch_add(1, Ordering::SeqCst);
            if let Some(v) = result {
                let mut list = SCAN.found.lock().unwrap();
                // Long scans can find thousands of nodes; the UI cannot render
                // that, so keep the 600 fastest.
                if list.len() < 600 {
                    list.push(v);
                } else {
                    // Already full: keep the faster of the two.
                    let worst = list
                        .iter()
                        .enumerate()
                        .max_by_key(|(_, item)| item.get("latency").and_then(|x| x.as_i64()).unwrap_or(0))
                        .map(|(i, item)| (i, item.get("latency").and_then(|x| x.as_i64()).unwrap_or(0)));
                    let new_latency = v.get("latency").and_then(|x| x.as_i64()).unwrap_or(9999);
                    if let Some((idx, worst_latency)) = worst {
                        if new_latency < worst_latency {
                            list[idx] = v;
                        }
                    }
                }
            }
        }));
    }

    // Bounded grace period: wait for the probes, but never hang the scan on a
    // single stuck node.
    let deadline = Instant::now() + Duration::from_secs(45);
    for handle in probes {
        if SCAN.cancel.load(Ordering::SeqCst) || Instant::now() > deadline {
            handle.abort();
            continue;
        }
        let _ = handle.await;
    }
    let mut found = SCAN.found.lock().unwrap().clone();
    found.sort_by_key(|v| v.get("latency").and_then(|x| x.as_i64()).unwrap_or(9999));
    *SCAN.found.lock().unwrap() = found;
    Ok(())
}

async fn check_one(
    cand: &Candidate,
    cfg: &ScanConfig,
    resolver: Arc<Resolver>,
    anon_budget: &AtomicUsize,
    speed_budget: &AtomicUsize,
    service_budget: &AtomicUsize,
) -> Option<Value> {
    let dialer = Dialer::new(resolver);
    let chain = vec![cand.proxy.clone()];
    let timeout = Duration::from_millis(cfg.timeout_ms.clamp(800, 15000));
    let started = Instant::now();
    let resp = match tokio::time::timeout(
        timeout,
        dialer.http_get_via(&chain, &cfg.check_url, "", 32768, timeout),
    )
    .await
    {
        Ok(Ok(r)) => r,
        _ => return None,
    };
    if resp.status >= 400 {
        return None;
    }
    let latency = started.elapsed().as_millis() as i64;
    let mut geo_info = geo_for_host(&dialer, &cand.proxy.host).await.unwrap_or_default();

    let mut anonymity = if matches!(cand.proxy.proto.as_str(), "http" | "https") {
        "Anonymous".to_string()
    } else {
        "Elite".to_string()
    };
    if cfg.anonymity_check && anon_budget.load(Ordering::SeqCst) > 0 {
        anon_budget.fetch_sub(1, Ordering::SeqCst);
        if let Ok(r) = tokio::time::timeout(
            Duration::from_secs(6),
            dialer.http_get_via(
                &chain,
                "https://httpbin.org/headers",
                "",
                131072,
                Duration::from_secs(6),
            ),
        )
        .await
        {
            if let Ok(resp) = r {
                let body = String::from_utf8_lossy(&resp.body).to_lowercase();
                if body.contains("x-forwarded-for") || body.contains("\"via\"") {
                    anonymity = "Transparent".to_string();
                } else if body.contains("\"headers\"") {
                    anonymity = "Elite".to_string();
                }
            }
        }
    }

    let mut speed = 0.0f64;
    // A node that connects but whose HTTPS body does not come back is not a
    // usable proxy. Checking this here (instead of stopping at the status
    // line) is what makes "found" results actually work for the user.
    let expected_body = cfg.check_url.contains("generate_204") || cfg.check_url.contains("/204");
    if !expected_body && resp.body.is_empty() {
        return None;
    }
    if cfg.speed_check && speed_budget.load(Ordering::SeqCst) > 0 {
        speed_budget.fetch_sub(1, Ordering::SeqCst);
        let speed_started = Instant::now();
        if let Ok(Ok(resp)) = tokio::time::timeout(
            Duration::from_secs(15),
            dialer.http_get_via(
                &chain,
                "https://speed.cloudflare.com/__down?bytes=524288",
                "",
                524288,
                Duration::from_secs(15),
            ),
        )
        .await
        {
            let secs = speed_started.elapsed().as_secs_f64().max(0.001);
            let bits = (resp.body.len() as f64) * 8.0;
            speed = bits / secs / 1_000_000.0;
        }
    }

    let mut tags: Vec<String> = Vec::new();
    if speed >= 15.0 {
        tags.push("Видео".into());
    }
    if matches!(cand.proxy.proto.as_str(), "socks5" | "trojan" | "vless" | "ss") {
        tags.push("UDP".into());
    }
    if cfg.service_check && service_budget.load(Ordering::SeqCst) > 0 {
        service_budget.fetch_sub(1, Ordering::SeqCst);
        let checks = [
            ("YouTube", "https://www.youtube.com/generate_204"),
            ("Discord", "https://discord.com/api/v9/gateway"),
            ("ChatGPT", "https://chatgpt.com/cdn-cgi/trace"),
            ("Netflix", "https://www.netflix.com/title/80057281"),
        ];
        for (name, url) in checks {
            if let Ok(Ok(r)) = tokio::time::timeout(
                Duration::from_secs(7),
                dialer.http_get_via(&chain, url, "", 65536, Duration::from_secs(7)),
            )
            .await
            {
                if r.status < 500 {
                    tags.push(name.to_string());
                }
            }
        }
    }

    if geo_info.code.is_empty() {
        geo_info = geo::GeoInfo {
            flag: "🌐".into(),
            country: if cand.proxy.country.is_empty() { "Неизвестно".into() } else { cand.proxy.country.clone() },
            ..Default::default()
        };
    }
    let mut proxy = cand.proxy.clone();
    proxy.latency = latency;
    proxy.speed = speed;
    proxy.encrypted = proxy.is_encrypted();
    proxy.country = geo_info.country.clone();
    proxy.country_code = geo_info.code.clone();
    proxy.city = geo_info.city.clone();
    proxy.flag = geo_info.flag.clone();
    proxy.anonymity = anonymity.clone();
    proxy.tags = tags.clone();
    if proxy.name.is_empty() {
        proxy.name = format!(
            "{} {}",
            geo_info.code,
            if geo_info.country.is_empty() { proxy.host.clone() } else { geo_info.country.clone() }
        );
    }
    Some(json!({
        "id": proxy.id,
        "proto": proxy.proto,
        "host": proxy.host,
        "port": proxy.port,
        "username": proxy.username,
        "password": proxy.password,
        "cipher": proxy.cipher,
        "uuid": proxy.uuid,
        "sni": proxy.sni,
        "tls": proxy.tls,
        "name": proxy.name,
        "country": proxy.country,
        "countryCode": proxy.country_code,
        "city": proxy.city,
        "flag": proxy.flag,
        "latency": latency,
        "speed": (speed * 10.0).round() / 10.0,
        "encrypted": proxy.encrypted,
        "anonymity": anonymity,
        "tags": tags,
        "raw": proxy.raw,
        "source": cand.source,
    }))
}

async fn geo_for_host(dialer: &Dialer, host: &str) -> Option<geo::GeoInfo> {
    if let Some(g) = geo::lookup_ip(host) {
        return Some(g);
    }
    let ip = dialer.resolver.resolve_first(host).await.ok()?;
    geo::lookup_ip(&ip.to_string())
}

pub fn fetch_subscription(url: &str) -> Value {
    // The FFI entry point runs on a Dart worker thread, so it must borrow the
    // shared runtime instead of building (and then dropping) its own reactor.
    RUNTIME.block_on(async move {
        let client = match reqwest::Client::builder()
            .timeout(Duration::from_secs(25))
            .user_agent("RustedProxy/1.0")
            .gzip(true)
            .build()
        {
            Ok(c) => c,
            Err(e) => return json!({"error": e.to_string()}),
        };
        let resp = match client.get(url).send().await {
            Ok(r) => r,
            Err(e) => return json!({"error": format!("{url}: {e}")}),
        };
        if !resp.status().is_success() {
            return json!({"error": format!("HTTP {} for {url}", resp.status())});
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(e) => return json!({"error": format!("{url}: {e}")}),
        };
        let parsed = if looks_like_clash(&text) {
            parse_clash(&text)
        } else {
            links::parse_many(&text, "socks5")
        };
        json!({
            "proxies": parsed.proxies,
            "skipped": parsed.skipped,
        })
    })
}

fn looks_like_clash(text: &str) -> bool {
    text.contains("proxies:") || (text.contains("type:") && text.contains("server:") && text.contains("port:"))
}

fn parse_clash(text: &str) -> links::ParseReport {
    let mut proxies: Vec<ProxyConfig> = Vec::new();
    let mut cur: Option<ProxyConfig> = None;
    for raw in text.lines() {
        let line = raw.trim();
        if line.starts_with("- ") || line.starts_with("-") && line.len() > 1 {
            if let Some(p) = cur.take() {
                if !p.host.is_empty() && p.port > 0 {
                    proxies.push(p);
                }
            }
            cur = Some(ProxyConfig::default());
            continue;
        }
        let Some(p) = cur.as_mut() else { continue };
        let Some((k, v)) = line.split_once(':') else { continue };
        let key = k.trim().trim_start_matches("- ").to_string();
        let val = v.trim().trim_matches('"').trim_matches('\'').to_string();
        match key.as_str() {
            "name" => p.name = val,
            "type" => p.proto = normalize_proto(&val),
            "server" => p.host = val,
            "port" => p.port = val.parse().unwrap_or(0),
            "password" => p.password = val,
            "cipher" => p.cipher = val,
            "uuid" => p.uuid = val,
            "sni" | "servername" => p.sni = val,
            "tls" => p.tls = val == "true",
            "username" | "user" => p.username = val,
            "udp" => {}
            _ => {}
        }
    }
    if let Some(p) = cur.take() {
        if !p.host.is_empty() && p.port > 0 {
            proxies.push(p);
        }
    }
    proxies.retain(|p| {
        is_supported(&p.proto)
            && !p.host.is_empty()
            && p.port > 0
            && !(p.proto == "vless" && p.uuid.is_empty())
            && !(p.proto == "ss" && p.password.is_empty())
    });
    for p in proxies.iter_mut() {
        p.id = format!("{}-{}-{}", p.proto, p.host, p.port);
        p.encrypted = p.is_encrypted();
    }
    links::ParseReport { proxies, skipped: 0 }
}

fn normalize_proto(t: &str) -> String {
    match t.to_lowercase().as_str() {
        "ss" | "shadowsocks" => "ss".into(),
        "socks5" => "socks5".into(),
        "socks4" => "socks4".into(),
        "http" => "http".into(),
        "trojan" => "trojan".into(),
        "vless" => "vless".into(),
        other => other.into(),
    }
}
