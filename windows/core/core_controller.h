#ifndef CHRNET_CORE_CORE_CONTROLLER_H_
#define CHRNET_CORE_CORE_CONTROLLER_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace chrnet {

enum class CoreState { kStopped, kStarting, kRunning, kStopping };

const char* CoreStateName(CoreState state);

struct TunnelOptions {
  std::wstring adapter_name = L"chrnet0";
  std::string address = "198.18.0.1";
  uint8_t prefix_length = 30;
  // Windows resolves names through this address, which the config answers with
  // Xray's DNS module. Empty leaves the system DNS alone.
  std::string dns_server = "198.18.0.2";
  // Prefixes sent into the TUN. Empty means all of IPv4.
  std::vector<std::string> routes;
  bool leak_protection = true;
  uint16_t guarded_dns_port = 53;
  bool block_ipv6 = true;
  // Rebuild the tunnel when the physical network changes underneath it.
  bool follow_network_changes = true;
};

struct StartOptions {
  std::string config_json;
  bool tunnel = false;
  // Every server the config dials, as host names or IPv4 literals. Tunnel mode
  // routes all of them around the TUN.
  std::vector<std::string> server_hosts;
  // Outbound tags counted in the traffic stats. Empty counts every outbound
  // except the direct, block and DNS ones.
  std::vector<std::string> proxy_tags;
  uint16_t socks_port = 10808;
  uint16_t http_port = 10809;
  uint16_t metrics_port = 10813;
  TunnelOptions tunnel_options;
};

struct CoreError {
  std::string message;  // Shown to the user as is.
  std::string code;
};

struct CoreStatus {
  CoreState state = CoreState::kStopped;
  bool tunnel = false;
  int64_t started_at_ms = 0;  // Unix time; 0 unless running.
  // Set when the core stopped without being asked to.
  std::string error;
  std::string error_code;
};

struct TrafficStats {
  int64_t uplink = 0;
  int64_t downlink = 0;
};

struct ControllerPaths {
  std::filesystem::path xray_exe;
  // Holds the generated config only while Xray reads it.
  std::filesystem::path runtime_dir;
  std::filesystem::path log_dir;
};

// Owns one Xray process and, in tunnel mode, everything that makes Windows send
// traffic into it: the TUN address, metric and DNS server, the routes and the
// leak filters. The work runs on a single worker thread, so a user's request, a
// crash of the core and a network change can never interleave.
class CoreController {
 public:
  using StatusListener = std::function<void(const CoreStatus&)>;

  explicit CoreController(ControllerPaths paths);
  ~CoreController();
  CoreController(const CoreController&) = delete;
  CoreController& operator=(const CoreController&) = delete;

  // Runs on the worker thread for every state change. It must not call Start or
  // Stop itself, which would wait for that same thread.
  void SetStatusListener(StatusListener listener);

  // Removes routes a previous instance added and could not delete because it
  // crashed.
  void CleanupLeftovers();

  // Both block until the work is done.
  bool Start(const StartOptions& options, CoreError& error);
  void Stop();

  CoreStatus Status() const;
  bool QueryStats(TrafficStats& stats) const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

bool IsProcessElevated();

}  // namespace chrnet

#endif  // CHRNET_CORE_CORE_CONTROLLER_H_
