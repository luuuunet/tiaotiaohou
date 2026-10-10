#![cfg(target_os = "macos")]

use std::path::Path;
use std::process::Command;

pub fn trust_pem(pem: &Path) -> Result<(), String> {
    let keychain = login_keychain()?;
    let status = Command::new("security")
        .args([
            "add-trusted-cert",
            "-r",
            "trustRoot",
            "-p",
            "ssl",
            "-p",
            "basic",
            "-k",
            &keychain,
            pem.to_str().ok_or("证书路径无效")?,
        ])
        .status()
        .map_err(|err| format!("无法写入钥匙串: {err}"))?;
    if !status.success() {
        return Err("把证书写入钥匙串失败".into());
    }
    Ok(())
}

pub fn untrust_root(pem: Option<&Path>, names: &[&str]) -> Result<(), String> {
    if let Some(pem) = pem {
        if let Some(path) = pem.to_str() {
            let _ = Command::new("security").args(["remove-trusted-cert", path]).status();
        }
    }
    let keychain = login_keychain()?;
    for name in names {
        let _ = Command::new("security")
            .args(["delete-certificate", "-c", name, &keychain])
            .status();
    }
    Ok(())
}

fn login_keychain() -> Result<String, String> {
    let home = std::env::var("HOME").map_err(|_| "找不到用户目录")?;
    Ok(format!("{home}/Library/Keychains/login.keychain-db"))
}
