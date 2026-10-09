use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use rcgen::{BasicConstraints, CertificateParams, DnType, ExtendedKeyUsagePurpose, IsCa, KeyPair, KeyUsagePurpose};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName};
use rustls::ServerConfig;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_rustls::TlsAcceptor;

use crate::config::Config;

static LEAF: OnceLock<Mutex<HashMap<String, Arc<ServerConfig>>>> = OnceLock::new();

pub async fn serve(socket: TcpStream, cfg: &Config, host: &str, port: u16) -> std::io::Result<()> {
    let acceptor = match acceptor_for(host) {
        Ok(acceptor) => acceptor,
        Err(err) => {
            let _ = socket;
            return Err(std::io::Error::other(err));
        }
    };
    let tls = acceptor.accept(socket).await?;
    let (mut reader, mut writer) = tokio::io::split(tls);
    loop {
        let Some(request) = read_http(&mut reader).await? else {
            break;
        };
        let scheme = if port == 443 { "https" } else { "http" };
        let url = format!("{scheme}://{host}{}", request.path);
        let response = match tokio::time::timeout(
            std::time::Duration::from_secs(20),
            worker_fetch(cfg, &request.method, &url, &request.headers, &request.body),
        )
        .await
        {
            Ok(Ok(response)) => response,
            Ok(Err(err)) => HttpResponse {
                status: 502,
                reason: "Bad Gateway".into(),
                headers: vec![("content-type".into(), "text/plain".into())],
                body: err.into_bytes(),
            },
            Err(_) => HttpResponse {
                status: 504,
                reason: "Gateway Timeout".into(),
                headers: vec![("content-type".into(), "text/plain".into())],
                body: b"fetch timeout".to_vec(),
            },
        };
        write_http(&mut writer, &response).await?;
        let close = request
            .headers
            .iter()
            .any(|(name, value)| name.eq_ignore_ascii_case("connection") && value.eq_ignore_ascii_case("close"));
        if close || request.method.eq_ignore_ascii_case("CONNECT") {
            break;
        }
    }
    Ok(())
}

