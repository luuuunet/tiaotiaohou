use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Once};
use std::time::Duration;

const HEARTBEAT_EVERY: Duration = Duration::from_secs(15);
const OP_TIMEOUT: Duration = Duration::from_secs(12);
const PING_WAIT: Duration = Duration::from_secs(4);
const QUIC_HEAD: Duration = Duration::from_secs(4);
const TUNNEL_IDLE: Duration = Duration::from_secs(90);

use bytes::{Buf, Bytes};
use http::StatusCode;
use rustls::pki_types::ServerName;
use rustls::ClientConfig;
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot, watch};
use tokio_rustls::TlsConnector;

use crate::config::Config;
use crate::guard::check_target;
use crate::http_proxy;
use crate::relay::Tunnel;
use crate::socks;
use crate::stats::Stats;

#[derive(Clone)]
pub struct Engine {
    tx: mpsc::Sender<Job>,
    pub cfg: Config,
}

pub(crate) struct Job {
    pub(crate) host: String,
    pub(crate) port: u16,
    pub(crate) reply: oneshot::Sender<Result<Tunnel, String>>,
}

pub(crate) enum Step {
    Shutdown,
    Auth,
    Lost { message: String, was_up: bool },
}

pub(crate) fn lost(message: impl Into<String>, was_up: bool) -> Step {
    Step::Lost {
        message: message.into(),
        was_up,
    }
}

pub(crate) enum PingErr {
    Auth,
    Fail(String),
}

struct PhaseGuard {
    epoch: u64,
    stats: Arc<Stats>,
}

impl Drop for PhaseGuard {
    fn drop(&mut self) {
        if crate::stats::EPOCH.load(std::sync::atomic::Ordering::SeqCst) == self.epoch {
            self.stats.set_phase("down");
        }
    }
}

pub async fn run(cfg: Config, stats: Arc<Stats>, mut shutdown: watch::Receiver<bool>, epoch: u64) {
    let _phase = PhaseGuard {
        epoch,
        stats: stats.clone(),
    };
    stats.set_phase("starting");
    stats.clear_error();
    if cfg.fetch_enabled {
        if let Err(err) = crate::fetch_proxy::ensure_trusted_ca() {
            stats.set_error(err);
        }
    } else {
        let _ = crate::fetch_proxy::remove_trusted_ca();
    }
    stats.socks_port.store(u32::from(cfg.socks_port), std::sync::atomic::Ordering::Relaxed);
    stats.http_port.store(u32::from(cfg.http_port), std::sync::atomic::Ordering::Relaxed);

    let socks_listener = match tokio::net::TcpListener::bind(("127.0.0.1", cfg.socks_port)).await {
        Ok(listener) => listener,
        Err(err) => {
            stats.set_error(format!("SOCKS 端口 {} 打不开: {err}", cfg.socks_port));
            return;
        }
    };
    let http_listener = match tokio::net::TcpListener::bind(("127.0.0.1", cfg.http_port)).await {
        Ok(listener) => listener,
        Err(err) => {
            stats.set_error(format!("HTTP 端口 {} 打不开: {err}", cfg.http_port));
            return;
        }
    };

    let (tx, rx) = mpsc::channel(256);
    let (health_tx, health_rx) = oneshot::channel();
    let session_stats = stats.clone();
    let session_shutdown = shutdown.clone();
    let session_cfg = cfg.clone();
    tokio::spawn(async move {
        session_loop(session_cfg, rx, health_tx, session_shutdown, session_stats).await;
    });

    match tokio::time::timeout(Duration::from_secs(8), health_rx).await {
        Ok(Ok(Ok(()))) => {
            stats.clear_error();
            stats.set_phase("up");
        }
        Ok(Ok(Err(err))) => {
            stats.set_error(err);
            return;
        }
        _ => {
            stats.set_error("连接节点超时");
            return;
        }
    }

    let engine = Engine { tx, cfg: cfg.clone() };
    tokio::select! {
        _ = socks::serve(socks_listener, engine.clone(), stats.clone(), shutdown.clone()) => {}
        _ = http_proxy::serve(http_listener, engine, stats.clone(), shutdown.clone()) => {}
        _ = shutdown.changed() => {}
    }
}

impl Engine {
    pub async fn open(&self, host: &str, port: u16) -> Result<Tunnel, String> {
        check_target(host, port)?;
        if self.cfg.is_bypass(host) {
            return open_direct(host, port).await;
        }
        let (reply, rx) = oneshot::channel();
        self.tx
            .send(Job {
                host: host.to_string(),
                port,
                reply,
            })
            .await
            .map_err(|_| "核心已停止".to_string())?;
        match tokio::time::timeout(Duration::from_secs(15), rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err("连接被取消".into()),
            Err(_) => Err("连接目标超时".into()),
        }
    }
}

async fn open_direct(host: &str, port: u16) -> Result<Tunnel, String> {
    let host = host.trim_matches(|c| c == '[' || c == ']').to_string();
    let stream = tokio::time::timeout(Duration::from_secs(8), TcpStream::connect((host.as_str(), port)))
        .await
        .map_err(|_| "直连超时".to_string())?
        .map_err(|err| format!("直连失败: {err}"))?;
    Ok(crate::relay::tunnel_from_tcp(stream))
}

