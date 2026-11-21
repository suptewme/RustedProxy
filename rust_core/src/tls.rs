use anyhow::{Context, Result};
use once_cell::sync::OnceCell;
use rustls::pki_types::ServerName;
use std::sync::Arc;
use tokio_rustls::TlsConnector;

use crate::util::BoxStream;

static TLS_CONFIG: OnceCell<Arc<rustls::ClientConfig>> = OnceCell::new();

pub fn config() -> Arc<rustls::ClientConfig> {
    TLS_CONFIG
        .get_or_init(|| {
            let mut roots = rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let cfg = rustls::ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth();
            Arc::new(cfg)
        })
        .clone()
}

pub async fn wrap(stream: BoxStream, server_name: &str) -> Result<BoxStream> {
    let connector = TlsConnector::from(config());
    let name = if let Ok(ip) = server_name.parse::<std::net::IpAddr>() {
        ServerName::IpAddress(ip.into())
    } else {
        ServerName::try_from(server_name.to_string()).context("invalid SNI")?
    };
    let tls = connector.connect(name, stream).await.context("tls handshake")?;
    Ok(Box::new(tls))
}

pub async fn wrap_dns(stream: BoxStream, host: &str) -> Result<BoxStream> {
    // Public DNS endpoints are served under well-known names; this keeps
    // certificate validation working when the user enters a bare IP.
    let sni = match host {
        "1.1.1.1" | "1.0.0.1" => "cloudflare-dns.com",
        "8.8.8.8" | "8.8.4.4" => "dns.google",
        "9.9.9.9" | "149.112.112.112" => "dns.quad9.net",
        "94.140.14.14" | "94.140.15.15" => "dns.adguard-dns.com",
        _ => host,
    };
    wrap(stream, sni).await
}
