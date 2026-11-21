//! Live end-to-end probe for the scanner. It starts a real scan against the
//! network, prints per-source stats and how many nodes actually answered.
//! This is the fastest way to see whether parser/dial fixes moved the needle.
//!
//! ```text
//! cargo run --release --example scan_probe -- keys 1500
//! cargo run --release --example scan_probe -- public 800
//! cargo run --release --example scan_probe -- json config.json
//! cargo run --release --example scan_probe -- check links.txt
//! ```
//!
//! With `json` the second argument is a [`ScanConfig`] file, e.g.
//! `{"mode":"public","sources":[{"url":"http://127.0.0.1:8471/list.txt","proto":"socks5"}]}`.
//!
//! With `check` the second argument is a file with one proxy link per line; each
//! is parsed and dialled directly (no scanning), printing the exact error for
//! failures. Use it to tell "node is dead" apart from "our handshake is wrong".

use rustedproxy_core::engine;
use rustedproxy_core::links;
use rustedproxy_core::scanner::{self, ScanConfig};
use std::time::Duration;

fn main() {
    let mut args = std::env::args().skip(1);
    let mode = args.next().unwrap_or_else(|| "keys".to_string());

    if mode == "stats" {
        let path = args.next().expect("usage: scan_probe stats <subscription.txt>");
        let text = std::fs::read_to_string(&path).expect("read file");
        let report = links::parse_many(&text, "");
        use std::collections::BTreeMap;
        let mut by_proto: BTreeMap<String, usize> = BTreeMap::new();
        for p in &report.proxies {
            *by_proto.entry(p.proto.clone()).or_default() += 1;
        }
        println!("parsed {} skipped {}", report.proxies.len(), report.skipped);
        for (k, v) in by_proto {
            println!("  {k:<8} {v}");
        }
        let mut failed = 0;
        for line in text.lines().map(str::trim).filter(|l| !l.is_empty()) {
            if links::parse_line(line, "").is_none() {
                failed += 1;
                if failed <= 12 {
                    println!("  SKIP {}", &line[..line.len().min(110)]);
                }
            }
        }
        return;
    }

    if mode == "reach" {
        // Honest denominator: only nodes whose TCP port answers are worth
        // probing. For each reachable node run the full proxy check and print
        // the outcome, so "dead node" is separated from "our bug".
        let path = args.next().expect("usage: scan_probe reach <links.txt> [concurrency] [check_url]");
        let conc: usize = args.next().and_then(|v| v.parse().ok()).unwrap_or(32);
        let check_url = args
            .next()
            .unwrap_or_else(|| "https://cp.cloudflare.com/generate_204".to_string());
        let timeout_ms: u64 = args.next().and_then(|v| v.parse().ok()).unwrap_or(8000);
        let text = std::fs::read_to_string(&path).expect("read links");
        let report = links::parse_many(&text, "");
        println!("parsed {} links ({} skipped)", report.proxies.len(), report.skipped);

        let runtime = tokio::runtime::Runtime::new().unwrap();
        let results = runtime.block_on(async {
            let sem = std::sync::Arc::new(tokio::sync::Semaphore::new(conc));
            let mut handles = Vec::new();
            for p in report.proxies {
                let sem = sem.clone();
                let check_url = check_url.clone();
                handles.push(tokio::spawn(async move {
                    let _permit = sem.acquire_owned().await.unwrap();
                    let ep = format!("{}:{}", p.host, p.port);
                    let open = matches!(
                        tokio::time::timeout(
                            Duration::from_secs(4),
                            tokio::net::TcpStream::connect(&ep),
                        )
                        .await,
                        Ok(Ok(_))
                    );
                    if !open {
                        return (p, None);
                    }
                    let r = engine::check_proxy(&p, timeout_ms, &check_url).await;
                    (p, Some(r))
                }));
            }
            let mut out = Vec::new();
            for h in handles {
                out.push(h.await.unwrap());
            }
            out
        });

        let reachable: Vec<_> = results.iter().filter(|(_, r)| r.is_some()).collect();
        let mut ok = 0;
        println!("\n--- reachable nodes ---");
        for (p, r) in &results {
            let Some(r) = r else { continue };
            if r.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
                ok += 1;
                println!(
                    "  OK   {:>6} ms  {:<8} {}",
                    r.get("latency").and_then(|v| v.as_i64()).unwrap_or(0),
                    p.proto,
                    format!("{}:{}", p.host, p.port)
                );
            } else {
                println!(
                    "  FAIL {:<8} {:<26} {}",
                    p.proto,
                    format!("{}:{}", p.host, p.port),
                    r.get("error").and_then(|v| v.as_str()).unwrap_or("?")
                );
            }
        }
        println!(
            "\nreachable {}/{}  working {}",
            reachable.len(),
            results.len(),
            ok
        );
        return;
    }

    if mode == "tcp" {
        // Raw reachability: parse the links, then only open a TCP socket to
        // host:port. Separates "node is offline" from "our crypto/parser is
        // wrong" without depending on any handshake.
        let path = args.next().expect("usage: scan_probe tcp <links.txt>");
        let text = std::fs::read_to_string(&path).expect("read links");
        let report = links::parse_many(&text, "");
        println!("parsed {} links ({} skipped)", report.proxies.len(), report.skipped);
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let (mut open, mut refused, mut timed) = (0, 0, 0);
        for p in &report.proxies {
            let ep = format!("{}:{}", p.host, p.port);
            let res = runtime.block_on(async {
                tokio::time::timeout(
                    Duration::from_secs(4),
                    tokio::net::TcpStream::connect(&ep),
                )
                .await
            });
            match res {
                Ok(Ok(_)) => {
                    open += 1;
                    println!("  OPEN  {:<8} {}", p.proto, ep);
                }
                Ok(Err(_)) => refused += 1,
                Err(_) => timed += 1,
            }
        }
        println!("\ntcp-open {open}  refused {refused}  timeout {timed}");
        return;
    }

    if mode == "check" {
        let path = args.next().expect("usage: scan_probe check <links.txt>");
        let text = std::fs::read_to_string(&path).expect("read links");
        let report = links::parse_many(&text, "");
        println!(
            "parsed {} links ({} skipped)",
            report.proxies.len(),
            report.skipped
        );
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let mut ok = 0;
        for p in &report.proxies {
            runtime.block_on(async {
                let result = engine::check_proxy(
                    p,
                    8000,
                    "https://cp.cloudflare.com/generate_204",
                )
                .await;
                let good = result.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
                if good {
                    ok += 1;
                    println!(
                        "  OK   {:>6} ms  {:<8} {}  {}",
                        result.get("latency").and_then(|v| v.as_i64()).unwrap_or(0),
                        p.proto,
                        p.host,
                        p.name
                    );
                } else {
                    println!(
                        "  FAIL {:<8} {:<24} {}  {}",
                        p.proto,
                        format!("{}:{}", p.host, p.port),
                        result.get("error").and_then(|v| v.as_str()).unwrap_or("?"),
                        p.name
                    );
                }
            });
        }
        println!("\nworking: {ok} / {}", report.proxies.len());
        return;
    }

    let cfg = if mode == "json" {
        let path = args.next().expect("usage: scan_probe json <config.json>");
        let text = std::fs::read_to_string(&path).expect("read config");
        serde_json::from_str::<ScanConfig>(&text).expect("parse config")
    } else {
        let max: usize = args.next().and_then(|v| v.parse().ok()).unwrap_or(1500);
        let check_url = args
            .next()
            .unwrap_or_else(|| "https://cp.cloudflare.com/generate_204".to_string());
        ScanConfig {
            mode: mode.clone(),
            workers: 200,
            timeout_ms: 6000,
            check_url,
            speed_check: false,
            service_check: false,
            anonymity_check: false,
            max_candidates: max,
            protocol_filter: "all".to_string(),
            require_encrypted: false,
            ..Default::default()
        }
    };

    println!(
        "starting scan mode={} workers={} timeout={}ms max_candidates={}",
        cfg.mode, cfg.workers, cfg.timeout_ms, cfg.max_candidates
    );
    scanner::start(cfg);

    let started = std::time::Instant::now();
    loop {
        let state = scanner::poll();
        let running = state.get("running").and_then(|v| v.as_bool()).unwrap_or(false);
        let phase = state.get("phase").and_then(|v| v.as_str()).unwrap_or("");
        let checked = state.get("checked").and_then(|v| v.as_u64()).unwrap_or(0);
        let total = state.get("total").and_then(|v| v.as_u64()).unwrap_or(0);
        let found = state
            .get("found")
            .and_then(|v| v.as_array())
            .map(|a| a.len())
            .unwrap_or(0);
        println!(
            "[{:>4}s] phase={phase:<9} checked={checked}/{total} found={found}",
            started.elapsed().as_secs()
        );
        if !running {
            break;
        }
        std::thread::sleep(Duration::from_secs(2));
    }

    let state = scanner::poll();
    println!("\n--- sources ---");
    if let Some(sources) = state.get("sources").and_then(|v| v.as_array()) {
        for s in sources {
            println!(
                "  {:<70} count={:<6} skipped={}",
                s.get("url").and_then(|v| v.as_str()).unwrap_or("?"),
                s.get("count").and_then(|v| v.as_u64()).unwrap_or(0),
                s.get("skipped").and_then(|v| v.as_u64()).unwrap_or(0),
            );
        }
    }
    println!("\n--- errors ---");
    if let Some(errs) = state.get("errors").and_then(|v| v.as_array()) {
        for e in errs {
            println!("  {}", e.as_str().unwrap_or("?"));
        }
    }

    println!("\n--- alive nodes (latency ms, proto, endpoint) ---");
    if let Some(found) = state.get("found").and_then(|v| v.as_array()) {
        let mut rows: Vec<(i64, String, String)> = found
            .iter()
            .map(|n| {
                (
                    n.get("latency").and_then(|v| v.as_i64()).unwrap_or(99999),
                    n.get("proto").and_then(|v| v.as_str()).unwrap_or("?").to_string(),
                    format!(
                        "{}:{}",
                        n.get("host").and_then(|v| v.as_str()).unwrap_or("?"),
                        n.get("port").and_then(|v| v.as_u64()).unwrap_or(0)
                    ),
                )
            })
            .collect();
        rows.sort();
        for (latency, proto, ep) in &rows {
            println!("  {latency:>6} ms  {proto:<8} {ep}");
        }
        println!("\ntotal alive: {}", rows.len());
    }
}