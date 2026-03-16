#include <winsock2.h>
#include <ws2tcpip.h>
#include "vpn_service_bridge.h"

#include <iphlpapi.h>
#include <wininet.h>

#include <algorithm>
#include <chrono>
#include <fstream>
#include <optional>
#include <sstream>
#include <string_view>
#include <vector>

namespace {

constexpr wchar_t kTunAdapterName[] = L"chrnet0";
constexpr wchar_t kChrNetProxyServer[] = L"127.0.0.1:10809";

struct DefaultRouteInfo {
  ULONG if_index = 0;
  std::string gateway;
  DWORD metric = 0;
};

struct AdapterInfo {
  ULONG if_index = 0;
  std::string ipv4;
};

std::string SockaddrToIpv4(const SOCKADDR* address);

std::string ForwardValueToIpv4(DWORD value) {
  std::ostringstream ip;
  ip << static_cast<int>(value & 0xFF) << '.'
     << static_cast<int>((value >> 8) & 0xFF) << '.'
     << static_cast<int>((value >> 16) & 0xFF) << '.'
     << static_cast<int>((value >> 24) & 0xFF);
  return ip.str();
}

bool IsChrNetSplitRoute(const MIB_IPFORWARDROW& row) {
  const auto destination = ForwardValueToIpv4(row.dwForwardDest);
  const auto mask = ForwardValueToIpv4(row.dwForwardMask);
  return mask == "128.0.0.0" &&
         (destination == "0.0.0.0" || destination == "128.0.0.0");
}

std::optional<AdapterInfo> FindAdapterByIndex(ULONG if_index) {
  ULONG size = 0;
  if (GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_PREFIX, nullptr, nullptr,
                           &size) != ERROR_BUFFER_OVERFLOW) {
    return std::nullopt;
  }

  std::vector<std::byte> buffer(size);
  auto* addresses =
      reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  if (GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_PREFIX, nullptr, addresses,
                           &size) != NO_ERROR) {
    return std::nullopt;
  }

  for (auto* current = addresses; current != nullptr; current = current->Next) {
    if (current->IfIndex != if_index) {
      continue;
    }

    std::string ipv4;
    for (auto* unicast = current->FirstUnicastAddress; unicast != nullptr;
         unicast = unicast->Next) {
      ipv4 = SockaddrToIpv4(unicast->Address.lpSockaddr);
      if (!ipv4.empty()) break;
    }

    return AdapterInfo{current->IfIndex, ipv4};
  }

  return std::nullopt;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return "";
  int length = WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                   static_cast<int>(value.size()), nullptr, 0,
                                   nullptr, nullptr);
  std::string out(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), out.data(), length,
                      nullptr, nullptr);
  return out;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return L"";
  int length = MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                                   static_cast<int>(value.size()), nullptr, 0);
  std::wstring out(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), out.data(), length);
  return out;
}

std::optional<std::string> ReadStringFromMap(
    const flutter::EncodableMap* map, const char* key) {
  if (!map) return std::nullopt;
  const auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) return std::nullopt;
  if (const auto* value = std::get_if<std::string>(&it->second)) {
    return *value;
  }
  return std::nullopt;
}

bool IsRunningAsAdmin() {
  BOOL is_admin = FALSE;
  SID_IDENTIFIER_AUTHORITY nt_authority = SECURITY_NT_AUTHORITY;
  PSID admin_group = nullptr;
  if (!AllocateAndInitializeSid(&nt_authority, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                                &admin_group)) {
    return false;
  }
  CheckTokenMembership(nullptr, admin_group, &is_admin);
  FreeSid(admin_group);
  return is_admin == TRUE;
}

std::string SockaddrToIpv4(const SOCKADDR* address) {
  if (!address || address->sa_family != AF_INET) return {};

  const auto* bytes =
      reinterpret_cast<const unsigned char*>(address->sa_data + 2);
  std::ostringstream out;
  out << static_cast<int>(bytes[0]) << '.'
      << static_cast<int>(bytes[1]) << '.'
      << static_cast<int>(bytes[2]) << '.'
      << static_cast<int>(bytes[3]);
  return out.str();
}

std::optional<DefaultRouteInfo> GetDefaultRouteInfo() {
  ULONG size = 0;
  if (GetIpForwardTable(nullptr, &size, FALSE) != ERROR_INSUFFICIENT_BUFFER) {
    return std::nullopt;
  }

  std::vector<std::byte> buffer(size);
  auto* table =
      reinterpret_cast<MIB_IPFORWARDTABLE*>(buffer.data());
  if (GetIpForwardTable(table, &size, FALSE) != NO_ERROR) {
    return std::nullopt;
  }

  std::optional<DefaultRouteInfo> best_route;
  for (DWORD i = 0; i < table->dwNumEntries; ++i) {
    const auto& row = table->table[i];
    if (row.dwForwardDest != 0 || row.dwForwardMask != 0) continue;
    if (row.dwForwardNextHop == 0) continue;

    if (!best_route.has_value() ||
        row.dwForwardMetric1 < best_route->metric) {
      best_route = DefaultRouteInfo{
          row.dwForwardIfIndex,
          ForwardValueToIpv4(row.dwForwardNextHop),
          row.dwForwardMetric1,
      };
    }
  }

  return best_route;
}