async fn session_loop(
    cfg: Config,
    mut jobs: mpsc::Receiver<Job>,
    health_tx: oneshot::Sender<Result<(), String>>,
    mut shutdown: watch::Receiver<bool>,
    stats: Arc<Stats>,
) {
    let mut health = Some(health_tx);
    let mut backoff = Duration::from_secs(1);
    loop {
        if *shutdown.borrow() {
            if let Some(tx) = health.take() {
                let _ = tx.send(Err("已停止".into()));
            }
            return;
        }
        let step = if cfg.exit_via == "vps" {
            run_vps(&cfg, &mut jobs, &mut health, &mut shutdown, &stats).await
        } else {
            crate::multipath::run(&cfg, &mut jobs, &mut health, &mut shutdown, &stats).await
        };
        match step {
            Step::Shutdown | Step::Auth => return,
            Step::Lost { message, was_up } => {
                stats.set_error(message.clone());
                if let Some(tx) = health.take() {
                    let _ = tx.send(Err(message));
                    return;
                }
                stats.set_phase("reconnecting");
                let wait = if was_up { Duration::from_secs(1) } else { backoff };
                backoff = if was_up {
                    Duration::from_secs(1)
                } else {
                    (backoff * 2).min(Duration::from_secs(15))
                };
                // 重连等待期间立刻拒绝新请求，避免浏览器卡在代理上十几秒。
                let deadline = tokio::time::Instant::now() + wait;
                loop {
                    tokio::select! {
                        _ = tokio::time::sleep_until(deadline) => break,
                        _ = shutdown.changed() => return,
                        job = jobs.recv() => {
                            let Some(job) = job else { return };
                            let _ = job.reply.send(Err("节点重连中".into()));
                        }
                    }
                }
            }
        }
    }
}

struct Abort(tokio::task::JoinHandle<()>);
impl Drop for Abort {
    fn drop(&mut self) {
        self.0.abort();
    }
}

async fn run_h3(
    cfg: &Config,
    jobs: &mut mpsc::Receiver<Job>,
    health: &mut Option<oneshot::Sender<Result<(), String>>>,
    shutdown: &mut watch::Receiver<bool>,
    stats: &Arc<Stats>,
) -> Step {
    let dial = async { dial_h3(cfg).await };
    let (mut driver, mut send_request) = tokio::select! {
        result = dial => match result {
            Ok(value) => value,
            Err(err) => return lost(err, false),
        },
        _ = shutdown.changed() => return Step::Shutdown,
    };
    let mut driver = Abort(tokio::spawn(async move {
        let _ = std::future::poll_fn(|cx| driver.poll_close(cx)).await;
    }));
    if let Some(step) = note_ping(h3_ping(&mut send_request, cfg).await, health) {
        return step;
    }
    stats.set_mode("h3");
    stats.set_phase("up");
    stats.clear_error();
    stats.beat();
    let quic_ok = Arc::new(AtomicBool::new(true));
    let mut beat = tokio::time::interval(HEARTBEAT_EVERY);
    beat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    beat.tick().await;
    loop {
        tokio::select! {
            _ = shutdown.changed() => return Step::Shutdown,
            _ = beat.tick() => {
                if let Err(err) = h3_ping(&mut send_request, cfg).await {
                    return ping_lost(err);
                }
                stats.beat();
                stats.clear_error();
            }
            job = jobs.recv() => {
                let Some(job) = job else { return Step::Shutdown };
                // 网页优先复用这条 QUIC 连接。流打不开或对端不收，再退回 WebSocket。
                let cfg = cfg.clone();
                let send = send_request.clone();
                let quic_ok = quic_ok.clone();
                tokio::spawn(async move {
                    open_quic_or_ws(send, cfg, job, quic_ok).await;
                });
            }
            _ = &mut driver.0 => return lost("HTTP/3 连接断了", true),
        }
    }
}

fn spawn_tunnel(cfg: &Config, job: Job) {
    let cfg = cfg.clone();
    tokio::spawn(async move {
        let Job { host, port, reply } = job;
        if cfg.exit_via == "vps" || cfg.should_direct_vps(port) {
            crate::vps::open(cfg, host, port, reply).await;
        } else {
            crate::ws::open(cfg, host, port, reply).await;
        }
    });
}

async fn run_vps(
    cfg: &Config,
    jobs: &mut mpsc::Receiver<Job>,
    health: &mut Option<oneshot::Sender<Result<(), String>>>,
    shutdown: &mut watch::Receiver<bool>,
    stats: &Arc<Stats>,
) -> Step {
    let ping = async { vps_ping(cfg).await };
    let ping = tokio::select! {
        result = ping => result,
        _ = shutdown.changed() => return Step::Shutdown,
    };
    if let Some(step) = note_ping(ping, health) {
        return step;
    }
    stats.set_mode("vps");
    stats.set_phase("up");
    stats.clear_error();
    stats.beat();
    let mut beat = tokio::time::interval(HEARTBEAT_EVERY);
    beat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    beat.tick().await;
    loop {
        tokio::select! {
            _ = shutdown.changed() => return Step::Shutdown,
            _ = beat.tick() => {
                if let Err(err) = vps_ping(cfg).await {
                    return ping_lost(err);
                }
                stats.beat();
                stats.clear_error();
            }
            job = jobs.recv() => {
                let Some(job) = job else { return Step::Shutdown };
                spawn_tunnel(cfg, job);
            }
        }
    }
}

async fn vps_ping(cfg: &Config) -> Result<(), PingErr> {
    match crate::vps::health(cfg).await {
        Ok(()) => Ok(()),
        Err(err) if err.contains("令牌") => Err(PingErr::Auth),
        Err(err) => Err(PingErr::Fail(err)),
    }
}

pub(crate) fn note_ping(
    ping: Result<(), PingErr>,
    health: &mut Option<oneshot::Sender<Result<(), String>>>,
) -> Option<Step> {
    match ping {
        Ok(()) => {
            if let Some(tx) = health.take() {
                let _ = tx.send(Ok(()));
            }
            None
        }
        Err(PingErr::Auth) => {
            if let Some(tx) = health.take() {
                let _ = tx.send(Err("令牌不对".into()));
            }
            Some(Step::Auth)
        }
        Err(PingErr::Fail(message)) => Some(lost(message, false)),
    }
}

