use anyhow::{anyhow, Result};
use serde_json::{json, Value};

use crate::engine::EngineSettings;

#[cfg(unix)]
mod imp {
    use super::*;
    use crate::engine::ENGINE;
    use std::sync::atomic::Ordering;
    use std::sync::Mutex;
    use tokio::task::JoinHandle;

    struct TunState {
        token: tun2proxy::CancellationToken,
        handle: JoinHandle<()>,
    }

    static TUN: Mutex<Option<TunState>> = Mutex::new(None);

    pub fn start(fd: i32, mtu: u16, settings: &EngineSettings) -> Result<Value> {
        if fd < 0 {
            return Err(anyhow!("некорректный файловый дескриптор TUN"));
        }
        if let Ok(guard) = TUN.lock() {
            if guard.is_some() {
                return Err(anyhow!("TUN уже запущен"));
            }
        }
        let port = ENGINE.port.load(Ordering::SeqCst);
        if port == 0 {
            return Err(anyhow!("сначала запустите сетевое ядро"));
        }
        let mut args = tun2proxy::Args::default();
        args.proxy = tun2proxy::ProxyParameters::try_from(format!("socks5://127.0.0.1:{port}").as_str())
            .map_err(|e| anyhow!("proxy url: {e}"))?;
        args.tun_fd = Some(fd);
        args.close_fd_on_drop = Some(false);
        args.dns = tun2proxy::ArgDns::Virtual;
        args.ipv6_enabled = settings.ipv6_enabled;
        args.mtu = mtu;
        args.setup = false;
        args.verbosity = tun2proxy::LevelFilter::Warn;
        args.tcp_timeout = 900;
        args.udp_timeout = 30;
        args.max_sessions = 512;
        let token = tun2proxy::CancellationToken::new();
        let token2 = token.clone();
        let handle = crate::RUNTIME.spawn(async move {
            if let Err(e) = tun2proxy::general_run_async(args, mtu, false, token2).await {
                ENGINE.log("ERROR", format!("tun2proxy: {e}"));
            }
        });
        *TUN.lock().unwrap() = Some(TunState { token, handle });
        ENGINE.tun_running.store(true, Ordering::SeqCst);
        ENGINE.log("INFO", format!("TUN attached · fd={fd} mtu={mtu} dns=virtual"));
        Ok(json!({"ok": true}))
    }

    pub fn stop() -> Result<Value> {
        if let Some(state) = TUN.lock().unwrap().take() {
            state.token.cancel();
            // `crate::RUNTIME.spawn` works from any thread, while
            // `tokio::spawn` panics when called from a Dart FFI thread.
            crate::RUNTIME.spawn(async move {
                let _ = tokio::time::timeout(std::time::Duration::from_secs(3), state.handle).await;
            });
            ENGINE.tun_running.store(false, Ordering::SeqCst);
            ENGINE.log("INFO", "TUN detached");
        }
        Ok(json!({"ok": true}))
    }

    pub fn running() -> bool {
        ENGINE.tun_running.load(Ordering::SeqCst)
    }
}

#[cfg(not(unix))]
mod imp {
    use super::*;

    pub fn start(_fd: i32, _mtu: u16, _settings: &EngineSettings) -> Result<Value> {
        Err(anyhow!("VPN-режим доступен только на Android"))
    }

    pub fn stop() -> Result<Value> {
        Ok(json!({"ok": true}))
    }

    pub fn running() -> bool {
        false
    }
}

pub use imp::{running, start, stop};
