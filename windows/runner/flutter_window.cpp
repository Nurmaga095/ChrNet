#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Wakes the platform thread to run tasks queued by background threads.
constexpr UINT kRunTasksMessage = WM_APP + 2;
constexpr UINT kTrayCommandToggle = 2003;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

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
  {
    std::lock_guard<std::mutex> lock(task_mutex_);
    task_window_ = GetHandle();
  }
  vpn_service_bridge_ = std::make_unique<VpnServiceBridge>(
      flutter_controller_->engine()->messenger(), this);

  // Deep-link channel — receives onDeepLink calls sent via WM_COPYDATA
  deep_link_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.chrnet.vpn/deep_link",
          &flutter::StandardMethodCodec::GetInstance());

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) {
      this->Show();
    }
  });
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  {
    std::lock_guard<std::mutex> lock(task_mutex_);
    task_window_ = nullptr;
    pending_tasks_.clear();
  }
  deep_link_channel_ = nullptr;
  // Stops the connection and restores the proxy before the engine goes away.
  vpn_service_bridge_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::PostToPlatformThread(std::function<void()> task) {
  HWND window = nullptr;
  {
    std::lock_guard<std::mutex> lock(task_mutex_);
    if (task_window_ == nullptr) return;
    pending_tasks_.push_back(std::move(task));
    window = task_window_;
  }
  PostMessageW(window, kRunTasksMessage, 0, 0);
}

void FlutterWindow::RunPendingTasks() {
  std::deque<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(task_mutex_);
    tasks.swap(pending_tasks_);
  }
  for (auto& task : tasks) {
    if (flutter_controller_) task();
  }
}

void FlutterWindow::UpdateTrayState(bool connected,
                                    const std::wstring& tooltip) {
  tray_connected_ = connected;
  SetTrayTooltip(tooltip);
}

void FlutterWindow::AppendTrayMenuItems(HMENU menu) {
  AppendMenuW(menu, MF_STRING | MF_GRAYED, 0,
              tray_connected_ ? L"ChrNet: подключено" : L"ChrNet: не подключено");
  AppendMenuW(menu, MF_STRING, kTrayCommandToggle,
              tray_connected_ ? L"Отключить VPN" : L"Подключить VPN");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
}

bool FlutterWindow::OnTrayCommand(UINT command) {
  if (command != kTrayCommandToggle) return false;
  if (vpn_service_bridge_) vpn_service_bridge_->RequestToggleFromTray();
  return true;
}

void FlutterWindow::OnSessionEnding() {
  // Windows may terminate the process right after this returns, so the proxy
  // settings have to be restored now, not in the destructor.
  if (vpn_service_bridge_) vpn_service_bridge_->ShutdownConnection();
}

void FlutterWindow::SendDeepLinkToFlutter(const std::string& url) {
  if (!deep_link_channel_) return;
  deep_link_channel_->InvokeMethod(
      "onDeepLink",
      std::make_unique<flutter::EncodableValue>(url));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kRunTasksMessage) {
    RunPendingTasks();
    return 0;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;

    case WM_COPYDATA: {
      auto* cds = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (cds && cds->dwData == 0x43484E54 && cds->lpData && cds->cbData > 0) {
        std::string url(static_cast<const char*>(cds->lpData),
                        cds->cbData - 1);
        SendDeepLinkToFlutter(url);
      }
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
