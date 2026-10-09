[Setup]
AppId={{8F3C1A2E-6B47-4D91-9E20-7C5A4B8D1F63}
AppName=跳跳猴
AppVersion=1.0.0
AppPublisher=跳跳猴
DefaultDirName={localappdata}\跳跳猴
DefaultGroupName=跳跳猴
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=tiaotiaohou-Setup
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\rsq.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "chinesesimp"; MessagesFile: "Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"; Flags: checkedonce

[Files]
Source: "..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\跳跳猴"; Filename: "{app}\rsq.exe"; IconFilename: "{app}\rsq.exe"
Name: "{autodesktop}\跳跳猴"; Filename: "{app}\rsq.exe"; IconFilename: "{app}\rsq.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\rsq.exe"; Description: "启动跳跳猴"; Flags: nowait postinstall skipifsilent

[Code]
procedure DisableLocalProxy;
var
  server: string;
begin
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Internet Settings', 'ProxyServer', server) then
  begin
    if (Pos('127.0.0.1:', server) = 1) or (Pos('localhost:', server) = 1) then
      RegWriteDWordValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Internet Settings', 'ProxyEnable', 0);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    DisableLocalProxy;
end;
