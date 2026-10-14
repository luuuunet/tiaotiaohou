//! 浏览器包里的核心。
//! 无参数时充当 Chrome / Edge 原生消息主机，再拉起一个脱离终端的 `--core` 进程。
//! `--core` 只听 127.0.0.1，网页打不开这条控制口。

use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;

const HOST_NAME: &str = "dev.rsq.tiaotiaohou";
const ALLOWED_ORIGIN: &str = "chrome-extension://mjgdoiafgphhklklnfloinljmlekfjad/";
const CONTROL_PORT: u16 = 17580;

fn main() {
    let mut args = std::env::args().skip(1);
    let code = match args.next().as_deref() {
        Some("--install") => install(),
        Some("--core") => run_core(Path::new(&args.next().unwrap_or_default())),
        Some(other) => {
            eprintln!("不认识的参数: {other}");
            2
        }
        None => {
            if console_stdin() {
                eprintln!("请双击旁边的启动.bat，不要直接打开这个程序。");
                0
            } else {
                native_loop()
            }
        }
    };
    std::process::exit(code);
}

fn data_dir() -> PathBuf {
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        if !local.is_empty() {
            return PathBuf::from(local).join("tiaotiaohou");
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        if !home.is_empty() {
            return PathBuf::from(home).join(".tiaotiaohou");
        }
    }
    std::env::temp_dir().join("tiaotiaohou")
}

fn console_stdin() -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        extern "C" {
            fn GetFileType(handle: isize) -> u32;
        }
        const FILE_TYPE_CHAR: u32 = 0x0002;
        unsafe { GetFileType(std::io::stdin().as_raw_handle() as isize) == FILE_TYPE_CHAR }
    }
    #[cfg(not(windows))]
    {
        false
    }
}

fn install() -> i32 {
    #[cfg(windows)]
    {
        extern "C" {
            fn SetConsoleOutputCP(code_page: u32) -> i32;
        }
        unsafe { SetConsoleOutputCP(65001) };
    }
    let exe = match std::env::current_exe() {
        Ok(path) => path,
        Err(err) => {
            eprintln!("找不到程序自己: {err}");
            return 1;
        }
    };
    let dir = data_dir();
    if let Err(err) = fs::create_dir_all(&dir) {
        eprintln!("建不了数据目录: {err}");
        return 1;
    }
    let manifest_path = dir.join("dev.rsq.tiaotiaohou.json");
    let host = serde_json::json!({
        "name": HOST_NAME,
        "description": "跳跳猴浏览器核心",
        "path": exe,
        "type": "stdio",
        "allowed_origins": [ALLOWED_ORIGIN],
    });
    let bytes = match serde_json::to_vec_pretty(&host) {
        Ok(bytes) => bytes,
        Err(err) => {
            eprintln!("写不了主机清单: {err}");
            return 1;
        }
    };
    if let Err(err) = fs::write(&manifest_path, bytes) {
        eprintln!("写不了主机清单: {err}");
        return 1;
    }
    #[cfg(not(windows))]
    {
        eprintln!("请在 Windows 上双击启动.bat。");
        return 1;
    }
    #[cfg(windows)]
    {
        let path_text = manifest_path.display().to_string();
        let keys = [
            r"HKCU\Software\Google\Chrome\NativeMessagingHosts\dev.rsq.tiaotiaohou",
            r"HKCU\Software\Microsoft\Edge\NativeMessagingHosts\dev.rsq.tiaotiaohou",
        ];
        for key in keys {
            let status = Command::new("reg")
                .args(["add", key, "/ve", "/d", &path_text, "/f"])
                .status();
            match status {
                Ok(code) if code.success() => {}
                Ok(code) => {
                    eprintln!("登记失败 {key}: {code}");
                    return 1;
                }
                Err(err) => {
                    eprintln!("登记失败: {err}");
                    return 1;
                }
            }
        }
        println!("已经登记到 Chrome 和 Edge。");
        println!("接下来加载 extension 文件夹，填好节点后点开始连接。");
        0
    }
}

#[derive(serde::Deserialize)]
struct InMsg {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    secret: String,
    #[serde(default)]
    config: Value,
}

#[derive(Serialize)]
struct OutMsg {
    ok: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    error: String,
}