std::optional<AdapterInfo> FindTunAdapter(std::wstring_view adapter_name) {
  // Use AF_UNSPEC so the adapter is found regardless of whether xray has
  // assigned an IPv4 address to the wintun interface yet.
  ULONG size = 0;
  if (GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX, nullptr,
                           nullptr, &size) != ERROR_BUFFER_OVERFLOW) {
    return std::nullopt;
  }

  std::vector<std::byte> buffer(size);
  auto* addresses =
      reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  if (GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX, nullptr,
                           addresses, &size) != NO_ERROR) {
    return std::nullopt;
  }

  for (auto* current = addresses; current != nullptr; current = current->Next) {
    if (!current->FriendlyName ||
        std::wstring_view(current->FriendlyName) != adapter_name) {
      continue;
    }
    // Return the adapter even if no IPv4 address is assigned yet.
    // We only need the interface index; autoRoute lets xray own the TUN routes.
    std::string ipv4;
    for (auto* unicast = current->FirstUnicastAddress; unicast != nullptr;
         unicast = unicast->Next) {
      ipv4 = SockaddrToIpv4(unicast->Address.lpSockaddr);
      if (!ipv4.empty()) break;
    }
    return AdapterInfo{current->IfIndex, ipv4};
  }

  return std::nullopt;
}

std::vector<std::string> ResolveHostIPv4(const std::string& host) {
  std::vector<std::string> result;
  if (host.empty()) return result;

  const auto is_ipv4 = std::all_of(host.begin(), host.end(), [](char ch) {
    return (ch >= '0' && ch <= '9') || ch == '.';
  });
  if (is_ipv4) {
    result.push_back(host);
    return result;
  }

  SECURITY_ATTRIBUTES sa = {};
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;

  HANDLE read_pipe = nullptr;
  HANDLE write_pipe = nullptr;
  if (!CreatePipe(&read_pipe, &write_pipe, &sa, 0)) {
    return result;
  }
  SetHandleInformation(read_pipe, HANDLE_FLAG_INHERIT, 0);

  wchar_t sys_root[MAX_PATH] = {};
  if (GetEnvironmentVariableW(L"SystemRoot", sys_root, MAX_PATH) == 0) {
    wcscpy_s(sys_root, L"C:\\Windows");
  }
  const auto powershell =
      std::filesystem::path(sys_root) /
      "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe";
  std::wstring command =
      L"\"" + powershell.wstring() +
      L"\" -NoProfile -Command "
      L"\"$ProgressPreference='SilentlyContinue'; "
      L"Resolve-DnsName -Type A -Name '" +
      Utf8ToWide(host) +
      L"' -ErrorAction Stop | Select-Object -ExpandProperty IPAddress\"";

  std::vector<wchar_t> cmdline(command.begin(), command.end());
  cmdline.push_back(L'\0');

  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;
  si.hStdOutput = write_pipe;
  si.hStdError = write_pipe;

  PROCESS_INFORMATION pi = {};
  const bool ok = CreateProcessW(nullptr, cmdline.data(), nullptr, nullptr, TRUE,
                                 CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
  CloseHandle(write_pipe);
  if (!ok) {
    CloseHandle(read_pipe);
    return result;
  }

  std::string output;
  char buffer[256];
  DWORD bytes_read = 0;
  while (ReadFile(read_pipe, buffer, sizeof(buffer), &bytes_read, nullptr) &&
         bytes_read > 0) {
    output.append(buffer, bytes_read);
  }

  WaitForSingleObject(pi.hProcess, 4000);
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  CloseHandle(read_pipe);

  std::istringstream lines(output);
  for (std::string line; std::getline(lines, line);) {
    line.erase(std::remove(line.begin(), line.end(), '\r'), line.end());
    if (line.empty()) continue;
    if (std::find(result.begin(), result.end(), line) == result.end()) {
      result.push_back(line);
    }
  }
  return result;
}

std::string BindDirectOutboundToInterface(const std::string& config_json,
                                          const std::string& interface_ip) {
  if (interface_ip.empty()) {
    return config_json;
  }

  const std::string needle = R"({"tag":"direct","protocol":"freedom"})";
  const std::string replacement =
      std::string(R"({"tag":"direct","protocol":"freedom","sendThrough":")") +
      interface_ip + R"("})";

  auto patched = config_json;
  const auto pos = patched.find(needle);
  if (pos != std::string::npos) {
    patched.replace(pos, needle.size(), replacement);
  }
  return patched;
}

}  // namespace

