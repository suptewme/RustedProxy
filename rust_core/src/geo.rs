use anyhow::{Context, Result};
use maxminddb::geoip2;
use once_cell::sync::OnceCell;
use serde::Serialize;
use std::io::Read;
use std::net::IpAddr;

static GEO: OnceCell<Option<maxminddb::Reader<Vec<u8>>>> = OnceCell::new();

#[derive(Clone, Debug, Serialize, Default)]
pub struct GeoInfo {
    pub code: String,
    pub country: String,
    pub city: String,
    pub asn: String,
    pub flag: String,
}

pub fn init() {
    GEO.get_or_init(|| {
        let gz = include_bytes!("../assets/dbip-country-lite.mmdb.gz");
        let mut decoder = flate2::read::GzDecoder::new(&gz[..]);
        let mut data = Vec::with_capacity(12 * 1024 * 1024);
        if decoder.read_to_end(&mut data).is_err() {
            return None;
        }
        maxminddb::Reader::from_source(data).ok()
    });
}

pub fn lookup_ip(ip: &str) -> Option<GeoInfo> {
    let ip: IpAddr = ip.parse().ok()?;
    // Never waste time on private addresses.
    if crate::util::is_private_ip(ip) {
        return None;
    }
    let reader = GEO.get().and_then(|r| r.as_ref())?;
    let rec: geoip2::Country = reader.lookup(ip).ok().flatten()?;
    let country = rec.country?;
    let code = country.iso_code.unwrap_or("").to_string();
    let name = country
        .names
        .as_ref()
        .and_then(|n| n.get("en").or_else(|| n.get("ru")))
        .copied()
        .unwrap_or("")
        .to_string();
    Some(GeoInfo { flag: flag_for(&code), code, country: name, city: String::new(), asn: String::new() })
}

pub fn flag_for(code: &str) -> String {
    let code = code.trim().to_uppercase();
    if code.len() != 2 || !code.chars().all(|c| c.is_ascii_alphabetic()) {
        return "🌐".to_string();
    }
    let mut out = String::new();
    for ch in code.chars() {
        let cp = 0x1F1E6 + (ch as u32 - 'A' as u32);
        if let Some(c) = char::from_u32(cp) {
            out.push(c);
        }
    }
    out
}

/// Best-effort city lookup via a public JSON endpoint. Used when the user asks
/// for refresh of a single server card; the offline base is country level.
pub async fn city_lookup(ip: &str) -> Result<GeoInfo> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(6))
        .build()?;
    let url = format!("https://ipwho.is/{ip}?fields=success,country,country_code,city,connection");
    let v: serde_json::Value = client.get(url).send().await?.json().await.context("geo json")?;
    if v.get("success").and_then(|x| x.as_bool()) == Some(false) {
        anyhow::bail!("geo lookup failed");
    }
    let code = v.get("country_code").and_then(|x| x.as_str()).unwrap_or("").to_string();
    Ok(GeoInfo {
        flag: flag_for(&code),
        code,
        country: v.get("country").and_then(|x| x.as_str()).unwrap_or("").to_string(),
        city: v.get("city").and_then(|x| x.as_str()).unwrap_or("").to_string(),
        asn: v
            .get("connection")
            .and_then(|c| c.get("isp"))
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string(),
    })
}
