use aes::{Aes128, Aes192, Aes256};
use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes128Gcm, Aes256Gcm};
use anyhow::{anyhow, bail, Context, Result};
use ctr::cipher::KeyIvInit;
use ctr::cipher::StreamCipher as _;
use chacha20poly1305::ChaCha20Poly1305;
use hkdf::Hkdf;
use md5::{Digest as Md5Digest, Md5};
use sha1::Sha1;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::util::{BoxStream, Target};

/// Encodes the Shadowsocks destination header: `[ATYP][ADDR][PORT]`. This must
/// be the very first plaintext written through the tunnel; without it the
/// server has no destination and treats the following HTTP request as a
/// malformed address.
fn address_header(target: &Target) -> Vec<u8> {
    let mut out = Vec::new();
    match target {
        Target::Domain(h, p) => {
            out.push(3);
            out.push(h.len() as u8);
            out.extend_from_slice(h.as_bytes());
            out.extend_from_slice(&p.to_be_bytes());
        }
        Target::Ip(std::net::IpAddr::V4(ip), p) => {
            out.push(1);
            out.extend_from_slice(&ip.octets());
            out.extend_from_slice(&p.to_be_bytes());
        }
        Target::Ip(std::net::IpAddr::V6(ip), p) => {
            out.push(4);
            out.extend_from_slice(&ip.octets());
            out.extend_from_slice(&p.to_be_bytes());
        }
    }
    out
}

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

/// AES-CFB128 built on the raw block cipher. The `cfb-mode` crate mixes the
/// IV into the first feedback block, which makes encrypt/decrypt states
/// asymmetric and non-interoperable with standard CFB128; doing it by hand is
/// ~30 lines and exactly matches the Shadowsocks reference implementation.
struct Cfb128<C: aes::cipher::BlockEncrypt> {
    cipher: C,
    /// Next feedback block (encrypted keystream block).
    keystream: [u8; 16],
    /// Register fed back after each block; equals the last ciphertext block.
    feedback: [u8; 16],
    pos: usize,
}

impl<C: aes::cipher::BlockEncrypt + aes::cipher::KeyInit> Cfb128<C> {
    fn new(key: &[u8], iv: [u8; 16]) -> Result<Self> {
        let cipher = C::new_from_slice(key).map_err(|_| anyhow!("bad ss key"))?;
        Ok(Self { cipher, keystream: iv, feedback: iv, pos: 0 })
    }

    fn encrypt(&mut self, data: &mut [u8]) {
        for byte in data.iter_mut() {
            if self.pos == 0 {
                let mut block = aes::cipher::Block::<C>::clone_from_slice(&self.keystream);
                self.cipher.encrypt_block(&mut block);
                self.keystream.copy_from_slice(&block);
            }
            let k = self.keystream[self.pos];
            *byte ^= k;
            self.feedback[self.pos] = *byte;
            self.pos += 1;
            if self.pos == 16 {
                self.pos = 0;
                self.keystream = self.feedback;
            }
        }
    }

    fn decrypt(&mut self, data: &mut [u8]) {
        for byte in data.iter_mut() {
            if self.pos == 0 {
                let mut block = aes::cipher::Block::<C>::clone_from_slice(&self.keystream);
                self.cipher.encrypt_block(&mut block);
                self.keystream.copy_from_slice(&block);
            }
            let k = self.keystream[self.pos];
            let cipher_byte = *byte;
            *byte ^= k;
            self.feedback[self.pos] = cipher_byte;
            self.pos += 1;
            if self.pos == 16 {
                self.pos = 0;
                self.keystream = self.feedback;
            }
        }
    }
}