fn ping_lost(err: PingErr) -> Step {
    match err {
        PingErr::Auth => Step::Auth,
        PingErr::Fail(message) => lost(message, true),
    }
}

pub(crate) async fn h3_ping<T, B>(
    send_request: &mut h3::client::SendRequest<T, B>,
    cfg: &Config,
) -> Result<(), PingErr>
where
    T: h3::quic::OpenStreams<B>,
    B: Buf,
{
    let mut stream = match tokio::time::timeout(PING_WAIT, send_request.send_request(cfg.health_request())).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(err)) => return Err(PingErr::Fail(format!("心跳失败: {err}"))),
        Err(_) => return Err(PingErr::Fail("心跳超时".into())),
    };
    if tokio::time::timeout(PING_WAIT, stream.finish()).await.is_err() {
        return Err(PingErr::Fail("心跳超时".into()));
    }
    let resp = match tokio::time::timeout(PING_WAIT, stream.recv_response()).await {
        Ok(Ok(resp)) => resp,
        Ok(Err(err)) => return Err(PingErr::Fail(format!("心跳失败: {err}"))),
        Err(_) => return Err(PingErr::Fail("心跳超时".into())),
    };
    if resp.status() == StatusCode::OK {
        Ok(())
    } else if resp.status() == StatusCode::UNAUTHORIZED {
        Err(PingErr::Auth)
    } else {
        Err(PingErr::Fail(format!("节点返回 {}", resp.status())))
    }
}

async fn open_quic_or_ws(
    mut send_request: h3::client::SendRequest<h3_quinn::OpenStreams, Bytes>,
    cfg: Config,
    job: Job,
    quic_ok: Arc<AtomicBool>,
) {
    let Job { host, port, reply } = job;
    if let Err(err) = check_target(&host, port) {
        let _ = reply.send(Err(err));
        return;
    }
    if !quic_ok.load(Ordering::Relaxed) {
        crate::ws::open(cfg, host, port, reply).await;
        return;
    }
    let opened = tokio::time::timeout(QUIC_HEAD, async {
        let mut stream = send_request
            .send_request(cfg.tcp_request(&host, port))
            .await
            .map_err(|err| format!("打开 HTTP/3 流失败: {err}"))?;
        stream
            .send_data(Bytes::from_static(&[0]))
            .await
            .map_err(|_| "发送握手超时".to_string())?;
        let (send, mut recv) = stream.split();
        let resp = recv.recv_response().await.map_err(|err| format!("没有响应: {err}"))?;
        Ok::<_, String>((send, recv, resp.status()))
    })
    .await;
    match opened {
        Ok(Ok((send, recv, status))) if status == StatusCode::OK => relay_h3(send, recv, reply).await,
        Ok(Ok((_, _, status))) if status == StatusCode::NOT_FOUND || status == StatusCode::METHOD_NOT_ALLOWED => {
            quic_ok.store(false, Ordering::Relaxed);
            crate::ws::open(cfg, host, port, reply).await;
        }
        Ok(Ok((_, _, status))) => {
            let _ = reply.send(Err(format!("出口拒绝: {status}")));
        }
        _ => {
            quic_ok.store(false, Ordering::Relaxed);
            crate::ws::open(cfg, host, port, reply).await;
        }
    }
}

#[allow(dead_code)]
async fn open_h3(
    send_request: &mut h3::client::SendRequest<h3_quinn::OpenStreams, Bytes>,
    cfg: &Config,
    job: Job,
) -> Result<(), String> {
    let Job { host, port, reply } = job;
    if let Err(err) = check_target(&host, port) {
        let _ = reply.send(Err(err));
        return Ok(());
    }
    let mut stream = match tokio::time::timeout(OP_TIMEOUT, send_request.send_request(cfg.tcp_request(&host, port))).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(err)) => {
            let msg = format!("打开 HTTP/3 流失败: {err}");
            let _ = reply.send(Err(msg.clone()));
            return Err(msg);
        }
        Err(_) => {
            let msg = "打开连接超时".to_string();
            let _ = reply.send(Err(msg.clone()));
            return Err(msg);
        }
    };
    if !matches!(
        tokio::time::timeout(OP_TIMEOUT, stream.send_data(Bytes::from_static(&[0]))).await,
        Ok(Ok(()))
    ) {
        let msg = "发送握手超时".to_string();
        let _ = reply.send(Err(msg.clone()));
        return Err(msg);
    }
    let (send, recv) = stream.split();
    tokio::spawn(async move {
        finish_h3(send, recv, reply).await;
    });
    Ok(())
}

async fn finish_h3(
    send: h3::client::RequestStream<h3_quinn::SendStream<Bytes>, Bytes>,
    mut recv: h3::client::RequestStream<h3_quinn::RecvStream, Bytes>,
    reply: oneshot::Sender<Result<Tunnel, String>>,
) {
    let status = match tokio::time::timeout(OP_TIMEOUT, recv.recv_response()).await {
        Ok(Ok(resp)) => resp.status(),
        Ok(Err(err)) => {
            let _ = reply.send(Err(format!("没有响应: {err}")));
            return;
        }
        Err(_) => {
            let _ = reply.send(Err("目标超时".into()));
            return;
        }
    };
    if status != StatusCode::OK {
        let _ = reply.send(Err(format!("出口拒绝: {status}")));
        return;
    }
    relay_h3(send, recv, reply).await;
}

