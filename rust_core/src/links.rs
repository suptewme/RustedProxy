use crate::proxy::ProxyConfig;
use crate::util::{base64_decode_maybe, split_host_port, url_decode};
use anyhow::{anyhow, Result};
use base64::Engine;
use serde::Serialize;
use std::collections::HashSet;
use url::Url;

#[derive(Serialize)]
pub struct ParseReport {
    pub proxies: Vec<ProxyConfig>,
    pub skipped: usize,
}

pub fn parse_many(text: &str, default_proto: &str) -> ParseReport {
    let mut body = text.trim().trim_start_matches('\u{feff}').to_string();
    // Subscription payloads are frequently base64 encoded as a whole. Real
    // lists often start with a UTF-8 BOM (fetch turns `resp.text()` into a
    // String that keeps it) and sometimes have leading whitespace.
    if !body.contains("://") {
        if let Some(decoded) = base64_decode_maybe(&body) {
            if let Ok(s) = String::from_utf8(decoded) {
                let s = s.trim_start_matches('\u{feff}').trim().to_string();
                if s.contains("://") || s.lines().any(|l| l.contains(':')) {
                    body = s;
                }
            }
        }
    }
    let mut proxies = Vec::new();
    let mut skipped = 0usize;
    let mut seen: HashSet<String> = HashSet::new();
    for raw_line in body.lines() {
        let line = raw_line.trim().trim_start_matches('\u{feff}');
        if line.is_empty() || line.starts_with('#') || line.starts_with("//") {
            continue;
        }
        match parse_line(line, default_proto) {
            Some(p) => {
                let key = format!("{}|{}|{}", p.proto, p.host, p.port);
                if seen.insert(key) {
                    proxies.push(p);
                }
            }
            None => skipped += 1,
        }
    }
    ParseReport { proxies, skipped }
}

pub fn parse_line(line: &str, default_proto: &str) -> Option<ProxyConfig> {
    let line = line.trim();
    if line.contains("://") {
        let l = line.to_lowercase();
        if l.starts_with("ss://") {
            return parse_ss(line);
        }
        if l.starts_with("trojan://") {
            return parse_trojan(line);
        }
        if l.starts_with("vless://") {
            return parse_vless(line);
        }
        if l.starts_with("vmess://") {
            return None; // VMess is out of scope for this core.
        }
        if l.starts_with("hysteria2://") || l.starts_with("hy2://") {
            return None;
        }
        if l.starts_with("socks5://") || l.starts_with("socks://") {
            return parse_plain_url(line, "socks5");
        }
        if l.starts_with("socks4://") || l.starts_with("socks4a://") {
            return parse_plain_url(line, "socks4");
        }
        if l.starts_with("http://") {
            if line.contains('@') {
                return parse_plain_url(line, "http");
            }
            return None;
        }
        if l.starts_with("https://") {
            if line.contains('@') {
                return parse_plain_url(line, "https");
            }
            return None;
        }
        return None;
    }
    if line.contains(':') && !line.contains(' ') {
        let hostport = line.split_once("://").map(|x| x.1).unwrap_or(line);
        let clean = hostport.split('#').next()?.trim();
        if let Ok((host, port)) = split_host_port(clean) {
            if host.is_empty() || port == 0 {
                return None;
            }
            return Some(ProxyConfig {
                id: format!("{default_proto}-{host}-{port}"),
                proto: default_proto.to_string(),
                host,
                port,
                encrypted: default_proto == "https",
                raw: line.to_string(),
                ..Default::default()
            });
        }
    }
    None
}

