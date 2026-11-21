use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub mod dns;
pub mod engine;
pub mod geo;
pub mod jni;
pub mod links;
pub mod logbuf;
pub mod proxy;
pub mod scanner;
pub mod ss;
pub mod tls;
pub mod tun;
pub mod util;

use engine::{EngineConfig, EngineSettings};

/// Renders an error together with its cause chain. `anyhow`'s `Display` only
/// prints the outermost context, which turns every failure into an unhelpful
/// `hop 1 (vless 1.2.3.4:443)` and hides the real reason from the log and UI.
pub fn err_chain(e: &anyhow::Error) -> String {
    let mut out = e.to_string();
    for cause in e.chain().skip(1) {
        out.push_str(": ");
        out.push_str(&cause.to_string());
    }
    out
}

pub static RUNTIME: once_cell::sync::Lazy<tokio::runtime::Runtime> = once_cell::sync::Lazy::new(|| {
    let threads = std::thread::available_parallelism().map(|n| n.get().clamp(2, 4)).unwrap_or(4);
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(threads)
        .enable_all()
        .thread_name("rustedproxy")
        .build()
        .expect("tokio runtime")
});

static DATA_DIR: Mutex<String> = Mutex::new(String::new());

fn init_once() {
    static INIT: once_cell::sync::OnceCell<()> = once_cell::sync::OnceCell::new();
    INIT.get_or_init(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
        geo::init();
        let _ = &*RUNTIME;
    });
}

fn cstr_to_string(p: *const c_char) -> Result<String> {
    if p.is_null() {
        return Err(anyhow!("null string"));
    }
    unsafe { CStr::from_ptr(p) }.to_str().map(|s| s.to_string()).map_err(|e| anyhow!(e))
}

fn json_ptr(v: Value) -> *mut c_char {
    let mut text = v.to_string();
    text = text.replace('\0', "");
    CString::new(text).unwrap_or_default().into_raw()
}

fn ffi<F>(f: F) -> *mut c_char
where
    F: FnOnce() -> Result<Value> + std::panic::UnwindSafe,
{
    let value = match std::panic::catch_unwind(f) {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => json!({"error": e.to_string()}),
        Err(_) => json!({"error": "internal panic in Rust core"}),
    };
    json_ptr(value)
}

#[no_mangle]
pub extern "C" fn rp_init(data_dir: *const c_char) -> *mut c_char {
    ffi(|| {
        init_once();
        if let Ok(dir) = cstr_to_string(data_dir) {
            *DATA_DIR.lock().unwrap() = dir;
        }
        Ok(json!({
            "version": env!("CARGO_PKG_VERSION"),
            "engine": "tokio",
            "geo": "DB-IP Lite (CC BY 4.0)",
            "protocols": ["socks5", "socks4", "http", "https", "ss", "trojan", "vless"],
        }))
    })
}

#[no_mangle]
pub extern "C" fn rp_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(ptr));
    }
}

#[no_mangle]
pub extern "C" fn rp_engine_start(cfg: *const c_char) -> *mut c_char {
    ffi(|| {
        init_once();
        let text = cstr_to_string(cfg)?;
        let config: EngineConfig = serde_json::from_str(&text).context("engine config json")?;
        RUNTIME.block_on(engine::start(config))
    })
}

#[no_mangle]
pub extern "C" fn rp_engine_stop() -> *mut c_char {
    ffi(|| {
        let _ = tun::stop();
        Ok(RUNTIME.block_on(engine::stop()))
    })
}

#[no_mangle]
pub extern "C" fn rp_engine_status() -> *mut c_char {
    ffi(|| Ok(engine::status()))
}

#[no_mangle]
pub extern "C" fn rp_engine_logs(after: u64) -> *mut c_char {
    ffi(|| Ok(engine::logs_since(after)))
}

#[no_mangle]
pub extern "C" fn rp_refresh_ips() -> *mut c_char {
    ffi(|| {
        RUNTIME.block_on(engine::refresh_ips())?;
        Ok(engine::status())
    })
}

#[no_mangle]
pub extern "C" fn rp_swap_route(index: usize) -> *mut c_char {
    ffi(|| RUNTIME.block_on(engine::swap_route(index)))
}

