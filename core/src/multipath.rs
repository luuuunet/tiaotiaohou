//! 网页隧道同时准备 HTTP/3、HTTP/2、HTTP/1。按最近的握手快慢自动选路，慢的那条在后台让位。

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use http::StatusCode;
use rustls::pki_types::ServerName;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader, BufWriter};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot, watch, Semaphore};
use tokio_rustls::TlsConnector;

use crate::config::Config;
use crate::engine::{self, h2_ping, h2_send, h3_ping, lost, note_ping, relay_h2, relay_h3, Job, PingErr, Step};
use crate::guard::check_target;
use crate::relay::Tunnel;
use crate::stats::Stats;

const HEAD_WAIT: Duration = Duration::from_millis(2500);
const LANE_COOL: Duration = Duration::from_secs(12);
const H1_LANES: usize = 8;

type H3Send = h3::client::SendRequest<h3_quinn::OpenStreams, Bytes>;
type H2Send = h2::client::SendRequest<Bytes>;

enum OpenErr {
    Again,
}

struct Lane {
    ok: AtomicBool,
    until: Mutex<Instant>,
    ewma_ms: AtomicU64,
    fails: AtomicU32,
    prior: u64,
}

impl Lane {
    fn new(prior: u64) -> Self {
        Self {
            ok: AtomicBool::new(true),
            until: Mutex::new(Instant::now()),
            ewma_ms: AtomicU64::new(0),
            fails: AtomicU32::new(0),
            prior,
        }
    }

    fn healthy(&self) -> bool {
        self.ok.load(Ordering::Relaxed)
    }

    fn usable(&self) -> bool {
        if self.healthy() {
            return true;
        }
        let until = self.until.lock().unwrap_or_else(|err| err.into_inner());
        Instant::now() >= *until
    }

    fn rank(&self) -> u64 {
        if !self.usable() {
            return u64::MAX;
        }
        let ewma = self.ewma_ms.load(Ordering::Relaxed);
        let base = if ewma == 0 { self.prior } else { ewma };
        base.saturating_add(u64::from(self.fails.load(Ordering::Relaxed)) * 250)
    }

    fn note_ok(&self, elapsed: Duration) {
        let sample = elapsed.as_millis() as u64;
        let prev = self.ewma_ms.load(Ordering::Relaxed);
        let next = if prev == 0 { sample } else { prev.saturating_mul(3).saturating_add(sample) / 4 };
        self.ewma_ms.store(next, Ordering::Relaxed);
        self.fails.store(0, Ordering::Relaxed);
        self.ok.store(true, Ordering::Relaxed);
    }

    fn note_fail(&self) {
        let n = self.fails.fetch_add(1, Ordering::Relaxed).saturating_add(1);
        if n >= 4 {
            self.cool();
        }
    }

    fn note_hard_fail(&self) {
        self.fails.store(4, Ordering::Relaxed);
        self.cool();
    }

    fn cool(&self) {
        self.ok.store(false, Ordering::Relaxed);
        *self.until.lock().unwrap_or_else(|err| err.into_inner()) = Instant::now() + LANE_COOL;
    }
}

