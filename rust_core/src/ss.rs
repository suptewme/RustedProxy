use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes128Gcm, Aes256Gcm};
use anyhow::{anyhow, bail, Context, Result};
use chacha20poly1305::ChaCha20Poly1305;
use hkdf::Hkdf;
use md5::{Digest as Md5Digest, Md5};
use sha1::Sha1;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::util::BoxStream;

enum Cipher {
    Aes128(Box<Aes128Gcm>),
    Aes256(Box<Aes256Gcm>),
    ChaCha(Box<ChaCha20Poly1305>),
}

impl Cipher {
    fn from_name(name: &str, key: &[u8]) -> Result<Self> {
        let n = name.to_lowercase();
        Ok(match n.as_str() {
            "aes-128-gcm" => Cipher::Aes128(Box::new(Aes128Gcm::new_from_slice(key).map_err(|_| anyhow!("bad key"))?)),
            "aes-256-gcm" => Cipher::Aes256(Box::new(Aes256Gcm::new_from_slice(key).map_err(|_| anyhow!("bad key"))?)),
            "chacha20-ietf-poly1305" | "chacha20-poly1305" => {
                Cipher::ChaCha(Box::new(ChaCha20Poly1305::new_from_slice(key).map_err(|_| anyhow!("bad key"))?))
            }
            other => bail!("шифр Shadowsocks не поддерживается: {other}"),
        })
    }

    fn key_len(name: &str) -> Result<usize> {
        Ok(match name.to_lowercase().as_str() {
            "aes-128-gcm" => 16,
            "aes-256-gcm" | "chacha20-ietf-poly1305" | "chacha20-poly1305" => 32,
            other => bail!("шифр Shadowsocks не поддерживается: {other}"),
        })
    }

    fn nonce(counter: u64) -> [u8; 12] {
        let mut nonce = [0u8; 12];
        nonce[..8].copy_from_slice(&counter.to_le_bytes());
        nonce
    }

    fn seal(&self, counter: u64, plain: &[u8]) -> Result<Vec<u8>> {
        let nonce = Self::nonce(counter);
        let n = aes_gcm::Nonce::from_slice(&nonce);
        let out = match self {
            Cipher::Aes128(c) => c.encrypt(n, plain),
            Cipher::Aes256(c) => c.encrypt(n, plain),
            Cipher::ChaCha(c) => c.encrypt(n, plain),
        };
        out.map_err(|_| anyhow!("ss encrypt failed"))
    }

    fn open(&self, counter: u64, cipher: &[u8]) -> Result<Vec<u8>> {
        let nonce = Self::nonce(counter);
        let n = aes_gcm::Nonce::from_slice(&nonce);
        let out = match self {
            Cipher::Aes128(c) => c.decrypt(n, cipher),
            Cipher::Aes256(c) => c.decrypt(n, cipher),
            Cipher::ChaCha(c) => c.decrypt(n, cipher),
        };
        out.map_err(|_| anyhow!("ss decrypt failed"))
    }
}

fn master_key(password: &str, key_len: usize) -> Vec<u8> {
    let mut key = Vec::new();
    let mut prev: Vec<u8> = Vec::new();
    while key.len() < key_len {
        let mut hasher = Md5::new();
        if !prev.is_empty() {
            hasher.update(&prev);
        }
        hasher.update(password.as_bytes());
        prev = hasher.finalize().to_vec();
        key.extend_from_slice(&prev);
    }
    key.truncate(key_len);
    key
}

fn subkey(master: &[u8], salt: &[u8], key_len: usize) -> Result<Vec<u8>> {
    let hk = Hkdf::<Sha1>::new(Some(salt), master);
    let mut out = vec![0u8; key_len];
    hk.expand(b"ss-subkey", &mut out).map_err(|_| anyhow!("hkdf"))?;
    Ok(out)
}

/// Wraps a TCP stream into a Shadowsocks AEAD stream.
pub async fn wrap(stream: BoxStream, password: &str, cipher_name: &str) -> Result<BoxStream> {
    let key_len = Cipher::key_len(cipher_name)?;
    let master = master_key(password, key_len);
    let salt = crate::util::random_bytes(key_len);
    let (mut reader, mut writer) = tokio::io::split(stream);

    writer.write_all(&salt).await?;
    writer.flush().await?;

    let client_key = subkey(&master, &salt, key_len)?;
    let client_cipher = Cipher::from_name(cipher_name, &client_key)?;

    // Plaintext pipes between the caller and the encryption tasks.
    let (mut plain_tx, mut plain_rx) = tokio::io::duplex(128 * 1024);
    let (mut clear_tx, clear_rx) = tokio::io::duplex(128 * 1024);

    tokio::spawn(async move {
        let mut counter: u64 = 0;
        let mut buf = vec![0u8; 0x3FFF];
        loop {
            let n = match plain_rx.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            let len = (n as u16).to_be_bytes();
            let enc_len = match client_cipher.seal(counter, &len) {
                Ok(v) => v,
                Err(_) => break,
            };
            counter += 1;
            let enc_payload = match client_cipher.seal(counter, &buf[..n]) {
                Ok(v) => v,
                Err(_) => break,
            };
            counter += 1;
            if writer.write_all(&enc_len).await.is_err()
                || writer.write_all(&enc_payload).await.is_err()
                || writer.flush().await.is_err()
            {
                break;
            }
        }
        let _ = writer.shutdown().await;
    });

    let reader_cipher_name = cipher_name.to_string();
    tokio::spawn(async move {
        let mut server_salt = vec![0u8; key_len];
        if reader.read_exact(&mut server_salt).await.is_err() {
            return;
        }
        let Ok(sk) = subkey(&master, &server_salt, key_len) else { return };
        let Ok(cipher) = Cipher::from_name(&reader_cipher_name, &sk) else { return };
        let mut counter: u64 = 0;
        loop {
            let mut enc_len = [0u8; 18];
            if reader.read_exact(&mut enc_len).await.is_err() {
                break;
            }
            let Ok(len_plain) = cipher.open(counter, &enc_len) else { break };
            counter += 1;
            if len_plain.len() != 2 {
                break;
            }
            let len = u16::from_be_bytes([len_plain[0], len_plain[1]]) as usize;
            if len == 0 || len > 0x3FFF {
                break;
            }
            let mut enc_payload = vec![0u8; len + 16];
            if reader.read_exact(&mut enc_payload).await.is_err() {
                break;
            }
            let Ok(payload) = cipher.open(counter, &enc_payload) else { break };
            counter += 1;
            if clear_tx.write_all(&payload).await.is_err() {
                break;
            }
        }
        let _ = clear_tx.shutdown().await;
    });

    Ok(Box::new(tokio::io::join(clear_rx, plain_tx)))
}

pub fn parse_sip002_password(userinfo: &str) -> Result<(String, String)> {
    use base64::Engine;
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(userinfo.trim_end_matches('='))
        .or_else(|_| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(userinfo))
        .context("ss: bad userinfo")?;
    let text = String::from_utf8(decoded)?;
    let (method, pass) = text.split_once(':').ok_or_else(|| anyhow!("ss: bad userinfo"))?;
    Ok((method.to_string(), pass.to_string()))
}
