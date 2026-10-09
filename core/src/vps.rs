use std::net::SocketAddr;
use std::sync::{Arc, Once};
use std::time::Duration;

use bytes::Bytes;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};
use tokio::sync::{mpsc, oneshot};
use tokio_rustls::TlsConnector;

use crate::config::Config;
use crate::guard::check_target;
use crate::relay::Tunnel;

const OP: Duration = Duration::from_secs(12);

pub fn encode_open(token: &str, host: &str, port: u16) -> Result<Vec<u8>, String> {
    let token = token.as_bytes();
    let host = host.as_bytes();
    if token.is_empty() || token.len() > 256 || host.is_empty() || host.len() > 253 {
        return Err("握手参数不合法".into());
    }
    let mut out = Vec::with_capacity(7 + token.len() + host.len());
    out.push(1);
    out.extend_from_slice(&(token.len() as u16).to_be_bytes());
    out.extend_from_slice(token);
    out.extend_from_slice(&(host.len() as u16).to_be_bytes());
    out.extend_from_slice(host);
    out.extend_from_slice(&port.to_be_bytes());
    Ok(out)
}

pub async fn health(cfg: &Config) -> Result<(), String> {
    let mut stream = dial(cfg).await?;
    let buf = encode_open(&cfg.token, "__health__", 1)?;
    tokio::time::timeout(OP, stream.write_all(&buf))
        .await
        .map_err(|_| "VPS 心跳超时".to_string())?
        .map_err(|err| format!("VPS 心跳失败: {err}"))?;
    let mut ack = [0u8; 1];
    tokio::time::timeout(OP, stream.read_exact(&mut ack))
        .await
        .map_err(|_| "VPS 心跳超时".to_string())?
        .map_err(|err| format!("VPS 心跳失败: {err}"))?;
    match ack[0] {
        1 => Ok(()),
        _ => Err("VPS 令牌不对".into()),
    }
}

pub async fn open(cfg: Config, host: String, port: u16, reply: oneshot::Sender<Result<Tunnel, String>>) {
    if let Err(err) = check_target(&host, port) {
        let _ = reply.send(Err(err));
        return;
    }
    match open_inner(cfg, host, port).await {
        Ok(tunnel) => {
            let _ = reply.send(Ok(tunnel));
        }
        Err(err) => {
            let _ = reply.send(Err(err));
        }
    }
}

