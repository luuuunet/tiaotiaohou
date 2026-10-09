use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::{LazyLock, Mutex, Once};
use std::time::{Duration, Instant};

use rustls::pki_types::ServerName;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::config::Config;

pub async fn lookup_node(cfg: &Config) -> Result<SocketAddr, String> {
    if let Some(addr) = cfg.pinned_addr() {
        return Ok(addr);
    }
    lookup_cached(&cfg.host, cfg.port).await
}

pub async fn resolve_dial_target(host: &str, port: u16) -> String {
    if host.parse::<IpAddr>().is_ok() {
        return host.to_string();
    }
    if let Some(ip) = doh(host).await {
        return ip;
    }
    if let Some(ip) = system_dns(host, port).await {
        return ip;
    }
    host.to_string()
}

async fn system_dns(host: &str, port: u16) -> Option<String> {
    let addresses = tokio::net::lookup_host((host, port)).await.ok()?;
    let addresses: Vec<IpAddr> = addresses.map(|item| item.ip()).collect();
    addresses
        .iter()
        .find(|ip| ip.is_ipv4() && public_ip(ip))
        .or_else(|| addresses.iter().find(|ip| public_ip(ip)))
        .map(|ip| ip.to_string())
}

fn public_ip(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            let [a, b, c, _] = ip.octets();
            !(a == 0
                || a == 10
                || a == 127
                || (a == 100 && (b & 0xc0) == 64)
                || (a == 169 && b == 254)
                || (a == 172 && (16..=31).contains(&b))
                || (a == 192 && b == 168)
                || (a == 192 && b == 0 && c == 2)
                || (a == 198 && (b == 18 || b == 19))
                || a >= 224)
        }
        IpAddr::V6(ip) => !(ip.is_loopback() || ip.is_unspecified() || ip.is_unique_local() || ip.is_unicast_link_local()),
    }
}

async fn doh(host: &str) -> Option<String> {
    for endpoint in ["dns.alidns.com", "doh.pub"] {
        if let Some(ip) = doh_one(endpoint, host).await {
            return Some(ip);
        }
    }
    None
}

async fn doh_one(endpoint: &str, host: &str) -> Option<String> {
    install_crypto();
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let config = std::sync::Arc::new(
        rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth(),
    );
    let addr = tokio::net::lookup_host((endpoint, 443)).await.ok()?.next()?;
    let tcp = TcpStream::connect(addr).await.ok()?;
    let name = ServerName::try_from(endpoint.to_string()).ok()?;
    let mut tls = tokio_rustls::TlsConnector::from(config)
        .connect(name, tcp)
        .await
        .ok()?;
    let path = format!("/resolve?name={host}&type=A");
    let request = format!(
        "GET {path} HTTP/1.1\r\nhost: {endpoint}\r\naccept: application/dns-json\r\nconnection: close\r\n\r\n"
    );
    tls.write_all(request.as_bytes()).await.ok()?;
    let mut raw = Vec::new();
    let _ = tokio::time::timeout(std::time::Duration::from_secs(5), tls.read_to_end(&mut raw)).await;
    let text = String::from_utf8_lossy(&raw);
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    let json: serde_json::Value = serde_json::from_str(&text[start..=end]).ok()?;
    let answers = json.get("Answer")?.as_array()?;
    for answer in answers {
        if answer.get("type")?.as_u64()? == 1 {
            let data = answer.get("data")?.as_str()?;
            if data.parse::<std::net::Ipv4Addr>().ok().is_some_and(|ip| public_ip(&IpAddr::V4(ip))) {
                return Some(data.to_string());
            }
        }
    }
    None
}

struct CachedAddr {
    addr: SocketAddr,
    at: Instant,
}

pub async fn lookup_cached(host: &str, port: u16) -> Result<SocketAddr, String> {
    let key = format!("{host}:{port}");
    if let Some(hit) = DNS.lock().unwrap_or_else(|err| err.into_inner()).get(&key) {
        if hit.at.elapsed() < Duration::from_secs(600) {
            return Ok(hit.addr);
        }
    }
    let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host, port))
        .await
        .map_err(|err| format!("DNS 失败: {err}"))?
        .collect();
    let addr = addrs
        .iter()
        .copied()
        .find(|item| item.is_ipv4())
        .or_else(|| addrs.first().copied())
        .ok_or_else(|| "DNS 没有结果".to_string())?;
    DNS.lock().unwrap_or_else(|err| err.into_inner()).insert(key, CachedAddr { addr, at: Instant::now() });
    Ok(addr)
}

static DNS: LazyLock<Mutex<HashMap<String, CachedAddr>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

fn install_crypto() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}
