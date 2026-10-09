use std::net::IpAddr;

/// Reject targets a Worker must not dial: loopback, LAN, link-local, CGNAT, SMTP.
pub fn check_target(host: &str, port: u16) -> Result<(), String> {
    if port == 0 || port == 25 {
        return Err("这个端口不能转发".into());
    }
    if host.is_empty() || host.len() > 253 {
        return Err("主机名不合法".into());
    }
    if host.chars().any(|c| c.is_control() || matches!(c, '/' | '\\' | ' ' | '@' | '#' | '?')) {
        return Err("主机名不合法".into());
    }
    let lower = host.trim_matches(|c| c == '[' || c == ']').to_ascii_lowercase();
    if lower == "localhost"
        || lower.ends_with(".localhost")
        || lower.ends_with(".local")
        || lower == "metadata.google.internal"
    {
        return Err("内网地址不能转发".into());
    }
    if let Ok(ip) = lower.parse::<IpAddr>() {
        if is_blocked_ip(ip) {
            return Err("内网地址不能转发".into());
        }
    }
    Ok(())
}

/// Orange-cloud addresses. connect() refuses these, and dialing them drops the site's cookies.
pub fn is_cloudflare_ip(ip: IpAddr) -> bool {
    let IpAddr::V4(v4) = ip else {
        return false;
    };
    let ip = u32::from(v4);
    const NETS: &[(u32, u8)] = &[
        (cidr(173, 245, 48, 0), 20),
        (cidr(103, 21, 244, 0), 22),
        (cidr(103, 22, 200, 0), 22),
        (cidr(103, 31, 4, 0), 22),
        (cidr(141, 101, 64, 0), 18),
        (cidr(108, 162, 192, 0), 18),
        (cidr(190, 93, 240, 0), 20),
        (cidr(188, 114, 96, 0), 20),
        (cidr(197, 234, 240, 0), 22),
        (cidr(198, 41, 128, 0), 17),
        (cidr(162, 158, 0, 0), 15),
        (cidr(104, 16, 0, 0), 13),
        (cidr(104, 24, 0, 0), 14),
        (cidr(172, 64, 0, 0), 13),
        (cidr(131, 0, 72, 0), 22),
        (cidr(1, 1, 1, 0), 24),
        (cidr(1, 0, 0, 0), 24),
    ];
    NETS.iter().any(|(base, bits)| {
        let mask = u32::MAX << (32 - *bits);
        ip & mask == *base & mask
    })
}

const fn cidr(a: u32, b: u32, c: u32, d: u32) -> u32 {
    (a << 24) | (b << 16) | (c << 8) | d
}

fn is_blocked_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_unspecified()
                || v4.is_multicast()
                || o[0] == 0
                || o[0] == 100 && (o[1] & 0b1100_0000) == 64
                || o[0] == 192 && o[1] == 0 && o[2] == 2
                || o[0] == 198 && (o[1] == 18 || o[1] == 19)
                || o[0] == 198 && o[1] == 51 && o[2] == 100
                || o[0] == 203 && o[1] == 0 && o[2] == 113
        }
        IpAddr::V6(v6) => {
            let s0 = v6.segments()[0];
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || (s0 & 0xfe00) == 0xfc00
                || (s0 & 0xffc0) == 0xfe80
        }
    }
}

#[cfg(test)]
mod tests {
    use super::check_target;

    #[test]
    fn allows_public_and_blocks_local() {
        assert!(check_target("example.com", 443).is_ok());
        assert!(check_target("1.1.1.1", 853).is_ok());
        assert!(check_target("8.8.8.8", 443).is_ok());
        assert!(check_target("127.0.0.1", 443).is_err());
        assert!(check_target("10.1.2.3", 80).is_err());
        assert!(check_target("192.168.0.1", 443).is_err());
        assert!(check_target("172.16.0.1", 443).is_err());
        assert!(check_target("169.254.1.1", 443).is_err());
        assert!(check_target("100.64.0.1", 443).is_err());
        assert!(check_target("localhost", 443).is_err());
        assert!(check_target("::1", 443).is_err());
        assert!(check_target("example.com", 25).is_err());
        assert!(check_target("example.com", 0).is_err());
        assert!(check_target("bad host", 443).is_err());
        assert!(super::is_cloudflare_ip("104.16.1.1".parse().unwrap()));
        assert!(super::is_cloudflare_ip("172.64.1.1".parse().unwrap()));
        assert!(!super::is_cloudflare_ip("142.251.150.119".parse().unwrap()));
        assert!(!super::is_cloudflare_ip("124.232.159.149".parse().unwrap()));
    }
}