VpnServiceBridge::VpnServiceBridge(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.chrnet.vpn/service",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });

  CleanupStaleNetworkArtifacts();
}

VpnServiceBridge::~VpnServiceBridge() {
  StopCore();
}

void VpnServiceBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = call.method_name();

  if (method == "getStatus") {
    result->Success(flutter::EncodableValue(IsCoreRunning()));
    return;
  }

  if (method == "getDeviceInfo") {
    flutter::EncodableMap info;
    info[flutter::EncodableValue("deviceId")] =
        flutter::EncodableValue(GetComputerNameUtf8());
    info[flutter::EncodableValue("osVersion")] =
        flutter::EncodableValue(GetWindowsVersion());
    info[flutter::EncodableValue("model")] =
        flutter::EncodableValue("Windows PC");
    result->Success(flutter::EncodableValue(info));
    return;
  }

  if (method == "getStats") {
    const auto s = GetCurrentStats();
    flutter::EncodableMap stats_map;
    stats_map[flutter::EncodableValue("download")] =
        flutter::EncodableValue(static_cast<int64_t>(s.download));
    stats_map[flutter::EncodableValue("upload")] =
        flutter::EncodableValue(static_cast<int64_t>(s.upload));
    result->Success(flutter::EncodableValue(stats_map));
    return;
  }

  if (method == "disconnect") {
    auto shared_result =
        std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
            result.release());
    std::thread([this, shared_result]() {
      std::lock_guard<std::mutex> lock(core_mutex_);
      StopCore();
      shared_result->Success();
    }).detach();
    return;
  }

  if (method == "connect" || method == "reconnect") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(call.arguments());
    const auto config_json = ReadStringFromMap(args, "configJson");
    const auto server_host = ReadStringFromMap(args, "host");
    if (!config_json || config_json->empty()) {
      result->Error("INVALID_ARG", "configJson is required for Windows");
      return;
    }
    const auto windows_mode = ReadStringFromMap(args, "windowsMode");
    const bool use_system_proxy =
        !windows_mode.has_value() || *windows_mode != "tunnel";

    auto shared_result =
        std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
            result.release());
    std::string config_copy = *config_json;
    std::string server_host_copy = server_host.value_or("");
    std::thread([this, config_copy, use_system_proxy, server_host_copy,
                 shared_result]() {
      std::lock_guard<std::mutex> lock(core_mutex_);
      StopCore();
      std::string error;
      if (!StartCore(config_copy, use_system_proxy, server_host_copy, error)) {
        shared_result->Error("CORE_START_FAILED", error);
      } else {
        shared_result->Success();
      }
    }).detach();
    return;
  }

  result->NotImplemented();
}

