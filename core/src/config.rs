use std::net::{IpAddr, SocketAddr};

use serde::Deserialize;
use url::Url;

#[derive(Clone, Debug)]
pub struct Config {
    pub host: String,
    pub port: u16,
    pub origin: String,
    pub token: String,
    pub socks_port: u16,
    pub http_port: u16,
    pub prefer_h3: bool,
    pub fetch_enabled: bool,
    pub exit_via: String,
    pub udp_host: String,
    pub udp_port: u16,
    pub bypass: Vec<String>,
    pub rule_mode: bool,
    pub connect_ip: String,
}

#[derive(Debug, Deserialize)]
struct RawConfig {
    endpoint: String,
    token: String,
    socks_port: u16,
    http_port: u16,
    #[serde(default = "yes")]
    prefer_h3: bool,
    #[serde(default)]
    fetch_enabled: bool,
    #[serde(default = "landing")]
    exit_via: String,
    #[serde(default)]
    udp_host: String,
    #[serde(default)]
    udp_port: u16,
    #[serde(default)]
    bypass: Vec<String>,
    #[serde(default = "yes")]
    rule_mode: bool,
    #[serde(default)]
    connect_ip: String,
}

fn landing() -> String {
    "landing".into()
}

fn yes() -> bool {
    true
}

impl Config {
    pub fn parse(json: &str) -> Result<Self, String> {
        let raw: RawConfig = serde_json::from_str(json).map_err(|e| format!("配置不是合法 JSON: {e}"))?;
        if raw.token.is_empty() || raw.token.len() > 512 || raw.token.chars().any(|c| c.is_control()) {
            return Err("令牌不能为空，也不能包含换行".into());
        }
        if raw.socks_port == 0 || raw.http_port == 0 {
            return Err("本地端口不能是 0".into());
        }
        if raw.socks_port == raw.http_port {
            return Err("SOCKS 和 HTTP 端口不能相同".into());
        }
        let url = Url::parse(raw.endpoint.trim()).map_err(|_| "节点地址不合法".to_string())?;
        if url.scheme() != "https" {
            return Err("节点必须是 https:// 开头".into());
        }
        if !url.username().is_empty() || url.password().is_some() {
            return Err("节点地址不能带用户名".into());
        }
        if url.path() != "/" && url.path() != "" {
            return Err("节点地址不要带路径，路径由协议自己加".into());
        }
        let host = url.host_str().ok_or("节点缺少主机名")?.to_string();
        let port = url.port().unwrap_or(443);
        let authority = if host.contains(':') {
            if port == 443 {
                format!("[{host}]")
            } else {
                format!("[{host}]:{port}")
            }
        } else if port == 443 {
            host.clone()
        } else {
            format!("{host}:{port}")
        };
        let connect_ip = parse_connect_ip(&raw.connect_ip)?;
        let mut bypass = Vec::new();
        for item in raw.bypass {
            if let Some(host) = normalize_bypass(&item) {
                if !bypass.iter().any(|x| x == &host) {
                    bypass.push(host);
                }
            }
        }
        Ok(Config {
            host,
            port,
            origin: format!("https://{authority}"),
            token: raw.token,
            socks_port: raw.socks_port,
            http_port: raw.http_port,
            prefer_h3: raw.prefer_h3,
            fetch_enabled: raw.fetch_enabled,
            exit_via: match raw.exit_via.as_str() {
                "direct" => "direct".into(),
                "vps" => "vps".into(),
                "cdn" => "cdn".into(),
                _ => "landing".into(),
            },
            udp_host: raw.udp_host.trim().to_string(),
            udp_port: if raw.udp_port == 0 { 8444 } else { raw.udp_port },
            bypass,
            rule_mode: raw.rule_mode,
            connect_ip,
        })
    }

    pub fn is_bypass(&self, host: &str) -> bool {
        let host = host.trim_matches(|c| c == '[' || c == ']').to_ascii_lowercase();
        if self.bypass.iter().any(|rule| host_matches(&host, rule)) {
            return true;
        }
        if is_private_host(&host) {
            return true;
        }
        self.rule_mode && is_mainland(&host)
    }