pub(crate) async fn run(
    cfg: &Config,
    jobs: &mut mpsc::Receiver<Job>,
    health: &mut Option<oneshot::Sender<Result<(), String>>>,
    shutdown: &mut watch::Receiver<bool>,
    stats: &Arc<Stats>,
) -> Step {
    let (h3a_tx, h3a_rx) = watch::channel(None::<H3Send>);
    let (h3b_tx, h3b_rx) = watch::channel(None::<H3Send>);
    let (h2a_tx, h2a_rx) = watch::channel(None::<H2Send>);
    let (h2b_tx, h2b_rx) = watch::channel(None::<H2Send>);
    let (first_tx, mut first_rx) = mpsc::channel(4);
    let (auth_tx, mut auth_rx) = watch::channel(false);

    let mut keepers = Vec::new();
    let mut waiting = 0u8;
    if cfg.prefer_h3 {
        waiting += 2;
        keepers.push(tokio::spawn(keep_h3(cfg.clone(), h3a_tx, first_tx.clone(), shutdown.clone(), auth_tx.clone(), stats.clone())));
        keepers.push(tokio::spawn(keep_later(keep_h3(cfg.clone(), h3b_tx, first_tx.clone(), shutdown.clone(), auth_tx.clone(), stats.clone()))));
    }
    waiting += 2;
    keepers.push(tokio::spawn(keep_h2(cfg.clone(), h2a_tx, first_tx.clone(), shutdown.clone(), auth_tx.clone(), stats.clone())));
    keepers.push(tokio::spawn(keep_later(keep_h2(cfg.clone(), h2b_tx, first_tx, shutdown.clone(), auth_tx.clone(), stats.clone()))));

    let mut last_fail = "连接节点失败".to_string();
    let up = loop {
        tokio::select! {
            _ = shutdown.changed() => {
                for task in keepers {
                    task.abort();
                }
                return Step::Shutdown;
            }
            _ = auth_rx.changed() => {
                if *auth_rx.borrow() {
                    for task in keepers {
                        task.abort();
                    }
                    return note_ping(Err(PingErr::Auth), health).unwrap_or(Step::Auth);
                }
            }
            msg = first_rx.recv() => {
                match msg {
                    Some(Ok(())) => break true,
                    Some(Err(PingErr::Auth)) => {
                        for task in keepers {
                            task.abort();
                        }
                        return note_ping(Err(PingErr::Auth), health).unwrap_or(Step::Auth);
                    }
                    Some(Err(PingErr::Fail(message))) => {
                        last_fail = message;
                        waiting = waiting.saturating_sub(1);
                        if waiting == 0 {
                            break false;
                        }
                    }
                    None => break false,
                }
            }
        }
    };
    if !up {
        for task in keepers {
            task.abort();
        }
        let fail = last_fail.clone();
        return note_ping(Err(PingErr::Fail(last_fail)), health).unwrap_or_else(|| lost(fail, false));
    }
    if let Some(step) = note_ping(Ok(()), health) {
        for task in keepers {
            task.abort();
        }
        return step;
    }

    let lanes = Arc::new(Lanes {
        h3: [h3a_rx, h3b_rx],
        h2: [h2a_rx, h2b_rx],
        prefer_h3: cfg.prefer_h3,
        h3_lane: Lane::new(280),
        h2_lane: Lane::new(320),
        h1_lane: Lane::new(480),
        picked: AtomicU8::new(if cfg.prefer_h3 { 0 } else { 255 }),
        stream_picked: AtomicU8::new(255),
        h1: Arc::new(Semaphore::new(H1_LANES)),
    });
    stats.set_phase("up");
    stats.clear_error();
    stats.beat();
    publish(stats, &lanes);

    let step = loop {
        tokio::select! {
            _ = shutdown.changed() => break Step::Shutdown,
            _ = auth_rx.changed() => {
                if *auth_rx.borrow() {
                    break Step::Auth;
                }
            }
            job = jobs.recv() => {
                let Some(job) = job else { break Step::Shutdown };
                publish(stats, &lanes);
                let cfg = cfg.clone();
                let lanes = lanes.clone();
                let stats = stats.clone();
                tokio::spawn(async move {
                    open_spread(cfg, job, lanes, stats).await;
                });
            }
        }
    };
    for task in keepers {
        task.abort();
    }
    step
}

struct Lanes {
    h3: [watch::Receiver<Option<H3Send>>; 2],
    h2: [watch::Receiver<Option<H2Send>>; 2],
    prefer_h3: bool,
    h3_lane: Lane,
    h2_lane: Lane,
    h1_lane: Lane,
    picked: AtomicU8,
    stream_picked: AtomicU8,
    h1: Arc<Semaphore>,
}

fn publish(stats: &Stats, lanes: &Lanes) {
    stats.set_mode(&format!("auto-{}", lanes.label()));
}

enum AttemptFail {
    Skip,
    Unsupported,
    Busy,
    Stop(String),
}

impl Lanes {
    fn h3_up(&self) -> bool {
        self.h3.iter().any(|rx| rx.borrow().is_some())
    }

    fn h2_up(&self) -> bool {
        self.h2.iter().any(|rx| rx.borrow().is_some())
    }

    fn lane(&self, id: u8) -> &Lane {
        match id {
            0 => &self.h3_lane,
            1 => &self.h2_lane,
            _ => &self.h1_lane,
        }
    }

    fn alive(&self, id: u8) -> bool {
        match id {
            0 => self.h3_up() && self.h3_lane.usable(),
            1 => self.h2_up() && self.h2_lane.usable(),
            2 => self.h1_lane.usable(),
            _ => false,
        }
    }