bool VpnServiceBridge::StartCore(const std::string& config_json,
                                 bool use_system_proxy,
                                 const std::string& server_host,
                                 std::string& error) {
  if (!use_system_proxy && !IsRunningAsAdmin()) {
    error = "Tunnel mode requires running the app as Administrator on Windows.";
    return false;
  }
  use_system_proxy_ = use_system_proxy;
  const auto xray_path = ResolveXrayPath();
  if (xray_path.empty()) {
    error =
        "xray.exe not found. Place it near chrnet.exe or set CHRNET_XRAY_PATH.";
    return false;
  }

  const auto runtime_dir = ResolveRuntimeDir();
  std::error_code ec;
  std::filesystem::create_directories(runtime_dir, ec);
  if (ec) {
    error = "Failed to create runtime directory: " + ec.message();
    return false;
  }

  auto config_to_write = config_json;
  if (!use_system_proxy) {
    const auto default_route = GetDefaultRouteInfo();
    if (default_route.has_value()) {
      const auto adapter = FindAdapterByIndex(default_route->if_index);
      if (adapter.has_value() && !adapter->ipv4.empty()) {
        // In TUN mode direct traffic must be bound to the physical adapter,
        // otherwise it can loop back into the TUN default routes.
        config_to_write =
            BindDirectOutboundToInterface(config_json, adapter->ipv4);
      }
    }
  }

  const auto config_path = runtime_dir / "xray-config.json";
  {
    std::ofstream out(config_path, std::ios::binary | std::ios::trunc);
    if (!out.is_open()) {
      error = "Failed to write xray config file";
      return false;
    }
    out.write(config_to_write.data(),
              static_cast<std::streamsize>(config_to_write.size()));
  }

  std::wstring cmd = L"\"" + xray_path.wstring() + L"\" run -c \"" +
                     config_path.wstring() + L"\"";
  std::vector<wchar_t> cmdline(cmd.begin(), cmd.end());
  cmdline.push_back(L'\0');

  // Redirect xray stdout/stderr to a log file for diagnostics.
  const auto log_path = runtime_dir / "xray.log";
  SECURITY_ATTRIBUTES log_sa = {};
  log_sa.nLength = sizeof(log_sa);
  log_sa.bInheritHandle = TRUE;
  HANDLE log_handle = CreateFileW(
      log_path.wstring().c_str(),
      GENERIC_WRITE, FILE_SHARE_READ, &log_sa,
      CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);

  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
  si.wShowWindow = SW_HIDE;
  si.hStdOutput = (log_handle != INVALID_HANDLE_VALUE) ? log_handle : nullptr;
  si.hStdError  = (log_handle != INVALID_HANDLE_VALUE) ? log_handle : nullptr;

  PROCESS_INFORMATION pi = {};
  const auto work_dir = xray_path.parent_path().wstring();
  if (!CreateProcessW(nullptr, cmdline.data(), nullptr, nullptr,
                      log_handle != INVALID_HANDLE_VALUE,  // bInheritHandles
                      CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr,
                      work_dir.c_str(), &si, &pi)) {
    if (log_handle != INVALID_HANDLE_VALUE) CloseHandle(log_handle);
    error = "CreateProcess failed with code " + std::to_string(GetLastError());
    return false;
  }
  if (log_handle != INVALID_HANDLE_VALUE) CloseHandle(log_handle);

  // Assign xray.exe to a Job Object so it is killed automatically when
  // chrnet.exe exits (even if it crashes or is force-terminated).
  if (job_handle_ != nullptr) {
    CloseHandle(job_handle_);
    job_handle_ = nullptr;
  }
  job_handle_ = CreateJobObjectW(nullptr, nullptr);
  if (job_handle_) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli = {};
    jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(job_handle_,
                            JobObjectExtendedLimitInformation,
                            &jeli, sizeof(jeli));
    AssignProcessToJobObject(job_handle_, pi.hProcess);
  }
  ResumeThread(pi.hThread);

  process_info_ = pi;
  has_process_ = true;
  is_running_ = true;

  if (use_system_proxy_) {
    if (!SetSystemProxy(kChrNetProxyServer)) {
      StopCore();
      error = "Failed to set Windows system proxy";
      return false;
    }
    proxy_enabled_ = true;
  } else {
    proxy_enabled_ = false;
  }

  if (!use_system_proxy_ && !ConfigureTunnelRoutes(server_host, error)) {
    StopCore();
    return false;
  }

  // Reset stats counters and start background polling thread.
  {
    std::lock_guard<std::mutex> lock(stats_mutex_);
    stats_cumulative_download_ = 0;
    stats_cumulative_upload_ = 0;
  }
  StartStatsThread();
  return true;
}

void VpnServiceBridge::StopCore() {
  StopStatsThread();
  if (has_process_) {
    if (IsCoreRunning()) {
      TerminateProcess(process_info_.hProcess, 0);
      WaitForSingleObject(process_info_.hProcess, 2000);
    }
    CloseHandle(process_info_.hThread);
    CloseHandle(process_info_.hProcess);
    process_info_ = {};
    has_process_ = false;
  }
  // Closing the job handle terminates xray.exe even if TerminateProcess failed.
  if (job_handle_ != nullptr) {
    CloseHandle(job_handle_);
    job_handle_ = nullptr;
  }
  if (proxy_enabled_) {
    RestoreProxyState();
    proxy_enabled_ = false;
  }
  RestoreTunnelRoutes();
  CleanupStaleNetworkArtifacts();
  is_running_ = false;
}

bool VpnServiceBridge::IsCoreRunning() {
  if (!has_process_) return false;
  const auto wait = WaitForSingleObject(process_info_.hProcess, 0);
  if (wait == WAIT_TIMEOUT) {
    is_running_ = true;
    return true;
  }
  CloseHandle(process_info_.hThread);
  CloseHandle(process_info_.hProcess);
  process_info_ = {};
  has_process_ = false;
  if (proxy_enabled_) {
    RestoreProxyState();
    proxy_enabled_ = false;
  }
  RestoreTunnelRoutes();
  CleanupStaleNetworkArtifacts();
  is_running_ = false;
  return false;
}

std::filesystem::path VpnServiceBridge::ResolveXrayPath() const {
  wchar_t env_path[1024] = {};
  const auto len =
      GetEnvironmentVariableW(L"CHRNET_XRAY_PATH", env_path, 1024);
  if (len > 0 && len < 1024) {
    std::filesystem::path p(env_path);
    if (std::filesystem::exists(p)) return p;
  }

  wchar_t exe_path[MAX_PATH] = {};
  const auto got = GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (got == 0) return {};

  std::filesystem::path exe_dir = std::filesystem::path(exe_path).parent_path();
  const auto p1 = exe_dir / "xray.exe";
  if (std::filesystem::exists(p1)) return p1;

  const auto p2 = exe_dir / "data" / "flutter_assets" / "assets" / "xray.exe";
  if (std::filesystem::exists(p2)) return p2;

  return {};
}