#[no_mangle]
pub extern "C" fn rp_test_proxy(payload: *const c_char) -> *mut c_char {
    ffi(|| {
        init_once();
        let text = cstr_to_string(payload)?;
        let v: Value = serde_json::from_str(&text)?;
        let proxy: proxy::ProxyConfig = serde_json::from_value(v.get("proxy").cloned().unwrap_or(Value::Null))?;
        let timeout = v.get("timeout_ms").and_then(|x| x.as_u64()).unwrap_or(5000);
        let check_url = v
            .get("check_url")
            .and_then(|x| x.as_str())
            .unwrap_or("https://cp.cloudflare.com/generate_204")
            .to_string();
        let result = RUNTIME.block_on(engine::check_proxy(&proxy, timeout, &check_url));
        Ok(result)
    })
}

#[no_mangle]
pub extern "C" fn rp_scan_start(payload: *const c_char) -> *mut c_char {
    ffi(|| {
        init_once();
        let text = cstr_to_string(payload)?;
        let cfg: scanner::ScanConfig = serde_json::from_str(&text).context("scan config json")?;
        scanner::start(cfg);
        Ok(scanner::poll())
    })
}

#[no_mangle]
pub extern "C" fn rp_scan_poll() -> *mut c_char {
    ffi(|| Ok(scanner::poll()))
}

#[no_mangle]
pub extern "C" fn rp_scan_stop() -> *mut c_char {
    ffi(|| {
        scanner::stop();
        Ok(scanner::poll())
    })
}

#[no_mangle]
pub extern "C" fn rp_parse_text(payload: *const c_char) -> *mut c_char {
    ffi(|| {
        let text = cstr_to_string(payload)?;
        let v: Value = serde_json::from_str(&text).unwrap_or_else(|_| json!({ "text": text, "proto": "socks5" }));
        let body = v.get("text").and_then(|x| x.as_str()).unwrap_or("");
        let proto = v.get("proto").and_then(|x| x.as_str()).unwrap_or("socks5");
        let report = links::parse_many(body, proto);
        Ok(json!({"proxies": report.proxies, "skipped": report.skipped}))
    })
}

#[no_mangle]
pub extern "C" fn rp_fetch_subscription(url: *const c_char) -> *mut c_char {
    ffi(|| {
        init_once();
        let url = cstr_to_string(url)?;
        Ok(scanner::fetch_subscription(&url))
    })
}

#[no_mangle]
pub extern "C" fn rp_build_link(payload: *const c_char) -> *mut c_char {
    ffi(|| {
        let text = cstr_to_string(payload)?;
        let p: proxy::ProxyConfig = serde_json::from_str(&text)?;
        let link = links::build_link(&p)?;
        Ok(json!({"link": link}))
    })
}

#[no_mangle]
pub extern "C" fn rp_geo(ip: *const c_char) -> *mut c_char {
    ffi(|| {
        init_once();
        let ip = cstr_to_string(ip)?;
        match geo::lookup_ip(&ip) {
            Some(g) => Ok(serde_json::to_value(g)?),
            None => Ok(json!({"code": "", "country": "", "flag": "🌐"})),
        }
    })
}

#[no_mangle]
pub extern "C" fn rp_geo_city(ip: *const c_char) -> *mut c_char {
    ffi(|| {
        init_once();
        let ip = cstr_to_string(ip)?;
        let g = RUNTIME.block_on(geo::city_lookup(&ip))?;
        Ok(serde_json::to_value(g)?)
    })
}

#[no_mangle]
pub extern "C" fn rp_tun_start(fd: i32, mtu: u32) -> *mut c_char {
    ffi(|| {
        init_once();
        let settings = engine::ENGINE.settings();
        tun::start(fd, mtu.clamp(576, 1500) as u16, &settings)
    })
}

#[no_mangle]
pub extern "C" fn rp_tun_stop() -> *mut c_char {
    ffi(|| tun::stop())
}

#[no_mangle]
pub extern "C" fn rp_tun_running() -> *mut c_char {
    ffi(|| Ok(json!({"running": tun::running()})))
}

#[no_mangle]
pub extern "C" fn rp_speedtest(payload: *const c_char) -> *mut c_char {
    ffi(|| {
        init_once();
        let _ = payload;
        RUNTIME.block_on(speedtest())
    })
}

#[no_mangle]
pub extern "C" fn rp_leak_test() -> *mut c_char {
    ffi(|| {
        init_once();
        RUNTIME.block_on(leak_test())
    })
}

