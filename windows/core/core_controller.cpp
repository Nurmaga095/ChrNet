#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include "core_controller.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <optional>
#include <thread>

#include "json.h"
#include "log.h"
#include "net_util.h"
#include "string_util.h"
#include "wfp_guard.h"

namespace chrnet {

namespace {

constexpr wchar_t kLeftoversKey[] = L"SOFTWARE\\ChrNet\\Service";
constexpr wchar_t kLeftoverRoutesValue[] = L"ActiveRoutes";
constexpr ULONG kTunInterfaceMetric = 1;
constexpr auto kAdapterTimeout = std::chrono::seconds(8);
constexpr auto kAddressTimeout = std::chrono::seconds(3);
constexpr auto kListenerTimeout = std::chrono::seconds(8);
constexpr auto kPortReleaseTimeout = std::chrono::seconds(3);
// Route and interface notifications arrive in bursts while a network comes up;
// acting only after they have been quiet this long avoids rebuilding the
// tunnel several times for one Wi-Fi switch.
constexpr auto kNetworkSettleDelay = std::chrono::milliseconds(2500);

// Keeps Xray's log away from any path an imported config names. Xray merges
// config files in order, and a later file replaces the whole "log" section,
// so this one always wins. Without it a config could make the core, which runs
// as SYSTEM under the service, write log lines into arbitrary files.
constexpr char kOverrideConfig[] =
    R"({"log":{"loglevel":"warning","access":"none","error":"","dnsLog":false}})";

int64_t NowUnixMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

bool WriteBytes(const std::filesystem::path& path, const std::string& content) {
  HANDLE file = CreateFileW(path.wstring().c_str(), GENERIC_WRITE,
                            FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const BOOL ok = WriteFile(file, content.data(),
                            static_cast<DWORD>(content.size()), &written,
                            nullptr);
  CloseHandle(file);
  return ok && written == content.size();
}

std::string ReplaceAll(std::string text, const std::string& from,
                       const std::string& to) {
  for (size_t pos = text.find(from); pos != std::string::npos;
       pos = text.find(from, pos + to.size())) {
    text.replace(pos, from.size(), to);
  }
  return text;
}

// The config builder marks every outbound that opens its own sockets with this
// placeholder in tunnel mode. Bound to the physical adapter's address, their
// connections leave through that adapter even though the TUN owns the default
// routes, so they can never loop back into the core.
std::string BindOutboundsToAddress(const std::string& config,
                                   const std::string& address) {
  return ReplaceAll(config, R"("sendThrough":"0.0.0.0")",
                    R"("sendThrough":")" + address + "\"");
}

std::string ToLowerCopy(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](char ch) {
    return (ch >= 'A' && ch <= 'Z') ? static_cast<char>(ch - 'A' + 'a') : ch;
  });
  return value;
}