std::filesystem::path VpnServiceBridge::ResolveRuntimeDir() const {
  wchar_t local_app_data[MAX_PATH] = {};
  const auto len =
      GetEnvironmentVariableW(L"LOCALAPPDATA", local_app_data, MAX_PATH);
  if (len > 0 && len < MAX_PATH) {
    return std::filesystem::path(local_app_data) / "ChrNet" / "xray";
  }
  return std::filesystem::temp_directory_path() / "ChrNet" / "xray";
}

bool VpnServiceBridge::SetSystemProxy(const std::wstring& proxy_server) {
  if (!CaptureProxyState()) return false;
  return ApplyProxyState(PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY, proxy_server,
                         L"<local>");
}

bool VpnServiceBridge::CaptureProxyState() {
  INTERNET_PER_CONN_OPTION options[3] = {};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;

  INTERNET_PER_CONN_OPTION_LIST list = {};
  list.dwSize = sizeof(list);
  list.pszConnection = nullptr;
  list.dwOptionCount = 3;
  list.dwOptionError = 0;
  list.pOptions = options;

  DWORD size = sizeof(list);
  if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                            &list, &size)) {
    return false;
  }

  proxy_state_.flags = options[0].Value.dwValue;
  proxy_state_.server =
      options[1].Value.pszValue ? options[1].Value.pszValue : L"";
  proxy_state_.bypass =
      options[2].Value.pszValue ? options[2].Value.pszValue : L"";
  proxy_state_.captured = true;

  if (options[1].Value.pszValue) GlobalFree(options[1].Value.pszValue);
  if (options[2].Value.pszValue) GlobalFree(options[2].Value.pszValue);
  return true;
}

bool VpnServiceBridge::RestoreProxyState() {
  if (!proxy_state_.captured) return true;
  return ApplyProxyState(proxy_state_.flags, proxy_state_.server,
                         proxy_state_.bypass);
}

bool VpnServiceBridge::ApplyProxyState(DWORD flags, const std::wstring& server,
                                       const std::wstring& bypass) {
  INTERNET_PER_CONN_OPTION options[3] = {};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = flags;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = const_cast<wchar_t*>(server.c_str());
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = const_cast<wchar_t*>(bypass.c_str());

  INTERNET_PER_CONN_OPTION_LIST list = {};
  list.dwSize = sizeof(list);
  list.pszConnection = nullptr;
  list.dwOptionCount = 3;
  list.dwOptionError = 0;
  list.pOptions = options;

  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list,
                          sizeof(list))) {
    return false;
  }
  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
  return true;
}

void VpnServiceBridge::CleanupStaleNetworkArtifacts() {
  CleanupProxyIfChrNetOwned();
  CleanupStaleTunnelRoutes();
}

void VpnServiceBridge::CleanupProxyIfChrNetOwned() {
  INTERNET_PER_CONN_OPTION options[3] = {};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;

  INTERNET_PER_CONN_OPTION_LIST list = {};
  list.dwSize = sizeof(list);
  list.pszConnection = nullptr;
  list.dwOptionCount = 3;
  list.dwOptionError = 0;
  list.pOptions = options;

  DWORD size = sizeof(list);
  if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                            &list, &size)) {
    return;
  }

  const DWORD flags = options[0].Value.dwValue;
  const std::wstring server =
      options[1].Value.pszValue ? options[1].Value.pszValue : L"";
  const std::wstring bypass =
      options[2].Value.pszValue ? options[2].Value.pszValue : L"";

  if (options[1].Value.pszValue) GlobalFree(options[1].Value.pszValue);
  if (options[2].Value.pszValue) GlobalFree(options[2].Value.pszValue);

  const bool proxy_enabled = (flags & PROXY_TYPE_PROXY) != 0;
  const bool looks_like_chrnet_proxy =
      server.find(kChrNetProxyServer) != std::wstring::npos;
  const bool matches_captured_state =
      proxy_state_.captured &&
      proxy_state_.flags == flags &&
      proxy_state_.server == server &&
      proxy_state_.bypass == bypass;

  if (!proxy_enabled || !looks_like_chrnet_proxy || matches_captured_state) {
    return;
  }

  ApplyProxyState(PROXY_TYPE_DIRECT, L"", L"");
}

