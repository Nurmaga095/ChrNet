#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>

#include "vpn_service_bridge.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window, public VpnBridgeHost {
 public:
  // |start_hidden| keeps the window in the tray, for launches at Windows
  // startup.
  FlutterWindow(const flutter::DartProject& project, bool start_hidden);
  virtual ~FlutterWindow();

  // VpnBridgeHost:
  void PostToPlatformThread(std::function<void()> task) override;
  void UpdateTrayState(bool connected, const std::wstring& tooltip) override;

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;
  void AppendTrayMenuItems(HMENU menu) override;
  bool OnTrayCommand(UINT command) override;
  void OnSessionEnding() override;

 private:
  // Forwards a deep-link URL to the Dart DeepLinkService via MethodChannel.
  void SendDeepLinkToFlutter(const std::string& url);
  void RunPendingTasks();

  flutter::DartProject project_;
  bool start_hidden_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<VpnServiceBridge> vpn_service_bridge_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      deep_link_channel_;

  std::mutex task_mutex_;
  std::deque<std::function<void()>> pending_tasks_;
  // Null once the window is closing, which drops further tasks.
  HWND task_window_ = nullptr;
  bool tray_connected_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