async fn open_inner(cfg: Config, host: String, port: u16) -> Result<Tunnel, String> {
    let mut stream = dial(&cfg).await?;
    let buf = encode_open(&cfg.token, &host, port)?;
    tokio::time::timeout(OP, stream.write_all(&buf))
        .await
        .map_err(|_| "VPS 握手超时".to_string())?
        .map_err(|err| format!("VPS 握手失败: {err}"))?;
    let mut ack = [0u8; 1];
    tokio::time::timeout(OP, stream.read_exact(&mut ack))
        .await
        .map_err(|_| "VPS 握手超时".to_string())?
        .map_err(|err| format!("VPS 握手失败: {err}"))?;
    if ack[0] != 1 {
        return Err("VPS 拒绝了这条连接".into());
    }
    let (up_tx, mut up_rx) = mpsc::channel::<Bytes>(crate::relay::PIPE_QUEUE);
    let (down_tx, down_rx) = mpsc::channel::<Bytes>(crate::relay::PIPE_QUEUE);
    let (mut rd, mut wr) = tokio::io::split(stream);
    tokio::spawn(async move {
        let mut buf = vec![0u8; 64 * 1024];
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
    Ok(Tunnel { tx: up_tx, rx: down_rx })
}

pub fn encode_udp(token: &str, host: &str, port: u16, payload: &[u8]) -> Result<Vec<u8>, String> {
    let token_b = token.as_bytes();
    let host_b = host.as_bytes();
    if token_b.is_empty() || token_b.len() > 256 || host_b.is_empty() || host_b.len() > 253 {
        return Err("UDP 参数不合法".into());
    }
    let mut out = Vec::with_capacity(8 + token_b.len() + host_b.len() + payload.len());
    out.push(2);
    out.extend_from_slice(&(token_b.len() as u16).to_be_bytes());
    out.extend_from_slice(token_b);
    out.push(3);
    out.push(host_b.len() as u8);
    out.extend_from_slice(host_b);
    out.extend_from_slice(&port.to_be_bytes());
    out.extend_from_slice(payload);
    Ok(out)
}

pub fn decode_udp(buf: &[u8]) -> Result<(String, u16, &[u8]), String> {
    if buf.len() < 5 || buf[0] != 2 {
        return Err("UDP 包不合法".into());
    }
    let atyp = buf[1];
    let (host, rest) = match atyp {
        1 if buf.len() >= 8 => {
            let host = format!("{}.{}.{}.{}", buf[2], buf[3], buf[4], buf[5]);
            (host, &buf[6..])
        }
        3 if buf.len() >= 5 => {
            let n = buf[2] as usize;
            if buf.len() < 5 + n {
                return Err("UDP 包不合法".into());
            }
            let host = String::from_utf8(buf[3..3 + n].to_vec()).map_err(|_| "UDP 主机名不合法")?;
            (host, &buf[3 + n..])
        }
        _ => return Err("UDP 地址类型不支持".into()),
    };
    if rest.len() < 2 {
        return Err("UDP 包不合法".into());
    }
    let port = u16::from_be_bytes([rest[0], rest[1]]);
    Ok((host, port, &rest[2..]))
}

pub async fn udp_addr(cfg: &Config) -> Result<SocketAddr, String> {
    let (host, port) = cfg.udp_endpoint()?;
    lookup(&host, port).await
}

pub async fn vps_addr(cfg: &Config) -> Result<SocketAddr, String> {
    lookup(&cfg.host, cfg.port).await
}

async fn lookup(host: &str, port: u16) -> Result<SocketAddr, String> {
    crate::dns::lookup_cached(host, port).await.map_err(|err| format!("VPS {err}"))
}

pub async fn udp_send(cfg: &Config, sock: &UdpSocket, host: &str, port: u16, payload: &[u8]) -> Result<(), String> {
    let pkt = encode_udp(&cfg.token, host, port, payload)?;
    let addr = udp_addr(cfg).await?;
    sock.send_to(&pkt, addr)
        .await
        .map_err(|err| format!("VPS UDP 失败: {err}"))?;
    Ok(())
}

async fn dial(cfg: &Config) -> Result<tokio_rustls::client::TlsStream<TcpStream>, String> {
    install_crypto();
    let addr = vps_addr(cfg).await?;
    let tcp = tokio::time::timeout(Duration::from_secs(10), TcpStream::connect(addr))
        .await
        .map_err(|_| "VPS TCP 超时".to_string())?
        .map_err(|err| format!("VPS TCP 失败: {err}"))?;
    crate::relay::tune(&tcp);
    let name = ServerName::try_from(cfg.host.clone()).map_err(|_| "VPS 主机名不合法".to_string())?;
    let tls = TlsConnector::from(Arc::new(tls_insecure()?));
    tokio::time::timeout(Duration::from_secs(10), tls.connect(name, tcp))
        .await
        .map_err(|_| "VPS TLS 超时".to_string())?
        .map_err(|err| format!("VPS TLS 失败: {err}"))
}

fn tls_insecure() -> Result<ClientConfig, String> {
    let config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(SkipServerCert))
        .with_no_client_auth();
    Ok(config)
}

fn install_crypto() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

#[derive(Debug)]
struct SkipServerCert;

impl ServerCertVerifier for SkipServerCert {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::{decode_udp, encode_open, encode_udp};

    #[test]
    fn handshake_layout() {
        let buf = encode_open("ab", "ex.com", 443).unwrap();
        assert_eq!(buf[0], 1);
        assert_eq!(&buf[1..3], &[0, 2]);
        assert_eq!(&buf[3..5], b"ab");
    }

    #[test]
    fn udp_roundtrip() {
        let reply = {
            let mut r = vec![2, 3, 12];
            r.extend_from_slice(b"game.example");
            r.extend_from_slice(&7777u16.to_be_bytes());
            r.extend_from_slice(b"hi");
            r
        };
        let (host, port, payload) = decode_udp(&reply).unwrap();
        assert_eq!(host, "game.example");
        assert_eq!(port, 7777);
        assert_eq!(payload, b"hi");
        let _ = encode_udp("tok", "game.example", 7777, b"hi").unwrap();
    }
}
