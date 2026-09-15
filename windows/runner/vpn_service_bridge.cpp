#include <winsock2.h>
#include <ws2tcpip.h>
#include "vpn_service_bridge.h"

#include <algorithm>
#include <filesystem>
#include <optional>
#include <vector>

#include "log.h"
#include "net_util.h"
#include "proxy_settings.h"
#include "string_util.h"

namespace {

constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"ChrNet";
constexpr uint16_t kDefaultHttpPort = 10809;

std::optional<std::string> ReadString(const flutter::EncodableMap* map,
                                      const char* key) {
  if (map == nullptr) return std::nullopt;
  const auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) return std::nullopt;
  if (const auto* value = std::get_if<std::string>(&it->second)) return *value;
  return std::nullopt;
}

std::vector<std::string> ReadStringList(const flutter::EncodableMap* map,
                                        const char* key) {
  std::vector<std::string> values;
  if (map == nullptr) return values;
  const auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) return values;
  if (const auto* list = std::get_if<flutter::EncodableList>(&it->second)) {
    for (const auto& item : *list) {
      if (const auto* value = std::get_if<std::string>(&item)) {
        values.push_back(*value);
      }
    }
  }
  return values;
}

int64_t ReadInt(const flutter::EncodableMap* map, const char* key,
                int64_t fallback) {
  if (map == nullptr) return fallback;
  const auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) return fallback;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&it->second)) return *value;
  return fallback;
}

bool ReadBool(const flutter::EncodableMap* map, const char* key, bool fallback) {
  if (map == nullptr) return fallback;
  const auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) return fallback;
  if (const auto* value = std::get_if<bool>(&it->second)) return *value;
  return fallback;
}

uint16_t ReadPort(const flutter::EncodableMap* map, const char* key,
                  uint16_t fallback) {
  const int64_t value = ReadInt(map, key, fallback);
  return value > 0 && value <= 65535 ? static_cast<uint16_t>(value) : fallback;
}

std::wstring ExecutablePath() {
  wchar_t path[MAX_PATH * 2] = {};
  const DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH * 2);
  return std::wstring(path, length);
}

std::wstring AutostartCommand() {
  return L"\"" + ExecutablePath() + L"\" --minimized";
}

bool IsLaunchAtStartupEnabled() {
  wchar_t value[MAX_PATH * 2 + 32] = {};
  DWORD size = sizeof(value);
  if (RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ,
                   nullptr, value, &size) != ERROR_SUCCESS) {
    return false;
  }
  // An entry for another copy of the app (an old install location) does not
  // count: it would start that copy instead.
  return chrnet::EqualsIgnoreCase(value, AutostartCommand());
}

bool SetLaunchAtStartup(bool enabled) {
  if (!enabled) {
    const LSTATUS status =
        RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunKey, kRunValue);
    return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
  }
  const std::wstring command = AutostartCommand();
  return RegSetKeyValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, REG_SZ,
                         command.c_str(),
                         static_cast<DWORD>((command.size() + 1) *
                                            sizeof(wchar_t))) == ERROR_SUCCESS;
}

// The x-hwid is this Windows installation's MachineGuid as is: generated once
// per install, it survives reboots and renaming the machine, and it passes
// Remnawave's ^[a-zA-Z0-9=-]{10,64}$ check (the computer name, often short or
// non-Latin, did not). Earlier releases already registered this exact value
// with subscription panels, so changing its form would count every updated PC
// as a new device. An empty result makes the Dart side send its stored
// fallback id instead.
std::string GetMachineId() {
  wchar_t machine_guid[128] = {};
  DWORD guid_bytes = static_cast<DWORD>(sizeof(machine_guid));
  if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Cryptography",
                   L"MachineGuid", RRF_RT_REG_SZ, nullptr, machine_guid,
                   &guid_bytes) != ERROR_SUCCESS) {
    return "";
  }
  return chrnet::WideToUtf8(std::wstring(machine_guid));
}

