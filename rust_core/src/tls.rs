use anyhow::{Context, Result};
use once_cell::sync::OnceCell;
use rustls::pki_types::ServerName;
use std::sync::Arc;
use tokio_rustls::TlsConnector;

use crate::util::BoxStream;

static TLS_CONFIG: OnceCell<Arc<rustls::ClientConfig>> = OnceCell::new();
static TLS_INSECURE: OnceCell<Arc<rustls::ClientConfig>> = OnceCell::new();

/// A `CertVerifier` that accepts any chain. Only used for bare-IP proxy nodes:
/// those servers are self-signed almost universally and there is no name to
/// validate, so the connection is still confidential but not authenticated.
#[derive(Debug)]
struct AcceptAny(Arc<rustls::crypto::CryptoProvider>);

impl rustls::client::danger::ServerCertVerifier for AcceptAny {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

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

/// TLS without certificate-chain validation. Used for the *proxy hop* only:
/// public Trojan/VLESS nodes present self-signed or shared certificates (a
/// node advertises `sni=hhcm.hhxaf.cc.cd` but serves a cert for
/// `sg.thephoenixsteam.com`), so strict validation rejects virtually every
/// one. The endpoint is still authenticated by the Trojan password / VLESS
/// UUID; TLS here is obfuscation, not the trust anchor. The outer TLS to the
/// real destination keeps full verification.
pub async fn wrap_insecure(stream: BoxStream, name: &str) -> Result<BoxStream> {
    let cfg = TLS_INSECURE
        .get_or_init(|| {
            let provider = rustls::crypto::ring::default_provider();
            let verifier = AcceptAny(Arc::new(provider.clone()));
            let cfg = rustls::ClientConfig::builder_with_provider(Arc::new(provider))
                .with_safe_default_protocol_versions()
                .expect("ring provider has TLS1.2/1.3 enabled")
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(verifier))
                .with_no_client_auth();
            Arc::new(cfg)
        })
        .clone();
    // The name drives SNI-based routing on the server, so send what the link
    // advertised; a bare IP parses as a valid `ServerName` too.
    let server_name = if let Ok(ip) = name.parse::<std::net::IpAddr>() {
        ServerName::IpAddress(ip.into())
    } else {
        ServerName::try_from(name.to_string())
            .or_else(|_| ServerName::try_from("localhost".to_string()))
            .context("invalid SNI")?
    };
    let connector = TlsConnector::from(cfg);
    let tls = connector.connect(server_name, stream).await.context("tls handshake")?;
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
