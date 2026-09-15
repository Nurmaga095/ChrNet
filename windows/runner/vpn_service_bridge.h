#ifndef RUNNER_VPN_SERVICE_BRIDGE_H_
#define RUNNER_VPN_SERVICE_BRIDGE_H_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "core_backend.h"
#include "service_client.h"

// What the bridge needs from the window hosting the Flutter view.
class VpnBridgeHost {
 public:
  virtual ~VpnBridgeHost() = default;
  // Runs |task| on the platform thread, the only one allowed to call into the
  // Flutter engine. Tasks posted while the window is closing are dropped.
  virtual void PostToPlatformThread(std::function<void()> task) = 0;
  virtual void UpdateTrayState(bool connected, const std::wstring& tooltip) = 0;
};

// Serves com.chrnet.vpn/service on Windows. Work that can block, talking to the
// service or starting the core, runs on one worker thread in request order;
// replies and events travel back through the host's platform thread.
class VpnServiceBridge {
 public:
  VpnServiceBridge(flutter::BinaryMessenger* messenger, VpnBridgeHost* host);
  ~VpnServiceBridge();
  VpnServiceBridge(const VpnServiceBridge&) = delete;
  VpnServiceBridge& operator=(const VpnServiceBridge&) = delete;

  // Stops the connection and puts the user's proxy settings back, right away
  // and on the calling thread. For the end of a Windows session and app exit.
  void ShutdownConnection();

  // The tray's connect/disconnect item. The Dart side owns the connection
  // flow, so the request is forwarded there.
  void RequestToggleFromTray();

  // Undoes the system proxy a killed or crashed instance left pointing at a
  // core that no longer runs. Used by "chrnet.exe --cleanup" in the installer.
  static void RestoreStaleSystemProxy();

 private:
  using Result =
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void RunOnWorker(std::function<void()> task);
  void WorkerLoop();
  void StopWorker();
  void ReplySuccess(const Result& result,
                    flutter::EncodableValue value = flutter::EncodableValue());
  void ReplyError(const Result& result, const std::string& code,
                  const std::string& message);

  // Worker thread only.
  void SyncOnStartup();
  CoreBackend* SelectBackendForStart();
  CoreBackend* BackendForQueries();
  void RestoreProxyIfNeeded();
  void OnBackendStatus(const chrnet::CoreStatus& status);

  VpnBridgeHost* host_;
  std::shared_ptr<std::atomic<bool>> alive_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  std::mutex worker_mutex_;
  std::condition_variable worker_cv_;
  std::deque<std::function<void()>> worker_queue_;
  bool worker_stop_ = false;
  std::thread worker_;

  // Owned by the worker thread; the platform thread takes over only after the
  // worker has been stopped.
  std::unique_ptr<ServiceClient> service_;
  std::unique_ptr<CoreBackend> in_process_;
  CoreBackend* active_ = nullptr;
  bool proxy_enabled_ = false;
  uint16_t http_port_ = 10809;
  bool connection_shut_down_ = false;
};

#endif  // RUNNER_VPN_SERVICE_BRIDGE_H_
