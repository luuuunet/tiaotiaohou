$ErrorActionPreference = "Stop"
if (-not (Get-Command cargo-ndk -ErrorAction SilentlyContinue)) {
    cargo install cargo-ndk
}
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
Set-Location "$PSScriptRoot\..\core"
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o "$PSScriptRoot\..\app\android\app\src\main\jniLibs" build --release
Set-Location "$PSScriptRoot\..\app"
flutter build apk
Write-Output "built app\build\app\outputs\flutter-apk\app-release.apk"