    fn name(id: u8) -> &'static str {
        match id {
            0 => "h3",
            1 => "h2",
            2 => "h1",
            _ => "ws",
        }
    }

    fn schedulable(&self, id: u8) -> bool {
        match id {
            0 => self.h3_up() && self.h3_lane.usable(),
            1 => self.h2_up() && self.h2_lane.usable(),
            2 => self.h1_lane.usable() && self.h1.available_permits() > 0,
            _ => false,
        }
    }

    fn label(&self) -> &'static str {
        if self.web_prefers_h2() {
            return "h2";
        }
        if self.prefer_h3 && self.h3_up() && self.h3_lane.healthy() && !self.web_should_compare() {
            return "h3";
        }
        let picked = self.picked.load(Ordering::Relaxed);
        if self.alive(picked) {
            return Self::name(picked);
        }
        self.order_web().first().copied().map(Self::name).unwrap_or("ws")
    }

    fn commit_web(&self, id: u8, elapsed: Duration) {
        self.lane(id).note_ok(elapsed);
        if self.web_prefers_h2() {
            self.picked.store(1, Ordering::Relaxed);
            return;
        }
        if self.prefer_h3 && self.h3_up() && self.h3_lane.healthy() {
            self.picked.store(0, Ordering::Relaxed);
            return;
        }
        self.picked.store(id, Ordering::Relaxed);
    }

    fn commit_stream(&self, id: u8, elapsed: Duration) {
        self.lane(id).note_ok(elapsed);
        let picked = self.stream_picked.load(Ordering::Relaxed);
        if !self.alive(picked) {
            self.stream_picked.store(id, Ordering::Relaxed);
            return;
        }
        if picked == id {
            return;
        }
        let lane = self.lane(picked);
        let picked_ms = {
            let ewma = lane.ewma_ms.load(Ordering::Relaxed);
            if ewma == 0 { lane.prior } else { ewma }
        };
        let sample = u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX);
        if sample.saturating_add(300) < picked_ms {
            self.stream_picked.store(id, Ordering::Relaxed);
        }
    }

    /// HTTP/3 只是能通，但打开流明显比 HTTP/2 慢时，网页改走 HTTP/2。
    fn web_prefers_h2(&self) -> bool {
        let h3 = self.h3_lane.ewma_ms.load(Ordering::Relaxed);
        let h2 = self.h2_lane.ewma_ms.load(Ordering::Relaxed);
        h2 > 0 && h3 > 0 && h2.saturating_add(80) < h3
    }

    /// 还没比出谁快，或者 HTTP/3 已经偏慢但 HTTP/2 还没样本。这时不要钉死在 HTTP/3。
    fn web_should_compare(&self) -> bool {
        if self.web_prefers_h2() {
            return false;
        }
        let h3 = self.h3_lane.ewma_ms.load(Ordering::Relaxed);
        let h2 = self.h2_lane.ewma_ms.load(Ordering::Relaxed);
        if h3 > 0 && h2 > 0 {
            return false;
        }
        if self.prefer_h3 && h3 > 0 && h3 <= 350 {
            return false;
        }
        true
    }

    fn order_web(&self) -> Vec<u8> {
        if self.web_prefers_h2() {
            return self.fixed(&[1, 0, 2]);
        }
        if self.prefer_h3 {
            return self.fixed(&[0, 1, 2]);
        }
        let mut ids = self.fixed(&[0, 1, 2]);
        ids.sort_by_key(|id| self.lane(*id).rank());
        let picked = self.picked.load(Ordering::Relaxed);
        if let Some(pos) = ids.iter().position(|id| *id == picked) {
            let id = ids.remove(pos);
            ids.insert(0, id);
        }
        ids
    }

    fn order_stream(&self) -> Vec<u8> {
        let mut ids = self.fixed(&[1, 2, 0]);
        let picked = self.stream_picked.load(Ordering::Relaxed);
        if let Some(pos) = ids.iter().position(|id| *id == picked) {
            let id = ids.remove(pos);
            ids.insert(0, id);
        }
        ids
    }

    fn fixed(&self, prefer: &[u8]) -> Vec<u8> {
        prefer.iter().copied().filter(|id| self.schedulable(*id)).collect()
    }
}

fn is_stream(host: &str) -> bool {
    crate::config::is_stream_host(host)
}