    pub fn has_udp(&self) -> bool {
        !self.udp_host.is_empty() || self.exit_via == "vps"
    }

    pub fn pinned_addr(&self) -> Option<SocketAddr> {
        self.connect_ip.parse::<IpAddr>().ok().map(|ip| SocketAddr::new(ip, self.port))
    }

    pub fn udp_endpoint(&self) -> Result<(String, u16), String> {
        if !self.udp_host.is_empty() {
            return Ok((self.udp_host.clone(), self.udp_port));
        }
        if self.exit_via == "vps" {
            return Ok((self.host.clone(), self.port));
        }
        Err("没有落地服务器，游戏 UDP 不可用".into())
    }

    pub fn should_direct_vps(&self, port: u16) -> bool {
        self.has_udp() && self.exit_via != "vps" && is_game_port(port)
    }

    pub fn exit_for(&self, host: &str, port: u16) -> &str {
        if self.should_direct_vps(port) {
            return "vps";
        }
        if is_stream_host(host) {
            return match self.exit_via.as_str() {
                "direct" => "direct",
                "cdn" => "cdn",
                "vps" => "vps",
                _ => "landing",
            };
        }
        self.exit_via.as_str()
    }

    pub fn tcp_request(&self, host: &str, port: u16) -> http::Request<()> {
        self.request(http::Method::POST, "/rsq/v1/tcp")
            .header("x-rsq-host", host)
            .header("x-rsq-port", port.to_string())
            .header("x-rsq-exit", self.exit_for(host, port))
            .header("content-type", "application/octet-stream")
            .body(())
            .expect("request")
    }

    pub fn health_request(&self) -> http::Request<()> {
        self.request(http::Method::GET, "/rsq/v1/health").body(()).expect("request")
    }

    fn request(&self, method: http::Method, path: &str) -> http::request::Builder {
        http::Request::builder()
            .method(method)
            .uri(format!("{}{path}", self.origin))
            .header("authorization", format!("Bearer {}", self.token))
            .header("user-agent", "rsq/1")
            .header("x-rsq-v", "1")
            .header("cache-control", "no-store")
    }
}

fn parse_connect_ip(raw: &str) -> Result<String, String> {
    let text = raw.trim();
    if text.is_empty() {
        return Ok(String::new());
    }
    let ip = text.parse::<IpAddr>().map_err(|_| "优选 IP 不合法".to_string())?;
    if !crate::guard::is_cloudflare_ip(ip) {
        return Err("优选 IP 必须是 Cloudflare 地址".into());
    }
    Ok(ip.to_string())
}

pub fn normalize_bypass(input: &str) -> Option<String> {
    let mut text = input.trim().to_ascii_lowercase();
    if text.is_empty() || text.len() > 253 {
        return None;
    }
    if let Some(rest) = text.strip_prefix("https://") {
        text = rest.to_string();
    } else if let Some(rest) = text.strip_prefix("http://") {
        text = rest.to_string();
    }
    if let Some((host, _)) = text.split_once('/') {
        text = host.to_string();
    }
    if let Some(rest) = text.strip_prefix("*.") {
        text = rest.to_string();
    }
    if let Some((host, port)) = text.rsplit_once(':') {
        if port.chars().all(|c| c.is_ascii_digit()) {
            text = host.to_string();
        }
    }
    text = text.trim_matches(|c| c == '[' || c == ']').to_string();
    if text.is_empty() || text.contains('/') || text.contains(' ') || text.contains('@') {
        return None;
    }
    if !text.contains('.') && text.parse::<std::net::IpAddr>().is_err() {
        return None;
    }
    Some(text)
}

fn host_matches(host: &str, rule: &str) -> bool {
    host == rule || host.ends_with(&format!(".{rule}"))
}

