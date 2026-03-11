#ifndef RUNNER_VPN_SERVICE_BRIDGE_H_
#define RUNNER_VPN_SERVICE_BRIDGE_H_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

class VpnServiceBridge {
 public:
  explicit VpnServiceBridge(flutter::BinaryMessenger* messenger);
  ~VpnServiceBridge();

 private:
  struct ProxyState {
    bool captured = false;
    DWORD flags = 0;
    std::wstring server;
    std::wstring bypass;
  };

  struct StatsResult {
    int64_t download = 0;
    int64_t upload = 0;
  };

  struct TunnelRouteState {
    bool configured = false;
    ULONG original_if_index = 0;
    ULONG tun_if_index = 0;
    std::string original_gateway;
    std::string tun_gateway;
    std::vector<std::string> server_ips;
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool StartCore(const std::string& config_json, bool use_system_proxy,
                 const std::string& server_host, std::string& error);
  void StopCore();
  bool IsCoreRunning();
  std::filesystem::path ResolveXrayPath() const;
  std::filesystem::path ResolveRuntimeDir() const;
  bool SetSystemProxy(const std::wstring& proxy_server);
  bool CaptureProxyState();
  bool RestoreProxyState();
  static bool ApplyProxyState(DWORD flags, const std::wstring& server,
                              const std::wstring& bypass);
  static std::string GetComputerNameUtf8();
  static std::string GetWindowsVersion();

  // Stats polling
  void StartStatsThread();
  void StopStatsThread();
  void StatsThreadFunc();
  std::string RunStatsQuery();
  StatsResult ParseStatsOutput(const std::string& json);
  StatsResult GetCurrentStats() const;
  bool ConfigureTunnelRoutes(const std::string& server_host,
                             std::string& error);
  void RestoreTunnelRoutes();
  static bool RunRouteCommand(const std::wstring& arguments);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool is_running_ = false;
  bool use_system_proxy_ = true;
  bool proxy_enabled_ = false;
  PROCESS_INFORMATION process_info_ = {};
  bool has_process_ = false;
  HANDLE job_handle_ = nullptr;
  ProxyState proxy_state_;
  TunnelRouteState tunnel_routes_;

  // Stats state
  std::thread stats_thread_;
  std::atomic<bool> stats_running_{false};
  mutable std::mutex stats_mutex_;
  std::condition_variable stats_cv_;
  std::mutex stats_cv_mutex_;
  int64_t stats_cumulative_download_ = 0;
  int64_t stats_cumulative_upload_ = 0;

  // Serializes connect/disconnect operations running on background threads
  std::mutex core_mutex_;
};

#endif  // RUNNER_VPN_SERVICE_BRIDGE_H_
