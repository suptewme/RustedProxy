use serde::Serialize;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

#[derive(Clone, Serialize)]
pub struct LogEntry {
    pub seq: u64,
    pub ts: u64,
    pub level: String,
    pub msg: String,
}

pub struct LogBuffer {
    seq: AtomicU64,
    items: Mutex<VecDeque<LogEntry>>,
    cap: usize,
}

impl LogBuffer {
    pub fn new(cap: usize) -> Self {
        Self { seq: AtomicU64::new(1), items: Mutex::new(VecDeque::with_capacity(cap)), cap }
    }

    pub fn push(&self, level: &str, msg: impl Into<String>) {
        let seq = self.seq.fetch_add(1, Ordering::SeqCst);
        let entry = LogEntry {
            seq,
            ts: crate::util::now_ms(),
            level: level.to_string(),
            msg: msg.into(),
        };
        if let Ok(mut items) = self.items.lock() {
            if items.len() >= self.cap {
                items.pop_front();
            }
            items.push_back(entry);
        }
    }

    pub fn since(&self, after: u64) -> Vec<LogEntry> {
        let items = self.items.lock().unwrap();
        items.iter().filter(|e| e.seq > after).cloned().collect()
    }

    pub fn head(&self) -> u64 {
        self.seq.load(Ordering::SeqCst)
    }

    pub fn clear(&self) {
        if let Ok(mut items) = self.items.lock() {
            items.clear();
        }
    }
}
