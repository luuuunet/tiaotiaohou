#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include <shellapi.h>

#include "win32_window.h"

class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void EnsureTray();
  void RemoveTray();
  void ShowFromTray();
  void HideToTray();
  void QuitApp();
  void SetTrayTip(const std::wstring& tip);
  void NotifyBalloon(const std::wstring& title, const std::wstring& body);
  void InvokeDart(const std::string& method);
  bool HandleHostMethod(const flutter::MethodCall<flutter::EncodableValue>& call,
                        flutter::MethodResult<flutter::EncodableValue>& result);
  void StartStayAlive();
  void StopStayAlive();

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> host_channel_;
  NOTIFYICONDATAW tray_{};
  bool tray_added_ = false;
  bool closing_ = false;
  bool quiet_ = false;
  bool session_notify_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
