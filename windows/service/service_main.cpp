// ChrNet VPN service.
//
// Runs as LocalSystem so the app itself never needs administrator rights: the
// app sends a finished Xray config over the pipe, the service starts the core
// and sets up the tunnel, and pushes status changes back.
//
//   chrnet_service.exe                  run under the service control manager
//   chrnet_service.exe --install        register (or update) and start
//   chrnet_service.exe --uninstall      stop and remove
//   chrnet_service.exe --console [--pipe NAME] [--test] [--allow-any-client]
//                                       run in the foreground for diagnostics

#include <winsock2.h>
#include <windows.h>

#include <aclapi.h>
#include <sddl.h>

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

#include "core_controller.h"
#include "json.h"
#include "log.h"
#include "pipe_protocol.h"
#include "pipe_server.h"
#include "string_util.h"

#ifndef CHRNET_VERSION
#define CHRNET_VERSION "dev"
#endif

namespace chrnet {
namespace {

constexpr wchar_t kDisplayName[] = L"ChrNet VPN Service";
constexpr wchar_t kDescription[] =
    L"Управляет туннелем ChrNet VPN: запускает ядро Xray и настраивает "
    L"маршруты и DNS. Без неё режим «Туннель» не работает.";

std::filesystem::path ExecutableDir() {
  wchar_t path[MAX_PATH * 2] = {};
  const DWORD length =
      GetModuleFileNameW(nullptr, path, static_cast<DWORD>(std::size(path)));
  return std::filesystem::path(std::wstring(path, length)).parent_path();
}

// Config files carry the user's keys, so only SYSTEM and administrators may
// read the runtime directory.
void RestrictToAdministrators(const std::filesystem::path& directory) {
  std::error_code ec;
  std::filesystem::create_directories(directory, ec);
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", SDDL_REVISION_1, &descriptor,
          nullptr)) {
    return;
  }
  SECURITY_ATTRIBUTES attributes = {sizeof(attributes), descriptor, FALSE};
  CreateDirectoryW(directory.wstring().c_str(), &attributes);
  BOOL present = FALSE;
  BOOL defaulted = FALSE;
  PACL dacl = nullptr;
  if (GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted) &&
      present) {
    std::wstring path = directory.wstring();
    SetNamedSecurityInfoW(path.data(), SE_FILE_OBJECT,
                          DACL_SECURITY_INFORMATION |
                              PROTECTED_DACL_SECURITY_INFORMATION,
                          nullptr, nullptr, dacl, nullptr);
  }
  LocalFree(descriptor);
}

JsonValue StatusToJson(const CoreStatus& status) {
  JsonValue json = JsonValue::MakeObject();
  json.SetString("state", CoreStateName(status.state));
  json.SetBool("tunnel", status.tunnel);
  json.SetInt("startedAt", status.started_at_ms);
  if (!status.error.empty()) json.SetString("error", status.error);
  if (!status.error_code.empty()) json.SetString("code", status.error_code);
  return json;
}

uint16_t PortMember(const JsonValue& object, std::string_view key,
                    uint16_t fallback) {
  const int64_t value = object.GetIntMember(key, fallback);
  return value > 0 && value <= 65535 ? static_cast<uint16_t>(value) : fallback;
}

struct RuntimeOptions {
  std::wstring pipe_name = pipe::kServicePipeName;
  bool console = false;
  // Accepts per-request tunnel overrides (a separate adapter, limited routes)
  // so the machinery can be exercised without taking over the machine's
  // traffic. Only honoured in console mode.
  bool test_mode = false;
  bool allow_any_client = false;
};

class ServiceRuntime {
 public:
  explicit ServiceRuntime(RuntimeOptions options) : options_(std::move(options)) {}

  bool Start(std::string& error) {
    const auto base = ExecutableDir();
    InitLog(base / "logs" / (options_.console ? "service-console.log"
                                              : "service.log"));
    LogInfo(std::string("ChrNet service ") + CHRNET_VERSION + " starting" +
            (options_.console ? " (console)" : ""));
    if (!IsProcessElevated()) {
      LogWarning("Not elevated: tunnel mode will be refused");
    }

    const auto runtime_dir = base / "runtime";
    RestrictToAdministrators(runtime_dir);

    ControllerPaths paths;
    paths.xray_exe = base / "xray.exe";
    paths.runtime_dir = runtime_dir;
    paths.log_dir = base / "logs";
    controller_ = std::make_unique<CoreController>(paths);
    controller_->CleanupLeftovers();

    PipeServer::Options server_options;
    server_options.pipe_name = options_.pipe_name;
    if (!options_.allow_any_client) {
      server_options.allowed_client_dir = base.wstring();
    }
    server_ = std::make_unique<PipeServer>(
        server_options, [this](const JsonValue& request, DWORD pid) {
          return HandleRequest(request, pid);
        });

    controller_->SetStatusListener([this](const CoreStatus& status) {
      JsonValue event = JsonValue::MakeObject();
      event.SetString("event", "status");
      event.Set("status", StatusToJson(status));
      if (server_) server_->Broadcast(event);
    });

    if (!server_->Start(error)) {
      LogError(error);
      return false;
    }
    LogInfo("Listening on " + WideToUtf8(options_.pipe_name));
    return true;
  }

