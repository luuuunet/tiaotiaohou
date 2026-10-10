#include "flutter_window.h"

#include <optional>
#include <string>
#include <wtsapi32.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayIconMsg = WM_USER + 32;
constexpr UINT kTrayShow = 40001;
constexpr UINT kTrayToggle = 40002;
constexpr UINT kTrayQuit = 40003;
constexpr UINT kNetChangedMsg = WM_APP + 41;

bool CommandHasQuiet() {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == nullptr) return false;
  bool quiet = false;
  for (int i = 1; i < argc; i++) {
    if (wcscmp(argv[i], L"--quiet") == 0) quiet = true;
  }
  LocalFree(argv);
  return quiet;
}


std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return L"";
  const int len = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  std::wstring out(len > 0 ? len - 1 : 0, L'\0');
  if (len > 1) {
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), len);
  }
  return out;
}

std::string GetStringArg(const flutter::EncodableValue* args) {
  if (args == nullptr) return "";
  if (const auto* map = std::get_if<flutter::EncodableMap>(args)) {
    const auto it = map->find(flutter::EncodableValue("text"));
    if (it != map->end()) {
      if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
    }
    const auto title = map->find(flutter::EncodableValue("title"));
    const auto body = map->find(flutter::EncodableValue("body"));
    if (title != map->end() || body != map->end()) {
      return "";
    }
  }
  if (const auto* s = std::get_if<std::string>(args)) return *s;
  return "";
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {
  ZeroMemory(&tray_, sizeof(tray_));
  quiet_ = CommandHasQuiet();
}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  host_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "dev.rsq/host",
      &flutter::StandardMethodCodec::GetInstance());
  host_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (!HandleHostMethod(call, *result)) {
          result->NotImplemented();
        }
      });

  EnsureTray();
  StartStayAlive();
  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (quiet_) {
      this->HideToTray();
    } else {
      this->Show();
    }
  });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::StartStayAlive() {
  HWND hwnd = GetHandle();
  if (hwnd && WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION)) {
    session_notify_ = true;
  }
}

void FlutterWindow::StopStayAlive() {
  HWND hwnd = GetHandle();
  if (session_notify_ && hwnd) {
    WTSUnRegisterSessionNotification(hwnd);
    session_notify_ = false;
  }
}

bool FlutterWindow::HandleHostMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    flutter::MethodResult<flutter::EncodableValue>& result) {
  const auto& name = call.method_name();
  HWND hwnd = GetHandle();
  if (name == "minimize") {
    ShowWindow(hwnd, SW_MINIMIZE);
    result.Success();
    return true;
  }
  if (name == "zoom") {
    ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
    result.Success();
    return true;
  }
  if (name == "hideToTray" || name == "close") {
    HideToTray();
    result.Success();
    return true;
  }
  if (name == "showWindow") {
    ShowFromTray();
    result.Success();
    return true;
  }
  if (name == "quit") {
    QuitApp();
    result.Success();
    return true;
  }
  if (name == "drag") {
    ReleaseCapture();
    SendMessage(hwnd, WM_SYSCOMMAND, SC_MOVE | 0x0002, 0);
    result.Success();
    return true;
  }
  if (name == "setTrayTip") {
    SetTrayTip(Utf8ToWide(GetStringArg(call.arguments())));
    result.Success();
    return true;
  }
  if (name == "notify") {
    std::string title = "跳跳猴";
    std::string body;
    if (const auto* map = std::get_if<flutter::EncodableMap>(call.arguments())) {
      const auto t = map->find(flutter::EncodableValue("title"));
      const auto b = map->find(flutter::EncodableValue("body"));
      if (t != map->end()) {
        if (const auto* s = std::get_if<std::string>(&t->second)) title = *s;
      }
      if (b != map->end()) {
        if (const auto* s = std::get_if<std::string>(&b->second)) body = *s;
      }
    }
    NotifyBalloon(Utf8ToWide(title), Utf8ToWide(body));
    result.Success();
    return true;
  }
  if (name == "start" || name == "stop") {
    result.Success();
    return true;
  }
  return false;
}