// The last few meaningful lines of xray.log, for error messages.
std::string XrayLogSummary(const std::filesystem::path& path) {
  HANDLE file = CreateFileW(path.wstring().c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE |
                                FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return {};
  LARGE_INTEGER size{};
  GetFileSizeEx(file, &size);
  constexpr LONGLONG kWindow = 8192;
  LARGE_INTEGER offset{};
  offset.QuadPart = size.QuadPart > kWindow ? size.QuadPart - kWindow : 0;
  SetFilePointerEx(file, offset, nullptr, FILE_BEGIN);
  std::string text(static_cast<size_t>(size.QuadPart - offset.QuadPart), '\0');
  DWORD read = 0;
  if (!text.empty()) {
    ReadFile(file, text.data(), static_cast<DWORD>(text.size()), &read,
             nullptr);
  }
  CloseHandle(file);
  text.resize(read);

  std::vector<std::string> lines;
  size_t start = 0;
  while (start < text.size()) {
    size_t end = text.find('\n', start);
    if (end == std::string::npos) end = text.size();
    auto line = TrimAscii(std::string_view(text).substr(start, end - start));
    if (!line.empty()) lines.push_back(std::move(line));
    start = end + 1;
  }

  std::vector<std::string> picked;
  for (auto it = lines.rbegin(); it != lines.rend() && picked.size() < 3; ++it) {
    const auto lower = ToLowerCopy(*it);
    if (lower.find("fail") != std::string::npos ||
        lower.find("error") != std::string::npos ||
        lower.find("panic") != std::string::npos ||
        lower.find("invalid") != std::string::npos) {
      picked.push_back(*it);
    }
  }
  // Startup chatter says nothing about why the core stopped; an empty summary
  // is better than a misleading one.
  std::reverse(picked.begin(), picked.end());

  std::string summary;
  for (const auto& line : picked) {
    if (!summary.empty()) summary += " | ";
    summary += line;
  }
  if (summary.size() > 600) summary = summary.substr(summary.size() - 600);
  return summary;
}

std::string SerializeRoute(const net::RouteEntry& route) {
  return std::to_string(route.if_index) + "|" +
         net::FormatIpv4(route.destination.address) + "/" +
         std::to_string(route.destination.length) + "|" +
         net::FormatIpv4(route.next_hop);
}

std::optional<net::RouteEntry> ParseRoute(const std::string& text) {
  const auto first = text.find('|');
  const auto second = text.find('|', first == std::string::npos ? 0 : first + 1);
  if (first == std::string::npos || second == std::string::npos) {
    return std::nullopt;
  }
  const auto destination = net::ParseIpv4Prefix(text.substr(first + 1, second - first - 1));
  const auto next_hop = net::ParseIpv4(text.substr(second + 1));
  const unsigned long if_index = strtoul(text.substr(0, first).c_str(), nullptr, 10);
  if (!destination || !next_hop || if_index == 0) return std::nullopt;
  net::RouteEntry route;
  route.if_index = static_cast<NET_IFINDEX>(if_index);
  route.destination = *destination;
  route.next_hop = *next_hop;
  return route;
}

void SaveLeftoverRoutes(const std::vector<net::RouteEntry>& routes) {
  if (routes.empty()) {
    RegDeleteKeyValueW(HKEY_LOCAL_MACHINE, kLeftoversKey, kLeftoverRoutesValue);
    return;
  }
  std::wstring multi;
  for (const auto& route : routes) {
    multi += Utf8ToWide(SerializeRoute(route));
    multi.push_back(L'\0');
  }
  multi.push_back(L'\0');
  RegSetKeyValueW(HKEY_LOCAL_MACHINE, kLeftoversKey, kLeftoverRoutesValue,
                  REG_MULTI_SZ, multi.data(),
                  static_cast<DWORD>(multi.size() * sizeof(wchar_t)));
}

std::vector<net::RouteEntry> LoadLeftoverRoutes() {
  std::vector<net::RouteEntry> routes;
  DWORD size = 0;
  if (RegGetValueW(HKEY_LOCAL_MACHINE, kLeftoversKey, kLeftoverRoutesValue,
                   RRF_RT_REG_MULTI_SZ, nullptr, nullptr, &size) !=
          ERROR_SUCCESS ||
      size == 0) {
    return routes;
  }
  std::vector<wchar_t> buffer(size / sizeof(wchar_t) + 2, L'\0');
  if (RegGetValueW(HKEY_LOCAL_MACHINE, kLeftoversKey, kLeftoverRoutesValue,
                   RRF_RT_REG_MULTI_SZ, nullptr, buffer.data(), &size) !=
      ERROR_SUCCESS) {
    return routes;
  }
  for (const wchar_t* entry = buffer.data(); *entry != L'\0';
       entry += wcslen(entry) + 1) {
    if (const auto route = ParseRoute(WideToUtf8(entry))) {
      routes.push_back(*route);
    }
  }
  return routes;
}

bool WaitForPortFree(uint16_t port, std::chrono::milliseconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (!net::FindTcpListeners(port).empty()) {
    if (std::chrono::steady_clock::now() >= deadline) return false;
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  return true;
}

bool IsNonProxyTag(const std::string& tag) {
  static const char* const kTags[] = {"direct", "block",     "dns-out", "api",
                                      "freedom", "blackhole", "dns"};
  return std::any_of(std::begin(kTags), std::end(kTags),
                     [&](const char* known) { return tag == known; });
}

}  // namespace

const char* CoreStateName(CoreState state) {
  switch (state) {
    case CoreState::kStopped:
      return "stopped";
    case CoreState::kStarting:
      return "starting";
    case CoreState::kRunning:
      return "running";
    case CoreState::kStopping:
      return "stopping";
  }
  return "stopped";
}

bool IsProcessElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION elevation = {};
  DWORD size = sizeof(elevation);
  const BOOL ok = GetTokenInformation(token, TokenElevation, &elevation,
                                      sizeof(elevation), &size);
  CloseHandle(token);
  return ok && elevation.TokenIsElevated != 0;
}

