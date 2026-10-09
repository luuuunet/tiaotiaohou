$ErrorActionPreference = "Stop"
Set-Location "$PSScriptRoot\..\core"
cargo build --release
Set-Location "$PSScriptRoot\..\app"
flutter pub get
flutter build windows
$dll = Resolve-Path "$PSScriptRoot\..\core\target\release\rsq_core.dll"
Copy-Item $dll "$PSScriptRoot\..\app\build\windows\x64\runner\Release\rsq_core.dll" -Force
Write-Output "built app\build\windows\x64\runner\Release\rsq.exe"