async fn open_spread(cfg: Config, job: Job, lanes: Arc<Lanes>, stats: Arc<Stats>) {
    let Job { host, port, reply } = job;
    if let Err(err) = check_target(&host, port) {
        let _ = reply.send(Err(err));
        return;
    }
    if cfg.should_direct_vps(port) {
        crate::vps::open(cfg, host, port, reply).await;
        return;
    }
    let stream = is_stream(&host);
    let order = if stream { lanes.order_stream() } else { lanes.order_web() };
    if order.is_empty() {
        crate::ws::open(cfg, host, port, reply).await;
        return;
    }
    let proven = if stream {
        lanes.lane(order[0]).healthy() && lanes.lane(order[0]).ewma_ms.load(Ordering::Relaxed) > 0
    } else {
        !lanes.web_should_compare() && lanes.lane(order[0]).healthy() && lanes.lane(order[0]).ewma_ms.load(Ordering::Relaxed) > 0
    };
    let leftover = if proven {
        open_in_order(&cfg, &host, port, &order, stream, &lanes, &stats, reply).await
    } else {
        open_raced(&cfg, &host, port, &order, stream, &lanes, &stats, reply).await
    };
    if let Some(reply) = leftover {
        crate::ws::open(cfg, host, port, reply).await;
    }
}

async fn open_in_order(
    cfg: &Config,
    host: &str,
    port: u16,
    order: &[u8],
    stream: bool,
    lanes: &Lanes,
    stats: &Stats,
    reply: oneshot::Sender<Result<Tunnel, String>>,
) -> Option<oneshot::Sender<Result<Tunnel, String>>> {
    let mut reply = Some(reply);
    for (index, id) in order.iter().copied().enumerate() {
        let Some(current) = reply.take() else { return None };
        let started = Instant::now();
        match attempt(lanes, cfg, id, index, host, port).await {
            Ok(tunnel) => {
                finish_open(stream, id, started.elapsed(), lanes, stats, current, tunnel);
                return None;
            }
            Err(AttemptFail::Stop(message)) => {
                let _ = current.send(Err(message));
                return None;
            }
            Err(AttemptFail::Busy) => reply = Some(current),
            Err(AttemptFail::Unsupported) => {
                lanes.lane(id).note_hard_fail();
                reply = Some(current);
            }
            Err(AttemptFail::Skip) => {
                lanes.lane(id).note_fail();
                reply = Some(current);
            }
        }
    }
    reply
}

async fn open_raced(
    cfg: &Config,
    host: &str,
    port: u16,
    order: &[u8],
    stream: bool,
    lanes: &Arc<Lanes>,
    stats: &Stats,
    reply: oneshot::Sender<Result<Tunnel, String>>,
) -> Option<oneshot::Sender<Result<Tunnel, String>>> {
    let mut reply = Some(reply);
    let claimed = Arc::new(AtomicBool::new(false));
    let (tx, mut rx) = mpsc::channel(order.len());
    let mut pending = 0u8;
    for (index, id) in order.iter().copied().enumerate() {
        pending += 1;
        let delay = Duration::from_millis(180) * index as u32;
        let lanes = lanes.clone();
        let cfg = cfg.clone();
        let host = host.to_string();
        let tx = tx.clone();
        let claimed = claimed.clone();
        tokio::spawn(async move {
            if !delay.is_zero() {
                tokio::time::sleep(delay).await;
            }
            if claimed.load(Ordering::Relaxed) {
                let _ = tx.send(RaceOut::Ignored).await;
                return;
            }
            let started = Instant::now();
            let out = match attempt(&lanes, &cfg, id, index, &host, port).await {
                Ok(tunnel) => RaceOut::Ready(tunnel, id, started.elapsed()),
                Err(AttemptFail::Stop(message)) => RaceOut::Stop(message),
                Err(AttemptFail::Busy) => RaceOut::Ignored,
                Err(AttemptFail::Unsupported) => {
                    lanes.lane(id).note_hard_fail();
                    RaceOut::Failed
                }
                Err(AttemptFail::Skip) => {
                    lanes.lane(id).note_fail();
                    RaceOut::Failed
                }
            };
            let _ = tx.send(out).await;
        });
    }
    drop(tx);
    while pending > 0 {
        match rx.recv().await {
            Some(RaceOut::Ready(tunnel, id, elapsed)) => {
                if claimed.swap(true, Ordering::AcqRel) {
                    lanes.lane(id).note_ok(elapsed);
                    drop(tunnel);
                } else if let Some(current) = reply.take() {
                    finish_open(stream, id, elapsed, lanes, stats, current, tunnel);
                    return None;
                }
            }
            Some(RaceOut::Failed) | Some(RaceOut::Ignored) => pending = pending.saturating_sub(1),
            Some(RaceOut::Stop(message)) => {
                if !claimed.swap(true, Ordering::AcqRel) {
                    if let Some(current) = reply.take() {
                        let _ = current.send(Err(message));
                    }
                }
                return None;
            }
            None => break,
        }
    }
    reply
}

