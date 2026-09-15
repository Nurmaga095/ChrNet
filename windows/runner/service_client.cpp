#include "service_client.h"

#include <chrono>
#include <vector>

#include "log.h"
#include "pipe_protocol.h"
#include "string_util.h"

using chrnet::CoreError;
using chrnet::CoreState;
using chrnet::CoreStatus;
using chrnet::JsonValue;

CoreStatus ParseCoreStatus(const JsonValue& json) {
  CoreStatus status;
  const auto state = json.GetStringMember("state");
  if (state == "starting") {
    status.state = CoreState::kStarting;
  } else if (state == "running") {
    status.state = CoreState::kRunning;
  } else if (state == "stopping") {
    status.state = CoreState::kStopping;
  } else {
    status.state = CoreState::kStopped;
  }
  status.tunnel = json.GetBoolMember("tunnel");
  status.started_at_ms = json.GetIntMember("startedAt");
  status.error = json.GetStringMember("error");
  status.error_code = json.GetStringMember("code");
  return status;
}

ServiceClient::ServiceClient() : pipe_name_(chrnet::pipe::kServicePipeName) {
  // A development override for pointing the app at a service started with
  // --console; such a service runs in the user's session, not session 0.
  wchar_t override_name[256] = {};
  const DWORD length =
      GetEnvironmentVariableW(L"CHRNET_SERVICE_PIPE", override_name, 256);
  if (length > 0 && length < 256) {
    pipe_name_ = std::wstring(L"\\\\.\\pipe\\") + override_name;
    verify_session_ = false;
  }
  cancel_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
}

ServiceClient::~ServiceClient() {
  {
    std::lock_guard<std::mutex> lock(listener_mutex_);
    listener_ = nullptr;
  }
  std::lock_guard<std::mutex> lock(connection_mutex_);
  closing_ = true;
  CloseConnection();
  if (cancel_event_ != nullptr) CloseHandle(cancel_event_);
}

void ServiceClient::CloseConnection() {
  if (reader_.joinable()) {
    SetEvent(cancel_event_);
    if (pipe_ != INVALID_HANDLE_VALUE) CancelIoEx(pipe_, nullptr);
    reader_.join();
  }
  if (pipe_ != INVALID_HANDLE_VALUE) {
    CloseHandle(pipe_);
    pipe_ = INVALID_HANDLE_VALUE;
  }
  std::lock_guard<std::mutex> lock(pending_mutex_);
  connected_ = false;
}

bool ServiceClient::EnsureConnected() {
  std::lock_guard<std::mutex> lock(connection_mutex_);
  {
    std::lock_guard<std::mutex> pending_lock(pending_mutex_);
    if (connected_) return true;
  }
  CloseConnection();

  HANDLE pipe = INVALID_HANDLE_VALUE;
  for (int attempt = 0; attempt < 3; ++attempt) {
    // FILE_WRITE_DATA, not GENERIC_WRITE: the latter includes
    // FILE_CREATE_PIPE_INSTANCE, which the pipe's ACL deliberately withholds
    // from ordinary users, so asking for it fails for everyone but admins.
    pipe = CreateFileW(pipe_name_.c_str(), GENERIC_READ | FILE_WRITE_DATA, 0,
                       nullptr, OPEN_EXISTING,
                       FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT |
                           SECURITY_IDENTIFICATION,
                       nullptr);
    if (pipe != INVALID_HANDLE_VALUE) break;
    if (GetLastError() != ERROR_PIPE_BUSY) return false;
    if (!WaitNamedPipeW(pipe_name_.c_str(), 1000)) return false;
  }
  if (pipe == INVALID_HANDLE_VALUE) return false;

  if (verify_session_) {
    // Services run in session 0, where an ordinary user cannot start a
    // process. A server anywhere else is some program squatting on the name.
    ULONG session = static_cast<ULONG>(-1);
    if (!GetNamedPipeServerSessionId(pipe, &session) || session != 0) {
      chrnet::LogWarning("Ignoring a ChrNet pipe served outside session 0");
      CloseHandle(pipe);
      return false;
    }
  }

  pipe_ = pipe;
  ResetEvent(cancel_event_);
  {
    std::lock_guard<std::mutex> pending_lock(pending_mutex_);
    connected_ = true;
  }
  reader_ = std::thread([this]() { ReaderLoop(); });
  return true;
}

bool ServiceClient::StartInstalledService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (manager == nullptr) return false;
  SC_HANDLE service = OpenServiceW(manager, chrnet::pipe::kServiceName,
                                   SERVICE_START | SERVICE_QUERY_STATUS);
  if (service == nullptr) {
    CloseServiceHandle(manager);
    return false;
  }
  const bool started = StartServiceW(service, 0, nullptr) ||
                       GetLastError() == ERROR_SERVICE_ALREADY_RUNNING;
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  if (!started) return false;

  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
  while (std::chrono::steady_clock::now() < deadline) {
    if (WaitNamedPipeW(pipe_name_.c_str(), 250)) return true;
    Sleep(250);
  }
  return false;
}

