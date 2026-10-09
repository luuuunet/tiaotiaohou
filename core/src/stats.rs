use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;

pub static EPOCH: AtomicU64 = AtomicU64::new(0);

#[derive(Default)]
pub struct Stats {
    pub bytes_up: AtomicU64,
    pub bytes_down: AtomicU64,
    pub active: AtomicU32,
    pub tunnels: AtomicU64,
    pub beats: AtomicU64,
    pub mode: Mutex<String>,
    pub phase: Mutex<String>,
    pub error: Mutex<String>,
    pub socks_port: AtomicU32,
    pub http_port: AtomicU32,
    pub running: Mutex<bool>,
}

impl Stats {
    pub fn set_mode(&self, mode: &str) {
        *self.mode.lock().unwrap_or_else(|e| e.into_inner()) = mode.to_string();
    }

    pub fn set_phase(&self, phase: &str) {
        *self.phase.lock().unwrap_or_else(|e| e.into_inner()) = phase.to_string();
        *self.running.lock().unwrap_or_else(|e| e.into_inner()) =
            matches!(phase, "up" | "reconnecting");
    }

    pub fn beat(&self) {
        self.beats.fetch_add(1, Ordering::Relaxed);
    }

    pub fn set_error(&self, error: impl Into<String>) {
        *self.error.lock().unwrap_or_else(|e| e.into_inner()) = error.into();
    }

    pub fn clear_error(&self) {
        self.set_error("");
    }

    pub fn add_up(&self, n: u64) {
        self.bytes_up.fetch_add(n, Ordering::Relaxed);
    }

    pub fn add_down(&self, n: u64) {
        self.bytes_down.fetch_add(n, Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> String {
        let mode = self.mode.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let phase = self.phase.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let error = self.error.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let running = *self.running.lock().unwrap_or_else(|e| e.into_inner());
        serde_json::json!({
            "running": running,
            "phase": if phase.is_empty() { "down" } else { phase.as_str() },
            "mode": mode,
            "bytes_up": self.bytes_up.load(Ordering::Relaxed),
            "bytes_down": self.bytes_down.load(Ordering::Relaxed),
            "active": self.active.load(Ordering::Relaxed),
            "tunnels": self.tunnels.load(Ordering::Relaxed),
            "beats": self.beats.load(Ordering::Relaxed),
            "socks_port": self.socks_port.load(Ordering::Relaxed),
            "http_port": self.http_port.load(Ordering::Relaxed),
            "error": error,
        })
        .to_string()
    }
}

pub struct Active(std::sync::Arc<Stats>);

impl Active {
    pub fn new(stats: std::sync::Arc<Stats>) -> Self {
        stats.active.fetch_add(1, Ordering::Relaxed);
        stats.tunnels.fetch_add(1, Ordering::Relaxed);
        Self(stats)
    }
}

impl Drop for Active {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::Relaxed);
    }
}
