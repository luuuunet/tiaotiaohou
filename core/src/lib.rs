mod config;
mod dns;
mod fetch_proxy;
mod engine;
mod multipath;
mod guard;
mod http_proxy;
mod relay;
mod socks;
mod stats;
mod vps;
#[cfg(target_os = "macos")]
mod macos_trust;
#[cfg(windows)]
mod windows_trust;
mod ws;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::Ordering;
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use tokio::sync::watch;

use crate::stats::Stats;

struct Server {
    shutdown: watch::Sender<bool>,
    done: Receiver<()>,
    thread: Option<JoinHandle<()>>,
}

static SERVER: Mutex<Option<Server>> = Mutex::new(None);
static STATS: Mutex<Option<Arc<Stats>>> = Mutex::new(None);
static LAST: Mutex<String> = Mutex::new(String::new());
static LAST_C: Mutex<Option<CString>> = Mutex::new(None);

fn stats_handle() -> Arc<Stats> {
    let mut guard = STATS.lock().unwrap_or_else(|err| err.into_inner());
    if guard.is_none() {
        *guard = Some(Arc::new(Stats::default()));
    }
    guard.as_ref().unwrap().clone()
}

fn set_err(message: impl Into<String>) -> i32 {
    *LAST.lock().unwrap_or_else(|err| err.into_inner()) = message.into();
    -1
}

fn clear_err() {
    LAST.lock().unwrap_or_else(|err| err.into_inner()).clear();
}

#[no_mangle]
pub unsafe extern "C" fn rsq_start(config_json: *const c_char) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if config_json.is_null() {
            return set_err("配置是空的");
        }
        let text = unsafe { CStr::from_ptr(config_json) }.to_string_lossy();
        start_inner(&text)
    }));
    match result {
        Ok(code) => code,
        Err(_) => set_err("核心崩溃了"),
    }
}

fn start_inner(json: &str) -> i32 {
    let cfg = match config::Config::parse(json) {
        Ok(cfg) => cfg,
        Err(err) => return set_err(err),
    };
    let mut server = SERVER.lock().unwrap_or_else(|err| err.into_inner());
    if let Some(existing) = server.as_mut() {
        let _ = existing.shutdown.send(true);
        let _ = existing.done.recv_timeout(Duration::from_secs(3));
        if let Some(thread) = existing.thread.take() {
            let _ = thread.join();
        }
    }
    *server = None;

    let stats = stats_handle();
    let epoch = crate::stats::EPOCH.fetch_add(1, Ordering::SeqCst) + 1;
    stats.set_phase("starting");
    stats.clear_error();
    stats.set_mode("");
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let (done_tx, done_rx) = mpsc::channel();
    let thread_stats = stats.clone();
    let thread = std::thread::Builder::new()
        .name("rsq".into())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
                Ok(runtime) => runtime,
                Err(err) => {
                    thread_stats.set_error(format!("运行时启动失败: {err}"));
                    if crate::stats::EPOCH.load(Ordering::SeqCst) == epoch {
                        thread_stats.set_phase("down");
                    }
                    let _ = done_tx.send(());
                    return;
                }
            };
            runtime.block_on(engine::run(cfg, thread_stats, shutdown_rx, epoch));
            runtime.shutdown_timeout(Duration::from_secs(1));
            let _ = done_tx.send(());
        });
    let thread = match thread {
        Ok(thread) => thread,
        Err(err) => return set_err(format!("线程启动失败: {err}")),
    };
    *server = Some(Server {
        shutdown: shutdown_tx,
        done: done_rx,
        thread: Some(thread),
    });
    clear_err();
    0
}

#[no_mangle]
pub unsafe extern "C" fn rsq_set_fetch(enabled: i32) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let outcome = if enabled != 0 {
            crate::fetch_proxy::ensure_trusted_ca()
        } else {
            crate::fetch_proxy::remove_trusted_ca()
        };
        match outcome {
            Ok(()) => {
                clear_err();
                0
            }
            Err(err) => set_err(err),
        }
    }));
    match result {
        Ok(code) => code,
        Err(_) => set_err("证书操作失败"),
    }
}

#[no_mangle]
pub unsafe extern "C" fn rsq_stop() -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let mut server = SERVER.lock().unwrap_or_else(|err| err.into_inner());
        if let Some(existing) = server.as_mut() {
            let _ = existing.shutdown.send(true);
            let _ = existing.done.recv_timeout(Duration::from_secs(5));
            if let Some(thread) = existing.thread.take() {
                let _ = thread.join();
            }
        }
        *server = None;
        stats_handle().set_phase("down");
        0
    }));
    result.unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn rsq_stats() -> *const c_char {
    let json = stats_handle().snapshot();
    let c = CString::new(json).unwrap_or_else(|_| CString::new("{}").unwrap());
    let ptr = c.as_ptr();
    *LAST_C.lock().unwrap_or_else(|err| err.into_inner()) = Some(c);
    ptr
}

#[no_mangle]
pub unsafe extern "C" fn rsq_last_error() -> *const c_char {
    let text = LAST.lock().unwrap_or_else(|err| err.into_inner()).clone();
    let c = CString::new(text).unwrap_or_else(|_| CString::new("error").unwrap());
    let ptr = c.as_ptr();
    *LAST_C.lock().unwrap_or_else(|err| err.into_inner()) = Some(c);
    ptr
}