fn finish_open(
    stream: bool,
    id: u8,
    elapsed: Duration,
    lanes: &Lanes,
    stats: &Stats,
    reply: oneshot::Sender<Result<Tunnel, String>>,
    tunnel: Tunnel,
) {
    if stream {
        lanes.commit_stream(id, elapsed);
    } else {
        lanes.commit_web(id, elapsed);
    }
    let _ = reply.send(Ok(tunnel));
    publish(stats, lanes);
}

async fn attempt(lanes: &Lanes, cfg: &Config, id: u8, index: usize, host: &str, port: u16) -> Result<Tunnel, AttemptFail> {
    match id {
        0 => match pick(&lanes.h3, index) {
            Some(send) => try_h3(send, cfg, host, port).await,
            None => Err(AttemptFail::Skip),
        },
        1 => match pick(&lanes.h2, index) {
            Some(send) => try_h2(send, cfg, host, port).await,
            None => Err(AttemptFail::Skip),
        },
        _ => try_h1(cfg, host, port, &lanes.h1).await,
    }
}

enum RaceOut {
    Ready(Tunnel, u8, Duration),
    Failed,
    Ignored,
    Stop(String),
}

fn pick<T: Clone>(slots: &[watch::Receiver<Option<T>>], salt: usize) -> Option<T> {
    let ready: Vec<T> = slots.iter().filter_map(|rx| rx.borrow().clone()).collect();
    if ready.is_empty() {
        None
    } else {
        Some(ready[salt % ready.len()].clone())
    }
}

async fn try_h3(mut send_request: H3Send, cfg: &Config, host: &str, port: u16) -> Result<Tunnel, AttemptFail> {
    let opened = tokio::time::timeout(HEAD_WAIT, async {
        let mut stream = send_request
            .send_request(cfg.tcp_request(host, port))
            .await
            .map_err(|_| OpenErr::Again)?;
        stream.send_data(Bytes::from_static(&[0])).await.map_err(|_| OpenErr::Again)?;
        let (send, mut recv) = stream.split();
        let resp = recv.recv_response().await.map_err(|_| OpenErr::Again)?;
        Ok::<_, OpenErr>((send, recv, resp.status()))
    })
    .await;
    let (send, recv, status) = match opened {
        Ok(Ok(value)) => value,
        _ => return Err(AttemptFail::Skip),
    };
    if status == StatusCode::NOT_FOUND || status == StatusCode::METHOD_NOT_ALLOWED {
        return Err(AttemptFail::Unsupported);
    }
    if status == StatusCode::UNAUTHORIZED {
        return Err(AttemptFail::Stop("令牌不对".into()));
    }
    if status != StatusCode::OK {
        return Err(AttemptFail::Stop(format!("出口拒绝: {status}")));
    }
    let (tx, rx) = oneshot::channel();
    tokio::spawn(async move {
        relay_h3(send, recv, tx).await;
    });
    match rx.await {
        Ok(Ok(tunnel)) => Ok(tunnel),
        Ok(Err(message)) => Err(AttemptFail::Stop(message)),
        Err(_) => Err(AttemptFail::Skip),
    }
}