void VpnServiceBridge::CleanupStaleTunnelRoutes() {
  std::vector<ULONG> candidate_if_indices;
  std::vector<std::string> candidate_next_hops;

  const auto add_if_index = [&candidate_if_indices](ULONG if_index) {
    if (if_index == 0) return;
    if (std::find(candidate_if_indices.begin(), candidate_if_indices.end(),
                  if_index) == candidate_if_indices.end()) {
      candidate_if_indices.push_back(if_index);
    }
  };

  const auto add_next_hop = [&candidate_next_hops](const std::string& ip) {
    if (ip.empty()) return;
    if (std::find(candidate_next_hops.begin(), candidate_next_hops.end(), ip) ==
        candidate_next_hops.end()) {
      candidate_next_hops.push_back(ip);
    }
  };

  add_if_index(tunnel_routes_.tun_if_index);
  add_next_hop(tunnel_routes_.tun_gateway);

  if (const auto tun_adapter = FindTunAdapter(kTunAdapterName);
      tun_adapter.has_value()) {
    add_if_index(tun_adapter->if_index);
    add_next_hop(tun_adapter->ipv4);
  }

  if (!candidate_if_indices.empty() || !candidate_next_hops.empty()) {
    ULONG size = 0;
    if (GetIpForwardTable(nullptr, &size, FALSE) == ERROR_INSUFFICIENT_BUFFER) {
      std::vector<std::byte> buffer(size);
      auto* table = reinterpret_cast<MIB_IPFORWARDTABLE*>(buffer.data());
      if (GetIpForwardTable(table, &size, FALSE) == NO_ERROR) {
        for (DWORD i = 0; i < table->dwNumEntries; ++i) {
          const auto& row = table->table[i];
          if (!IsChrNetSplitRoute(row)) continue;

          const bool matches_if_index =
              std::find(candidate_if_indices.begin(),
                        candidate_if_indices.end(),
                        row.dwForwardIfIndex) != candidate_if_indices.end();
          const auto next_hop = ForwardValueToIpv4(row.dwForwardNextHop);
          const bool matches_next_hop =
              std::find(candidate_next_hops.begin(),
                        candidate_next_hops.end(),
                        next_hop) != candidate_next_hops.end();

          if (!matches_if_index && !matches_next_hop) continue;

          auto row_copy = row;
          DeleteIpForwardEntry(&row_copy);
        }
      }
    }
  }

  for (const auto if_index : candidate_if_indices) {
    for (const auto& destination : {L"0.0.0.0", L"128.0.0.0"}) {
      std::wstringstream route_args;
      route_args << L"DELETE " << destination
                 << L" MASK 128.0.0.0 IF " << if_index;
      RunRouteCommand(route_args.str());
    }
  }

  for (const auto& next_hop : candidate_next_hops) {
    for (const auto& destination : {L"0.0.0.0", L"128.0.0.0"}) {
      std::wstringstream route_args;
      route_args << L"DELETE " << destination
                 << L" MASK 128.0.0.0 "
                 << Utf8ToWide(next_hop);
      RunRouteCommand(route_args.str());
    }
  }

  tunnel_routes_ = {};
}