struct HttpRequest {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

struct HttpResponse {
    status: u16,
    reason: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

async fn read_http(reader: &mut (impl AsyncReadExt + Unpin)) -> std::io::Result<Option<HttpRequest>> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    let header_end = loop {
        if buf.len() > 64 * 1024 {
            return Err(std::io::Error::other("请求头太大"));
        }
        let n = reader.read(&mut tmp).await?;
        if n == 0 {
            return Ok(None);
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break end + 4;
        }
    };
    let header_text = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut lines = header_text.split("\r\n");
    let Some(start) = lines.next() else {
        return Ok(None);
    };
    let mut parts = start.split_whitespace();
    let method = parts.next().unwrap_or("GET").to_string();
    let path = parts.next().unwrap_or("/").to_string();
    let mut headers = Vec::new();
    let mut length = 0usize;
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim().to_string();
        let value = value.trim().to_string();
        if name.eq_ignore_ascii_case("content-length") {
            length = value.parse().unwrap_or(0);
        }
        headers.push((name, value));
    }
    let mut body = buf[header_end..].to_vec();
    while body.len() < length {
        let n = reader.read(&mut tmp).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    body.truncate(length);
    Ok(Some(HttpRequest { method, path, headers, body }))
}

async fn write_http(writer: &mut (impl AsyncWriteExt + Unpin), response: &HttpResponse) -> std::io::Result<()> {
    let mut head = format!("HTTP/1.1 {} {}\r\n", response.status, response.reason);
    let mut has_len = false;
    for (name, value) in &response.headers {
        if name.eq_ignore_ascii_case("transfer-encoding") || name.eq_ignore_ascii_case("connection") {
            continue;
        }
        if name.eq_ignore_ascii_case("content-length") {
            has_len = true;
        }
        head.push_str(name);
        head.push_str(": ");
        head.push_str(value);
        head.push_str("\r\n");
    }
    if !has_len {
        head.push_str(&format!("content-length: {}\r\n", response.body.len()));
    }
    head.push_str("connection: close\r\n\r\n");
    writer.write_all(head.as_bytes()).await?;
    writer.write_all(&response.body).await?;
    writer.flush().await?;
    Ok(())
}

async fn worker_fetch(
    cfg: &Config,
    method: &str,
    url: &str,
    headers: &[(String, String)],
    body: &[u8],
) -> Result<HttpResponse, String> {
    let mut pairs = Vec::new();
    for (name, value) in headers {
        let lower = name.to_ascii_lowercase();
        if matches!(
            lower.as_str(),
            "host" | "connection" | "proxy-connection" | "content-length" | "transfer-encoding" | "upgrade" | "te" | "trailer"
        ) {
            continue;
        }
        pairs.push(serde_json::json!([name, value]));
    }
    let host = url.split("://").nth(1).unwrap_or("").split('/').next().unwrap_or("");
    let host = host.split(':').next().unwrap_or(host);
    let resolved = crate::dns::resolve_dial_target(host, if url.starts_with("https") { 443 } else { 80 }).await;
    let ip = match resolved.parse::<std::net::IpAddr>() {
        Ok(addr) if !crate::guard::is_cloudflare_ip(addr) => resolved,
        _ => String::new(),
    };
    let meta = serde_json::json!({
        "method": method,
        "url": url,
        "ip": ip,
        "headers": pairs,
    });
    let meta_bytes = meta.to_string().into_bytes();
    let mut payload = Vec::with_capacity(4 + meta_bytes.len() + body.len());
    payload.extend_from_slice(&(meta_bytes.len() as u32).to_be_bytes());
    payload.extend_from_slice(&meta_bytes);
    payload.extend_from_slice(body);

    client_config_install();
    let tls = client_tls_config()?;
    let addr = crate::dns::lookup_node(cfg).await?;
    let tcp = TcpStream::connect(addr).await.map_err(|err| format!("连接节点失败: {err}"))?;
    let name = ServerName::try_from(cfg.host.clone()).map_err(|_| "SNI 不合法".to_string())?;
    let mut tls = tokio_rustls::TlsConnector::from(tls)
        .connect(name, tcp)
        .await
        .map_err(|err| format!("节点 TLS 失败: {err}"))?;
    let path = "/rsq/v1/fetch";
    let request = format!(
        "POST {path} HTTP/1.1\r\nhost: {}\r\nauthorization: Bearer {}\r\ncontent-type: application/octet-stream\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
        cfg.host,
        cfg.token,
        payload.len()
    );
    tls.write_all(request.as_bytes()).await.map_err(|err| err.to_string())?;
    tls.write_all(&payload).await.map_err(|err| err.to_string())?;
    let raw = read_http_message(&mut tls).await.map_err(|err| err.to_string())?;
    parse_response(&raw)
}

async fn read_http_message(socket: &mut (impl AsyncReadExt + Unpin)) -> std::io::Result<Vec<u8>> {
    let mut raw = Vec::new();
    let mut tmp = [0u8; 8192];
    let header_end = loop {
        let n = socket.read(&mut tmp).await?;
        if n == 0 {
            return Err(std::io::Error::other("节点提前关闭"));
        }
        raw.extend_from_slice(&tmp[..n]);
        if let Some(end) = raw.windows(4).position(|item| item == b"\r\n\r\n") {
            break end;
        }
        if raw.len() > 1024 * 1024 {
            return Err(std::io::Error::other("响应头太大"));
        }
    };
    let header = String::from_utf8_lossy(&raw[..header_end]);
    let mut length: Option<usize> = None;
    let mut chunked = false;
    for line in header.split("\r\n").skip(1) {
        let Some((name, value)) = line.split_once(':') else { continue };
        if name.eq_ignore_ascii_case("content-length") {
            length = value.trim().parse().ok();
        }
        if name.eq_ignore_ascii_case("transfer-encoding") && value.to_ascii_lowercase().contains("chunked") {
            chunked = true;
        }
    }
    if let Some(length) = length {
        let need = header_end + 4 + length;
        while raw.len() < need {
            let n = socket.read(&mut tmp).await?;
            if n == 0 {
                break;
            }
            raw.extend_from_slice(&tmp[..n]);
        }
        return Ok(raw);
    }
    if chunked {
        while !raw.ends_with(b"0\r\n\r\n") && raw.len() < 8 * 1024 * 1024 {
            let n = socket.read(&mut tmp).await?;
            if n == 0 {
                break;
            }
            raw.extend_from_slice(&tmp[..n]);
        }
        return Ok(decode_chunked(&raw, header_end + 4));
    }
    loop {
        match tokio::time::timeout(std::time::Duration::from_secs(2), socket.read(&mut tmp)).await {
            Ok(Ok(0)) | Ok(Err(_)) | Err(_) => break,
            Ok(Ok(n)) => {
                raw.extend_from_slice(&tmp[..n]);
                if raw.len() > 8 * 1024 * 1024 {
                    break;
                }
            }
        }
    }
    Ok(raw)
}

fn decode_chunked(raw: &[u8], _index: usize) -> Vec<u8> {
    let header_end = raw.windows(4).position(|item| item == b"\r\n\r\n").unwrap_or(0);
    let mut body = Vec::new();
    let mut index = header_end + 4;
    while index < raw.len() {
        let line_end = raw[index..].windows(2).position(|item| item == b"\r\n").unwrap_or(raw.len() - index);
        let line = String::from_utf8_lossy(&raw[index..index + line_end]);
        let size = usize::from_str_radix(line.trim().split(';').next().unwrap_or("0"), 16).unwrap_or(0);
        index += line_end + 2;
        if size == 0 || index + size > raw.len() {
            break;
        }
        body.extend_from_slice(&raw[index..index + size]);
        index += size + 2;
    }
    let mut rebuilt = raw[..header_end].to_vec();
    rebuilt.extend_from_slice(b"\r\n\r\n");
    rebuilt.extend_from_slice(&body);
    rebuilt
}

fn parse_response(raw: &[u8]) -> Result<HttpResponse, String> {
    let end = raw.windows(4).position(|w| w == b"\r\n\r\n").ok_or("节点没有返回完整响应")?;
    let text = String::from_utf8_lossy(&raw[..end]);
    let mut lines = text.split("\r\n");
    let status_line = lines.next().unwrap_or("");
    let mut parts = status_line.splitn(3, ' ');
    let _http = parts.next();
    let status: u16 = parts.next().unwrap_or("502").parse().unwrap_or(502);
    let reason = parts.next().unwrap_or("Bad Gateway").to_string();
    let mut headers = Vec::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.push((name.trim().to_string(), value.trim().to_string()));
        }
    }
    Ok(HttpResponse {
        status,
        reason,
        headers,
        body: raw[end + 4..].to_vec(),
    })
}

