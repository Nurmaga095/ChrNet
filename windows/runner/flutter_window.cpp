#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

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
  vpn_service_bridge_ =
      std::make_unique<VpnServiceBridge>(flutter_controller_->engine()->messenger());

  // Deep-link channel — receives onDeepLink calls sent via WM_COPYDATA
  deep_link_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.chrnet.vpn/deep_link",
          &flutter::StandardMethodCodec::GetInstance());

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  deep_link_channel_ = nullptr;
  if (vpn_service_bridge_) {
    vpn_service_bridge_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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
      flutter_controller_->engine()->ReloadSystemFonts();
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