class CoreController::Impl {
 public:
  explicit Impl(ControllerPaths paths) : paths_(std::move(paths)) {
    queue_event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    network_event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    worker_ = std::thread([this]() { WorkerLoop(); });
  }

  ~Impl() {
    auto command = std::make_shared<Command>();
    command->kind = Command::Kind::kShutdown;
    Submit(command);
    if (worker_.joinable()) worker_.join();
    CloseHandle(queue_event_);
    CloseHandle(network_event_);
  }

  void SetStatusListener(StatusListener listener) {
    std::lock_guard<std::mutex> lock(listener_mutex_);
    listener_ = std::move(listener);
  }

  void CleanupLeftovers() {
    auto command = std::make_shared<Command>();
    command->kind = Command::Kind::kCleanup;
    Submit(command);
  }

  bool Start(const StartOptions& options, CoreError& error) {
    auto command = std::make_shared<Command>();
    command->kind = Command::Kind::kStart;
    command->options = options;
    Submit(command);
    error = command->error;
    return command->ok;
  }

  void Stop() {
    auto command = std::make_shared<Command>();
    command->kind = Command::Kind::kStop;
    Submit(command);
  }

  CoreStatus Status() const {
    std::lock_guard<std::mutex> lock(status_mutex_);
    return status_;
  }

  bool QueryStats(TrafficStats& stats) const {
    uint16_t port = 0;
    std::vector<std::string> tags;
    {
      std::lock_guard<std::mutex> lock(status_mutex_);
      if (status_.state != CoreState::kRunning) return false;
      port = stats_port_;
      tags = stats_tags_;
    }
    if (port == 0) return false;

    const auto body =
        net::HttpGetLocal(port, "/debug/vars", std::chrono::milliseconds(800));
    if (!body) return false;
    const auto document = JsonValue::Parse(*body);
    if (!document) return false;
    const auto* expvar_stats = document->Find("stats");
    const auto* outbounds =
        expvar_stats != nullptr ? expvar_stats->Find("outbound") : nullptr;
    if (outbounds == nullptr || !outbounds->is_object()) return false;

    TrafficStats total;
    for (const auto& member : outbounds->members()) {
      const bool counted =
          tags.empty() ? !IsNonProxyTag(member.key)
                       : std::find(tags.begin(), tags.end(), member.key) !=
                             tags.end();
      if (!counted) continue;
      total.uplink += member.value.GetIntMember("uplink");
      total.downlink += member.value.GetIntMember("downlink");
    }
    stats = total;
    return true;
  }

 private:
  struct Command {
    enum class Kind { kStart, kStop, kCleanup, kShutdown };
    Kind kind = Kind::kStop;
    StartOptions options;
    bool done = false;
    bool ok = false;
    CoreError error;
  };