/// Legacy (pre-AEAD) Shadowsocks stream ciphers. Roughly 40% of the nodes in
/// the big public subscription lists still use them, and dropping the whole
/// stream on an unknown name was one of the reasons the scan came back empty.
enum StreamCipher {
    /// AES-*-CFB128: a 16-byte IV prefix, then a stateful stream.
    Cfb128E(Box<Cfb128<Aes128>>),
    Cfb128D(Box<Cfb128<Aes128>>),
    Cfb192E(Box<Cfb128<Aes192>>),
    Cfb192D(Box<Cfb128<Aes192>>),
    Cfb256E(Box<Cfb128<Aes256>>),
    Cfb256D(Box<Cfb128<Aes256>>),
    /// AES-*-CTR with a random IV prefix (symmetric).
    Ctr128(Box<ctr::Ctr128BE<Aes128>>),
    Ctr192(Box<ctr::Ctr128BE<Aes192>>),
    Ctr256(Box<ctr::Ctr128BE<Aes256>>),
    /// RC4-MD5: key = MD5(master || IV), IV is the first 16 bytes on the wire.
    Rc4Md5(Box<rc4::Rc4<rc4::consts::U16>>),
}

impl StreamCipher {
    /// `encrypt` only matters for CFB (the feedback differs by direction).
    fn new(name: &str, master: &[u8], iv: [u8; 16], encrypt: bool) -> Result<Self> {
        let n = name.to_lowercase();
        let key_err = |_| anyhow!("bad ss key");
        Ok(match n.as_str() {
            "aes-128-cfb" => {
                let c = Cfb128::<Aes128>::new(master, iv)?;
                if encrypt { StreamCipher::Cfb128E(Box::new(c)) } else { StreamCipher::Cfb128D(Box::new(c)) }
            }
            "aes-192-cfb" => {
                let c = Cfb128::<Aes192>::new(master, iv)?;
                if encrypt { StreamCipher::Cfb192E(Box::new(c)) } else { StreamCipher::Cfb192D(Box::new(c)) }
            }
            "aes-256-cfb" => {
                let c = Cfb128::<Aes256>::new(master, iv)?;
                if encrypt { StreamCipher::Cfb256E(Box::new(c)) } else { StreamCipher::Cfb256D(Box::new(c)) }
            }
            "aes-128-ctr" => StreamCipher::Ctr128(Box::new(
                KeyIvInit::new_from_slices(master, &iv).map_err(key_err)?,
            )),
            "aes-192-ctr" => StreamCipher::Ctr192(Box::new(
                KeyIvInit::new_from_slices(master, &iv).map_err(key_err)?,
            )),
            "aes-256-ctr" => StreamCipher::Ctr256(Box::new(
                KeyIvInit::new_from_slices(master, &iv).map_err(key_err)?,
            )),
            "rc4-md5" => {
                let mut hasher = Md5::new();
                hasher.update(master);
                hasher.update(iv);
                let mut key = [0u8; 16];
                key.copy_from_slice(&hasher.finalize());
                StreamCipher::Rc4Md5(Box::new(
                    rc4::Rc4::<rc4::consts::U16>::new_from_slice(&key).map_err(key_err)?,
                ))
            }
            other => bail!("шифр Shadowsocks не поддерживается: {other}"),
        })
    }

    fn apply(&mut self, data: &mut [u8]) -> Result<()> {
        match self {
            StreamCipher::Cfb128E(c) => c.encrypt(data),
            StreamCipher::Cfb128D(c) => c.decrypt(data),
            StreamCipher::Cfb192E(c) => c.encrypt(data),
            StreamCipher::Cfb192D(c) => c.decrypt(data),
            StreamCipher::Cfb256E(c) => c.encrypt(data),
            StreamCipher::Cfb256D(c) => c.decrypt(data),
            StreamCipher::Ctr128(c) => c.apply_keystream(data),
            StreamCipher::Ctr192(c) => c.apply_keystream(data),
            StreamCipher::Ctr256(c) => c.apply_keystream(data),
            StreamCipher::Rc4Md5(c) => c.apply_keystream(data),
        }
        Ok(())
    }