fn client_tls_config() -> Result<Arc<rustls::ClientConfig>, String> {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    Ok(Arc::new(
        rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth(),
    ))
}

fn acceptor_for(host: &str) -> Result<TlsAcceptor, String> {
    let cache = LEAF.get_or_init(|| Mutex::new(HashMap::new()));
    let mut guard = cache.lock().unwrap_or_else(|err| err.into_inner());
    if let Some(config) = guard.get(host) {
        return Ok(TlsAcceptor::from(config.clone()));
    }
    client_config_install();
    let (ca_cert, ca_key) = load_or_create_ca()?;
    let leaf_key = KeyPair::generate().map_err(|err| err.to_string())?;
    let mut params = CertificateParams::new(vec![host.to_string()]).map_err(|err| err.to_string())?;
    params.distinguished_name.push(DnType::CommonName, host);
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature, KeyUsagePurpose::KeyEncipherment];
    params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    params.not_before = rcgen::date_time_ymd(2024, 1, 1);
    params.not_after = rcgen::date_time_ymd(2035, 1, 1);
    let leaf = params
        .signed_by(&leaf_key, &ca_cert, &ca_key)
        .map_err(|err| err.to_string())?;
    let cert = CertificateDer::from(leaf.der().to_vec());
    let ca_der = CertificateDer::from(ca_cert.der().to_vec());
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(leaf_key.serialize_der()));
    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert, ca_der], key)
        .map_err(|err| err.to_string())?;
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    let config = Arc::new(config);
    guard.insert(host.to_string(), config.clone());
    Ok(TlsAcceptor::from(config))
}

pub fn ensure_trusted_ca() -> Result<(), String> {
    let _ = load_or_create_ca()?;
    Ok(())
}

pub fn remove_trusted_ca() -> Result<(), String> {
    if !cfg!(windows) {
        return Ok(());
    }
    let der = current_ca_der();
    #[cfg(windows)]
    crate::windows_trust::untrust_root(der.as_deref(), &["跳跳猴", "Crush VPN"])?;
    let marker = ca_dir().join("ca-trusted.txt");
    let _ = std::fs::remove_file(marker);
    Ok(())
}

fn current_ca_der() -> Option<Vec<u8>> {
    let pem = std::fs::read_to_string(ca_dir().join("ca-cert.pem")).ok()?;
    pem_to_der(&pem).ok()
}