pub(crate) async fn relay_h3(
    mut send: h3::client::RequestStream<h3_quinn::SendStream<Bytes>, Bytes>,
    mut recv: h3::client::RequestStream<h3_quinn::RecvStream, Bytes>,
    reply: oneshot::Sender<Result<Tunnel, String>>,
) {
    let (up_tx, mut up_rx) = mpsc::channel::<Bytes>(crate::relay::PIPE_QUEUE);
    let (down_tx, down_rx) = mpsc::channel::<Bytes>(crate::relay::PIPE_QUEUE);
    if reply.send(Ok(Tunnel { tx: up_tx, rx: down_rx })).is_err() {
        return;
    }
    let mut upload_done = false;
    let mut idle = tokio::time::interval(TUNNEL_IDLE);
    idle.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    idle.tick().await;
    loop {
        tokio::select! {
            _ = idle.tick() => break,
            msg = up_rx.recv(), if !upload_done => {
                idle.reset();
                match msg {
                    Some(chunk) => {
                        if !matches!(tokio::time::timeout(OP_TIMEOUT, send.send_data(chunk)).await, Ok(Ok(()))) {
                            break;
                        }
                    }
                    None => {
                        let _ = tokio::time::timeout(OP_TIMEOUT, send.finish()).await;
                        upload_done = true;
                    }
                }
            }
            incoming = recv.recv_data() => {
                idle.reset();
                match incoming {
                    Ok(Some(mut chunk)) => {
                        let bytes = chunk.copy_to_bytes(chunk.remaining());
                        if down_tx.send(bytes).await.is_err() {
                            break;
                        }
                    }
                    _ => break,
                }
            }
        }
    }
}

pub(crate) async fn dial_h3(
    cfg: &Config,
) -> Result<
    (
        h3::client::Connection<h3_quinn::Connection, Bytes>,
        h3::client::SendRequest<h3_quinn::OpenStreams, Bytes>,
    ),
    String,
> {
    install_crypto();
    let addr = resolve(cfg).await?;
    let bind = if addr.is_ipv4() {
        SocketAddr::from(([0, 0, 0, 0], 0))
    } else {
        SocketAddr::from(([0u16; 8], 0))
    };
    let mut tls = tls_config(b"h3")?;
    tls.alpn_protocols = vec![b"h3".to_vec()];
    let quic = quinn::crypto::rustls::QuicClientConfig::try_from(tls)
        .map_err(|err| format!("QUIC 配置失败: {err}"))?;
    let mut client = quinn::ClientConfig::new(Arc::new(quic));
    let mut transport = quinn::TransportConfig::default();
    transport.keep_alive_interval(Some(Duration::from_secs(2)));
    transport.max_idle_timeout(Some(Duration::from_secs(30).try_into().unwrap()));
    // 窗口按大约 200ms 往返、上百 Mbps 来留。BBR 比默认拥塞控制更适合高延迟、会丢包的国际线路。
    transport
        .stream_receive_window(quinn::VarInt::from_u32(8 * 1024 * 1024))
        .receive_window(quinn::VarInt::from_u32(32 * 1024 * 1024))
        .send_window(16 * 1024 * 1024)
        .initial_rtt(Duration::from_millis(300))
        .congestion_controller_factory(Arc::new(quinn::congestion::BbrConfig::default()));
    client.transport_config(Arc::new(transport));
    let mut endpoint = quinn::Endpoint::client(bind).map_err(|err| format!("UDP 套接字失败: {err}"))?;
    endpoint.set_default_client_config(client);
    let connecting = endpoint
        .connect(addr, &cfg.host)
        .map_err(|err| format!("HTTP/3 连接失败: {err}"))?;
    let connection = tokio::time::timeout(Duration::from_secs(5), connecting)
        .await
        .map_err(|_| "HTTP/3 握手超时".to_string())?
        .map_err(|err| format!("HTTP/3 握手失败: {err}"))?;
    let connection = h3_quinn::Connection::new(connection);
    h3::client::new(connection)
        .await
        .map_err(|err| format!("HTTP/3 会话失败: {err}"))
}

async fn run_h2(
    cfg: &Config,
    jobs: &mut mpsc::Receiver<Job>,
    health: &mut Option<oneshot::Sender<Result<(), String>>>,
    shutdown: &mut watch::Receiver<bool>,
    stats: &Arc<Stats>,
) -> Step {
    let dial = async { dial_h2(cfg).await };
    let (mut send_request, connection) = tokio::select! {
        result = dial => match result {
            Ok(value) => value,
            Err(err) => return lost(err, false),
        },
        _ = shutdown.changed() => return Step::Shutdown,
    };
    let mut connection = Abort(tokio::spawn(async move {
        let _ = connection.await;
    }));
    if let Some(step) = note_ping(h2_ping(&mut send_request, cfg).await, health) {
        return step;
    }
    stats.set_mode("h2");
    stats.set_phase("up");
    stats.clear_error();
    stats.beat();
    let mut beat = tokio::time::interval(HEARTBEAT_EVERY);
    beat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    beat.tick().await;
    loop {
        tokio::select! {
            _ = shutdown.changed() => return Step::Shutdown,
            _ = beat.tick() => {
                if let Err(err) = h2_ping(&mut send_request, cfg).await {
                    return ping_lost(err);
                }
                stats.beat();
                stats.clear_error();
            }
            job = jobs.recv() => {
                let Some(job) = job else { return Step::Shutdown };
                // QUIC 会话已经不在，网页直接走 WebSocket。
                spawn_tunnel(cfg, job);
            }
            _ = &mut connection.0 => return lost("HTTP/2 连接断了", true),
        }
    }
}

pub(crate) async fn h2_ping(send_request: &mut h2::client::SendRequest<Bytes>, cfg: &Config) -> Result<(), PingErr> {
    let (response, _send) = match send_request.send_request(cfg.health_request(), true) {
        Ok(pair) => pair,
        Err(err) => return Err(PingErr::Fail(format!("心跳失败: {err}"))),
    };
    let resp = match tokio::time::timeout(PING_WAIT, response).await {
        Ok(Ok(resp)) => resp,
        Ok(Err(err)) => return Err(PingErr::Fail(format!("心跳失败: {err}"))),
        Err(_) => return Err(PingErr::Fail("心跳超时".into())),
    };
    if resp.status() == StatusCode::OK {
        Ok(())
    } else if resp.status() == StatusCode::UNAUTHORIZED {
        Err(PingErr::Auth)
    } else {
        Err(PingErr::Fail(format!("节点返回 {}", resp.status())))
    }
}