fn is_private_host(host: &str) -> bool {
    if host == "localhost" || host.ends_with(".local") || host.ends_with(".localhost") {
        return true;
    }
    let Ok(ip) = host.parse::<std::net::Ipv4Addr>() else {
        return false;
    };
    let [a, b, _, _] = ip.octets();
    a == 0 || a == 10 || a == 127 || (a == 169 && b == 254) || (a == 172 && (16..=31).contains(&b)) || (a == 192 && b == 168) || (a == 100 && (64..=127).contains(&b))
}

fn is_mainland(host: &str) -> bool {
    if host.ends_with(".cn") {
        return true;
    }
    const ROOTS: &[&str] = &[
        "baidu.com", "bdstatic.com", "bdimg.com", "qq.com", "gtimg.com", "wechat.com", "taobao.com", "tmall.com", "alicdn.com", "aliyun.com", "alipay.com", "alibaba.com", "jd.com", "360buyimg.com", "bilibili.com", "hdslb.com", "163.com", "126.com", "netease.com", "sina.com", "weibo.com", "douyin.com", "douyinpic.com", "byteimg.com", "bytedance.com", "toutiao.com", "zhihu.com", "zhimg.com", "meituan.com", "dianping.com", "ctrip.com", "iqiyi.com", "youku.com", "sohu.com", "sogou.com", "mi.com", "xiaomi.com", "huawei.com", "pinduoduo.com", "csdn.net", "cnblogs.com", "gitee.com",
    ];
    ROOTS.iter().any(|root| host_matches(host, root))
}

pub fn is_stream_host(host: &str) -> bool {
    let host = host.trim_matches(|c| c == '[' || c == ']').to_ascii_lowercase();
    const MARKS: &[&str] = &[
        "googlevideo.com",
        "ytimg.com",
        "youtube.com",
        "youtube-nocookie.com",
        "ggpht.com",
        "nflxvideo.net",
        "nflxso.net",
        "nflximg.net",
        "netflix.com",
        "bilivideo.com",
        "bilivideo.cn",
        "akamaized.net",
        "ttvnw.net",
        "twitch.tv",
        "tiktokcdn.com",
        "tiktokv.com",
        "muscdn.com",
        "byteoversea.com",
        "ibytedtos.com",
        "ixigua.com",
        "pstatp.com",
        "iqiyi.com",
        "iqiyipic.com",
        "youku.com",
        "ykimg.com",
        "huya.com",
        "douyucdn.cn",
        "douyu.com",
    ];
    MARKS.iter().any(|mark| host == *mark || host.strip_suffix(mark).is_some_and(|rest| rest.ends_with('.')))
}

pub fn is_game_port(port: u16) -> bool {
    matches!(
        port,
        3074 | 3478 | 3479 | 3480 | 3724 | 6112 | 6113 | 7777 | 7778 | 7779 | 8088 | 25565 | 27015 | 27016 | 27017 | 27018 | 27019 | 27020 | 27031 | 27036
    )
}

#[cfg(test)]
mod tests {
    use super::Config;

    #[test]
    fn parses_https_endpoint() {
        let cfg = Config::parse(
            r#"{"endpoint":"https://rsq.example.workers.dev/","token":"abc","socks_port":1080,"http_port":8080}"#,
        )
        .unwrap();
        assert_eq!(cfg.host, "rsq.example.workers.dev");
        assert_eq!(cfg.port, 443);
        assert_eq!(cfg.origin, "https://rsq.example.workers.dev");
        assert!(cfg.prefer_h3);
        assert_eq!(cfg.exit_via, "landing");
        assert!(!cfg.has_udp());
        assert!(cfg.connect_ip.is_empty());
    }

    #[test]
    fn parses_cloudflare_connect_ip() {
        let cfg = Config::parse(
            r#"{"endpoint":"https://rsq.example.workers.dev","token":"abc","socks_port":1080,"http_port":8080,"connect_ip":"104.16.1.1"}"#,
        )
        .unwrap();
        assert_eq!(cfg.connect_ip, "104.16.1.1");
        assert_eq!(cfg.pinned_addr().unwrap().ip().to_string(), "104.16.1.1");
    }