fn name_from_fragment(parsed: &Url) -> String {
    parsed
        .fragment()
        .map(url_decode)
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn parse_ss(line: &str) -> Option<ProxyConfig> {
    let rest = line.strip_prefix("ss://")?;
    let (body, fragment) = match rest.split_once('#') {
        Some((a, b)) => (a, url_decode(b)),
        None => (rest, String::new()),
    };
    let query_split = body.split_once('?').map(|x| x.0).unwrap_or(body);
    let (userinfo, hostport) = match query_split.rsplit_once('@') {
        Some(v) => v,
        None => {
            // Legacy format: ss://base64(method:password@host:port)
            let decoded = base64_decode_maybe(query_split)?;
            let text = String::from_utf8(decoded).ok()?;
            let (cred, hp) = text.rsplit_once('@')?;
            let (host, port) = split_host_port(hp).ok()?;
            let (method, password) = cred.split_once(':')?;
            let name = if fragment.is_empty() { format!("Shadowsocks {host}") } else { fragment };
            return Some(ProxyConfig {
                id: format!("ss-{host}-{port}"),
                proto: "ss".into(),
                host,
                port,
                password: password.to_string(),
                cipher: method.to_string(),
                encrypted: true,
                name,
                raw: line.to_string(),
                ..Default::default()
            });
        }
    };
    let (host, port) = split_host_port(hostport.trim_matches('/')).ok()?;
    let (method, password) = crate::ss::parse_sip002_password(userinfo).ok()?;
    let name = if fragment.is_empty() { format!("Shadowsocks {host}") } else { fragment };
    Some(ProxyConfig {
        id: format!("ss-{host}-{port}"),
        proto: "ss".into(),
        host,
        port,
        password,
        cipher: method,
        encrypted: true,
        name,
        raw: line.to_string(),
        ..Default::default()
    })
}

fn parse_trojan(line: &str) -> Option<ProxyConfig> {
    let rest = line.strip_prefix("trojan://")?;
    let (body, fragment) = rest
        .split_once('#')
        .map(|(a, b)| (a, url_decode(b)))
        .unwrap_or((rest, String::new()));
    let parsed = Url::parse(&format!("https://{body}")).ok();
    let parsed = parsed?;
    let password = url_decode(parsed.username());
    let host = parsed.host_str()?.to_string();
    let port = parsed.port().unwrap_or(443);
    let params = parsed.query_pairs().into_owned().collect::<std::collections::HashMap<_, _>>();
    let sni = params.get("sni").or_else(|| params.get("peer")).cloned().unwrap_or_else(|| host.clone());
    let name = if fragment.is_empty() { format!("Trojan {host}") } else { fragment };
    Some(ProxyConfig {
        id: format!("trojan-{host}-{port}"),
        proto: "trojan".into(),
        host,
        port,
        password,
        sni,
        tls: true,
        encrypted: true,
        name,
        raw: line.to_string(),
        ..Default::default()
    })
}

fn parse_vless(line: &str) -> Option<ProxyConfig> {
    let rest = line.strip_prefix("vless://")?;
    let (body, fragment) = rest
        .split_once('#')
        .map(|(a, b)| (a, url_decode(b)))
        .unwrap_or((rest, String::new()));
    let parsed = Url::parse(&format!("https://{body}")).ok()?;
    let uuid = parsed.username().to_string().to_lowercase();
    if uuid::Uuid::parse_str(&uuid).is_err() {
        return None;
    }
    let host = parsed.host_str()?.to_string();
    let port = parsed.port().unwrap_or(443);
    let params = parsed.query_pairs().into_owned().collect::<std::collections::HashMap<_, _>>();
    let security = params.get("security").map(|s| s.to_lowercase()).unwrap_or_default();
    if security == "reality" {
        // REALITY needs the XTLS/uTLS handshake which this core does not ship.
        return None;
    }
    let tls = matches!(security.as_str(), "tls" | "xtls");
    let sni = params
        .get("sni")
        .or_else(|| params.get("host"))
        .cloned()
        .unwrap_or_else(|| host.clone());
    let name = if fragment.is_empty() { format!("VLESS {host}") } else { fragment };
    Some(ProxyConfig {
        id: format!("vless-{host}-{port}"),
        proto: "vless".into(),
        host,
        port,
        uuid,
        sni,
        tls,
        encrypted: tls,
        name,
        raw: line.to_string(),
        ..Default::default()
    })
}

fn parse_plain_url(line: &str, proto: &str) -> Option<ProxyConfig> {
    let parsed = Url::parse(line).ok()?;
    let host = parsed.host_str()?.to_string();
    let port = parsed.port()?;
    Some(ProxyConfig {
        id: format!("{proto}-{host}-{port}"),
        proto: proto.to_string(),
        host,
        port,
        username: url_decode(parsed.username()),
        password: url_decode(parsed.password().unwrap_or("")),
        encrypted: proto == "https",
        tls: proto == "https",
        sni: parsed.host_str().unwrap_or("").to_string(),
        name: parsed.fragment().map(url_decode).unwrap_or_default(),
        raw: line.to_string(),
        ..Default::default()
    })
}

pub fn build_link(p: &ProxyConfig) -> Result<String> {
    let fragment = percent_encoding::utf8_percent_encode(
        &p.name,
        percent_encoding::NON_ALPHANUMERIC,
    )
    .to_string();
    match p.proto.to_lowercase().as_str() {
        "ss" => {
            let creds = format!("{}:{}", p.cipher, p.password);
            let encoded = base64::engine::general_purpose::STANDARD.encode(creds);
            Ok(format!("ss://{}@{}:{}#{}", encoded, p.host, p.port, fragment))
        }
        "trojan" => Ok(format!(
            "trojan://{}@{}:{}?sni={}&security=tls#{}",
            urlencoding(&p.password),
            p.host,
            p.port,
            urlencoding(if p.sni.is_empty() { &p.host } else { &p.sni }),
            fragment
        )),
        "vless" => Ok(format!(
            "vless://{}@{}:{}?encryption=none&security={}&sni={}&type=tcp#{}",
            p.uuid,
            p.host,
            p.port,
            if p.tls { "tls" } else { "none" },
            urlencoding(if p.sni.is_empty() { &p.host } else { &p.sni }),
            fragment
        )),
        "socks5" | "socks4" | "http" | "https" => {
            let auth = if p.username.is_empty() {
                String::new()
            } else {
                format!("{}:{}@", urlencoding(&p.username), urlencoding(&p.password))
            };
            Ok(format!("{}://{}{}:{}#{}", p.proto, auth, p.host, p.port, fragment))
        }
        other => Err(anyhow!("cannot build link for {other}")),
    }
}

fn urlencoding(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
}
