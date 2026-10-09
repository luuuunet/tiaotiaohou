use std::net::IpAddr;
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use rustls::pki_types::ServerName;
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot};
use tokio_rustls::TlsConnector;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::handshake::client::Request;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{client_async, connect_async, MaybeTlsStream};

use crate::config::Config;
use crate::guard::check_target;
use crate::relay::Tunnel;

const PING_EVERY: Duration = Duration::from_secs(15);

pub async fn open(cfg: Config, host: String, port: u16, reply: oneshot::Sender<Result<Tunnel, String>>) {
    if let Err(err) = check_target(&host, port) {
        let _ = reply.send(Err(err));
        return;
    }
    let socket = match connect(&cfg, &host, port).await {
        Ok(socket) => socket,
        Err(err) => {
            let _ = reply.send(Err(err));
            return;
        }
    };
    let (mut write, mut read) = socket.split();
    let (up_tx, mut up_rx) = mpsc::channel::<Bytes>(crate::relay::PIPE_QUEUE);
    let (down_tx, down_rx) = mpsc::channel::<Bytes>(crate::relay::PIPE_QUEUE);
    if reply.send(Ok(Tunnel { tx: up_tx, rx: down_rx })).is_err() {
        return;
    }
    let mut ping = tokio::time::interval(PING_EVERY);
    ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    ping.tick().await;
    loop {
        tokio::select! {
            _ = ping.tick() => {
                if write.send(Message::Ping(Vec::new().into())).await.is_err() {
                    break;
                }
            }
            incoming = read.next() => {
                match incoming {
                    Some(Ok(Message::Binary(chunk))) => {
                        if down_tx.send(Bytes::from(chunk)).await.is_err() {
                            break;
                        }
                    }
                    Some(Ok(Message::Pong(_))) => {}
                    Some(Ok(Message::Ping(payload))) => {
                        if write.send(Message::Pong(payload)).await.is_err() {
                            break;
                        }
                    }
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                    _ => {}
                }
            }
            outgoing = up_rx.recv() => {
                match outgoing {
                    Some(chunk) => {
                        if write.send(Message::Binary(chunk)).await.is_err() {
                            break;
                        }
                    }
                    None => {
                        let _ = write.send(Message::Close(None)).await;
                        break;
                    }
                }
            }
        }
    }
}

async fn connect(
    cfg: &Config,
    host: &str,
    port: u16,
) -> Result<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>, String> {
    // 本机 DNS 会把谷歌指到别的地址。先把域名交给节点解析。
    if host.parse::<IpAddr>().is_err() {
        match dial(cfg, host, port).await {
            Ok(socket) => return Ok(socket),
            Err(err) if err.contains("502") => {
                let ip = crate::dns::resolve_dial_target(host, port).await;
                if let Ok(addr) = ip.parse::<IpAddr>() {
                    if !crate::guard::is_cloudflare_ip(addr) {
                        return dial(cfg, &ip, port).await;
                    }
                }
                return Err(err);
            }
            Err(err) => return Err(err),
        }
    }
    dial(cfg, host, port).await
}

async fn dial(
    cfg: &Config,
    host: &str,
    port: u16,
) -> Result<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>, String> {
    let url = format!("{}/rsq/v1/ws", cfg.origin.replace("https://", "wss://"));
    let mut request = url.into_client_request().map_err(|err| format!("地址不合法: {err}"))?;
    let headers = request.headers_mut();
    headers.insert(
        "authorization",
        format!("Bearer {}", cfg.token).parse().map_err(|_| "令牌不能放进请求头")?,
    );
    headers.insert("x-rsq-host", host.parse().map_err(|_| "主机名不能放进请求头")?);
    headers.insert("x-rsq-port", port.to_string().parse().unwrap());
    headers.insert("x-rsq-exit", cfg.exit_for(host, port).parse().unwrap());
    if let Some(addr) = cfg.pinned_addr() {
        return dial_pinned(cfg, request, addr).await;
    }
    match tokio::time::timeout(Duration::from_secs(12), connect_async(request)).await {
        Ok(Ok((socket, _))) => Ok(socket),
        Ok(Err(err)) => Err(format!("隧道握手失败: {err}")),
        Err(_) => Err("隧道握手超时".into()),
    }
}

async fn dial_pinned(
    cfg: &Config,
    request: Request,
    addr: std::net::SocketAddr,
) -> Result<tokio_tungstenite::WebSocketStream<MaybeTlsStream<TcpStream>>, String> {
    let tcp = tokio::time::timeout(Duration::from_secs(10), TcpStream::connect(addr))
        .await
        .map_err(|_| "TCP 连接超时".to_string())?
        .map_err(|err| format!("TCP 连接失败: {err}"))?;
    crate::relay::tune(&tcp);
    let name = ServerName::try_from(cfg.host.clone()).map_err(|_| "SNI 不合法".to_string())?;
    let tls = TlsConnector::from(Arc::new(crate::engine::tls_config(b"http/1.1")?));
    let tls = tokio::time::timeout(Duration::from_secs(10), tls.connect(name, tcp))
        .await
        .map_err(|_| "TLS 握手超时".to_string())?
        .map_err(|err| format!("TLS 握手失败: {err}"))?;
    match tokio::time::timeout(Duration::from_secs(12), client_async(request, MaybeTlsStream::Rustls(tls))).await {
        Ok(Ok((socket, _))) => Ok(socket),
        Ok(Err(err)) => Err(format!("隧道握手失败: {err}")),
        Err(_) => Err("隧道握手超时".into()),
    }
}
