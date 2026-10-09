use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;

use crate::engine::Engine;
use crate::relay::splice;
use crate::stats::Stats;

const SUCCESS: &[u8] = &[0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];

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
                    if let Err(err) = handle(socket, engine, stats, shutdown).await {
                        let _ = err;
                    }
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
    let mut methods_len = [0u8; 2];
    socket.read_exact(&mut methods_len).await?;
    if methods_len[0] != 0x05 {
        return Ok(());
    }
    let mut methods = vec![0u8; methods_len[1] as usize];
    socket.read_exact(&mut methods).await?;
    if !methods.contains(&0x00) {
        socket.write_all(&[0x05, 0xff]).await?;
        return Ok(());
    }
    socket.write_all(&[0x05, 0x00]).await?;

    let mut head = [0u8; 4];
    socket.read_exact(&mut head).await?;
    if head[0] != 0x05 {
        return Ok(());
    }
    if head[1] == 0x03 {
        if !engine.cfg.has_udp() {
            reply(&mut socket, 0x07).await?;
            return Ok(());
        }
        let _ = read_target(&mut socket, head[3]).await;
        return udp_associate(socket, engine, stats, shutdown).await;
    }
    if head[1] != 0x01 {
        reply(&mut socket, 0x07).await?;
        return Ok(());
    }
    let target = match read_target(&mut socket, head[3]).await {
        Ok(v) => v,
        Err(code) => {
            reply(&mut socket, code).await?;
            return Ok(());
        }
    };
    match engine.open(&target.0, target.1).await {
        Ok(tunnel) => {
            socket.write_all(SUCCESS).await?;
            splice(socket, tunnel, stats, shutdown).await;
        }
        Err(err) => {
            if engine.cfg.exit_via != "vps"
                && engine.cfg.exit_via != "cdn"
                && (target.1 == 80 || target.1 == 443)
                && !err.contains("重连")
                && !err.contains("已停止")
                && !err.contains("连接目标超时")
                && (err.contains("502")
                    || err.contains("1016")
                    || err.contains("connect failed")
                    || err.contains("握手"))
            {
                socket.write_all(SUCCESS).await?;
                socket.flush().await?;
                tokio::task::yield_now().await;
                crate::fetch_proxy::serve(socket, &engine.cfg, &target.0, target.1).await?;
            } else {
                reply(&mut socket, 0x05).await?;
            }
        }
    }
    Ok(())
}

async fn read_target(socket: &mut TcpStream, atyp: u8) -> Result<(String, u16), u8> {
    let host = match atyp {
        0x01 => {
            let mut buf = [0u8; 4];
            socket.read_exact(&mut buf).await.map_err(|_| 0x01u8)?;
            format!("{}.{}.{}.{}", buf[0], buf[1], buf[2], buf[3])
        }
        0x03 => {
            let mut len = [0u8; 1];
            socket.read_exact(&mut len).await.map_err(|_| 0x01u8)?;
            if len[0] == 0 {
                return Err(0x08);
            }
            let mut name = vec![0u8; len[0] as usize];
            socket.read_exact(&mut name).await.map_err(|_| 0x01u8)?;
            String::from_utf8(name).map_err(|_| 0x08u8)?
        }
        0x04 => {
            let mut buf = [0u8; 16];
            socket.read_exact(&mut buf).await.map_err(|_| 0x01u8)?;
            let v6 = std::net::Ipv6Addr::from(buf);
            v6.to_string()
        }
        _ => return Err(0x08),
    };
    let mut port_buf = [0u8; 2];
    socket.read_exact(&mut port_buf).await.map_err(|_| 0x01u8)?;
    let port = u16::from_be_bytes(port_buf);
    Ok((host, port))
}

async fn reply(socket: &mut TcpStream, code: u8) -> std::io::Result<()> {
    socket
        .write_all(&[0x05, code, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        .await
}

async fn udp_associate(
    mut control: TcpStream,
    engine: Engine,
    stats: Arc<Stats>,
    mut shutdown: watch::Receiver<bool>,
) -> std::io::Result<()> {
    let local = match tokio::net::UdpSocket::bind("127.0.0.1:0").await {
        Ok(sock) => sock,
        Err(_) => {
            reply(&mut control, 0x01).await?;
            return Ok(());
        }
    };
    let wan = match tokio::net::UdpSocket::bind("0.0.0.0:0").await {
        Ok(sock) => sock,
        Err(_) => {
            reply(&mut control, 0x01).await?;
            return Ok(());
        }
    };
    let port = local.local_addr()?.port();
    control
        .write_all(&[0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, (port >> 8) as u8, (port & 0xff) as u8])
        .await?;
    let mut last = None;
    let mut local_buf = vec![0u8; 64 * 1024];
    let mut wan_buf = vec![0u8; 64 * 1024];
    let mut peek = [0u8; 1];
    loop {
        tokio::select! {
            _ = shutdown.changed() => break,
            n = control.read(&mut peek) => {
                if n.unwrap_or(0) == 0 {
                    break;
                }
            }
            got = local.recv_from(&mut local_buf) => {
                let Ok((n, from)) = got else { break };
                last = Some(from);
                if let Some((host, port, payload)) = parse_socks_udp(&local_buf[..n]) {
                    stats.add_up(payload.len() as u64);
                    let _ = crate::vps::udp_send(&engine.cfg, &wan, &host, port, payload).await;
                }
            }
            got = wan.recv_from(&mut wan_buf) => {
                let Ok((n, _)) = got else { break };
                if let (Some(to), Ok((host, port, payload))) = (last, crate::vps::decode_udp(&wan_buf[..n])) {
                    stats.add_down(payload.len() as u64);
                    let pkt = pack_socks_udp(&host, port, payload);
                    let _ = local.send_to(&pkt, to).await;
                }
            }
        }
    }
    Ok(())
}

fn parse_socks_udp(buf: &[u8]) -> Option<(String, u16, &[u8])> {
    if buf.len() < 10 || buf[0] != 0 || buf[1] != 0 || buf[2] != 0 {
        return None;
    }
    let atyp = buf[3];
    let (host, rest) = match atyp {
        1 if buf.len() >= 10 => (
            format!("{}.{}.{}.{}", buf[4], buf[5], buf[6], buf[7]),
            &buf[8..],
        ),
        3 if buf.len() >= 7 => {
            let n = buf[4] as usize;
            if buf.len() < 7 + n {
                return None;
            }
            let host = String::from_utf8(buf[5..5 + n].to_vec()).ok()?;
            (host, &buf[5 + n..])
        }
        _ => return None,
    };
    if rest.len() < 2 {
        return None;
    }
    let port = u16::from_be_bytes([rest[0], rest[1]]);
    Some((host, port, &rest[2..]))
}

fn pack_socks_udp(host: &str, port: u16, payload: &[u8]) -> Vec<u8> {
    let mut out = vec![0, 0, 0];
    if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() {
        out.push(1);
        out.extend_from_slice(&ip.octets());
    } else {
        let bytes = host.as_bytes();
        out.push(3);
        out.push(bytes.len() as u8);
        out.extend_from_slice(bytes);
    }
    out.extend_from_slice(&port.to_be_bytes());
    out.extend_from_slice(payload);
    out
}
