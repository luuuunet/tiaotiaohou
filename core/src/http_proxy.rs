use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;

use crate::engine::Engine;
use crate::relay::splice;
use crate::stats::Stats;

pub async fn serve(
    listener: TcpListener,
    engine: Engine,
    stats: Arc<Stats>,
    mut shutdown: watch::Receiver<bool>,
) {
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let Ok((socket, _)) = accepted else { break };
                let engine = engine.clone();
                let stats = stats.clone();
                let shutdown = shutdown.clone();
                tokio::spawn(async move {
                    let _ = handle(socket, engine, stats, shutdown).await;
                });
            }
            _ = shutdown.changed() => {
                if *shutdown.borrow() {
                    break;
                }
            }
        }
    }
}

async fn handle(
    mut socket: TcpStream,
    engine: Engine,
    stats: Arc<Stats>,
    shutdown: watch::Receiver<bool>,
) -> std::io::Result<()> {
    crate::relay::tune(&socket);
    let mut buf = Vec::with_capacity(1024);
    let mut tmp = [0u8; 1024];
    let header_end = loop {
        if buf.len() > 16 * 1024 {
            return write_status(&mut socket, 400, "headers too large").await;
        }
        let n = match tokio::time::timeout(std::time::Duration::from_secs(5), socket.read(&mut tmp)).await {
            Ok(Ok(n)) => n,
            Ok(Err(err)) => return Err(err),
            Err(_) => return Ok(()),
        };
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(i) = find_header_end(&buf) {
            break i;
        }
    };
    let header = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut lines = header.split("\r\n");
    let Some(request) = lines.next() else {
        return write_status(&mut socket, 400, "bad request").await;
    };
    let mut parts = request.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("");
    if !method.eq_ignore_ascii_case("CONNECT") {
        return write_status(&mut socket, 405, "only CONNECT").await;
    }
    let Some((host, port)) = split_host_port(target) else {
        return write_status(&mut socket, 400, "bad connect target").await;
    };
    match engine.open(&host, port).await {
        Ok(tunnel) => {
            socket
                .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                .await?;
            if buf.len() > header_end {
                let _ = tunnel.tx.send(bytes::Bytes::copy_from_slice(&buf[header_end..])).await;
            }
            splice(socket, tunnel, stats, shutdown).await;
            Ok(())
        }
        Err(err) => {
            if should_fetch(&err, port, &engine.cfg) {
                socket.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n").await?;
                socket.flush().await?;
                tokio::task::yield_now().await;
                crate::fetch_proxy::serve(socket, &engine.cfg, &host, port).await?;
                Ok(())
            } else {
                write_status(&mut socket, 502, &err).await
            }
        }
    }
}

fn should_fetch(err: &str, port: u16, cfg: &crate::config::Config) -> bool {
    // 超时/重连时不要再叠一层 fetch，否则 Chrome 会连卡两轮。
    cfg.fetch_enabled
        && cfg.exit_via != "vps"
        && cfg.exit_via != "cdn"
        && (port == 80 || port == 443)
        && !err.contains("重连")
        && !err.contains("已停止")
        && !err.contains("连接目标超时")
        && (err.contains("502")
            || err.contains("1016")
            || err.contains("connect failed")
            || err.contains("握手"))
}

fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n").map(|i| i + 4)
}

pub fn split_host_port(target: &str) -> Option<(String, u16)> {
    if let Some(rest) = target.strip_prefix('[') {
        let (host, port) = rest.split_once("]:")?;
        if host.is_empty() {
            return None;
        }
        return Some((host.to_string(), port.parse().ok()?));
    }
    let (host, port) = target.rsplit_once(':')?;
    if host.is_empty() {
        return None;
    }
    Some((host.to_string(), port.parse().ok()?))
}

async fn write_status(socket: &mut TcpStream, code: u16, reason: &str) -> std::io::Result<()> {
    let body = reason.replace(['\r', '\n'], " ");
    let msg = format!("HTTP/1.1 {code} {body}\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{body}", len = body.len());
    socket.write_all(msg.as_bytes()).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::split_host_port;

    #[test]
    fn splits_connect_targets() {
        assert_eq!(split_host_port("example.com:443").unwrap(), ("example.com".into(), 443));
        assert_eq!(split_host_port("[2001:db8::1]:443").unwrap(), ("2001:db8::1".into(), 443));
        assert!(split_host_port("noport").is_none());
    }
}