    fn is_stream(name: &str) -> bool {
        matches!(
            name.to_lowercase().as_str(),
            "aes-128-cfb" | "aes-192-cfb" | "aes-256-cfb"
                | "aes-128-ctr" | "aes-192-ctr" | "aes-256-ctr"
                | "rc4-md5"
        )
    }

    fn key_len(name: &str) -> Result<usize> {
        Ok(match name.to_lowercase().as_str() {
            "aes-128-cfb" | "aes-128-ctr" | "rc4-md5" => 16,
            "aes-192-cfb" | "aes-192-ctr" => 24,
            "aes-256-cfb" | "aes-256-ctr" => 32,
            other => bail!("шифр Shadowsocks не поддерживается: {other}"),
        })
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

/// Wraps a TCP stream into a Shadowsocks stream (AEAD or legacy) and sends the
/// destination header first.
pub async fn wrap(
    stream: BoxStream,
    password: &str,
    cipher_name: &str,
    target: &Target,
) -> Result<BoxStream> {
    let mut wrapped = if StreamCipher::is_stream(cipher_name) {
        wrap_stream(stream, password, cipher_name).await?
    } else {
        wrap_aead(stream, password, cipher_name).await?
    };
    wrapped.write_all(&address_header(target)).await?;
    wrapped.flush().await?;
    Ok(wrapped)
}

async fn wrap_stream(stream: BoxStream, password: &str, cipher_name: &str) -> Result<BoxStream> {
    let key_len = StreamCipher::key_len(cipher_name)?;
    let master = master_key(password, key_len);
    let name = cipher_name.to_string();

    let iv = crate::util::random_bytes(16);
    let mut iv_arr = [0u8; 16];
    iv_arr.copy_from_slice(&iv);
    let mut enc = StreamCipher::new(&name, &master, iv_arr, true)?;

    let (mut reader, mut writer) = tokio::io::split(stream);
    writer.write_all(&iv).await?;
    writer.flush().await?;

    let (plain_tx, mut plain_rx) = tokio::io::duplex(128 * 1024);
    let (mut clear_tx, clear_rx) = tokio::io::duplex(128 * 1024);

    tokio::spawn(async move {
        let mut buf = vec![0u8; 16 * 1024];
        loop {
            let n = match plain_rx.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            if enc.apply(&mut buf[..n]).is_err() {
                break;
            }
            if writer.write_all(&buf[..n]).await.is_err() {
                break;
            }
        }
        let _ = writer.flush().await;
        let _ = writer.shutdown().await;
    });

    let master_for_reader = master.clone();
    let name_for_reader = name.clone();
    tokio::spawn(async move {
        let mut server_iv = [0u8; 16];
        if reader.read_exact(&mut server_iv).await.is_err() {
            return;
        }
        let Ok(mut dec) = StreamCipher::new(&name_for_reader, &master_for_reader, server_iv, false) else {
            return;
        };
        let mut buf = vec![0u8; 16 * 1024];
        loop {
            match reader.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if dec.apply(&mut buf[..n]).is_err() {
                        break;
                    }
                    if clear_tx.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
            }
        }
        let _ = clear_tx.shutdown().await;
    });

    Ok(Box::new(tokio::io::join(clear_rx, plain_tx)))
}

async fn wrap_aead(stream: BoxStream, password: &str, cipher_name: &str) -> Result<BoxStream> {
    let key_len = Cipher::key_len(cipher_name)?;
    let master = master_key(password, key_len);
    let salt = crate::util::random_bytes(key_len);
    let (mut reader, mut writer) = tokio::io::split(stream);

    writer.write_all(&salt).await?;
    writer.flush().await?;

    let client_key = subkey(&master, &salt, key_len)?;
    let client_cipher = Cipher::from_name(cipher_name, &client_key)?;

    // Plaintext pipes between the caller and the encryption tasks.
    let (plain_tx, mut plain_rx) = tokio::io::duplex(128 * 1024);
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
    // The userinfo is standard base64 (`...Nz0=`), so the trailing padding has
    // to be kept: stripping it makes every SIP002 link fail to decode.
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(userinfo)
        .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(userinfo))
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(userinfo))
        .or_else(|_| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(userinfo))
        .context("ss: bad userinfo")?;
    let text = String::from_utf8(decoded)?;
    let (method, pass) = text.split_once(':').ok_or_else(|| anyhow!("ss: bad userinfo"))?;
    Ok((method.to_string(), pass.to_string()))
}
#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(name: &str, password: &str, payload: &[u8]) {
        let key_len = StreamCipher::key_len(name).unwrap();
        let master = master_key(password, key_len);
        let iv = [7u8; 16];
        let mut enc = StreamCipher::new(name, &master, iv, true).unwrap();
        let mut dec = StreamCipher::new(name, &master, iv, false).unwrap();
        let mut a = payload.to_vec();
        enc.apply(&mut a).unwrap();
        let mut b = a.clone();
        dec.apply(&mut b).unwrap();
        assert_eq!(b, payload, "{name} round-trip");
        assert_ne!(a, payload, "{name} must actually encrypt");
    }

    #[test]
    fn legacy_stream_ciphers_round_trip() {
        let data = b"ss legacy cipher test payload, longer than one block so the CFB state matters.";
        for name in [
            "aes-128-cfb",
            "aes-192-cfb",
            "aes-256-cfb",
            "aes-128-ctr",
            "aes-192-ctr",
            "aes-256-ctr",
            "rc4-md5",
        ] {
            roundtrip(name, "secret-password", data);
        }
    }

    #[test]
    fn all_public_list_methods_have_a_path() {
        // Every method seen in the big public subscription lists must be
        // accepted by one of the two backends; unknown names must fail loudly.
        for name in [
            "aes-256-gcm",
            "aes-128-gcm",
            "chacha20-ietf-poly1305",
            "chacha20-poly1305",
            "aes-256-cfb",
            "aes-128-cfb",
            "aes-192-cfb",
            "aes-256-ctr",
            "rc4-md5",
        ] {
            assert!(
                Cipher::key_len(name).is_ok() || StreamCipher::is_stream(name),
                "{name} must be dialable"
            );
        }
        for name in ["2022-blake3-aes-256-gcm", "aes-256-cfb8", "plain"] {
            assert!(Cipher::key_len(name).is_err() && !StreamCipher::is_stream(name));
        }
    }

    #[test]
    fn cfb128_matches_nist_vector() {
        // NIST SP 800-38A, F.3.13 CFB128-AES128.
        let key = hex::decode("2b7e151628aed2a6abf7158809cf4f3c").unwrap();
        let iv: [u8; 16] = hex::decode("000102030405060708090a0b0c0d0e0f")
            .unwrap()
            .try_into()
            .unwrap();
        let plain = hex::decode(
            "6bc1bee22e409f96e93d7e117393172a\
             ae2d8a571e03ac9c9eb76fac45af8e51\
             30c81c46a35ce411e5fbc1191a0a52ef\
             f69f2445df4f9b17ad2b417be66c3710",
        )
        .unwrap();
        let expected = hex::decode(
            "3b3fd92eb72dad20333449f8e83cfb4a\
             c8a64537a0b3a93fcde3cdad9f1ce58b\
             26751f67a3cbb140b1808cf187a4f4df\
             c04b05357c5d1c0eeac4c66f9ff7f2e6",
        )
        .unwrap();

        let mut enc = Cfb128::<Aes128>::new(&key, iv).unwrap();
        let mut buf = plain.clone();
        enc.encrypt(&mut buf);
        assert_eq!(hex::encode(&buf), hex::encode(&expected));

        let mut dec = Cfb128::<Aes128>::new(&key, iv).unwrap();
        dec.decrypt(&mut buf);
        assert_eq!(hex::encode(&buf), hex::encode(&plain));
    }

    #[test]
    fn cfb_state_survives_partial_buffers() {
        // Real streams arrive in odd-sized chunks; the CFB register must carry
        // over between calls, otherwise every >=16-byte chunk is garbage.
        let key = hex::decode("2b7e151628aed2a6abf7158809cf4f3c").unwrap();
        let iv = [0u8; 16];
        let plain: Vec<u8> = (0..200u16).map(|i| i as u8).collect();

        let mut whole = Cfb128::<Aes128>::new(&key, iv).unwrap();
        let mut whole_ct = plain.clone();
        whole.encrypt(&mut whole_ct);

        let mut split = Cfb128::<Aes128>::new(&key, iv).unwrap();
        let mut split_ct = plain.clone();
        for chunk in split_ct.chunks_mut(7) {
            split.encrypt(chunk);
        }
        assert_eq!(whole_ct, split_ct);

        let mut dec = Cfb128::<Aes128>::new(&key, iv).unwrap();
        let mut dec_pt = split_ct.clone();
        for chunk in dec_pt.chunks_mut(5) {
            dec.decrypt(chunk);
        }
        assert_eq!(dec_pt, plain);
    }

    #[test]
    fn sip002_userinfo_from_public_lists_decodes() {
        // Real link from V2RayAggregator/sub_merge.txt. The trailing `=` is
        // part of the standard base64 alphabet and must not be stripped.
        let (method, pass) = parse_sip002_password(
            "YWVzLTI1Ni1nY206WlJwZ2FCZUd4dEVOSVhndmhwa1pCS3o5R25XUlMyZFljeDlPK2EyaXdOND0=",
        )
        .unwrap();
        assert_eq!(method, "aes-256-gcm");
        assert!(!pass.is_empty());
        // URL-safe variant (no padding) from another list.
        let (m2, p2) = parse_sip002_password("YWVzLTEyOC1nY206c2hhZG93c29ja3M").unwrap();
        assert_eq!(m2, "aes-128-gcm");
        assert_eq!(p2, "shadowsocks");
    }

    #[tokio::test]
    async fn aead_wrap_round_trips_across_many_frames() {
        // Drives `ss::wrap` over an echoing duplex pair. The payload is larger
        // than 0x3FFF so the AEAD path has to emit several length/payload
        // frames and keep the nonce counter in step across reads that split
        // frames at arbitrary boundaries.
        let target = crate::util::Target::domain("example.com", 80);
        let hdr_len = address_header(&target).len();
        for cipher in ["aes-256-gcm", "aes-128-gcm", "chacha20-ietf-poly1305"] {
            let (client, server) = tokio::io::duplex(64 * 1024);
            let echo = tokio::spawn(async move {
                let (mut r, mut w) = tokio::io::split(server);
                tokio::io::copy(&mut r, &mut w).await.ok();
            });
            let mut s = wrap(Box::new(client), "hunter2", cipher, &target).await.unwrap();
            // `wrap` already queued the address header; drop its echo so the
            // comparison below only sees the payload we send.
            let mut header = vec![0u8; hdr_len];
            tokio::io::AsyncReadExt::read_exact(&mut s, &mut header)
                .await
                .unwrap();
            assert_eq!(header, address_header(&target));
            let payload: Vec<u8> = (0..50_000u32).map(|i| (i % 251) as u8).collect();
            tokio::io::AsyncWriteExt::write_all(&mut s, &payload).await.unwrap();
            let mut got = vec![0u8; payload.len()];
            tokio::io::AsyncReadExt::read_exact(&mut s, &mut got).await.unwrap();
            assert_eq!(got, payload, "{cipher} round-trip");
            echo.abort();
        }
    }

    #[test]
    fn master_key_is_md5_chain() {
        // Reference value for the standard EVP_BytesToKey chain.
        let key = master_key("password", 32);
        let first = Md5::digest(b"password");
        assert_eq!(&key[..16], first.as_slice());
        let second = Md5::digest(&[first.as_slice(), b"password"].concat());
        assert_eq!(&key[16..], second.as_slice());
    }
}