  void Stop() {
    LogInfo("Service stopping");
    if (controller_) controller_->Stop();
    if (server_) server_->Stop();
    controller_.reset();
    server_.reset();
  }

  HANDLE shutdown_event() const { return shutdown_event_; }
  void set_shutdown_event(HANDLE event) { shutdown_event_ = event; }

 private:
  JsonValue HandleRequest(const JsonValue& request, DWORD pid) {
    const int64_t id = request.GetIntMember("id");
    const std::string method = request.GetStringMember("method");
    static const JsonValue kEmpty = JsonValue::MakeObject();
    const JsonValue* params = request.Find("params");
    if (params == nullptr || !params->is_object()) params = &kEmpty;

    JsonValue response = JsonValue::MakeObject();
    response.SetInt("id", id);
    const auto succeed = [&](JsonValue result) {
      response.SetBool("ok", true);
      response.Set("result", std::move(result));
      return response;
    };
    const auto fail = [&](const std::string& message, const std::string& code) {
      response.SetBool("ok", false);
      response.SetString("error", message);
      response.SetString("code", code);
      return response;
    };

    if (method == "hello") {
      JsonValue result = JsonValue::MakeObject();
      result.SetInt("protocol", pipe::kProtocolVersion);
      result.SetString("version", CHRNET_VERSION);
      result.SetBool("elevated", IsProcessElevated());
      result.SetBool("testMode", options_.test_mode);
      return succeed(std::move(result));
    }
    if (method == "status") {
      return succeed(StatusToJson(controller_->Status()));
    }
    if (method == "stats") {
      TrafficStats stats;
      JsonValue result = JsonValue::MakeObject();
      const bool available = controller_->QueryStats(stats);
      result.SetBool("available", available);
      result.SetInt("uplink", stats.uplink);
      result.SetInt("downlink", stats.downlink);
      return succeed(std::move(result));
    }
    if (method == "stop") {
      LogInfo("Stop requested by pid " + std::to_string(pid));
      controller_->Stop();
      return succeed(StatusToJson(controller_->Status()));
    }
    if (method == "start") {
      LogInfo("Start requested by pid " + std::to_string(pid));
      StartOptions start;
      start.config_json = params->GetStringMember("config");
      start.tunnel = params->GetStringMember("mode") == "tunnel";
      start.server_hosts = params->GetStringArrayMember("serverHosts");
      start.proxy_tags = params->GetStringArrayMember("proxyTags");
      start.socks_port = PortMember(*params, "socksPort", start.socks_port);
      start.http_port = PortMember(*params, "httpPort", start.http_port);
      start.metrics_port =
          PortMember(*params, "metricsPort", start.metrics_port);
      if (options_.test_mode) ApplyTestOverrides(*params, start);

      CoreError error;
      if (!controller_->Start(start, error)) {
        return fail(error.message, error.code);
      }
      return succeed(StatusToJson(controller_->Status()));
    }
    if (method == "shutdown" && options_.test_mode) {
      if (shutdown_event_ != nullptr) SetEvent(shutdown_event_);
      return succeed(JsonValue::MakeObject());
    }
    return fail("Unknown method: " + method, "UNKNOWN_METHOD");
  }

  static void ApplyTestOverrides(const JsonValue& params, StartOptions& start) {
    const auto* test = params.Find("test");
    if (test == nullptr || !test->is_object()) return;
    auto& tunnel = start.tunnel_options;
    if (const auto* name = test->Find("adapterName"); name && name->is_string()) {
      tunnel.adapter_name = Utf8ToWide(name->GetString());
    }
    tunnel.address = test->GetStringMember("address", tunnel.address);
    tunnel.prefix_length = static_cast<uint8_t>(std::clamp<int64_t>(
        test->GetIntMember("prefixLength", tunnel.prefix_length), 0, 32));
    tunnel.dns_server = test->GetStringMember("dnsServer", tunnel.dns_server);
    const auto routes = test->GetStringArrayMember("routes");
    if (!routes.empty()) tunnel.routes = routes;
    tunnel.leak_protection =
        test->GetBoolMember("leakProtection", tunnel.leak_protection);
    tunnel.guarded_dns_port =
        PortMember(*test, "guardedDnsPort", tunnel.guarded_dns_port);
    tunnel.block_ipv6 = test->GetBoolMember("blockIpv6", tunnel.block_ipv6);
    tunnel.follow_network_changes = test->GetBoolMember(
        "followNetworkChanges", tunnel.follow_network_changes);
  }