async fn try_h2(mut send_request: H2Send, cfg: &Config, host: &str, port: u16) -> Result<Tunnel, AttemptFail> {
    let (response, mut send) = match send_request.send_request(cfg.tcp_request(host, port), false) {
        Ok(pair) => pair,
        Err(_) => return Err(AttemptFail::Skip),
    };
    if h2_send(&mut send, Bytes::from_static(&[0]), false).await.is_err() {
        return Err(AttemptFail::Skip);
    }
    let resp = match tokio::time::timeout(HEAD_WAIT, response).await {
        Ok(Ok(resp)) => resp,
        _ => return Err(AttemptFail::Skip),
    };
    let status = resp.status();
    if status == StatusCode::NOT_FOUND || status == StatusCode::METHOD_NOT_ALLOWED {
        return Err(AttemptFail::Unsupported);
    }
    if status == StatusCode::UNAUTHORIZED {
        return Err(AttemptFail::Stop("令牌不对".into()));
    }
    if status != StatusCode::OK {
        return Err(AttemptFail::Stop(format!("出口拒绝: {status}")));
    }
    let (tx, rx) = oneshot::channel();
    tokio::spawn(async move {
        relay_h2(send, resp.into_body(), tx).await;
    });
    match rx.await {
        Ok(Ok(tunnel)) => Ok(tunnel),
        Ok(Err(message)) => Err(AttemptFail::Stop(message)),
        Err(_) => Err(AttemptFail::Skip),
    }
}