    #[test]
    fn parses_udp_host_for_landing() {
        let cfg = Config::parse(
            r#"{"endpoint":"https://vpn.example.com","token":"abc","socks_port":1080,"http_port":8080,"exit_via":"landing","udp_host":"203.0.113.8","udp_port":8444}"#,
        )
        .unwrap();
        assert!(cfg.has_udp());
        assert_eq!(cfg.udp_endpoint().unwrap(), ("203.0.113.8".into(), 8444));
    }

    #[test]
    fn parses_cdn_exit() {
        let cfg = Config::parse(
            r#"{"endpoint":"https://vpn.example.com","token":"abc","socks_port":1080,"http_port":8080,"exit_via":"cdn","udp_host":"203.0.113.8"}"#,
        )
        .unwrap();
        assert_eq!(cfg.exit_via, "cdn");
        assert!(cfg.has_udp());
    }

    #[test]
    fn auto_exit_for_stream_and_game() {
        let landing = Config::parse(
            r#"{"endpoint":"https://vpn.example.com","token":"abc","socks_port":1080,"http_port":8080,"exit_via":"landing","udp_host":"203.0.113.8"}"#,
        )
        .unwrap();
        assert_eq!(landing.exit_for("www.example.com", 443), "landing");
        assert_eq!(landing.exit_for("r1.googlevideo.com", 443), "landing");
        assert!(landing.should_direct_vps(27015));
        assert!(!landing.should_direct_vps(443));
        let direct = Config::parse(
            r#"{"endpoint":"https://vpn.example.com","token":"abc","socks_port":1080,"http_port":8080,"exit_via":"direct"}"#,
        )
        .unwrap();
        assert_eq!(direct.exit_for("r1.googlevideo.com", 443), "direct");
        assert!(!direct.should_direct_vps(27015));
    }

    #[test]
    fn parses_vps_endpoint() {
        let cfg = Config::parse(
            r#"{"endpoint":"https://203.0.113.8:8444","token":"abc","socks_port":1080,"http_port":8080,"exit_via":"vps"}"#,
        )
        .unwrap();
        assert_eq!(cfg.host, "203.0.113.8");
        assert_eq!(cfg.port, 8444);
        assert_eq!(cfg.exit_via, "vps");
    }

    #[test]
    fn rejects_http_and_empty_token() {
        assert!(Config::parse(
            r#"{"endpoint":"http://x.workers.dev","token":"abc","socks_port":1080,"http_port":8080}"#
        )
        .is_err());
        assert!(Config::parse(
            r#"{"endpoint":"https://x.workers.dev","token":"","socks_port":1080,"http_port":8080}"#
        )
        .is_err());
    }

    #[test]
    fn bypass_matches_host_and_subdomain() {
        let cfg = Config::parse(
            r#"{"endpoint":"https://vpn.example.com","token":"abc","socks_port":1080,"http_port":8080,"bypass":["https://Baidu.com/path","*.qq.com", "8.8.8.8"]}"#,
        )
        .unwrap();
        assert!(cfg.is_bypass("baidu.com"));
        assert!(cfg.is_bypass("www.baidu.com"));
        assert!(cfg.is_bypass("news.qq.com"));
        assert!(cfg.is_bypass("8.8.8.8"));
        assert!(!cfg.is_bypass("google.com"));
        assert!(cfg.is_bypass("www.bilibili.com"));
        assert!(cfg.is_bypass("192.168.1.1"));
        assert!(cfg.rule_mode);
        let global = Config::parse(
            r#"{"endpoint":"https://vpn.example.com","token":"abc","socks_port":1080,"http_port":8080,"rule_mode":false}"#,
        )
        .unwrap();
        assert!(!global.is_bypass("www.baidu.com"));
        assert!(global.is_bypass("10.0.0.1"));
    }
}