  void Submit(const std::shared_ptr<Command>& command) {
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      queue_.push_back(command);
    }
    SetEvent(queue_event_);
    std::unique_lock<std::mutex> lock(queue_mutex_);
    done_cv_.wait(lock, [&]() { return command->done; });
  }

  void Complete(const std::shared_ptr<Command>& command) {
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      command->done = true;
    }
    done_cv_.notify_all();
  }

  void WorkerLoop() {
    while (true) {
      HANDLE handles[3] = {};
      DWORD count = 0;
      handles[count++] = queue_event_;
      DWORD process_index = MAXDWORD;
      DWORD network_index = MAXDWORD;
      if (has_process_) {
        process_index = count;
        handles[count++] = process_.hProcess;
      }
      if (network_watch_) {
        network_index = count;
        handles[count++] = network_event_;
      }

      DWORD timeout = INFINITE;
      if (network_change_pending_) {
        const auto remaining =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                network_change_deadline_ - std::chrono::steady_clock::now())
                .count();
        timeout = remaining > 0 ? static_cast<DWORD>(remaining) : 0;
      }

      const DWORD wait = WaitForMultipleObjects(count, handles, FALSE, timeout);
      if (wait == WAIT_OBJECT_0) {
        if (!DrainCommands()) return;
      } else if (process_index != MAXDWORD &&
                 wait == WAIT_OBJECT_0 + process_index) {
        HandleCoreExit();
      } else if (network_index != MAXDWORD &&
                 wait == WAIT_OBJECT_0 + network_index) {
        network_change_pending_ = true;
        network_change_deadline_ =
            std::chrono::steady_clock::now() + kNetworkSettleDelay;
      } else if (wait == WAIT_TIMEOUT) {
        network_change_pending_ = false;
        HandleNetworkChange();
      } else {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
      }
    }
  }

  // Returns false once the controller is shutting down.
  bool DrainCommands() {
    while (true) {
      std::shared_ptr<Command> command;
      {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        if (queue_.empty()) return true;
        command = queue_.front();
        queue_.pop_front();
      }
      bool keep_running = true;
      switch (command->kind) {
        case Command::Kind::kStart:
          command->ok = DoStart(command->options, command->error);
          break;
        case Command::Kind::kStop:
          DoStop();
          command->ok = true;
          break;
        case Command::Kind::kCleanup:
          DoCleanupLeftovers();
          command->ok = true;
          break;
        case Command::Kind::kShutdown:
          if (has_process_) DoStop();
          command->ok = true;
          keep_running = false;
          break;
      }
      Complete(command);
      if (!keep_running) return false;
    }
  }

  static CoreStatus MakeStatus(CoreState state, bool tunnel) {
    CoreStatus status;
    status.state = state;
    status.tunnel = tunnel;
    return status;
  }

  void PublishStatus(const CoreStatus& status) {
    {
      std::lock_guard<std::mutex> lock(status_mutex_);
      status_ = status;
    }
    StatusListener listener;
    {
      std::lock_guard<std::mutex> lock(listener_mutex_);
      listener = listener_;
    }
    if (listener) listener(status);
  }

  bool DoStart(const StartOptions& options, CoreError& error) {
    TearDown();
    PublishStatus(MakeStatus(CoreState::kStarting, options.tunnel));
    LogInfo(std::string("Starting core, mode ") +
            (options.tunnel ? "tunnel" : "proxy") + ", " +
            std::to_string(options.server_hosts.size()) + " server host(s)");

    const auto fail = [&](std::string message, const char* code) {
      TearDown();
      error.message = std::move(message);
      error.code = code;
      LogError(std::string("Start failed [") + code + "]: " + error.message);
      PublishStatus(MakeStatus(CoreState::kStopped, options.tunnel));
      return false;
    };

    if (options.config_json.empty()) {
      return fail("Пустая конфигурация подключения", "INVALID_CONFIG");
    }
    std::error_code ec;
    if (!std::filesystem::exists(paths_.xray_exe, ec)) {
      return fail("Не найден xray.exe рядом с ChrNet. Переустановите приложение.",
                  "XRAY_MISSING");
    }
    if (options.tunnel && !IsProcessElevated()) {
      return fail("Для режима «Туннель» нужна служба ChrNet. Переустановите "
                  "приложение или выберите режим «Системный прокси».",
                  "NOT_ELEVATED");
    }

    for (const uint16_t port :
         {options.socks_port, options.http_port, options.metrics_port}) {
      if (port == 0) continue;
      // The core from the previous session may still be releasing the port.
      if (!WaitForPortFree(port, kPortReleaseTimeout)) {
        return fail("Порт " + std::to_string(port) +
                        " занят другой программой (например, другим "
                        "VPN-клиентом). Закройте её и подключитесь снова.",
                    "PORT_IN_USE");
      }
    }

    std::string config = options.config_json;
    if (options.tunnel) {
      const auto physical = net::FindPhysicalDefaultRoute();
      if (!physical) {
        return fail("Нет подключения к сети: не найден активный сетевой "
                    "адаптер.",
                    "NETWORK_UNAVAILABLE");
      }
      physical_route_ = *physical;

      // Resolve before the TUN exists, while the system resolver still goes
      // around the tunnel.
      std::vector<std::string> server_ips;
      for (const auto& host : options.server_hosts) {
        for (const auto& ip : net::ResolveHostIpv4(host)) {
          if (std::find(server_ips.begin(), server_ips.end(), ip) ==
              server_ips.end()) {
            server_ips.push_back(ip);
          }
        }
      }
      if (server_ips.empty()) {
        return fail("Не удалось определить адрес VPN-сервера. Проверьте "
                    "подключение к интернету.",
                    "RESOLVE_FAILED");
      }

      // Server routes go in first, so nothing addressed to a server is ever
      // caught by the TUN routes added later.
      for (const auto& ip : server_ips) {
        net::RouteEntry route;
        route.if_index = physical_route_.if_index;
        route.destination = *net::ParseIpv4Prefix(ip);
        route.next_hop = physical_route_.gateway;
        std::string route_error;
        const auto added = net::AddRoute(route, route_error);
        if (added == net::AddRouteResult::kFailed) {
          return fail("Не удалось проложить маршрут до VPN-сервера " + ip +
                          ": " + route_error,
                      "ROUTE_FAILED");
        }
        if (added == net::AddRouteResult::kAdded) {
          routes_.push_back(route);
          SaveLeftoverRoutes(routes_);
        }
      }
      LogInfo("Server routes via " + net::FormatIpv4(physical_route_.gateway) +
              ": " + std::to_string(server_ips.size()) + " address(es)");

      config = BindOutboundsToAddress(
          config, net::FormatIpv4(physical_route_.local_address));
    }

    std::filesystem::create_directories(paths_.runtime_dir, ec);
    const auto config_path = paths_.runtime_dir / "config.json";
    const auto override_path = paths_.runtime_dir / "override.json";
    if (!WriteBytes(config_path, config) ||
        !WriteBytes(override_path, kOverrideConfig)) {
      return fail("Не удалось записать конфигурацию ядра", "CONFIG_WRITE_FAILED");
    }

    std::string launch_error;
    if (!LaunchXray(config_path, override_path, launch_error)) {
      return fail("Не удалось запустить xray.exe: " + launch_error,
                  "XRAY_LAUNCH_FAILED");
    }

    if (options.tunnel) {
      std::string tunnel_error;
      const char* code = "TUNNEL_FAILED";
      if (!SetUpTunnel(options.tunnel_options, tunnel_error, code)) {
        return fail(tunnel_error, code);
      }
    }

    // The local HTTP inbound doubles as the signal that the core is up.
    if (options.http_port != 0 &&
        !net::WaitForProcessListener(options.http_port, process_.hProcess,
                                     process_.dwProcessId, kListenerTimeout)) {
      const bool exited = WaitForSingleObject(process_.hProcess, 0) != WAIT_TIMEOUT;
      const auto summary = XrayLogSummary(paths_.log_dir / "xray.log");
      return fail(exited ? "Ядро xray завершилось при запуске" +
                               (summary.empty() ? "." : ": " + summary)
                         : "Ядро xray не открыло локальный прокси на порту " +
                               std::to_string(options.http_port) + ".",
                  exited ? "CORE_EXITED" : "CORE_NOT_READY");
    }
    DeleteRuntimeFiles();

    active_options_ = options;
    {
      std::lock_guard<std::mutex> lock(status_mutex_);
      stats_port_ = options.metrics_port;
      stats_tags_ = options.proxy_tags;
    }
    if (options.tunnel && options.tunnel_options.follow_network_changes) {
      StartNetworkWatch();
    }

    auto running = MakeStatus(CoreState::kRunning, options.tunnel);
    running.started_at_ms = NowUnixMs();
    PublishStatus(running);
    LogInfo("Core running");
    return true;
  }

  bool SetUpTunnel(const TunnelOptions& tunnel, std::string& error,
                   const char*& code) {
    const auto adapter_deadline =
        std::chrono::steady_clock::now() + kAdapterTimeout;
    auto adapter = net::FindAdapterByName(tunnel.adapter_name);
    while (!adapter && std::chrono::steady_clock::now() < adapter_deadline) {
      if (WaitForSingleObject(process_.hProcess, 0) != WAIT_TIMEOUT) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
      adapter = net::FindAdapterByName(tunnel.adapter_name);
    }
    if (!adapter) {
      const auto summary = XrayLogSummary(paths_.log_dir / "xray.log");
      error = "Ядро xray не создало сетевой адаптер туннеля" +
              (summary.empty() ? std::string(".") : ": " + summary);
      code = "TUN_NOT_CREATED";
      return false;
    }
    tun_ = adapter;

    const auto address = net::ParseIpv4(tunnel.address);
    if (!address) {
      error = "Неверный адрес туннеля";
      code = "INVALID_OPTIONS";
      return false;
    }
    std::string detail;
    if (!net::AssignIpv4Address(adapter->if_index, *address,
                                tunnel.prefix_length, detail)) {
      error = "Не удалось назначить адрес адаптеру туннеля: " + detail;
      code = "TUN_ADDRESS_FAILED";
      return false;
    }
    const auto address_deadline =
        std::chrono::steady_clock::now() + kAddressTimeout;
    while (!net::IsIpv4AddressReady(adapter->if_index, *address) &&
           std::chrono::steady_clock::now() < address_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (!net::IsIpv4AddressReady(adapter->if_index, *address)) {
      error = "Адаптер туннеля не принял свой адрес";
      code = "TUN_ADDRESS_FAILED";
      return false;
    }

    // A low metric makes Windows prefer the TUN, and with it the TUN's DNS
    // server, over every physical adapter.
    if (!net::SetInterfaceMetric(adapter->if_index, kTunInterfaceMetric,
                                 detail)) {
      LogWarning("Could not lower the TUN metric: " + detail);
    }
    bool dns_ready = false;
    if (!tunnel.dns_server.empty()) {
      detail.clear();
      if (net::SetInterfaceDnsServers(adapter->guid,
                                      Utf8ToWide(tunnel.dns_server), detail)) {
        net::FlushDnsCache();
        dns_ready = true;
      } else {
        LogWarning("Could not set the TUN DNS server: " + detail);
      }
    }

    std::vector<std::string> prefixes = tunnel.routes;
    if (prefixes.empty()) prefixes = {"0.0.0.0/1", "128.0.0.0/1"};
    for (const auto& text : prefixes) {
      const auto prefix = net::ParseIpv4Prefix(text);
      if (!prefix) {
        error = "Неверный маршрут туннеля: " + text;
        code = "INVALID_OPTIONS";
        return false;
      }
      net::RouteEntry route;
      route.if_index = adapter->if_index;
      route.destination = *prefix;
      detail.clear();
      const auto added = net::AddRoute(route, detail);
      if (added == net::AddRouteResult::kFailed) {
        error = "Не удалось направить трафик в туннель: " + detail;
        code = "ROUTE_FAILED";
        return false;
      }
      if (added == net::AddRouteResult::kAdded) {
        routes_.push_back(route);
        SaveLeftoverRoutes(routes_);
      }
    }

    // Blocking DNS outside the tunnel is only safe once Windows resolves
    // through it: without the TUN resolver the block would leave the whole
    // machine without DNS. A test run guards some other port and needs none.
    const bool guard_is_safe = dns_ready || tunnel.guarded_dns_port != 53;
    if (tunnel.leak_protection && !guard_is_safe) {
      LogWarning("Leak protection skipped: the TUN has no DNS server");
    } else if (tunnel.leak_protection) {
      LeakGuard::Options guard;
      guard.tun_luid = adapter->luid.Value;
      guard.xray_path = paths_.xray_exe;
      guard.dns_port = tunnel.guarded_dns_port;
      guard.block_ipv6 = tunnel.block_ipv6;
      detail.clear();
      if (!leak_guard_.Install(guard, detail)) {
        LogWarning("Leak protection unavailable: " + detail);
      }
    }
    LogInfo("Tunnel configured on interface " +
            std::to_string(adapter->if_index));
    return true;
  }

  bool LaunchXray(const std::filesystem::path& config,
                  const std::filesystem::path& override_config,
                  std::string& error) {
    std::error_code ec;
    std::filesystem::create_directories(paths_.log_dir, ec);
    const auto log_path = paths_.log_dir / "xray.log";
    SECURITY_ATTRIBUTES inheritable = {sizeof(inheritable), nullptr, TRUE};
    HANDLE log_file = CreateFileW(log_path.wstring().c_str(), GENERIC_WRITE,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE |
                                      FILE_SHARE_DELETE,
                                  &inheritable, CREATE_ALWAYS,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);

    std::wstring command = L"\"" + paths_.xray_exe.wstring() + L"\" run -c \"" +
                           config.wstring() + L"\" -c \"" +
                           override_config.wstring() + L"\"";
    std::vector<wchar_t> command_line(command.begin(), command.end());
    command_line.push_back(L'\0');

    STARTUPINFOEXW startup = {};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESHOWWINDOW;
    startup.StartupInfo.wShowWindow = SW_HIDE;
    std::vector<BYTE> attributes;
    BOOL inherit_handles = FALSE;
    DWORD creation_flags = CREATE_NO_WINDOW | CREATE_SUSPENDED;
    if (log_file != INVALID_HANDLE_VALUE) {
      startup.StartupInfo.dwFlags |= STARTF_USESTDHANDLES;
      startup.StartupInfo.hStdOutput = log_file;
      startup.StartupInfo.hStdError = log_file;
      // Only the log handle is inherited, not every inheritable handle the
      // service or the app happens to hold.
      SIZE_T size = 0;
      InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
      attributes.resize(size);
      auto* list =
          reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
      if (InitializeProcThreadAttributeList(list, 1, 0, &size)) {
        if (UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                      &log_file, sizeof(log_file), nullptr,
                                      nullptr)) {
          startup.lpAttributeList = list;
          inherit_handles = TRUE;
          creation_flags |= EXTENDED_STARTUPINFO_PRESENT;
        } else {
          DeleteProcThreadAttributeList(list);
        }
      }
    }

    PROCESS_INFORMATION info = {};
    const auto work_dir = paths_.xray_exe.parent_path().wstring();
    const BOOL created = CreateProcessW(
        nullptr, command_line.data(), nullptr, nullptr, inherit_handles,
        creation_flags, nullptr, work_dir.c_str(), &startup.StartupInfo, &info);
    const DWORD create_error = GetLastError();
    if (startup.lpAttributeList != nullptr) {
      DeleteProcThreadAttributeList(startup.lpAttributeList);
    }
    if (log_file != INVALID_HANDLE_VALUE) CloseHandle(log_file);
    if (!created) {
      error = net::Win32ErrorMessage(create_error);
      return false;
    }

    // Kill-on-close ties Xray's lifetime to this process: even a crash of the
    // service or the app cannot leave an orphaned core holding the TUN.
    job_ = CreateJobObjectW(nullptr, nullptr);
    if (job_ != nullptr) {
      JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
      limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
      SetInformationJobObject(job_, JobObjectExtendedLimitInformation, &limits,
                              sizeof(limits));
      AssignProcessToJobObject(job_, info.hProcess);
    }
    ResumeThread(info.hThread);
    CloseHandle(info.hThread);
    process_ = info;
    process_.hThread = nullptr;
    has_process_ = true;
    LogInfo("xray started, pid " + std::to_string(info.dwProcessId));
    return true;
  }

  void DoStop() {
    if (!has_process_ && routes_.empty()) {
      PublishStatus(MakeStatus(CoreState::kStopped, false));
      return;
    }
    const bool tunnel = active_options_.tunnel;
    PublishStatus(MakeStatus(CoreState::kStopping, tunnel));
    TearDown();
    PublishStatus(MakeStatus(CoreState::kStopped, tunnel));
    LogInfo("Core stopped");
  }

  void DoCleanupLeftovers() {
    const auto leftovers = LoadLeftoverRoutes();
    for (const auto& route : leftovers) {
      net::DeleteRoute(route);
    }
    if (!leftovers.empty()) {
      LogWarning("Removed " + std::to_string(leftovers.size()) +
                 " route(s) left behind by a previous session");
      SaveLeftoverRoutes({});
    }
  }

  void HandleCoreExit() {
    DWORD exit_code = 0;
    GetExitCodeProcess(process_.hProcess, &exit_code);
    const auto summary = XrayLogSummary(paths_.log_dir / "xray.log");
    LogError("xray exited unexpectedly with code " + std::to_string(exit_code) +
             (summary.empty() ? "" : ": " + summary));
    const bool tunnel = active_options_.tunnel;
    TearDown();
    auto status = MakeStatus(CoreState::kStopped, tunnel);
    status.error = "Ядро xray неожиданно завершилось" +
                   (summary.empty() ? std::string(".") : ": " + summary);
    status.error_code = "CORE_EXITED";
    PublishStatus(status);
  }

  void HandleNetworkChange() {
    if (!has_process_ || !active_options_.tunnel) return;
    const auto current =
        net::FindPhysicalDefaultRoute(tun_ ? tun_->if_index : 0);
    if (current && net::SamePhysicalRoute(*current, physical_route_)) return;

    const StartOptions options = active_options_;
    if (!current) {
      LogWarning("Physical network lost, tearing the tunnel down");
      TearDown();
      auto status = MakeStatus(CoreState::kStopped, true);
      status.error = "Пропало подключение к сети.";
      status.error_code = "NETWORK_UNAVAILABLE";
      PublishStatus(status);
      return;
    }

    LogWarning("Physical network changed, rebuilding the tunnel");
    CoreError error;
    if (!DoStart(options, error)) {
      auto status = MakeStatus(CoreState::kStopped, true);
      status.error = error.message;
      status.error_code = error.code.empty() ? "NETWORK_CHANGED" : error.code;
      PublishStatus(status);
    }
  }

  static void CALLBACK OnRouteChange(PVOID context, PMIB_IPFORWARD_ROW2,
                                     MIB_NOTIFICATION_TYPE) {
    SetEvent(static_cast<Impl*>(context)->network_event_);
  }

  static void CALLBACK OnInterfaceChange(PVOID context, PMIB_IPINTERFACE_ROW,
                                         MIB_NOTIFICATION_TYPE) {
    SetEvent(static_cast<Impl*>(context)->network_event_);
  }

  void StartNetworkWatch() {
    if (network_watch_) return;
    NotifyRouteChange2(AF_INET, &Impl::OnRouteChange, this, FALSE,
                       &route_notify_);
    NotifyIpInterfaceChange(AF_INET, &Impl::OnInterfaceChange, this, FALSE,
                            &interface_notify_);
    network_watch_ = true;
    network_change_pending_ = false;
    ResetEvent(network_event_);
  }

  void StopNetworkWatch() {
    if (route_notify_ != nullptr) {
      CancelMibChangeNotify2(route_notify_);
      route_notify_ = nullptr;
    }
    if (interface_notify_ != nullptr) {
      CancelMibChangeNotify2(interface_notify_);
      interface_notify_ = nullptr;
    }
    network_watch_ = false;
    network_change_pending_ = false;
    ResetEvent(network_event_);
  }

  void DeleteRuntimeFiles() {
    std::error_code ec;
    std::filesystem::remove(paths_.runtime_dir / "config.json", ec);
    std::filesystem::remove(paths_.runtime_dir / "override.json", ec);
  }

  void TearDown() {
    StopNetworkWatch();
    leak_guard_.Remove();
    const bool had_tunnel = tun_.has_value();
    if (has_process_) {
      if (WaitForSingleObject(process_.hProcess, 0) == WAIT_TIMEOUT) {
        TerminateProcess(process_.hProcess, 0);
        WaitForSingleObject(process_.hProcess, 3000);
      }
      CloseHandle(process_.hProcess);
      process_ = {};
      has_process_ = false;
    }
    if (job_ != nullptr) {
      CloseHandle(job_);
      job_ = nullptr;
    }
    // TUN routes vanish with the adapter, but the adapter may outlive the
    // process for a moment; server routes stay until deleted.
    for (auto it = routes_.rbegin(); it != routes_.rend(); ++it) {
      net::DeleteRoute(*it);
    }
    if (!routes_.empty()) {
      routes_.clear();
      SaveLeftoverRoutes(routes_);
    }
    tun_.reset();
    DeleteRuntimeFiles();
    if (had_tunnel) net::FlushDnsCache();
  }

  ControllerPaths paths_;

  std::mutex listener_mutex_;
  StatusListener listener_;

  mutable std::mutex status_mutex_;
  CoreStatus status_;
  uint16_t stats_port_ = 0;
  std::vector<std::string> stats_tags_;

  std::mutex queue_mutex_;
  std::condition_variable done_cv_;
  std::deque<std::shared_ptr<Command>> queue_;
  HANDLE queue_event_ = nullptr;
  HANDLE network_event_ = nullptr;
  std::thread worker_;

  // Owned by the worker thread.
  PROCESS_INFORMATION process_ = {};
  bool has_process_ = false;
  HANDLE job_ = nullptr;
  StartOptions active_options_;
  net::PhysicalRoute physical_route_;
  std::optional<net::AdapterInfo> tun_;
  std::vector<net::RouteEntry> routes_;
  LeakGuard leak_guard_;
  bool network_watch_ = false;
  HANDLE route_notify_ = nullptr;
  HANDLE interface_notify_ = nullptr;
  bool network_change_pending_ = false;
  std::chrono::steady_clock::time_point network_change_deadline_;
};

CoreController::CoreController(ControllerPaths paths)
    : impl_(std::make_unique<Impl>(std::move(paths))) {}

CoreController::~CoreController() = default;

void CoreController::SetStatusListener(StatusListener listener) {
  impl_->SetStatusListener(std::move(listener));
}

void CoreController::CleanupLeftovers() { impl_->CleanupLeftovers(); }

bool CoreController::Start(const StartOptions& options, CoreError& error) {
  return impl_->Start(options, error);
}

void CoreController::Stop() { impl_->Stop(); }

CoreStatus CoreController::Status() const { return impl_->Status(); }

bool CoreController::QueryStats(TrafficStats& stats) const {
  return impl_->QueryStats(stats);
}

}  // namespace chrnet