void ServiceClient::ReaderLoop() {
  std::string message;
  bool cancelled = false;
  while (true) {
    const auto result =
        chrnet::pipe::ReadMessage(pipe_, cancel_event_, message);
    if (result == chrnet::pipe::IoResult::kCancelled) {
      cancelled = true;
      break;
    }
    if (result != chrnet::pipe::IoResult::kOk) break;

    auto json = JsonValue::Parse(message);
    if (!json || !json->is_object()) continue;
    if (json->Find("event") != nullptr) {
      const auto* status = json->Find("status");
      if (json->GetStringMember("event") == "status" && status != nullptr) {
        Notify(ParseCoreStatus(*status));
      }
      continue;
    }
    const int64_t id = json->GetIntMember("id", -1);
    std::lock_guard<std::mutex> lock(pending_mutex_);
    const auto it = pending_.find(id);
    if (it != pending_.end()) {
      it->second->response = std::move(*json);
      it->second->done = true;
      pending_cv_.notify_all();
    }
  }

  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    connected_ = false;
    for (auto& entry : pending_) entry.second->done = true;
    pending_cv_.notify_all();
  }
  if (!cancelled) {
    // The service went away; its core, which it keeps in a kill-on-close job,
    // went with it.
    chrnet::LogWarning("Lost the connection to the ChrNet service");
    CoreStatus status;
    status.state = CoreState::kStopped;
    status.error = "Служба ChrNet перезапустилась, соединение прервано.";
    status.error_code = "SERVICE_DISCONNECTED";
    Notify(status);
  }
}

void ServiceClient::Notify(const CoreStatus& status) {
  StatusListener listener;
  {
    std::lock_guard<std::mutex> lock(listener_mutex_);
    listener = listener_;
  }
  if (listener) listener(status);
}

std::optional<JsonValue> ServiceClient::Call(const std::string& method,
                                             JsonValue params,
                                             DWORD timeout_ms,
                                             CoreError& error) {
  if (!EnsureConnected()) {
    error.message = "Служба ChrNet не запущена.";
    error.code = "SERVICE_UNAVAILABLE";
    return std::nullopt;
  }

  auto pending = std::make_shared<Pending>();
  int64_t id = 0;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    id = next_id_++;
    pending_[id] = pending;
  }

  JsonValue request = JsonValue::MakeObject();
  request.SetInt("id", id);
  request.SetString("method", method);
  request.Set("params", std::move(params));
  bool written = false;
  {
    std::lock_guard<std::mutex> lock(connection_mutex_);
    written = pipe_ != INVALID_HANDLE_VALUE &&
              chrnet::pipe::WriteMessage(pipe_, request.Serialize(), 5000) ==
                  chrnet::pipe::IoResult::kOk;
  }

  std::unique_lock<std::mutex> lock(pending_mutex_);
  const bool completed =
      written && pending_cv_.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                                      [&]() { return pending->done; });
  pending_.erase(id);
  if (!completed || !pending->response) {
    error.message = !written || completed
                        ? "Связь со службой ChrNet прервалась."
                        : "Служба ChrNet не ответила вовремя.";
    error.code = !written || completed ? "SERVICE_DISCONNECTED" : "SERVICE_TIMEOUT";
    return std::nullopt;
  }
  return std::move(pending->response);
}

bool ServiceClient::Start(const chrnet::StartOptions& options,
                          CoreError& error) {
  JsonValue params = JsonValue::MakeObject();
  params.SetString("config", options.config_json);
  params.SetString("mode", options.tunnel ? "tunnel" : "proxy");
  params.Set("serverHosts", JsonValue::MakeStringArray(options.server_hosts));
  params.Set("proxyTags", JsonValue::MakeStringArray(options.proxy_tags));
  params.SetInt("socksPort", options.socks_port);
  params.SetInt("httpPort", options.http_port);
  params.SetInt("metricsPort", options.metrics_port);

  // Resolving servers, creating the adapter and waiting for the core can take
  // a while on a slow network.
  auto response = Call("start", std::move(params), 90000, error);
  if (!response) return false;
  if (!response->GetBoolMember("ok")) {
    error.message = response->GetStringMember(
        "error", "Служба ChrNet не смогла запустить подключение.");
    error.code = response->GetStringMember("code", "START_FAILED");
    return false;
  }
  return true;
}

void ServiceClient::Stop() {
  CoreError ignored;
  Call("stop", JsonValue::MakeObject(), 30000, ignored);
}

bool ServiceClient::Status(CoreStatus& status) {
  CoreError ignored;
  const auto response = Call("status", JsonValue::MakeObject(), 3000, ignored);
  if (!response || !response->GetBoolMember("ok")) return false;
  const auto* result = response->Find("result");
  if (result == nullptr) return false;
  status = ParseCoreStatus(*result);
  return true;
}

bool ServiceClient::Stats(chrnet::TrafficStats& stats) {
  CoreError ignored;
  const auto response = Call("stats", JsonValue::MakeObject(), 2000, ignored);
  if (!response || !response->GetBoolMember("ok")) return false;
  const auto* result = response->Find("result");
  if (result == nullptr || !result->GetBoolMember("available")) return false;
  stats.uplink = result->GetIntMember("uplink");
  stats.downlink = result->GetIntMember("downlink");
  return true;
}

void ServiceClient::SetStatusListener(StatusListener listener) {
  std::lock_guard<std::mutex> lock(listener_mutex_);
  listener_ = std::move(listener);
}