fn native_loop() -> i32 {
    let mut input = std::io::stdin();
    let mut len_buf = [0u8; 4];
    if input.read_exact(&mut len_buf).is_err() {
        return 0;
    }
    let len = u32::from_le_bytes(len_buf) as usize;
    if len == 0 || len > 1_000_000 {
        write_msg(&OutMsg { ok: false, error: "消息太大".into() });
        return 1;
    }
    let mut body = vec![0u8; len];
    if input.read_exact(&mut body).is_err() {
        return 1;
    }
    let reply = match serde_json::from_slice::<InMsg>(&body) {
        Ok(msg) => handle_native(msg),
        Err(_) => OutMsg { ok: false, error: "扩展发来的消息读不懂".into() },
    };
    write_msg(&reply);
    0
}

fn handle_native(msg: InMsg) -> OutMsg {
    match msg.kind.as_str() {
        "ping" => OutMsg { ok: true, error: String::new() },
        "stop" => match stop_running(&msg.secret) {
            Ok(()) => OutMsg { ok: true, error: String::new() },
            Err(err) => OutMsg { ok: false, error: err },
        },
        "start" => match start_running(&msg.secret, &msg.config) {
            Ok(()) => OutMsg { ok: true, error: String::new() },
            Err(err) => OutMsg { ok: false, error: err },
        },
        _ => OutMsg { ok: false, error: "不认识的指令".into() },
    }
}