bool VpnServiceBridge::ConfigureTunnelRoutes(const std::string& server_host,
                                             std::string& error) {
  tunnel_routes_ = {};

  const auto default_route = GetDefaultRouteInfo();
  if (!default_route.has_value()) {
    error = "Failed to detect current default IPv4 route";
    return false;
  }

  auto tun_adapter = FindTunAdapter(kTunAdapterName);
  for (int attempt = 0; attempt < 12 && !tun_adapter.has_value(); ++attempt) {
    // Stop waiting early if xray has already exited.
    if (WaitForSingleObject(process_info_.hProcess, 0) != WAIT_TIMEOUT) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    tun_adapter = FindTunAdapter(kTunAdapterName);
  }

  if (!tun_adapter.has_value()) {
    const auto log_hint = ResolveRuntimeDir() / "xray.log";
    error = "TUN adapter chrnet0 was not created by Xray. "
            "Check log: " + log_hint.string();
    return false;
  }

  // Wait up to 2 s for xray to assign an IPv4 address (via the "address" config
  // field). If it hasn't appeared by then, assign one ourselves via netsh so we
  // don't have to wait 30–60 s for Windows APIPA auto-assignment.
  for (int attempt = 0; attempt < 4 && tun_adapter->ipv4.empty(); ++attempt) {
    if (WaitForSingleObject(process_info_.hProcess, 0) != WAIT_TIMEOUT) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    tun_adapter = FindTunAdapter(kTunAdapterName);
  }

  if (!tun_adapter.has_value()) {
    const auto log_hint = ResolveRuntimeDir() / "xray.log";
    error = "TUN adapter chrnet0 disappeared unexpectedly. "
            "Check log: " + log_hint.string();
    return false;
  }

  if (tun_adapter->ipv4.empty()) {
    // xray did not assign an IP — do it ourselves via netsh.
    wchar_t sys_dir[MAX_PATH] = {};
    GetSystemDirectoryW(sys_dir, MAX_PATH);
    const auto netsh = std::filesystem::path(sys_dir) / "netsh.exe";
    std::wstring netsh_cmd =
        L"\"" + netsh.wstring() +
        L"\" interface ipv4 set address name=\"" +
        std::wstring(kTunAdapterName) +
        L"\" static 10.0.0.1 255.255.255.0";
    std::vector<wchar_t> netsh_cmdline(netsh_cmd.begin(), netsh_cmd.end());
    netsh_cmdline.push_back(L'\0');

    STARTUPINFOW ns_si = {};
    ns_si.cb = sizeof(ns_si);
    ns_si.dwFlags = STARTF_USESHOWWINDOW;
    ns_si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION ns_pi = {};
    if (CreateProcessW(nullptr, netsh_cmdline.data(), nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW, nullptr, nullptr, &ns_si, &ns_pi)) {
      WaitForSingleObject(ns_pi.hProcess, 5000);
      CloseHandle(ns_pi.hProcess);
      CloseHandle(ns_pi.hThread);
    }

    // Wait for the IP to appear after the netsh command.
    for (int attempt = 0; attempt < 6 && tun_adapter->ipv4.empty(); ++attempt) {
      std::this_thread::sleep_for(std::chrono::milliseconds(500));
      tun_adapter = FindTunAdapter(kTunAdapterName);
    }
  }

  if (!tun_adapter.has_value() || tun_adapter->ipv4.empty()) {
    const auto log_hint = ResolveRuntimeDir() / "xray.log";
    error = "TUN adapter chrnet0 has no IPv4 address even after netsh. "
            "Check log: " + log_hint.string();
    return false;
  }

  tunnel_routes_.original_if_index = default_route->if_index;
  tunnel_routes_.original_gateway = default_route->gateway;
  tunnel_routes_.tun_if_index = tun_adapter->if_index;
  tunnel_routes_.tun_gateway = tun_adapter->ipv4;
  tunnel_routes_.server_ips = ResolveHostIPv4(server_host);

  // Add a host route for the VPN server IP via the original gateway so its
  // traffic bypasses the TUN, preventing a routing loop.
  for (const auto& ip : tunnel_routes_.server_ips) {
    std::wstringstream route_args;
    route_args << L"ADD " << Utf8ToWide(ip)
               << L" MASK 255.255.255.255 "
               << Utf8ToWide(tunnel_routes_.original_gateway)
               << L" METRIC 1 IF " << tunnel_routes_.original_if_index;
    if (!RunRouteCommand(route_args.str())) {
      RestoreTunnelRoutes();
      error = "Failed to add direct route for VPN server " + ip;
      return false;
    }
  }

  // Route all IPv4 traffic through TUN with metric 1, overriding the physical
  // default route. Split into two /1 routes to avoid conflicting with the
  // existing 0.0.0.0/0 default route.
  for (const auto& destination : {L"0.0.0.0", L"128.0.0.0"}) {
    std::wstringstream route_args;
    route_args << L"ADD " << destination
               << L" MASK 128.0.0.0 "
               << Utf8ToWide(tunnel_routes_.tun_gateway)
               << L" METRIC 1 IF " << tunnel_routes_.tun_if_index;
    if (!RunRouteCommand(route_args.str())) {
      RestoreTunnelRoutes();
      error = "Failed to route traffic through TUN adapter";
      return false;
    }
  }

  tunnel_routes_.configured = true;
  return true;
}

void VpnServiceBridge::RestoreTunnelRoutes() {
  if (!tunnel_routes_.configured) {
    tunnel_routes_ = {};
    return;
  }

  // Remove the 0.0.0.0/1 and 128.0.0.0/1 TUN routes we added.
  for (const auto& destination : {L"0.0.0.0", L"128.0.0.0"}) {
    std::wstringstream route_args;
    route_args << L"DELETE " << destination
               << L" MASK 128.0.0.0 "
               << Utf8ToWide(tunnel_routes_.tun_gateway)
               << L" IF " << tunnel_routes_.tun_if_index;
    RunRouteCommand(route_args.str());
  }

  // Remove server host routes.
  for (const auto& ip : tunnel_routes_.server_ips) {
    std::wstringstream route_args;
    route_args << L"DELETE " << Utf8ToWide(ip)
               << L" MASK 255.255.255.255 "
               << Utf8ToWide(tunnel_routes_.original_gateway)
               << L" IF " << tunnel_routes_.original_if_index;
    RunRouteCommand(route_args.str());
  }

  tunnel_routes_ = {};
}