void FlutterWindow::EnsureTray() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || tray_added_) return;
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = hwnd;
  tray_.uID = 1;
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_.uCallbackMessage = kTrayIconMsg;
  tray_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcsncpy_s(tray_.szTip, L"跳跳猴", _TRUNCATE);
  if (Shell_NotifyIconW(NIM_ADD, &tray_)) {
    tray_added_ = true;
  }
}

void FlutterWindow::RemoveTray() {
  if (!tray_added_) return;
  Shell_NotifyIconW(NIM_DELETE, &tray_);
  tray_added_ = false;
}

void FlutterWindow::HideToTray() {
  EnsureTray();
  HWND hwnd = GetHandle();
  if (hwnd) ShowWindow(hwnd, SW_HIDE);
}

void FlutterWindow::ShowFromTray() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  ShowWindow(hwnd, SW_SHOW);
  ShowWindow(hwnd, SW_RESTORE);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::QuitApp() {
  RemoveTray();
  HWND hwnd = GetHandle();
  if (hwnd) DestroyWindow(hwnd);
}

void FlutterWindow::SetTrayTip(const std::wstring& tip) {
  EnsureTray();
  if (!tray_added_) return;
  wcsncpy_s(tray_.szTip, tip.c_str(), _TRUNCATE);
  tray_.uFlags = NIF_TIP;
  Shell_NotifyIconW(NIM_MODIFY, &tray_);
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
}

void FlutterWindow::NotifyBalloon(const std::wstring& title, const std::wstring& body) {
  EnsureTray();
  if (!tray_added_) return;
  tray_.uFlags = NIF_INFO;
  wcsncpy_s(tray_.szInfoTitle, title.c_str(), _TRUNCATE);
  wcsncpy_s(tray_.szInfo, body.c_str(), _TRUNCATE);
  tray_.dwInfoFlags = NIIF_INFO;
  Shell_NotifyIconW(NIM_MODIFY, &tray_);
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
}

void FlutterWindow::InvokeDart(const std::string& method) {
  if (!host_channel_) return;
  host_channel_->InvokeMethod(method, std::make_unique<flutter::EncodableValue>());
}

void FlutterWindow::OnDestroy() {
  StopStayAlive();
  RemoveTray();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (message == kTrayIconMsg) {
    if (lparam == WM_LBUTTONDBLCLK || lparam == WM_LBUTTONUP) {
      ShowFromTray();
      InvokeDart("trayShow");
      return 0;
    }
    if (lparam == WM_RBUTTONUP) {
      POINT pt;
      GetCursorPos(&pt);
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, kTrayShow, L"显示窗口");
      AppendMenuW(menu, MF_STRING, kTrayToggle, L"连接 / 断开");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING, kTrayQuit, L"退出");
      SetForegroundWindow(hwnd);
      const UINT cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, 0, hwnd, nullptr);
      DestroyMenu(menu);
      if (cmd == kTrayShow) {
        ShowFromTray();
        InvokeDart("trayShow");
      } else if (cmd == kTrayToggle) {
        InvokeDart("trayToggle");
      } else if (cmd == kTrayQuit) {
        InvokeDart("trayQuit");
      }
      return 0;
    }
  }

  switch (message) {
    case WM_CLOSE:
      if (!closing_) {
        closing_ = true;
        InvokeDart("trayQuit");
      }
      return 0;
    case kNetChangedMsg:
      InvokeDart("networkChanged");
      return 0;
    case WM_POWERBROADCAST:
      if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
        InvokeDart("sessionUnlock");
        InvokeDart("networkChanged");
      }
      return TRUE;
    case WM_WTSSESSION_CHANGE:
      if (wparam == WTS_SESSION_UNLOCK) {
        InvokeDart("sessionUnlock");
      }
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