async fn try_h1(cfg: &Config, host: &str, port: u16, limit: &Arc<Semaphore>) -> Result<Tunnel, AttemptFail> {
    let Ok(permit) = Arc::clone(limit).try_acquire_owned() else {
        return Err(AttemptFail::Busy);
    };
    let addr = match engine::resolve(cfg).await {
        Ok(addr) => addr,
        Err(_) => return Err(AttemptFail::Skip),
    };
    let tcp = match tokio::time::timeout(Duration::from_secs(8), TcpStream::connect(addr)).await {
        Ok(Ok(tcp)) => tcp,
        _ => return Err(AttemptFail::Skip),
    };
    crate::relay::tune(&tcp);
    let name = match ServerName::try_from(cfg.host.clone()) {
        Ok(name) => name,
        Err(_) => return Err(AttemptFail::Skip),
    };
    let tls_cfg = match engine::tls_config(b"http/1.1") {
        Ok(cfg) => cfg,
        Err(_) => return Err(AttemptFail::Skip),
    };
    let tls = match tokio::time::timeout(Duration::from_secs(8), TlsConnector::from(Arc::new(tls_cfg)).connect(name, tcp)).await {
        Ok(Ok(tls)) => tls,
        _ => return Err(AttemptFail::Skip),
    };
    let (read_half, write_half) = tokio::io::split(tls);
    let mut reader = BufReader::new(read_half);
    let mut writer = BufWriter::with_capacity(64 * 1024, write_half);
    let head = format!(
        "POST /rsq/v1/tcp HTTP/1.1\r\nhost: {}\r\nauthorization: Bearer {}\r\nuser-agent: rsq/1\r\nx-rsq-v: 1\r\nx-rsq-host: {host}\r\nx-rsq-port: {port}\r\nx-rsq-exit: {}\r\ncontent-type: application/octet-stream\r\ntransfer-encoding: chunked\r\ncache-control: no-store\r\n\r\n1\r\n\x00\r\n",
        cfg.host, cfg.token, cfg.exit_for(host, port)
    );
    if writer.write_all(head.as_bytes()).await.is_err() || writer.flush().await.is_err() {
        return Err(AttemptFail::Skip);
    }
    let (status, chunked) = match tokio::time::timeout(HEAD_WAIT, read_head(&mut reader)).await {
        Ok(Ok(value)) => value,
        _ => return Err(AttemptFail::Skip),
    };
    if status == StatusCode::NOT_FOUND || status == StatusCode::METHOD_NOT_ALLOWED {
        return Err(AttemptFail::Unsupported);
    }
    if status == StatusCode::UNAUTHORIZED {
        return Err(AttemptFail::Stop("令牌不对".into()));
    }
    if status != StatusCode::OK {
        return Err(AttemptFail::Stop(format!("出口拒绝: {status}")));
    }
    let (up_tx, mut up_rx) = mpsc::channel::<Bytes>(crate::relay::PIPE_QUEUE);
    let (down_tx, down_rx) = mpsc::channel::<Bytes>(crate::relay::PIPE_QUEUE);
    let tunnel = Tunnel { tx: up_tx, rx: down_rx };
    tokio::spawn(async move {
        let _permit = permit;
        let upload = async {
            while let Some(chunk) = up_rx.recv().await {
                let small = chunk.len() < 16 * 1024;
                if write_chunk(&mut writer, &chunk).await.is_err() {
                    break;
                }
                if small && writer.flush().await.is_err() {
                    break;
                }
            }
            let _ = writer.write_all(b"0\r\n\r\n").await;
            let _ = writer.flush().await;
        };
        let download = async {
            if chunked {
                loop {
                    match read_chunk(&mut reader).await {
                        Ok(chunk) if chunk.is_empty() => break,
                        Ok(chunk) => {
                            if down_tx.send(chunk).await.is_err() {
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
            } else {
                let mut buf = vec![0u8; 32 * 1024];
                loop {
                    match reader.read(&mut buf).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            if down_tx.send(Bytes::copy_from_slice(&buf[..n])).await.is_err() {
                                break;
                            }
                        }
                    }
                }
            }
        };
        tokio::pin!(upload);
        tokio::pin!(download);
        tokio::select! {
            _ = &mut upload => {}
            _ = &mut download => {}
        }
    });
    Ok(tunnel)
}

async fn read_head<R: AsyncRead + Unpin>(reader: &mut BufReader<R>) -> Result<(StatusCode, bool), OpenErr> {
    let mut raw = Vec::new();
    loop {
        let n = reader.read_until(b'\n', &mut raw).await.map_err(|_| OpenErr::Again)?;
        if n == 0 || raw.len() > 16384 {
            return Err(OpenErr::Again);
        }
        if raw.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
    }
    let text = String::from_utf8_lossy(&raw);
    let mut lines = text.split("\r\n");
    let status_line = lines.next().unwrap_or("");
    let code = status_line.split_whitespace().nth(1).unwrap_or("0");
    let status = StatusCode::from_u16(code.parse().unwrap_or(0)).unwrap_or(StatusCode::BAD_GATEWAY);
    let chunked = text.to_ascii_lowercase().contains("transfer-encoding: chunked");
    Ok((status, chunked))
}

async fn write_chunk(writer: &mut BufWriter<impl AsyncWrite + Unpin>, data: &[u8]) -> Result<(), ()> {
    if data.is_empty() {
        return Ok(());
    }
    writer.write_all(format!("{:x}\r\n", data.len()).as_bytes()).await.map_err(|_| ())?;
    writer.write_all(data).await.map_err(|_| ())?;
    writer.write_all(b"\r\n").await.map_err(|_| ())?;
    Ok(())
}

async fn read_chunk<R: AsyncRead + Unpin>(reader: &mut BufReader<R>) -> Result<Bytes, ()> {
    let mut line = String::new();
    if reader.read_line(&mut line).await.map_err(|_| ())? == 0 {
        return Err(());
    }
    let size = usize::from_str_radix(line.trim().split(';').next().unwrap_or("0"), 16).map_err(|_| ())?;
    if size == 0 {
        return Ok(Bytes::new());
    }
    if size > 1024 * 1024 {
        return Err(());
    }
    let mut buf = vec![0u8; size];
    reader.read_exact(&mut buf).await.map_err(|_| ())?;
    let mut tail = [0u8; 2];
    reader.read_exact(&mut tail).await.map_err(|_| ())?;
    Ok(Bytes::from(buf))
}

async fn keep_later<F: std::future::Future<Output = ()>>(task: F) {
    tokio::time::sleep(Duration::from_millis(300)).await;
    task.await;
}

async fn keep_h3(
    cfg: Config,
    slot: watch::Sender<Option<H3Send>>,
    first: mpsc::Sender<Result<(), PingErr>>,
    mut shutdown: watch::Receiver<bool>,
    auth: watch::Sender<bool>,
    stats: Arc<Stats>,
) {
    let mut announced = false;
    let mut backoff = Duration::from_secs(1);
    loop {
        if *shutdown.borrow() || *auth.borrow() {
            let _ = slot.send(None);
            return;
        }
        match engine::dial_h3(&cfg).await {
            Err(err) => {
                if !announced {
                    let _ = first.send(Err(PingErr::Fail(err))).await;
                    announced = true;
                }
                if sleep_or_stop(backoff, &mut shutdown, &auth).await {
                    let _ = slot.send(None);
                    return;
                }
                backoff = (backoff * 2).min(Duration::from_secs(15));
            }
            Ok((mut driver, mut send)) => match h3_ping(&mut send, &cfg).await {
                Err(PingErr::Auth) => {
                    let _ = auth.send(true);
                    if !announced {
                        let _ = first.send(Err(PingErr::Auth)).await;
                    }
                    let _ = slot.send(None);
                    return;
                }
                Err(PingErr::Fail(err)) => {
                    if !announced {
                        let _ = first.send(Err(PingErr::Fail(err))).await;
                        announced = true;
                    }
                    if sleep_or_stop(backoff, &mut shutdown, &auth).await {
                        let _ = slot.send(None);
                        return;
                    }
                    backoff = (backoff * 2).min(Duration::from_secs(15));
                }
                Ok(()) => {
                    if !announced {
                        let _ = first.send(Ok(())).await;
                        announced = true;
                    }
                    backoff = Duration::from_secs(1);
                    let _ = slot.send(Some(send.clone()));
                    let mut beat = tokio::time::interval(Duration::from_secs(15));
                    beat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                    beat.tick().await;
                    loop {
                        tokio::select! {
                            _ = shutdown.changed() => {
                                let _ = slot.send(None);
                                return;
                            }
                            _ = beat.tick() => {
                                match h3_ping(&mut send, &cfg).await {
                                    Err(PingErr::Auth) => {
                                        let _ = auth.send(true);
                                        let _ = slot.send(None);
                                        return;
                                    }
                                    Err(_) => break,
                                    Ok(()) => stats.beat(),
                                }
                            }
                            _ = std::future::poll_fn(|cx| driver.poll_close(cx)) => break,
                        }
                    }
                    let _ = slot.send(None);
                }
            },
        }
    }
}

async fn keep_h2(
    cfg: Config,
    slot: watch::Sender<Option<H2Send>>,
    first: mpsc::Sender<Result<(), PingErr>>,
    mut shutdown: watch::Receiver<bool>,
    auth: watch::Sender<bool>,
    stats: Arc<Stats>,
) {
    let mut announced = false;
    let mut backoff = Duration::from_secs(1);
    loop {
        if *shutdown.borrow() || *auth.borrow() {
            let _ = slot.send(None);
            return;
        }
        match engine::dial_h2(&cfg).await {
            Err(err) => {
                if !announced {
                    let _ = first.send(Err(PingErr::Fail(err))).await;
                    announced = true;
                }
                if sleep_or_stop(backoff, &mut shutdown, &auth).await {
                    let _ = slot.send(None);
                    return;
                }
                backoff = (backoff * 2).min(Duration::from_secs(15));
            }
            Ok((mut send, connection)) => {
                let mut driver = tokio::spawn(async move {
                    let _ = connection.await;
                });
                match h2_ping(&mut send, &cfg).await {
                    Err(PingErr::Auth) => {
                        driver.abort();
                        let _ = auth.send(true);
                        if !announced {
                            let _ = first.send(Err(PingErr::Auth)).await;
                        }
                        let _ = slot.send(None);
                        return;
                    }
                    Err(PingErr::Fail(err)) => {
                        driver.abort();
                        if !announced {
                            let _ = first.send(Err(PingErr::Fail(err))).await;
                            announced = true;
                        }
                        if sleep_or_stop(backoff, &mut shutdown, &auth).await {
                            let _ = slot.send(None);
                            return;
                        }
                        backoff = (backoff * 2).min(Duration::from_secs(15));
                    }
                    Ok(()) => {
                        if !announced {
                            let _ = first.send(Ok(())).await;
                            announced = true;
                        }
                        backoff = Duration::from_secs(1);
                        let _ = slot.send(Some(send.clone()));
                        let mut beat = tokio::time::interval(Duration::from_secs(15));
                        beat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                        beat.tick().await;
                        loop {
                            tokio::select! {
                                _ = shutdown.changed() => {
                                    driver.abort();
                                    let _ = slot.send(None);
                                    return;
                                }
                                _ = beat.tick() => {
                                    match h2_ping(&mut send, &cfg).await {
                                        Err(PingErr::Auth) => {
                                            driver.abort();
                                            let _ = auth.send(true);
                                            let _ = slot.send(None);
                                            return;
                                        }
                                        Err(_) => break,
                                        Ok(()) => stats.beat(),
                                    }
                                }
                                _ = &mut driver => break,
                            }
                        }
                        driver.abort();
                        let _ = slot.send(None);
                    }
                }
            }
        }
    }
}

async fn sleep_or_stop(wait: Duration, shutdown: &mut watch::Receiver<bool>, auth: &watch::Sender<bool>) -> bool {
    tokio::select! {
        _ = tokio::time::sleep(wait) => *shutdown.borrow() || *auth.borrow(),
        _ = shutdown.changed() => true,
    }
}