async fn open_cdn_h2(send_request: &mut h2::client::SendRequest<Bytes>, cfg: &Config, job: Job) {
    let Job { host, port, reply } = job;
    if let Err(err) = check_target(&host, port) {
        let _ = reply.send(Err(err));
        return;
    }
    match send_request.send_request(cfg.tcp_request(&host, port), false) {
        Ok((response, mut send)) => {
            if h2_send(&mut send, Bytes::from_static(&[0]), false).await.is_err() {
                crate::ws::open(cfg.clone(), host, port, reply).await;
                return;
            }
            tokio::spawn(async move {
                finish_h2(send, response, reply).await;
            });
        }
        Err(_) => crate::ws::open(cfg.clone(), host, port, reply).await,
    }
}

#[allow(dead_code)]
async fn open_h2(
    send_request: &mut h2::client::SendRequest<Bytes>,
    cfg: &Config,
    job: Job,
) -> Result<(), String> {
    let Job { host, port, reply } = job;
    if let Err(err) = check_target(&host, port) {
        let _ = reply.send(Err(err));
        return Ok(());
    }
    let (response, mut send) = match send_request.send_request(cfg.tcp_request(&host, port), false) {
        Ok(pair) => pair,
        Err(err) => {
            let msg = format!("打开 HTTP/2 流失败: {err}");
            let _ = reply.send(Err(msg.clone()));
            return Err(msg);
        }
    };
    if h2_send(&mut send, Bytes::from_static(&[0]), false).await.is_err() {
        let msg = "发送握手超时".to_string();
        let _ = reply.send(Err(msg.clone()));
        return Err(msg);
    }
    tokio::spawn(async move {
        finish_h2(send, response, reply).await;
    });
    Ok(())
}

async fn finish_h2(
    send: h2::SendStream<Bytes>,
    response: h2::client::ResponseFuture,
    reply: oneshot::Sender<Result<Tunnel, String>>,
) {
    let resp = match tokio::time::timeout(OP_TIMEOUT, response).await {
        Ok(Ok(resp)) => resp,
        Ok(Err(err)) => {
            let _ = reply.send(Err(format!("没有响应: {err}")));
            return;
        }
        Err(_) => {
            let _ = reply.send(Err("目标超时".into()));
            return;
        }
    };
    if resp.status() != StatusCode::OK {
        let _ = reply.send(Err(format!("出口拒绝: {}", resp.status())));
        return;
    }
    relay_h2(send, resp.into_body(), reply).await;
}

pub(crate) async fn relay_h2(
    mut send: h2::SendStream<Bytes>,
    mut body: h2::RecvStream,
    reply: oneshot::Sender<Result<Tunnel, String>>,
) {
    let (up_tx, mut up_rx) = mpsc::channel::<Bytes>(crate::relay::PIPE_QUEUE);
    let (down_tx, down_rx) = mpsc::channel::<Bytes>(crate::relay::PIPE_QUEUE);
    if reply.send(Ok(Tunnel { tx: up_tx, rx: down_rx })).is_err() {
        return;
    }
    let mut upload_done = false;
    let mut idle = tokio::time::interval(TUNNEL_IDLE);
    idle.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    idle.tick().await;
    loop {
        tokio::select! {
            _ = idle.tick() => break,
            msg = up_rx.recv(), if !upload_done => {
                idle.reset();
                match msg {
                    Some(chunk) => {
                        if h2_send(&mut send, chunk, false).await.is_err() {
                            break;
                        }
                    }
                    None => {
                        let _ = h2_send(&mut send, Bytes::new(), true).await;
                        upload_done = true;
                    }
                }
            }
            incoming = body.data() => {
                idle.reset();
                match incoming {
                    Some(Ok(chunk)) => {
                        let n = chunk.len();
                        if down_tx.send(chunk).await.is_err() {
                            break;
                        }
                        let _ = body.flow_control().release_capacity(n);
                    }
                    _ => break,
                }
            }
        }
    }
}

pub(crate) async fn h2_send(send: &mut h2::SendStream<Bytes>, data: Bytes, end: bool) -> Result<(), String> {
    let needed = data.len();
    send.reserve_capacity(needed.max(1));
    while needed > 0 && send.capacity() < needed {
        match tokio::time::timeout(OP_TIMEOUT, std::future::poll_fn(|cx| send.poll_capacity(cx))).await {
            Ok(Some(Ok(_))) => {}
            Ok(Some(Err(err))) => return Err(err.to_string()),
            Ok(None) => return Err("HTTP/2 发送窗口关闭".into()),
            Err(_) => return Err("发送超时".into()),
        }
    }
    send.send_data(data, end).map_err(|err| err.to_string())
}

pub(crate) async fn dial_h2(cfg: &Config) -> Result<(h2::client::SendRequest<Bytes>, h2::client::Connection<TlsStream, Bytes>), String> {
    install_crypto();
    let addr = resolve(cfg).await?;
    let tcp = tokio::time::timeout(Duration::from_secs(4), TcpStream::connect(addr))
        .await
        .map_err(|_| "TCP 连接超时".to_string())?
        .map_err(|err| format!("TCP 连接失败: {err}"))?;
    crate::relay::tune(&tcp);
    let name = ServerName::try_from(cfg.host.clone()).map_err(|_| "SNI 不合法".to_string())?;
    let tls = TlsConnector::from(Arc::new(tls_config(b"h2")?));
    let tls = tokio::time::timeout(Duration::from_secs(4), tls.connect(name, tcp))
        .await
        .map_err(|_| "TLS 握手超时".to_string())?
        .map_err(|err| format!("TLS 握手失败: {err}"))?;
    let mut builder = h2::client::Builder::new();
    builder
        .initial_window_size(16 * 1024 * 1024)
        .initial_connection_window_size(64 * 1024 * 1024)
        .max_frame_size(256 * 1024);
    let (send, connection) = builder
        .handshake::<_, Bytes>(tls)
        .await
        .map_err(|err| format!("HTTP/2 握手失败: {err}"))?;
    Ok((send, connection))
}