fn write_msg(value: &impl Serialize) {
    let body = serde_json::to_vec(value).unwrap_or_else(|_| r#"{"ok":false,"error":"内部错误"}"#.as_bytes().to_vec());
    let len = (body.len() as u32).to_le_bytes();
    let mut out = std::io::stdout();
    let _ = out.write_all(&len);
    let _ = out.write_all(&body);
    let _ = out.flush();
}

fn valid_secret(secret: &str) -> bool {
    let n = secret.len();
    (16..=128).contains(&n) && secret.bytes().all(|b| b.is_ascii_hexdigit())
}

fn start_running(secret: &str, config: &Value) -> Result<(), String> {
    if !valid_secret(secret) {
        return Err("扩展没有带上本机口令".into());
    }
    if !config.is_object() {
        return Err("节点配置不完整".into());
    }
    let config_text = serde_json::to_string(config).map_err(|_| "节点配置写不出来".to_string())?;
    if config_text.len() > 64 * 1024 {
        return Err("节点配置太大".into());
    }
    match post_json(secret, "/start", &config_text) {
        Ok(body) => {
            if let Some(err) = json_error(&body) {
                return Err(err);
            }
            return wait_until_up(secret);
        }
        Err(ControlError::Down) => {}
        Err(ControlError::Denied) => {
            stop_recorded();
        }
        Err(ControlError::Message(err)) => return Err(err),
    }
    let session = write_session(secret, config)?;
    clear_error_file();
    if let Err(err) = spawn_detached(&session) {
        let _ = fs::remove_file(&session);
        return Err(format!("核心没有启动: {err}"));
    }
    let result = wait_until_up(secret);
    let _ = fs::remove_file(&session);
    result
}

fn clear_error_file() {
    let _ = fs::remove_file(error_file());
}

fn stop_running(secret: &str) -> Result<(), String> {
    if !valid_secret(secret) {
        return Err("扩展没有带上本机口令".into());
    }
    match post_json(secret, "/stop", "") {
        Ok(_) | Err(ControlError::Down) => Ok(()),
        Err(ControlError::Denied) => Err("核心拒绝了断开".into()),
        Err(ControlError::Message(err)) => Err(err),
    }
}

fn json_error(body: &str) -> Option<String> {
    let value: Value = serde_json::from_str(body).ok()?;
    if value.get("ok").and_then(|item| item.as_bool()) == Some(false) {
        Some(value.get("error").and_then(|item| item.as_str()).unwrap_or("核心启动失败").to_string())
    } else {
        None
    }
}

fn wait_until_up(secret: &str) -> Result<(), String> {
    let mut last = "核心没有起来".to_string();
    for _ in 0..60 {
        match get_health(secret) {
            Ok(body) => {
                let value: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
                let phase = value.get("phase").and_then(|item| item.as_str()).unwrap_or("");
                let error = value.get("error").and_then(|item| item.as_str()).unwrap_or("");
                if phase == "up" || phase == "reconnecting" {
                    return Ok(());
                }
                if !error.is_empty() && phase != "starting" {
                    return Err(error.to_string());
                }
                last = if error.is_empty() { "正在连接节点".into() } else { error.to_string() };
            }
            Err(ControlError::Down) => {
                if let Some(saved) = read_error_file() {
                    return Err(saved);
                }
            }
            Err(ControlError::Denied) => return Err("核心拒绝了这次启动".into()),
            Err(ControlError::Message(err)) => last = err,
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    Err(last)
}

fn write_session(secret: &str, config: &Value) -> Result<PathBuf, String> {
    let dir = data_dir();
    fs::create_dir_all(&dir).map_err(|err| format!("建不了数据目录: {err}"))?;
    let path = dir.join(format!("session-{}.json", std::process::id()));
    let body = serde_json::json!({ "secret": secret, "config": config });
    let bytes = serde_json::to_vec(&body).map_err(|_| "节点配置写不出来".to_string())?;
    fs::write(&path, bytes).map_err(|err| format!("写不了启动配置: {err}"))?;
    Ok(path)
}

fn error_file() -> PathBuf {
    data_dir().join("core-error.txt")
}

fn pid_file() -> PathBuf {
    data_dir().join("core.pid")
}

fn read_error_file() -> Option<String> {
    let text = fs::read_to_string(error_file()).ok()?;
    let text = text.trim();
    if text.is_empty() { None } else { Some(text.to_string()) }
}

fn spawn_detached(session: &Path) -> std::io::Result<u32> {
    let exe = std::env::current_exe()?;
    let mut cmd = Command::new(exe);
    cmd.arg("--core")
        .arg(session)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            cmd.pre_exec(|| {
                extern "C" {
                    fn setsid() -> i32;
                }
                if setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    let child = cmd.spawn()?;
    Ok(child.id())
}

fn stop_recorded() {
    let Ok(text) = fs::read_to_string(pid_file()) else {
        return;
    };
    let Ok(pid) = text.trim().parse::<u32>() else {
        return;
    };
    if pid == 0 || pid == std::process::id() {
        return;
    }
    #[cfg(windows)]
    {
        let _ = Command::new("taskkill").args(["/PID", &pid.to_string(), "/F"]).output();
    }
    #[cfg(not(windows))]
    {
        let _ = Command::new("kill").args(["-9", &pid.to_string()]).output();
    }
    let _ = fs::remove_file(pid_file());
    std::thread::sleep(Duration::from_millis(300));
}

enum ControlError {
    Down,
    Denied,
    Message(String),
}

fn control_addr() -> std::net::SocketAddr {
    std::net::SocketAddr::from(([127, 0, 0, 1], CONTROL_PORT))
}

fn exchange(method: &str, path: &str, secret: &str, body: &str) -> Result<String, ControlError> {
    let mut stream = TcpStream::connect_timeout(&control_addr(), Duration::from_secs(2)).map_err(down_or_message)?;
    stream.set_read_timeout(Some(Duration::from_secs(3))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(3))).ok();
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Tth-Secret: {secret}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(req.as_bytes()).map_err(|err| ControlError::Message(err.to_string()))?;
    let text = read_limited(&mut stream, 256 * 1024).map_err(|err| ControlError::Message(err.to_string()))?;
    let status = text.split_whitespace().nth(1).unwrap_or("");
    if status == "403" {
        return Err(ControlError::Denied);
    }
    let payload = text.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
    if status != "200" {
        return Err(ControlError::Message(if payload.is_empty() { "核心没有正常回应".into() } else { payload }));
    }
    Ok(payload)
}

fn down_or_message(err: std::io::Error) -> ControlError {
    if err.kind() == std::io::ErrorKind::ConnectionRefused || err.kind() == std::io::ErrorKind::TimedOut {
        ControlError::Down
    } else {
        ControlError::Message(err.to_string())
    }
}

fn post_json(secret: &str, path: &str, body: &str) -> Result<String, ControlError> {
    exchange("POST", path, secret, body)
}

fn get_health(secret: &str) -> Result<String, ControlError> {
    exchange("GET", "/health", secret, "")
}

fn read_limited(stream: &mut impl Read, cap: usize) -> std::io::Result<String> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 2048];
    loop {
        if buf.len() >= cap {
            break;
        }
        match stream.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(err) if err.kind() == std::io::ErrorKind::TimedOut || err.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(err) => return Err(err),
        }
    }
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

#[derive(serde::Deserialize)]
struct SessionFile {
    secret: String,
    config: Value,
}

fn run_core(path: &Path) -> i32 {
    let _ = fs::create_dir_all(data_dir());
    let _ = fs::remove_file(error_file());
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(err) => {
            let _ = fs::write(error_file(), format!("读不到启动配置: {err}"));
            return 1;
        }
    };
    let _ = fs::remove_file(path);
    let session: SessionFile = match serde_json::from_str(&text) {
        Ok(session) => session,
        Err(_) => {
            let _ = fs::write(error_file(), "启动配置读不懂");
            return 1;
        }
    };
    if !valid_secret(&session.secret) || !session.config.is_object() {
        let _ = fs::write(error_file(), "启动配置不完整");
        return 1;
    }
    let listener = match TcpListener::bind(control_addr()) {
        Ok(listener) => listener,
        Err(err) => {
            let _ = fs::write(error_file(), format!("本机控制口 {CONTROL_PORT} 被占用: {err}"));
            return 1;
        }
    };
    if let Err(err) = fs::write(pid_file(), std::process::id().to_string()) {
        let _ = fs::write(error_file(), format!("写不了进程号: {err}"));
        return 1;
    }
    let config_text = match serde_json::to_string(&session.config) {
        Ok(text) => text,
        Err(_) => {
            let _ = fs::write(error_file(), "节点配置写不出来");
            return 1;
        }
    };
    if let Err(err) = rsq_core::start_json(&config_text) {
        let _ = fs::write(error_file(), err);
        let _ = fs::remove_file(pid_file());
        return 1;
    }
    for conn in listener.incoming() {
        let Ok(mut stream) = conn else { continue };
        if serve_one(&mut stream, &session.secret) {
            break;
        }
    }
    rsq_core::stop_core();
    let _ = fs::remove_file(pid_file());
    0
}

fn serve_one(stream: &mut TcpStream, secret: &str) -> bool {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(3)));
    let Ok(text) = read_request(stream) else {
        return false;
    };
    let mut lines = text.split("\r\n");
    let request = lines.next().unwrap_or("");
    let mut parts = request.split_whitespace();
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("");
    if !secret_header_ok(&text, secret) {
        let _ = write_http(stream, 403, r#"{"ok":false,"error":"拒绝"}"#);
        return false;
    }
    if method == "GET" && path == "/health" {
        let _ = write_http(stream, 200, &rsq_core::stats_json());
        return false;
    }
    if method == "POST" && path == "/stop" {
        let _ = write_http(stream, 200, r#"{"ok":true}"#);
        return true;
    }
    if method == "POST" && path == "/start" {
        let body = text.split("\r\n\r\n").nth(1).unwrap_or("");
        let reply = match rsq_core::start_json(body) {
            Ok(()) => r#"{"ok":true}"#.to_string(),
            Err(err) => serde_json::json!({"ok": false, "error": err}).to_string(),
        };
        let _ = write_http(stream, 200, &reply);
        return false;
    }
    let _ = write_http(stream, 404, r#"{"ok":false}"#);
    false
}

fn secret_header_ok(head: &str, secret: &str) -> bool {
    let Some(got) = header_value(head, "x-tth-secret") else {
        return false;
    };
    if got.len() != secret.len() {
        return false;
    }
    let mut diff = 0u8;
    for (a, b) in got.bytes().zip(secret.bytes()) {
        diff |= a ^ b;
    }
    diff == 0
}

fn read_request(stream: &mut TcpStream) -> std::io::Result<String> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 2048];
    loop {
        let n = stream.read(&mut tmp)?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.len() > 256 * 1024 {
            break;
        }
        if let Some(end) = find_header_end(&buf) {
            let header = String::from_utf8_lossy(&buf[..end]);
            let need = content_length(&header);
            if buf.len() >= end + 4 + need {
                buf.truncate(end + 4 + need);
                break;
            }
        }
    }
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|item| item == b"\r\n\r\n")
}

fn content_length(header: &str) -> usize {
    header_value(header, "content-length").and_then(|value| value.parse().ok()).unwrap_or(0)
}

fn header_value(head: &str, name: &str) -> Option<String> {
    let headers = head.split("\r\n\r\n").next().unwrap_or(head);
    for line in headers.split("\r\n").skip(1) {
        let Some((key, value)) = line.split_once(':') else { continue };
        if key.eq_ignore_ascii_case(name) {
            return Some(value.trim().to_string());
        }
    }
    None
}

fn write_http(stream: &mut TcpStream, status: u16, body: &str) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        403 => "Forbidden",
        404 => "Not Found",
        _ => "Error",
    };
    let bytes = body.as_bytes();
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        bytes.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(bytes)?;
    stream.flush()
}

#[cfg(test)]
mod tests {
    use super::header_value;

    #[test]
    fn reads_secret_header_ignoring_case() {
        let raw = "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Tth-Secret: abc\r\n\r\n";
        assert_eq!(header_value(raw, "x-tth-secret").as_deref(), Some("abc"));
    }
}