/// Resolve a hostname with exactly the configured DNS transport, so the UI can
/// prove that DoH/DoT/UDP actually works on this network.
#[no_mangle]
pub extern "C" fn rp_dns_test(payload: *const c_char) -> *mut c_char {
    ffi(|| {
        init_once();
        let text = cstr_to_string(payload).unwrap_or_else(|_| "{}".into());
        let v: Value = serde_json::from_str(&text).unwrap_or_else(|_| json!({}));
        let settings: dns::DnsSettings = v
            .get("dns")
            .and_then(|d| serde_json::from_value(d.clone()).ok())
            .unwrap_or_default();
        let host = v
            .get("host")
            .and_then(|x| x.as_str())
            .unwrap_or("example.com")
            .trim()
            .to_string();
        let host = if host.is_empty() { "example.com".to_string() } else { host };
        let started = Instant::now();
        let resolver = dns::Resolver::new(settings.clone());
        match RUNTIME.block_on(resolver.resolve_strict(&host)) {
            Ok(ips) => Ok(json!({
                "ok": true,
                "host": host,
                "ips": ips.iter().map(|ip| ip.to_string()).collect::<Vec<_>>(),
                "elapsed": started.elapsed().as_millis() as u64,
                "protocol": engine::dns_protocol_name(&settings.protocol),
                "server": settings.server,
            })),
            Err(e) => Ok(json!({
                "ok": false,
                "host": host,
                "error": e.to_string(),
                "protocol": engine::dns_protocol_name(&settings.protocol),
                "server": settings.server,
            })),
        }
    })
}

async fn http_client(through_engine: bool) -> Result<reqwest::Client> {
    let mut builder = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .user_agent("RustedProxy/1.0");
    if through_engine {
        let port = engine::ENGINE.port.load(std::sync::atomic::Ordering::SeqCst);
        if port != 0 {
            builder = builder.proxy(reqwest::Proxy::http(format!("http://127.0.0.1:{port}"))?);
        }
    }
    Ok(builder.build()?)
}

fn device_probe_urls() -> [&'static str; 3] {
    ["https://api.ipify.org", "https://icanhazip.com", "https://ifconfig.me/ip"]
}

async fn probe_ip(through_engine: bool) -> Result<String> {
    let client = http_client(through_engine).await?;
    for url in device_probe_urls() {
        if let Ok(resp) = client.get(url).send().await {
            if resp.status().is_success() {
                if let Ok(text) = resp.text().await {
                    let t = text.trim().to_string();
                    if t.parse::<std::net::IpAddr>().is_ok() {
                        return Ok(t);
                    }
                }
            }
        }
    }
    Err(anyhow!("не удалось определить IP"))
}

async fn speedtest() -> Result<Value> {
    let running = engine::ENGINE.is_running() && !engine::ENGINE.active_chain().is_empty();
    let client = http_client(running).await?;

    // Ping: a tiny download. Failure here must not abort the whole test.
    let mut ping = 0u64;
    for url in [
        "https://speed.cloudflare.com/__down?bytes=1",
        "https://cp.cloudflare.com/generate_204",
    ] {
        let started = Instant::now();
        if let Ok(Ok(resp)) = tokio::time::timeout(Duration::from_secs(8), client.get(url).send()).await {
            if resp.status().is_success() {
                let _ = resp.bytes().await;
                ping = started.elapsed().as_millis() as u64;
                break;
            }
        }
    }

    // Download: stream the payload and compute the rate from the bytes that
    // actually arrived inside a fixed time budget. Waiting for a full 10-25 MB
    // body (the previous implementation) timed out on slow proxy chains and
    // reported 0 Mbit/s even when the connection worked.
    let mut download = 0.0f64;
    let mut bytes = 0usize;
    let mut server = String::new();
    for url in [
        "https://speed.cloudflare.com/__down?bytes=26214400",
        "https://speed.hetzner.de/100MB.bin",
        "https://proof.ovh.net/files/100Mb.dat",
        "https://speed.cloudflare.com/__down?bytes=10485760",
    ] {
        let started = Instant::now();
        let Ok(Ok(mut resp)) = tokio::time::timeout(
            Duration::from_secs(12),
            client
                .get(url)
                .header("cache-control", "no-cache")
                .send(),
        )
        .await
        else {
            continue;
        };
        if !resp.status().is_success() {
            continue;
        }
        let mut got = 0usize;
        let budget = Duration::from_secs(10);
        loop {
            let elapsed = started.elapsed();
            if elapsed >= budget {
                break;
            }
            let left = budget.saturating_sub(elapsed);
            match tokio::time::timeout(left, resp.chunk()).await {
                Ok(Ok(Some(chunk))) => {
                    got += chunk.len();
                    // Stop after enough samples on very fast links.
                    if got >= 24 * 1024 * 1024 {
                        break;
                    }
                }
                Ok(Ok(None)) => break,
                _ => break,
            }
        }
        if got < 128 * 1024 {
            continue;
        }
        let secs = started.elapsed().as_secs_f64().max(0.15);
        download = (got as f64 * 8.0) / secs / 1_000_000.0;
        bytes = got;
        server = url.to_string();
        break;
    }

    // Upload: Cloudflare accepts raw bodies. Try the full payload, then a
    // smaller one, and always report the bytes that made it through.
    let mut upload = 0.0f64;
    for size in [2 * 1024 * 1024usize, 512 * 1024] {
        let payload = vec![0u8; size];
        let ul_started = Instant::now();
        let ul_resp = tokio::time::timeout(
            Duration::from_secs(18),
            client
                .post("https://speed.cloudflare.com/__up")
                .header("content-type", "application/octet-stream")
                .body(payload)
                .send(),
        )
        .await;
        if let Ok(Ok(resp)) = ul_resp {
            if resp.status().is_success() {
                let _ = resp.bytes().await;
                let secs = ul_started.elapsed().as_secs_f64().max(0.05);
                upload = (size as f64 * 8.0) / secs / 1_000_000.0;
                break;
            }
        }
    }

    if download <= 0.0 && upload <= 0.0 {
        return Err(anyhow!(
            "не удалось измерить скорость — проверьте соединение или смените прокси"
        ));
    }
    Ok(json!({
        "download": (download * 10.0).round() / 10.0,
        "upload": (upload * 10.0).round() / 10.0,
        "ping": ping,
        "bytes": bytes,
        "server": server,
        "via": if running { "engine" } else { "direct" },
    }))
}