type TlsStream = tokio_rustls::client::TlsStream<TcpStream>;

pub(crate) fn tls_config(alpn: &[u8]) -> Result<ClientConfig, String> {
    if alpn == b"h3" {
        return shared_tls(&H3_TLS, b"h3");
    }
    if alpn == b"h2" {
        return shared_tls(&H2_TLS, b"h2");
    }
    shared_tls(&H1_TLS, b"http/1.1")
}

fn shared_tls(slot: &std::sync::OnceLock<ClientConfig>, alpn: &'static [u8]) -> Result<ClientConfig, String> {
    if let Some(config) = slot.get() {
        return Ok(config.clone());
    }
    let built = build_tls(alpn)?;
    let _ = slot.set(built);
    Ok(slot.get().expect("tls config").clone())
}

fn build_tls(alpn: &[u8]) -> Result<ClientConfig, String> {
    install_crypto();
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let mut config = ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    config.alpn_protocols = vec![alpn.to_vec()];
    Ok(config)
}

static H3_TLS: std::sync::OnceLock<ClientConfig> = std::sync::OnceLock::new();
static H2_TLS: std::sync::OnceLock<ClientConfig> = std::sync::OnceLock::new();
static H1_TLS: std::sync::OnceLock<ClientConfig> = std::sync::OnceLock::new();

#[cfg(test)]
mod live {
    use super::*;