// "10.0.26200" for x-ver-os. GetVersionEx lies to unmanifested callers, so the
// numbers come from the registry.
std::string GetWindowsVersion() {
  constexpr wchar_t kKey[] = L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
  DWORD major = 0;
  DWORD minor = 0;
  DWORD size = sizeof(DWORD);
  const bool has_major =
      RegGetValueW(HKEY_LOCAL_MACHINE, kKey, L"CurrentMajorVersionNumber",
                   RRF_RT_REG_DWORD, nullptr, &major, &size) == ERROR_SUCCESS;
  size = sizeof(DWORD);
  RegGetValueW(HKEY_LOCAL_MACHINE, kKey, L"CurrentMinorVersionNumber",
               RRF_RT_REG_DWORD, nullptr, &minor, &size);
  wchar_t build[32] = {};
  DWORD build_bytes = static_cast<DWORD>(sizeof(build));
  const bool has_build =
      RegGetValueW(HKEY_LOCAL_MACHINE, kKey, L"CurrentBuildNumber",
                   RRF_RT_REG_SZ, nullptr, build, &build_bytes) ==
      ERROR_SUCCESS;

  std::string version;
  if (has_major) {
    version = std::to_string(major) + "." + std::to_string(minor);
  }
  if (has_build) {
    if (!version.empty()) version += ".";
    version += chrnet::WideToUtf8(std::wstring(build));
  }
  return version.empty() ? "Windows" : version;
}

std::wstring TrayLabel(const std::string& state) {
  if (state == "connected") return L"подключено";
  if (state == "connecting") return L"подключение…";
  if (state == "disconnecting") return L"отключение…";
  if (state == "error") return L"ошибка подключения";
  return L"не подключено";
}

std::filesystem::path AppLogPath() {
  wchar_t local_app_data[MAX_PATH] = {};
  const DWORD length =
      GetEnvironmentVariableW(L"LOCALAPPDATA", local_app_data, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    std::error_code ec;
    return std::filesystem::temp_directory_path(ec) / "ChrNet" / "app.log";
  }
  return std::filesystem::path(local_app_data) / "ChrNet" / "logs" / "app.log";
}

}  // namespace

VpnServiceBridge::VpnServiceBridge(flutter::BinaryMessenger* messenger,
                                   VpnBridgeHost* host)
    : host_(host), alive_(std::make_shared<std::atomic<bool>>(true)) {
  chrnet::InitLog(AppLogPath());

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.chrnet.vpn/service",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });

  service_ = std::make_unique<ServiceClient>();
  service_->SetStatusListener(
      [this, alive = alive_](const chrnet::CoreStatus& status) {
        if (*alive) OnBackendStatus(status);
      });

  worker_ = std::thread([this]() { WorkerLoop(); });
  RunOnWorker([this]() { SyncOnStartup(); });
}

VpnServiceBridge::~VpnServiceBridge() {
  *alive_ = false;
  channel_->SetMethodCallHandler(nullptr);
  ShutdownConnection();
  service_->SetStatusListener(nullptr);
  in_process_.reset();
  service_.reset();
}

void VpnServiceBridge::ShutdownConnection() {
  StopWorker();
  if (connection_shut_down_) return;
  connection_shut_down_ = true;
  if (active_ != nullptr) {
    chrnet::LogInfo("Stopping the connection on exit");
    active_->Stop();
    active_ = nullptr;
  }
  RestoreProxyIfNeeded();
}

void VpnServiceBridge::RequestToggleFromTray() {
  channel_->InvokeMethod("trayToggle", nullptr);
}

void VpnServiceBridge::RestoreStaleSystemProxy() {
  if (chrnet::proxy::HasPendingRestore()) {
    chrnet::proxy::RestoreAfterChrNet(kDefaultHttpPort);
    return;
  }
  // ChrNet 2.0 and older kept no backup. Their settings are recognisable, and
  // a proxy nobody listens on is broken internet anyway, so resetting it is
  // safe even if some other client had chosen the same port.
  chrnet::proxy::Settings current;
  if (chrnet::proxy::Read(current) &&
      chrnet::proxy::IsChrNetProxy(current, kDefaultHttpPort) &&
      current.bypass == L"<local>" &&
      chrnet::net::FindTcpListeners(kDefaultHttpPort).empty()) {
    chrnet::proxy::Apply(chrnet::proxy::Settings{});
    chrnet::LogInfo("Reset a system proxy left by an older ChrNet version");
  }
}

void VpnServiceBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
        raw_result) {
  const auto& method = call.method_name();
  Result result(raw_result.release());
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  if (method == "getDeviceInfo") {
    flutter::EncodableMap info;
    info[flutter::EncodableValue("deviceId")] =
        flutter::EncodableValue(GetMachineId());
    info[flutter::EncodableValue("osVersion")] =
        flutter::EncodableValue(GetWindowsVersion());
    info[flutter::EncodableValue("model")] =
        flutter::EncodableValue("Windows PC");
    result->Success(flutter::EncodableValue(info));
    return;
  }

  if (method == "getLaunchAtStartup") {
    result->Success(flutter::EncodableValue(IsLaunchAtStartupEnabled()));
    return;
  }

  if (method == "setLaunchAtStartup") {
    const bool enabled = ReadBool(args, "enabled", false);
    result->Success(flutter::EncodableValue(SetLaunchAtStartup(enabled)));
    return;
  }

  if (method == "updateTrayStatus") {
    const auto state = ReadString(args, "state").value_or("disconnected");
    const auto server = chrnet::Utf8ToWide(ReadString(args, "server").value_or(""));
    std::wstring tooltip = L"ChrNet: " + TrayLabel(state);
    if (!server.empty() && state == "connected") tooltip += L" — " + server;
    host_->UpdateTrayState(state == "connected", tooltip);
    result->Success();
    return;
  }

  if (method == "getStatus") {
    RunOnWorker([this, result]() {
      chrnet::CoreStatus status;
      auto* backend = BackendForQueries();
      const bool running = backend != nullptr && backend->Status(status) &&
                           status.state == chrnet::CoreState::kRunning;
      if (running && active_ == nullptr) active_ = backend;
      ReplySuccess(result, flutter::EncodableValue(running));
    });
    return;
  }

  if (method == "getCoreState") {
    RunOnWorker([this, result]() {
      chrnet::CoreStatus status;
      auto* backend = BackendForQueries();
      const bool reachable = backend != nullptr && backend->Status(status);
      const bool running =
          reachable && status.state == chrnet::CoreState::kRunning;
      if (running && active_ == nullptr) active_ = backend;
      flutter::EncodableMap state;
      state[flutter::EncodableValue("running")] = flutter::EncodableValue(running);
      state[flutter::EncodableValue("tunnel")] =
          flutter::EncodableValue(status.tunnel);
      state[flutter::EncodableValue("startedAt")] =
          flutter::EncodableValue(static_cast<int64_t>(status.started_at_ms));
      state[flutter::EncodableValue("backend")] = flutter::EncodableValue(
          backend != nullptr ? backend->name() : "none");
      ReplySuccess(result, flutter::EncodableValue(state));
    });
    return;
  }

  if (method == "getServiceInfo") {
    RunOnWorker([this, result]() {
      flutter::EncodableMap info;
      info[flutter::EncodableValue("available")] =
          flutter::EncodableValue(service_->EnsureConnected());
      info[flutter::EncodableValue("elevated")] =
          flutter::EncodableValue(chrnet::IsProcessElevated());
      ReplySuccess(result, flutter::EncodableValue(info));
    });
    return;
  }

  if (method == "getStats") {
    RunOnWorker([this, result]() {
      chrnet::TrafficStats stats;
      if (active_ != nullptr) active_->Stats(stats);
      flutter::EncodableMap map;
      map[flutter::EncodableValue("download")] =
          flutter::EncodableValue(static_cast<int64_t>(stats.downlink));
      map[flutter::EncodableValue("upload")] =
          flutter::EncodableValue(static_cast<int64_t>(stats.uplink));
      ReplySuccess(result, flutter::EncodableValue(map));
    });
    return;
  }

  if (method == "disconnect") {
    RunOnWorker([this, result]() {
      if (active_ != nullptr) {
        active_->Stop();
        active_ = nullptr;
      } else if (service_->EnsureConnected()) {
        service_->Stop();
      }
      RestoreProxyIfNeeded();
      ReplySuccess(result);
    });
    return;
  }

  if (method == "connect" || method == "reconnect") {
    chrnet::StartOptions options;
    options.config_json = ReadString(args, "configJson").value_or("");
    options.tunnel = ReadString(args, "windowsMode").value_or("") == "tunnel";
    options.server_hosts = ReadStringList(args, "serverHosts");
    if (const auto host = ReadString(args, "host");
        host && !host->empty() &&
        std::find(options.server_hosts.begin(), options.server_hosts.end(),
                  *host) == options.server_hosts.end()) {
      options.server_hosts.push_back(*host);
    }
    options.proxy_tags = ReadStringList(args, "proxyTags");
    options.socks_port = ReadPort(args, "socksPort", options.socks_port);
    options.http_port = ReadPort(args, "httpPort", options.http_port);
    options.metrics_port = ReadPort(args, "metricsPort", options.metrics_port);
    if (options.config_json.empty()) {
      result->Error("INVALID_ARG", "configJson is required for Windows");
      return;
    }

    RunOnWorker([this, result, options]() {
      auto* backend = SelectBackendForStart();
      if (active_ != nullptr && active_ != backend) active_->Stop();
      chrnet::LogInfo(std::string("Connecting through the ") + backend->name() +
                      (options.tunnel ? " in tunnel mode" : " in proxy mode"));

      chrnet::CoreError error;
      if (!backend->Start(options, error)) {
        active_ = nullptr;
        RestoreProxyIfNeeded();
        ReplyError(result, error.code.empty() ? "CORE_START_FAILED" : error.code,
                   error.message);
        return;
      }
      active_ = backend;
      http_port_ = options.http_port;

      // The system proxy is set in both modes: in tunnel mode it serves
      // applications that only ever talk to a configured proxy.
      std::string proxy_error;
      if (chrnet::proxy::EnableForChrNet(options.http_port, proxy_error)) {
        proxy_enabled_ = true;
      } else if (!options.tunnel) {
        backend->Stop();
        active_ = nullptr;
        ReplyError(result, "PROXY_FAILED", proxy_error);
        return;
      } else {
        chrnet::LogWarning(proxy_error);
      }
      ReplySuccess(result);
    });
    return;
  }

  result->NotImplemented();
}