async fn leak_test() -> Result<Value> {
    let engine_running = engine::ENGINE.is_running();
    let real_ip = probe_ip(false).await.unwrap_or_default();
    let visible_ip = if engine_running { probe_ip(true).await.unwrap_or_default() } else { real_ip.clone() };
    let real_geo = geo::lookup_ip(&real_ip).unwrap_or_default();
    let visible_geo = geo::lookup_ip(&visible_ip).unwrap_or_default();
    let settings = engine::ENGINE.settings();
    let mut checks = Vec::new();
    let ip_ok = engine_running && !visible_ip.is_empty() && visible_ip != real_ip;
    checks.push(json!({
        "name": "Видимый IP",
        "value": if visible_ip.is_empty() { "—".to_string() } else { format!("{visible_ip} · {}", visible_geo.country) },
        "status": if ip_ok { "ok" } else if engine_running { "warn" } else { "err" },
        "hint": if ip_ok { "IP прокси скрывает реальный адрес" } else if engine_running { "Цепочка использует прямой выход" } else { "Ядро не запущено" },
    }));
    checks.push(json!({
        "name": "Реальный IP",
        "value": if real_ip.is_empty() { "—".to_string() } else { format!("{real_ip} · {}", real_geo.country) },
        "status": "info",
        "hint": "Определён напрямую, в обход туннеля",
    }));
    let dns_is_secure = matches!(settings.dns.protocol, dns::DnsProtocol::Doh | dns::DnsProtocol::Dot);
    checks.push(json!({
        "name": "DNS",
        "value": format!("{} · {}", engine::dns_protocol_name(&settings.dns.protocol), settings.dns.server),
        "status": if dns_is_secure { "ok" } else { "warn" },
        "hint": if dns_is_secure { "Запросы шифруются, порт 53 не используется" } else { "Обычный UDP DNS может быть подменён провайдером" },
    }));
    let udp_ok = engine::ENGINE.tun_running.load(std::sync::atomic::Ordering::SeqCst);
    checks.push(json!({
        "name": "UDP / WebRTC",
        "value": if udp_ok { "UDP внутри TUN" } else { "UDP напрямую" },
        "status": if udp_ok { "ok" } else { "warn" },
        "hint": if udp_ok { "STUN и голосовые чаты идут через туннель" } else { "В локальном режиме UDP может раскрыть IP" },
    }));
    checks.push(json!({
        "name": "Kill Switch",
        "value": if settings.kill_switch { "Включён" } else { "Выключен" },
        "status": if settings.kill_switch { "ok" } else { "warn" },
        "hint": "Блокировка трафика при обрыве апстрима",
    }));
    Ok(json!({"checks": checks, "real_ip": real_ip, "visible_ip": visible_ip}))
}

/// Which build is running — handy in the About sheet.
#[no_mangle]
pub extern "C" fn rp_build_info() -> *mut c_char {
    ffi(|| {
        Ok(json!({
            "crate": env!("CARGO_PKG_VERSION"),
            "target": std::env::consts::ARCH,
            "os": std::env::consts::OS,
        }))
    })
}

#[allow(dead_code)]
fn _keep(_: EngineSettings) {}