bool VpnServiceBridge::RunRouteCommand(const std::wstring& arguments) {
  wchar_t system_dir[MAX_PATH] = {};
  const auto length = GetSystemDirectoryW(system_dir, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return false;
  }

  const auto route_path = std::filesystem::path(system_dir) / "route.exe";
  std::wstring command =
      L"\"" + route_path.wstring() + L"\" " + arguments;
  std::vector<wchar_t> cmdline(command.begin(), command.end());
  cmdline.push_back(L'\0');

  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;

  PROCESS_INFORMATION pi = {};
  if (!CreateProcessW(nullptr, cmdline.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
    return false;
  }

  WaitForSingleObject(pi.hProcess, 5000);
  DWORD exit_code = 1;
  GetExitCodeProcess(pi.hProcess, &exit_code);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return exit_code == 0;
}

// ─── Stats polling ───────────────────────────────────────────────────────────

void VpnServiceBridge::StartStatsThread() {
  if (stats_running_.load()) return;
  stats_running_.store(true);
  stats_thread_ = std::thread([this]() { StatsThreadFunc(); });
}

void VpnServiceBridge::StopStatsThread() {
  stats_running_.store(false);
  stats_cv_.notify_all();
  if (stats_thread_.joinable()) {
    stats_thread_.join();
  }
}

void VpnServiceBridge::StatsThreadFunc() {
  // Wait for xray to fully start before the first query.
  {
    std::unique_lock<std::mutex> lock(stats_cv_mutex_);
    stats_cv_.wait_for(lock, std::chrono::seconds(2),
                       [this] { return !stats_running_.load(); });
  }
  while (stats_running_.load()) {
    const auto json = RunStatsQuery();
    if (!json.empty()) {
      const auto result = ParseStatsOutput(json);
      std::lock_guard<std::mutex> lock(stats_mutex_);
      stats_cumulative_download_ = result.download;
      stats_cumulative_upload_ = result.upload;
    }
    // Poll every second — speed is computed in Dart from the delta.
    std::unique_lock<std::mutex> lock(stats_cv_mutex_);
    stats_cv_.wait_for(lock, std::chrono::seconds(1),
                       [this] { return !stats_running_.load(); });
  }
}

// Runs: xray.exe api statsquery -s 127.0.0.1:10853 -reset=false
// and returns its stdout as a UTF-8 string.
std::string VpnServiceBridge::RunStatsQuery() {
  const auto xray_path = ResolveXrayPath();
  if (xray_path.empty()) return {};

  std::wstring cmd = L"\"" + xray_path.wstring() +
                     L"\" api statsquery -s 127.0.0.1:10853 -reset=false";
  std::vector<wchar_t> cmdline(cmd.begin(), cmd.end());
  cmdline.push_back(L'\0');

  SECURITY_ATTRIBUTES sa = {};
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;

  HANDLE read_pipe = nullptr;
  HANDLE write_pipe = nullptr;
  if (!CreatePipe(&read_pipe, &write_pipe, &sa, 0)) return {};

  // Ensure write end is not inherited by the parent.
  SetHandleInformation(read_pipe, HANDLE_FLAG_INHERIT, 0);

  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;
  si.hStdOutput = write_pipe;
  si.hStdError = write_pipe;

  PROCESS_INFORMATION pi = {};
  const auto work_dir = xray_path.parent_path().wstring();
  const bool ok =
      CreateProcessW(nullptr, cmdline.data(), nullptr, nullptr, TRUE,
                     CREATE_NO_WINDOW, nullptr, work_dir.c_str(), &si, &pi);
  CloseHandle(write_pipe);
  if (!ok) {
    CloseHandle(read_pipe);
    return {};
  }

  std::string output;
  char buf[512];
  DWORD bytes_read = 0;
  while (ReadFile(read_pipe, buf, sizeof(buf), &bytes_read, nullptr) &&
         bytes_read > 0) {
    output.append(buf, bytes_read);
  }

  WaitForSingleObject(pi.hProcess, 1500);
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  CloseHandle(read_pipe);
  return output;
}

// Parse the JSON array returned by "xray api statsquery".
// Each element has the shape: {"name":"outbound>>>proxy>>>traffic>>>downlink","value":"12345"}
VpnServiceBridge::StatsResult VpnServiceBridge::ParseStatsOutput(
    const std::string& json) {
  StatsResult result;
  // Simple substring search — avoids pulling in a JSON library.
  auto extractValue = [&](const std::string& key) -> int64_t {
    const auto pos = json.find(key);
    if (pos == std::string::npos) return 0;
    // Find "value" after the key
    const auto vpos = json.find("\"value\"", pos);
    if (vpos == std::string::npos) return 0;
    const auto colon = json.find(':', vpos);
    if (colon == std::string::npos) return 0;
    // Skip whitespace and optional quote
    auto start = colon + 1;
    while (start < json.size() &&
           (json[start] == ' ' || json[start] == '"')) {
      ++start;
    }
    return std::stoll(json.c_str() + start);
  };
  result.download = extractValue("downlink");
  result.upload = extractValue("uplink");
  return result;
}

VpnServiceBridge::StatsResult VpnServiceBridge::GetCurrentStats() const {
  std::lock_guard<std::mutex> lock(stats_mutex_);
  return {stats_cumulative_download_, stats_cumulative_upload_};
}

std::string VpnServiceBridge::GetComputerNameUtf8() {
  wchar_t buffer[256] = {};
  DWORD size = 256;
  if (!GetComputerNameW(buffer, &size)) return "";
  return WideToUtf8(std::wstring(buffer, size));
}

std::string VpnServiceBridge::GetWindowsVersion() {
  return "Windows";
}