void VpnServiceBridge::RunOnWorker(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(worker_mutex_);
    if (worker_stop_) return;
    worker_queue_.push_back(std::move(task));
  }
  worker_cv_.notify_one();
}

void VpnServiceBridge::WorkerLoop() {
  while (true) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(worker_mutex_);
      worker_cv_.wait(lock,
                      [this]() { return worker_stop_ || !worker_queue_.empty(); });
      if (worker_queue_.empty()) return;
      task = std::move(worker_queue_.front());
      worker_queue_.pop_front();
    }
    task();
  }
}

void VpnServiceBridge::StopWorker() {
  {
    std::lock_guard<std::mutex> lock(worker_mutex_);
    worker_stop_ = true;
  }
  worker_cv_.notify_all();
  if (worker_.joinable()) worker_.join();
}

void VpnServiceBridge::ReplySuccess(const Result& result,
                                    flutter::EncodableValue value) {
  host_->PostToPlatformThread(
      [result, value = std::move(value)]() { result->Success(value); });
}

void VpnServiceBridge::ReplyError(const Result& result, const std::string& code,
                                  const std::string& message) {
  host_->PostToPlatformThread(
      [result, code, message]() { result->Error(code, message); });
}

void VpnServiceBridge::SyncOnStartup() {
  chrnet::CoreStatus status;
  if (service_->EnsureConnected() && service_->Status(status) &&
      status.state == chrnet::CoreState::kRunning) {
    // The tunnel outlived the previous app instance. Its proxy settings, if
    // any, are still ChrNet's own and still work.
    active_ = service_.get();
    proxy_enabled_ = chrnet::proxy::HasPendingRestore();
    chrnet::LogInfo("Attached to a connection kept by the ChrNet service");
    return;
  }
  RestoreStaleSystemProxy();
}

CoreBackend* VpnServiceBridge::SelectBackendForStart() {
  if (service_->EnsureConnected()) return service_.get();
  if (service_->StartInstalledService() && service_->EnsureConnected()) {
    return service_.get();
  }
  if (!in_process_) {
    chrnet::LogWarning("ChrNet service unavailable, running the core in-process");
    in_process_ = CreateInProcessBackend();
    in_process_->SetStatusListener(
        [this, alive = alive_](const chrnet::CoreStatus& status) {
          if (*alive) OnBackendStatus(status);
        });
  }
  return in_process_.get();
}

CoreBackend* VpnServiceBridge::BackendForQueries() {
  if (active_ != nullptr) return active_;
  if (service_->EnsureConnected()) return service_.get();
  return in_process_.get();
}

void VpnServiceBridge::RestoreProxyIfNeeded() {
  if (proxy_enabled_ || chrnet::proxy::HasPendingRestore()) {
    chrnet::proxy::RestoreAfterChrNet(http_port_);
  }
  proxy_enabled_ = false;
}

void VpnServiceBridge::OnBackendStatus(const chrnet::CoreStatus& status) {
  if (status.state != chrnet::CoreState::kStopped || status.error.empty()) {
    return;
  }
  // The core died, the network went away or the service restarted. Nothing
  // listens on the local proxy any more, so the proxy settings go right away
  // instead of leaving the user without internet until the app reconnects.
  chrnet::LogWarning("Connection lost: " + status.error);
  auto alive = alive_;
  RunOnWorker([this, alive]() {
    if (!*alive) return;
    active_ = nullptr;
    RestoreProxyIfNeeded();
  });
  host_->PostToPlatformThread([this, alive, status]() {
    if (!*alive) return;
    flutter::EncodableMap details;
    details[flutter::EncodableValue("error")] =
        flutter::EncodableValue(status.error);
    details[flutter::EncodableValue("code")] =
        flutter::EncodableValue(status.error_code);
    channel_->InvokeMethod(
        "onCoreStopped",
        std::make_unique<flutter::EncodableValue>(std::move(details)));
  });
}