  RuntimeOptions options_;
  std::unique_ptr<CoreController> controller_;
  std::unique_ptr<PipeServer> server_;
  HANDLE shutdown_event_ = nullptr;
};

// ─── Service control manager ────────────────────────────────────────────────

SERVICE_STATUS_HANDLE g_status_handle = nullptr;
SERVICE_STATUS g_status = {};
HANDLE g_stop_event = nullptr;

void ReportStatus(DWORD state, DWORD exit_code, DWORD wait_hint) {
  static DWORD checkpoint = 1;
  g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  g_status.dwCurrentState = state;
  g_status.dwWin32ExitCode = exit_code;
  g_status.dwWaitHint = wait_hint;
  g_status.dwControlsAccepted =
      state == SERVICE_START_PENDING ? 0
                                     : SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
  g_status.dwCheckPoint =
      (state == SERVICE_RUNNING || state == SERVICE_STOPPED) ? 0 : checkpoint++;
  SetServiceStatus(g_status_handle, &g_status);
}

DWORD WINAPI ControlHandler(DWORD control, DWORD, LPVOID, LPVOID) {
  switch (control) {
    case SERVICE_CONTROL_STOP:
    case SERVICE_CONTROL_SHUTDOWN:
      ReportStatus(SERVICE_STOP_PENDING, NO_ERROR, 20000);
      SetEvent(g_stop_event);
      return NO_ERROR;
    case SERVICE_CONTROL_INTERROGATE:
      return NO_ERROR;
    default:
      return ERROR_CALL_NOT_IMPLEMENTED;
  }
}

void WINAPI ServiceMain(DWORD, LPWSTR*) {
  g_status_handle =
      RegisterServiceCtrlHandlerExW(pipe::kServiceName, ControlHandler, nullptr);
  if (g_status_handle == nullptr) return;
  ReportStatus(SERVICE_START_PENDING, NO_ERROR, 10000);
  g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);

  RuntimeOptions options;
  ServiceRuntime runtime(options);
  std::string error;
  if (!runtime.Start(error)) {
    ReportStatus(SERVICE_STOPPED, ERROR_SERVICE_SPECIFIC_ERROR, 0);
    return;
  }
  ReportStatus(SERVICE_RUNNING, NO_ERROR, 0);
  WaitForSingleObject(g_stop_event, INFINITE);
  runtime.Stop();
  ReportStatus(SERVICE_STOPPED, NO_ERROR, 0);
}

// ─── Install / uninstall ────────────────────────────────────────────────────

bool WaitForServiceState(SC_HANDLE service, DWORD wanted, DWORD timeout_ms) {
  const ULONGLONG deadline = GetTickCount64() + timeout_ms;
  SERVICE_STATUS_PROCESS status = {};
  DWORD needed = 0;
  while (QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
                              reinterpret_cast<LPBYTE>(&status), sizeof(status),
                              &needed)) {
    if (status.dwCurrentState == wanted) return true;
    if (GetTickCount64() >= deadline) return false;
    Sleep(200);
  }
  return false;
}

int Install() {
  SC_HANDLE manager =
      OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE);
  if (manager == nullptr) {
    fprintf(stderr, "OpenSCManager failed: %lu (run as administrator)\n",
            GetLastError());
    return 1;
  }
  wchar_t path[MAX_PATH * 2] = {};
  const DWORD length =
      GetModuleFileNameW(nullptr, path, static_cast<DWORD>(std::size(path)));
  const std::wstring binary = L"\"" + std::wstring(path, length) + L"\"";

  SC_HANDLE service = OpenServiceW(manager, pipe::kServiceName, SERVICE_ALL_ACCESS);
  if (service != nullptr) {
    if (!ChangeServiceConfigW(service, SERVICE_WIN32_OWN_PROCESS,
                              SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
                              binary.c_str(), nullptr, nullptr, nullptr, nullptr,
                              nullptr, kDisplayName)) {
      fprintf(stderr, "ChangeServiceConfig failed: %lu\n", GetLastError());
    }
  } else {
    service = CreateServiceW(manager, pipe::kServiceName, kDisplayName,
                             SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS,
                             SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
                             binary.c_str(), nullptr, nullptr, nullptr, nullptr,
                             nullptr);
    if (service == nullptr) {
      fprintf(stderr, "CreateService failed: %lu\n", GetLastError());
      CloseServiceHandle(manager);
      return 1;
    }
  }

  std::wstring description = kDescription;
  SERVICE_DESCRIPTIONW description_info = {description.data()};
  ChangeServiceConfig2W(service, SERVICE_CONFIG_DESCRIPTION, &description_info);

  // Come back on its own after a crash, so the app never loses the tunnel for
  // longer than a few seconds.
  SC_ACTION actions[3] = {{SC_ACTION_RESTART, 2000},
                          {SC_ACTION_RESTART, 5000},
                          {SC_ACTION_RESTART, 10000}};
  SERVICE_FAILURE_ACTIONSW failure = {};
  failure.dwResetPeriod = 24 * 60 * 60;
  failure.cActions = static_cast<DWORD>(std::size(actions));
  failure.lpsaActions = actions;
  ChangeServiceConfig2W(service, SERVICE_CONFIG_FAILURE_ACTIONS, &failure);

  // Interactive users may start and query the service (the app starts it when
  // it finds it stopped) but not stop or reconfigure it.
  PSECURITY_DESCRIPTOR service_security = nullptr;
  if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)"
          L"(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)"
          L"(A;;CCLCSWRPLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)",
          SDDL_REVISION_1, &service_security, nullptr)) {
    SetServiceObjectSecurity(service, DACL_SECURITY_INFORMATION,
                             service_security);
    LocalFree(service_security);
  }

  int result = 0;
  if (!StartServiceW(service, 0, nullptr) &&
      GetLastError() != ERROR_SERVICE_ALREADY_RUNNING) {
    fprintf(stderr, "StartService failed: %lu\n", GetLastError());
    result = 1;
  } else if (!WaitForServiceState(service, SERVICE_RUNNING, 15000)) {
    fprintf(stderr, "Service did not reach the running state\n");
    result = 1;
  }
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  return result;
}