    #[tokio::test]
    #[ignore = "needs network"]
    async fn cloudflare_accepts_http3() {
        let cfg = Config::parse(
            r#"{"endpoint":"https://cloudflare.com","token":"probe","socks_port":1080,"http_port":8080}"#,
        )
        .unwrap();
        let (mut driver, mut send_request) = dial_h3(&cfg).await.expect("http3 handshake");
        let driver = tokio::spawn(async move {
            let _ = std::future::poll_fn(|cx| driver.poll_close(cx)).await;
        });
        let request = http::Request::builder()
            .method(http::Method::GET)
            .uri("https://cloudflare.com/cdn-cgi/trace")
            .header("user-agent", "rsq/1")
            .body(())
            .unwrap();
        let mut stream = send_request.send_request(request).await.expect("request");
        stream.finish().await.expect("finish");
        let response = tokio::time::timeout(Duration::from_secs(15), stream.recv_response())
            .await
            .expect("timeout")
            .expect("response");
        driver.abort();
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    #[ignore = "needs network"]
    async fn probe_post() {
        let raw = std::fs::read_to_string("../worker/.dev.vars").expect("token");
        let token = raw.trim().trim_start_matches("RSQ_TOKEN=").trim().to_string();
        let cfg = Config::parse(&format!(
            r#"{{"endpoint":"https://vpn.example.com","token":"{token}","socks_port":11081,"http_port":18081}}"#
        ))
        .unwrap();
        let (mut driver, mut send) = dial_h3(&cfg).await.expect("h3");
        let drive = tokio::spawn(async move {
            let _ = std::future::poll_fn(|cx| driver.poll_close(cx)).await;
        });
        let mut stream = send.send_request(cfg.tcp_request("gnu.org", 80)).await.expect("req");
        stream.send_data(Bytes::from_static(&[0])).await.expect("preface");
        let resp = tokio::time::timeout(Duration::from_secs(15), stream.recv_response()).await;
        println!("h3 post: {resp:?}");
        drive.abort();

        let (mut send, conn) = dial_h2(&cfg).await.expect("h2");
        let drive = tokio::spawn(async move { let _ = conn.await; });
        let (resp_fut, mut out) = send.send_request(cfg.tcp_request("gnu.org", 80), false).expect("h2 req");
        h2_send(&mut out, Bytes::from_static(&[0]), false).await.expect("h2 preface");
        let resp = tokio::time::timeout(Duration::from_secs(15), resp_fut).await;
        println!("h2 post: {resp:?}");
        drive.abort();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "needs network"]
    async fn fetch_orange_cloud() {
        let raw = std::fs::read_to_string("../worker/.dev.vars").expect("worker/.dev.vars");
        let token = raw.trim().trim_start_matches("RSQ_TOKEN=").trim();
        let cfg = Config::parse(&format!(
            r#"{{"endpoint":"https://vpn.example.com","token":"{token}","socks_port":11083,"http_port":18083,"prefer_h3":true}}"#
        ))
        .unwrap();
        let stats = Arc::new(Stats::default());
        let (shut_tx, shut_rx) = watch::channel(false);
        let task_stats = stats.clone();
        let task = tokio::spawn(async move { run(cfg, task_stats, shut_rx, 3).await });
        let deadline = std::time::Instant::now() + Duration::from_secs(25);
        loop {
            if stats.phase.lock().unwrap().as_str() == "up" {
                break;
            }
            if std::time::Instant::now() > deadline {
                panic!("没有连上 {}", stats.error.lock().unwrap());
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let mut sock = TcpStream::connect("127.0.0.1:18083").await.unwrap();
        sock.write_all(b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
            .await
            .unwrap();
        let mut buf = vec![0u8; 128];
        let n = tokio::time::timeout(Duration::from_secs(20), sock.read(&mut buf))
            .await
            .unwrap()
            .unwrap();
        let head = String::from_utf8_lossy(&buf[..n]);
        assert!(head.starts_with("HTTP/1.1 200"), "{head}");
        drop(sock);
        let script = r#"
$c = New-Object Net.Sockets.TcpClient
$c.Connect('127.0.0.1',18083)
$s = $c.GetStream()
$bytes = [Text.Encoding]::ASCII.GetBytes("CONNECT example.com:443 HTTP/1.1`r`nHost: example.com:443`r`n`r`n")
$s.Write($bytes,0,$bytes.Length)
$buf = New-Object byte[] 128
$n = $s.Read($buf,0,$buf.Length)
$line = [Text.Encoding]::ASCII.GetString($buf,0,$n)
if ($line -notlike 'HTTP/1.1 200*') { throw $line }
$ssl = New-Object Net.Security.SslStream($s, $false)
$ssl.AuthenticateAsClient('example.com')
$get = [Text.Encoding]::ASCII.GetBytes("GET / HTTP/1.1`r`nHost: example.com`r`nConnection: close`r`n`r`n")
$ssl.Write($get,0,$get.Length)
$rb = New-Object byte[] 220
$rn = $ssl.Read($rb,0,$rb.Length)
[Text.Encoding]::ASCII.GetString($rb,0,$rn)
"#;
        let output = std::process::Command::new("powershell")
            .args(["-NoProfile", "-Command", script])
            .output()
            .expect("powershell");
        let text = String::from_utf8_lossy(&output.stdout);
        let err = String::from_utf8_lossy(&output.stderr);
        assert!(
            output.status.success() && text.contains("HTTP/1.1"),
            "stdout={text} stderr={err}"
        );
        println!("{text}");
        let _ = shut_tx.send(true);
        let _ = tokio::time::timeout(Duration::from_secs(5), task).await;
    }

    #[tokio::test]
    #[ignore = "needs network"]
    async fn browse_targets() {
        let raw = std::fs::read_to_string("../worker/.dev.vars").expect("worker/.dev.vars");
        let token = raw.trim().trim_start_matches("RSQ_TOKEN=").trim();
        let cfg = Config::parse(&format!(
            r#"{{"endpoint":"https://vpn.example.com","token":"{token}","socks_port":11082,"http_port":18082,"prefer_h3":true}}"#
        ))
        .unwrap();
        let stats = Arc::new(Stats::default());
        let (shut_tx, shut_rx) = watch::channel(false);
        let task_stats = stats.clone();
        let task = tokio::spawn(async move { run(cfg, task_stats, shut_rx, 2).await });
        let deadline = std::time::Instant::now() + Duration::from_secs(25);
        loop {
            if stats.phase.lock().unwrap().as_str() == "up" {
                break;
            }
            if std::time::Instant::now() > deadline {
                panic!("没有连上 {}", stats.error.lock().unwrap());
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        for target in [
            "gnu.org:443",
            "www.baidu.com:443",
            "github.com:443",
            "www.google.com:443",
            "example.com:443",
            "www.cloudflare.com:443",
        ] {
            let mut sock = TcpStream::connect("127.0.0.1:18082").await.unwrap();
            let req = format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n");
            sock.write_all(req.as_bytes()).await.unwrap();
            let mut buf = vec![0u8; 180];
            let n = tokio::time::timeout(Duration::from_secs(20), sock.read(&mut buf))
                .await
                .unwrap_or(Ok(0))
                .unwrap_or(0);
            let head = String::from_utf8_lossy(&buf[..n]);
            let line = head.lines().next().unwrap_or("无响应");
            println!("{target} => {line}");
        }
        let _ = shut_tx.send(true);
        let _ = tokio::time::timeout(Duration::from_secs(5), task).await;
    }

    #[tokio::test]
    #[ignore = "needs network"]
    async fn live_proxy_and_heartbeat() {
        let raw = std::fs::read_to_string("../worker/.dev.vars").expect("worker/.dev.vars");
        let token = raw.trim().trim_start_matches("RSQ_TOKEN=").trim();
        let cfg = Config::parse(&format!(
            r#"{{"endpoint":"https://vpn.example.com","token":"{token}","socks_port":11080,"http_port":18080,"prefer_h3":true}}"#
        ))
        .unwrap();
        let stats = Arc::new(Stats::default());
        let (shut_tx, shut_rx) = watch::channel(false);
        let task_stats = stats.clone();
        let task = tokio::spawn(async move { run(cfg, task_stats, shut_rx, 1).await });
        let deadline = std::time::Instant::now() + Duration::from_secs(25);
        loop {
            let phase = stats.phase.lock().unwrap().clone();
            if phase == "up" {
                break;
            }
            if std::time::Instant::now() > deadline {
                panic!("没有连上: {phase} {}", stats.error.lock().unwrap());
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        let mut sock = TcpStream::connect("127.0.0.1:18080").await.unwrap();
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        sock.write_all(b"CONNECT gnu.org:80 HTTP/1.1\r\nHost: gnu.org:80\r\n\r\n")
            .await
            .unwrap();
        let mut buf = vec![0u8; 256];
        let n = tokio::time::timeout(Duration::from_secs(20), sock.read(&mut buf))
            .await
            .expect("connect timeout")
            .unwrap();
        let head = String::from_utf8_lossy(&buf[..n]);
        assert!(
            head.starts_with("HTTP/1.1 200"),
            "{head} mode={}",
            stats.mode.lock().unwrap()
        );
        sock.write_all(b"GET / HTTP/1.0\r\nHost: gnu.org\r\n\r\n")
            .await
            .unwrap();
        let n = tokio::time::timeout(Duration::from_secs(20), sock.read(&mut buf))
            .await
            .expect("body timeout")
            .unwrap();
        assert!(n > 0, "隧道没有数据");
        let before = stats.beats.load(std::sync::atomic::Ordering::Relaxed);
        tokio::time::sleep(Duration::from_secs(16)).await;
        let after = stats.beats.load(std::sync::atomic::Ordering::Relaxed);
        assert!(after > before, "心跳没有跳");
        assert_eq!(stats.phase.lock().unwrap().as_str(), "up");
        let _ = shut_tx.send(true);
        let _ = tokio::time::timeout(Duration::from_secs(5), task).await;
    }

    #[tokio::test]
    #[ignore = "needs network"]
    async fn cloudflare_accepts_http2() {
        let cfg = Config::parse(
            r#"{"endpoint":"https://cloudflare.com","token":"probe","socks_port":1080,"http_port":8080}"#,
        )
        .unwrap();
        let (mut send_request, connection) = dial_h2(&cfg).await.expect("http2 handshake");
        let driver = tokio::spawn(async move {
            let _ = connection.await;
        });
        let request = http::Request::builder()
            .method(http::Method::GET)
            .uri("https://cloudflare.com/cdn-cgi/trace")
            .header("user-agent", "rsq/1")
            .body(())
            .unwrap();
        let (response, _) = send_request.send_request(request, true).expect("request");
        let response = tokio::time::timeout(Duration::from_secs(15), response)
            .await
            .expect("timeout")
            .expect("response");
        driver.abort();
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "needs network"]
    async fn china_sites_not_1016() {
        let raw = std::fs::read_to_string("../worker/.dev.vars").expect("worker/.dev.vars");
        let token = raw.trim().trim_start_matches("RSQ_TOKEN=").trim();
        let cfg = Config::parse(&format!(
            r#"{{"endpoint":"https://vpn.example.com","token":"{token}","socks_port":11084,"http_port":18084,"prefer_h3":true}}"#
        ))
        .unwrap();
        for host in ["www.google.com", "www.cloudflare.com", "example.com", "www.taobao.com"] {
            let ip = crate::dns::resolve_dial_target(host, 443).await;
            println!("{host} -> {ip}");
        }
        let stats = Arc::new(Stats::default());
        let (shut_tx, shut_rx) = watch::channel(false);
        let task_stats = stats.clone();
        let task = tokio::spawn(async move { run(cfg, task_stats, shut_rx, 3).await });
        let deadline = std::time::Instant::now() + Duration::from_secs(25);
        loop {
            if stats.phase.lock().unwrap().as_str() == "up" {
                break;
            }
            if std::time::Instant::now() > deadline {
                panic!("没有连上 {}", stats.error.lock().unwrap());
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        let script = r#"
$ErrorActionPreference = 'Continue'
$hosts = @('www.google.com','www.cloudflare.com','example.com','www.taobao.com')
foreach ($h in $hosts) {
  try {
    $c = New-Object Net.Sockets.TcpClient
    $c.ReceiveTimeout = 25000
    $c.SendTimeout = 15000
    $c.Connect('127.0.0.1',18084)
    $s = $c.GetStream()
    $s.ReadTimeout = 25000
    $req = "CONNECT ${h}:443 HTTP/1.1`r`nHost: ${h}:443`r`n`r`n"
    $bytes = [Text.Encoding]::ASCII.GetBytes($req)
    $s.Write($bytes,0,$bytes.Length)
    $buf = New-Object byte[] 256
    $n = $s.Read($buf,0,$buf.Length)
    $line = [Text.Encoding]::ASCII.GetString($buf,0,$n).Split("`n")[0].Trim()
    if ($line -notlike 'HTTP/1.1 200*') { Write-Output ($h + ' CONNECT ' + $line); $c.Close(); continue }
    $ssl = New-Object Net.Security.SslStream($s, $false)
    $ssl.ReadTimeout = 25000
    $ssl.AuthenticateAsClient($h)
    $get = [Text.Encoding]::ASCII.GetBytes("GET / HTTP/1.1`r`nHost: $h`r`nConnection: close`r`n`r`n")
    $ssl.Write($get,0,$get.Length)
    $rb = New-Object byte[] 8192
    $rn = $ssl.Read($rb,0,$rb.Length)
    $body = [Text.Encoding]::ASCII.GetString($rb,0,$rn)
    $status = ($body.Split("`n")[0]).Trim()
    $cookies = ([regex]::Matches($body, '(?im)^set-cookie:')).Count
    $mark = 'ok'
    if ($body -match '1016|Origin DNS|Error 1027|Please enable cookies') { $mark = 'dns-error' }
    Write-Output ($h + ' ' + $status + ' ' + $mark + ' cookies=' + $cookies)
    $c.Close()
  } catch {
    Write-Output ($h + ' ERR ' + $_.Exception.Message)
  }
}
"#;
        let output = std::process::Command::new("powershell")
            .args(["-NoProfile", "-Command", script])
            .output()
            .expect("powershell");
        let text = String::from_utf8_lossy(&output.stdout);
        let err = String::from_utf8_lossy(&output.stderr);
        println!("{text}");
        if !err.is_empty() {
            println!("stderr={err}");
        }
        assert!(text.contains("www.google.com"), "{text}");
        assert!(text.contains("www.cloudflare.com"), "{text}");
        assert!(
            text.lines().any(|line| line.contains("www.cloudflare.com") && line.contains("cookies=") && !line.contains("cookies=0")),
            "{text}"
        );
        assert!(text.contains("www.taobao.com"), "{text}");
        assert!(!text.contains("dns-error"), "{text}");
        assert!(!text.contains("1016"), "{text}");
        let _ = shut_tx.send(true);
        let _ = tokio::time::timeout(Duration::from_secs(5), task).await;
    }
}

fn install_crypto() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

pub(crate) async fn resolve(cfg: &Config) -> Result<SocketAddr, String> {
    crate::dns::lookup_node(cfg).await
}
