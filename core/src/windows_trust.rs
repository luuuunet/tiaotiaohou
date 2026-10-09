#![cfg(windows)]

use std::ptr;

use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
use windows_sys::Win32::Security::Cryptography::{
    CertAddEncodedCertificateToStore, CertCloseStore, CertControlStore, CertFindCertificateInStore, CertFreeCertificateContext,
    CertGetCertificateContextProperty, CertOpenStore, CertOpenSystemStoreW, CertSerializeCertificateStoreElement, CryptHashCertificate,
    CERT_FIND_SUBJECT_STR, CERT_HASH_PROP_ID, CERT_STORE_ADD_REPLACE_EXISTING, CERT_STORE_CTRL_RESYNC, CERT_STORE_PROV_MEMORY,
    X509_ASN_ENCODING,
};
use windows_sys::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegDeleteTreeW, RegSetValueExW, HKEY_CURRENT_USER, KEY_WRITE, REG_BINARY, REG_OPTION_NON_VOLATILE,
};

const CALG_SHA1: u32 = 0x8004;
const ROOT_CERTS: &str = r"Software\Microsoft\SystemCertificates\Root\Certificates";

pub fn trust_root(der: &[u8]) -> Result<(), String> {
    let thumb = sha1_hex(der)?;
    let blob = serialize_element(der)?;
    write_blob(&thumb, &blob)?;
    resync_root();
    Ok(())
}

pub fn untrust_root(der: Option<&[u8]>, names: &[&str]) -> Result<(), String> {
    if let Some(der) = der {
        if let Ok(thumb) = sha1_hex(der) {
            let _ = delete_thumb(&thumb);
        }
    }
    for name in names {
        for thumb in find_thumbs(name) {
            let _ = delete_thumb(&thumb);
        }
    }
    resync_root();
    Ok(())
}

fn serialize_element(der: &[u8]) -> Result<Vec<u8>, String> {
    unsafe {
        let store = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, ptr::null());
        if store.is_null() {
            return Err("打不开证书仓库".into());
        }
        let mut ctx = ptr::null_mut();
        let added = CertAddEncodedCertificateToStore(
            store,
            X509_ASN_ENCODING,
            der.as_ptr(),
            der.len() as u32,
            CERT_STORE_ADD_REPLACE_EXISTING,
            &mut ctx,
        );
        if added == 0 || ctx.is_null() {
            CertCloseStore(store, 0);
            return Err("证书格式不对".into());
        }
        let mut size = 0u32;
        let _ = CertSerializeCertificateStoreElement(ctx, 0, ptr::null_mut(), &mut size);
        let mut blob = vec![0u8; size as usize];
        let ok = CertSerializeCertificateStoreElement(ctx, 0, blob.as_mut_ptr(), &mut size);
        CertFreeCertificateContext(ctx);
        CertCloseStore(store, 0);
        if ok == 0 {
            return Err("证书没法写入系统".into());
        }
        blob.truncate(size as usize);
        Ok(blob)
    }
}

fn sha1_hex(der: &[u8]) -> Result<String, String> {
    let mut hash = [0u8; 20];
    let mut len = hash.len() as u32;
    let ok = unsafe { CryptHashCertificate(0, CALG_SHA1, 0, der.as_ptr(), der.len() as u32, hash.as_mut_ptr(), &mut len) };
    if ok == 0 {
        return Err("证书没法识别".into());
    }
    Ok(hash[..len as usize].iter().map(|byte| format!("{byte:02X}")).collect())
}

fn write_blob(thumb: &str, blob: &[u8]) -> Result<(), String> {
    let path = wide(&format!(r"{ROOT_CERTS}\{thumb}"));
    let mut key = ptr::null_mut();
    let status = unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            path.as_ptr(),
            0,
            ptr::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            ptr::null(),
            &mut key,
            ptr::null_mut(),
        )
    };
    if status != ERROR_SUCCESS {
        return Err("系统没有允许写入信任列表".into());
    }
    let name = wide("Blob");
    let set = unsafe { RegSetValueExW(key, name.as_ptr(), 0, REG_BINARY, blob.as_ptr(), blob.len() as u32) };
    unsafe { RegCloseKey(key) };
    if set != ERROR_SUCCESS {
        return Err("系统没有允许写入信任列表".into());
    }
    Ok(())
}

fn delete_thumb(thumb: &str) -> Result<(), String> {
    let path = wide(&format!(r"{ROOT_CERTS}\{thumb}"));
    let status = unsafe { RegDeleteTreeW(HKEY_CURRENT_USER, path.as_ptr()) };
    if status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND {
        return Err("没法删掉旧证明".into());
    }
    Ok(())
}

fn find_thumbs(cn: &str) -> Vec<String> {
    let mut out = Vec::new();
    let store_name = wide("Root");
    let subject = wide(cn);
    unsafe {
        let store = CertOpenSystemStoreW(0, store_name.as_ptr());
        if store.is_null() {
            return out;
        }
        let mut prev = ptr::null_mut();
        loop {
            let ctx = CertFindCertificateInStore(store, X509_ASN_ENCODING, 0, CERT_FIND_SUBJECT_STR, subject.as_ptr().cast(), prev);
            if ctx.is_null() {
                break;
            }
            let mut size = 0u32;
            CertGetCertificateContextProperty(ctx, CERT_HASH_PROP_ID, ptr::null_mut(), &mut size);
            if size > 0 {
                let mut hash = vec![0u8; size as usize];
                if CertGetCertificateContextProperty(ctx, CERT_HASH_PROP_ID, hash.as_mut_ptr().cast(), &mut size) != 0 {
                    out.push(hash[..size as usize].iter().map(|byte| format!("{byte:02X}")).collect());
                }
            }
            prev = ctx;
        }
        CertCloseStore(store, 0);
    }
    out
}

fn resync_root() {
    let name = wide("Root");
    unsafe {
        let store = CertOpenSystemStoreW(0, name.as_ptr());
        if store.is_null() {
            return;
        }
        let _ = CertControlStore(store, 0, CERT_STORE_CTRL_RESYNC, ptr::null_mut());
        CertCloseStore(store, 0);
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}