fn load_or_create_ca() -> Result<(rcgen::Certificate, KeyPair), String> {
    let dir = ca_dir();
    std::fs::create_dir_all(&dir).map_err(|err| err.to_string())?;
    let cert_path = dir.join("ca-cert.pem");
    let key_path = dir.join("ca-key.pem");
    let version_path = dir.join("ca-version.txt");
    let current = std::fs::read_to_string(&version_path).unwrap_or_default();
    if current.trim() == "4" && cert_path.exists() && key_path.exists() {
        let cert_pem = std::fs::read_to_string(&cert_path).map_err(|err| err.to_string())?;
        let key_pem = std::fs::read_to_string(&key_path).map_err(|err| err.to_string())?;
        let key = KeyPair::from_pem(&key_pem).map_err(|err| err.to_string())?;
        let params = CertificateParams::from_ca_cert_pem(&cert_pem).map_err(|err| err.to_string())?;
        let cert = params.self_signed(&key).map_err(|err| err.to_string())?;
        install_ca(cert.der().as_ref())?;
        return Ok((cert, key));
    }
    let _ = std::fs::remove_file(&cert_path);
    let _ = std::fs::remove_file(&key_path);
    let key = KeyPair::generate().map_err(|err| err.to_string())?;
    let mut params = CertificateParams::new(Vec::<String>::new()).map_err(|err| err.to_string())?;
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    params.distinguished_name.push(DnType::CommonName, "跳跳猴");
    params.not_before = rcgen::date_time_ymd(2024, 1, 1);
    params.not_after = rcgen::date_time_ymd(2035, 1, 1);
    let cert = params.self_signed(&key).map_err(|err| err.to_string())?;
    std::fs::write(&cert_path, cert.pem()).map_err(|err| err.to_string())?;
    std::fs::write(&key_path, key.serialize_pem()).map_err(|err| err.to_string())?;
    std::fs::write(&version_path, "4").map_err(|err| err.to_string())?;
    #[cfg(windows)]
    let _ = crate::windows_trust::untrust_root(None, &["Crush VPN"]);
    install_ca(cert.der().as_ref())?;
    Ok((cert, key))
}

fn install_ca(der: &[u8]) -> Result<(), String> {
    if !cfg!(windows) {
        return Ok(());
    }
    let marker = ca_dir().join("ca-trusted.txt");
    if std::fs::read_to_string(&marker).unwrap_or_default().trim() == "4" {
        return Ok(());
    }
    #[cfg(windows)]
    crate::windows_trust::trust_root(der)?;
    let _ = std::fs::write(&marker, "4");
    Ok(())
}

fn pem_to_der(pem: &str) -> Result<Vec<u8>, String> {
    let start = pem.find("-----BEGIN CERTIFICATE-----").ok_or("证书文件坏了")?;
    let rest = &pem[start + "-----BEGIN CERTIFICATE-----".len()..];
    let end = rest.find("-----END CERTIFICATE-----").ok_or("证书文件坏了")?;
    let b64: String = rest[..end].chars().filter(|ch| !ch.is_whitespace()).collect();
    decode_b64(&b64)
}

fn decode_b64(input: &str) -> Result<Vec<u8>, String> {
    fn val(ch: u8) -> Option<u8> {
        match ch {
            b'A'..=b'Z' => Some(ch - b'A'),
            b'a'..=b'z' => Some(ch - b'a' + 26),
            b'0'..=b'9' => Some(ch - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'=' {
            break;
        }
        let a = val(bytes[i]).ok_or("证书文件坏了")?;
        let b = val(*bytes.get(i + 1).ok_or("证书文件坏了")?).ok_or("证书文件坏了")?;
        out.push((a << 2) | (b >> 4));
        let cch = *bytes.get(i + 2).unwrap_or(&b'=');
        if cch == b'=' {
            break;
        }
        let c = val(cch).ok_or("证书文件坏了")?;
        out.push((b << 4) | (c >> 2));
        let dch = *bytes.get(i + 3).unwrap_or(&b'=');
        if dch == b'=' {
            break;
        }
        let d = val(dch).ok_or("证书文件坏了")?;
        out.push((c << 6) | d);
        i += 4;
    }
    Ok(out)
}

fn ca_dir() -> PathBuf {
    let base = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("CrushVpn")
}

pub fn client_config_install() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}
