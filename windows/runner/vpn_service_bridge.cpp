#include "vpn_service_bridge.h"

#include <wininet.h>

#include <chrono>
#include <fstream>
#include <optional>
#include <sstream>
#include <vector>

namespace {

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

}  // namespace

VpnServiceBridge::VpnServiceBridge(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.chrnet.vpn/service",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
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
    std::thread([this, config_copy, use_system_proxy, shared_result]() {
      std::lock_guard<std::mutex> lock(core_mutex_);
      StopCore();
      std::string error;
      if (!StartCore(config_copy, use_system_proxy, error)) {
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

  const auto config_path = runtime_dir / "xray-config.json";
  {
    std::ofstream out(config_path, std::ios::binary | std::ios::trunc);
    if (!out.is_open()) {
      error = "Failed to write xray config file";
      return false;
    }
    out.write(config_json.data(), static_cast<std::streamsize>(config_json.size()));
  }

  std::wstring cmd = L"\"" + xray_path.wstring() + L"\" run -c \"" +
                     config_path.wstring() + L"\"";
  std::vector<wchar_t> cmdline(cmd.begin(), cmd.end());
  cmdline.push_back(L'\0');

  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;

  PROCESS_INFORMATION pi = {};
  const auto work_dir = xray_path.parent_path().wstring();
  if (!CreateProcessW(nullptr, cmdline.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr,
                      work_dir.c_str(), &si, &pi)) {
    error = "CreateProcess failed with code " + std::to_string(GetLastError());
    return false;
  }

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
    if (!SetSystemProxy(L"127.0.0.1:10809")) {
      StopCore();
      error = "Failed to set Windows system proxy";
      return false;
    }
    proxy_enabled_ = true;
  } else {
    proxy_enabled_ = false;
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
