use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, watch};

use crate::stats::{Active, Stats};

pub const PIPE_QUEUE: usize = 64;
const PIPE_BUF: usize = 64 * 1024;

pub fn tune(tcp: &TcpStream) {
    let _ = tcp.set_nodelay(true);
    let sock = socket2::SockRef::from(tcp);
    let keepalive = socket2::TcpKeepalive::new()
        .with_time(Duration::from_secs(30))
        .with_interval(Duration::from_secs(10));
    let _ = sock.set_tcp_keepalive(&keepalive);
    let _ = sock.set_recv_buffer_size(1024 * 1024);
    let _ = sock.set_send_buffer_size(1024 * 1024);
}

pub struct Tunnel {
    pub tx: mpsc::Sender<Bytes>,
    pub rx: mpsc::Receiver<Bytes>,
}

/// 本机直连：不走节点隧道。
pub fn tunnel_from_tcp(tcp: TcpStream) -> Tunnel {
    tune(&tcp);
    let (up_tx, mut up_rx) = mpsc::channel::<Bytes>(PIPE_QUEUE);
    let (down_tx, down_rx) = mpsc::channel::<Bytes>(PIPE_QUEUE);
    let (mut rd, mut wr) = tcp.into_split();
    tokio::spawn(async move {
        let mut buf = vec![0u8; PIPE_BUF];
        loop {
            match rd.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if down_tx.send(Bytes::copy_from_slice(&buf[..n])).await.is_err() {
                        break;
                    }
                }
            }
        }
    });
    tokio::spawn(async move {
        while let Some(chunk) = up_rx.recv().await {
            if wr.write_all(&chunk).await.is_err() {
                break;
            }
        }
        let _ = wr.shutdown().await;
    });
    Tunnel { tx: up_tx, rx: down_rx }
}

pub async fn splice(
    tcp: TcpStream,
    tunnel: Tunnel,
    stats: Arc<Stats>,
    mut shutdown: watch::Receiver<bool>,
) {
    let _active = Active::new(stats.clone());
    tune(&tcp);
    let (mut rd, mut wr) = tcp.into_split();
    let tx = tunnel.tx;
    let mut rx = tunnel.rx;
    let up_stats = stats.clone();
    let down_stats = stats;
    let up = async move {
        let mut buf = vec![0u8; PIPE_BUF];
        loop {
            let n = match rd.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => break,
            };
            up_stats.add_up(n as u64);
            if tx.send(Bytes::copy_from_slice(&buf[..n])).await.is_err() {
                break;
            }
        }
        drop(tx);
    };
    let down = async move {
        while let Some(chunk) = rx.recv().await {
            down_stats.add_down(chunk.len() as u64);
            if wr.write_all(&chunk).await.is_err() {
                break;
            }
        }
        let _ = wr.shutdown().await;
    };
    tokio::select! {
        _ = async { tokio::join!(up, down) } => {}
        _ = shutdown.changed() => {}
    }
}