int Uninstall() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (manager == nullptr) {
    fprintf(stderr, "OpenSCManager failed: %lu\n", GetLastError());
    return 1;
  }
  SC_HANDLE service = OpenServiceW(manager, pipe::kServiceName,
                                   SERVICE_STOP | SERVICE_QUERY_STATUS | DELETE);
  if (service == nullptr) {
    CloseServiceHandle(manager);
    return GetLastError() == ERROR_SERVICE_DOES_NOT_EXIST ? 0 : 1;
  }
  SERVICE_STATUS status = {};
  if (ControlService(service, SERVICE_CONTROL_STOP, &status)) {
    WaitForServiceState(service, SERVICE_STOPPED, 20000);
  }
  const int result = DeleteService(service) ||
                             GetLastError() == ERROR_SERVICE_MARKED_FOR_DELETE
                         ? 0
                         : 1;
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  return result;
}

// ─── Console mode ───────────────────────────────────────────────────────────

HANDLE g_console_stop = nullptr;

BOOL WINAPI ConsoleCtrlHandler(DWORD) {
  if (g_console_stop != nullptr) SetEvent(g_console_stop);
  return TRUE;
}

int RunConsole(const RuntimeOptions& options) {
  g_console_stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  SetConsoleCtrlHandler(ConsoleCtrlHandler, TRUE);
  ServiceRuntime runtime(options);
  runtime.set_shutdown_event(g_console_stop);
  std::string error;
  if (!runtime.Start(error)) {
    fprintf(stderr, "Failed to start: %s\n", error.c_str());
    return 1;
  }
  printf("ChrNet service running in console mode on %ls%s\n",
         options.pipe_name.c_str(), options.test_mode ? " (test mode)" : "");
  fflush(stdout);
  WaitForSingleObject(g_console_stop, INFINITE);
  runtime.Stop();
  printf("Stopped\n");
  return 0;
}

}  // namespace
}  // namespace chrnet

int wmain(int argc, wchar_t** argv) {
  using namespace chrnet;
  RuntimeOptions options;
  for (int i = 1; i < argc; ++i) {
    const std::wstring arg = argv[i];
    if (arg == L"--install") return Install();
    if (arg == L"--uninstall") return Uninstall();
    if (arg == L"--console") {
      options.console = true;
    } else if (arg == L"--test") {
      options.test_mode = true;
    } else if (arg == L"--allow-any-client") {
      options.allow_any_client = true;
    } else if (arg == L"--pipe" && i + 1 < argc) {
      options.pipe_name = std::wstring(L"\\\\.\\pipe\\") + argv[++i];
    }
  }

  // Test overrides reroute the tunnel, so a registered service never takes them.
  options.test_mode = options.test_mode && options.console;
  if (options.console) return RunConsole(options);

  SERVICE_TABLE_ENTRYW table[] = {
      {const_cast<LPWSTR>(pipe::kServiceName), ServiceMain}, {nullptr, nullptr}};
  if (!StartServiceCtrlDispatcherW(table)) {
    if (GetLastError() == ERROR_FAILED_SERVICE_CONTROLLER_CONNECT) {
      fprintf(stderr,
              "chrnet_service.exe runs as a Windows service.\n"
              "  --install      register and start the service\n"
              "  --uninstall    stop and remove the service\n"
              "  --console      run in the foreground\n");
    }
    return 1;
  }
  return 0;
}
