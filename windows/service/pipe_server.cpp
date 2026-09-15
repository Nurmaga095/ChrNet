#include "pipe_server.h"

#include <sddl.h>

#include "log.h"
#include "pipe_protocol.h"
#include "string_util.h"

namespace chrnet {

namespace {

// SYSTEM and Administrators get full access. Interactive users get only what a
// client needs: read and write data, attributes, synchronize. FILE_GENERIC_WRITE
// would also carry FILE_CREATE_PIPE_INSTANCE, which lets any user open another
// server end under this name and intercept the app's requests.
constexpr wchar_t kPipeSecurity[] =
    L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x0012019B;;;IU)";

}  // namespace

class PipeServer::Client {
 public:
  Client(HANDLE pipe, DWORD pid) : pipe_(pipe), pid_(pid) {}

  ~Client() {
    if (thread.joinable()) thread.join();
    DisconnectNamedPipe(pipe_);
    CloseHandle(pipe_);
  }

  void Run(const RequestHandler& handler, HANDLE stop_event) {
    std::string message;
    while (true) {
      const auto result = pipe::ReadMessage(pipe_, stop_event, message);
      if (result != pipe::IoResult::kOk) break;

      JsonValue response;
      const auto request = JsonValue::Parse(message);
      if (!request || !request->is_object()) {
        response = JsonValue::MakeObject();
        response.SetInt("id", 0);
        response.SetBool("ok", false);
        response.SetString("error", "Malformed request");
        response.SetString("code", "BAD_REQUEST");
      } else {
        response = handler(*request, pid_);
      }
      if (!Send(response.Serialize())) break;
    }
    finished_ = true;
  }

  bool Send(const std::string& message) {
    std::lock_guard<std::mutex> lock(write_mutex_);
    return pipe::WriteMessage(pipe_, message, 5000) == pipe::IoResult::kOk;
  }

  HANDLE pipe() const { return pipe_; }
  bool finished() const { return finished_.load(); }

  std::thread thread;

 private:
  HANDLE pipe_;
  DWORD pid_;
  std::mutex write_mutex_;
  std::atomic<bool> finished_{false};
};

PipeServer::PipeServer(Options options, RequestHandler handler)
    : options_(std::move(options)), handler_(std::move(handler)) {
  stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
}

PipeServer::~PipeServer() {
  Stop();
  if (security_descriptor_ != nullptr) LocalFree(security_descriptor_);
  if (stop_event_ != nullptr) CloseHandle(stop_event_);
}

HANDLE PipeServer::CreateInstance(bool first) {
  SECURITY_ATTRIBUTES attributes = {sizeof(attributes), security_descriptor_,
                                    FALSE};
  DWORD open_mode = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED;
  // Refuses to start when some other process already owns the name.
  if (first) open_mode |= FILE_FLAG_FIRST_PIPE_INSTANCE;
  return CreateNamedPipeW(
      options_.pipe_name.c_str(), open_mode,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS,
      PIPE_UNLIMITED_INSTANCES, 64 * 1024, 64 * 1024, 0, &attributes);
}

bool PipeServer::Start(std::string& error) {
  if (running_) return true;
  if (security_descriptor_ == nullptr &&
      !ConvertStringSecurityDescriptorToSecurityDescriptorW(
          kPipeSecurity, SDDL_REVISION_1, &security_descriptor_, nullptr)) {
    error = "Failed to build the pipe security descriptor";
    return false;
  }
  first_instance_ = CreateInstance(true);
  if (first_instance_ == INVALID_HANDLE_VALUE) {
    error = "Failed to create pipe " + WideToUtf8(options_.pipe_name) +
            ", error " + std::to_string(GetLastError());
    return false;
  }
  ResetEvent(stop_event_);
  running_ = true;
  accept_thread_ = std::thread([this]() { AcceptLoop(); });
  return true;
}

void PipeServer::Stop() {
  if (!running_.exchange(false)) return;
  SetEvent(stop_event_);
  if (accept_thread_.joinable()) accept_thread_.join();

  std::vector<std::shared_ptr<Client>> clients;
  {
    std::lock_guard<std::mutex> lock(clients_mutex_);
    clients.swap(clients_);
  }
  for (auto& client : clients) {
    CancelIoEx(client->pipe(), nullptr);
    if (client->thread.joinable()) client->thread.join();
  }
}

void PipeServer::Broadcast(const JsonValue& event) {
  const std::string message = event.Serialize();
  std::vector<std::shared_ptr<Client>> targets;
  {
    std::lock_guard<std::mutex> lock(clients_mutex_);
    targets = clients_;
  }
  for (auto& client : targets) {
    if (!client->finished()) client->Send(message);
  }
}

void PipeServer::PruneFinishedClients() {
  std::vector<std::shared_ptr<Client>> finished;
  {
    std::lock_guard<std::mutex> lock(clients_mutex_);
    for (auto it = clients_.begin(); it != clients_.end();) {
      if ((*it)->finished()) {
        finished.push_back(*it);
        it = clients_.erase(it);
      } else {
        ++it;
      }
    }
  }
  // Destroying a finished client joins its thread outside the lock.
  finished.clear();
}

bool PipeServer::IsClientAllowed(HANDLE pipe, DWORD& pid) {
  if (!GetNamedPipeClientProcessId(pipe, &pid)) return false;
  if (options_.allowed_client_dir.empty()) return true;

  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return false;
  wchar_t image[MAX_PATH * 2] = {};
  DWORD size = static_cast<DWORD>(std::size(image));
  const BOOL ok = QueryFullProcessImageNameW(process, 0, image, &size);
  CloseHandle(process);
  if (!ok) return false;

  const std::wstring expected =
      ToLowerAscii(options_.allowed_client_dir + L"\\chrnet.exe");
  const bool allowed = ToLowerAscii(std::wstring(image, size)) == expected;
  if (!allowed) {
    LogWarning("Rejected pipe client " + WideToUtf8(std::wstring(image, size)));
  }
  return allowed;
}

void PipeServer::AcceptLoop() {
  HANDLE connect_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE pipe = first_instance_;
  first_instance_ = INVALID_HANDLE_VALUE;

  while (running_) {
    if (pipe == INVALID_HANDLE_VALUE) {
      pipe = CreateInstance(false);
      if (pipe == INVALID_HANDLE_VALUE) {
        if (WaitForSingleObject(stop_event_, 1000) == WAIT_OBJECT_0) break;
        continue;
      }
    }

    OVERLAPPED overlapped = {};
    overlapped.hEvent = connect_event;
    ResetEvent(connect_event);
    DWORD status = ConnectNamedPipe(pipe, &overlapped) ? ERROR_PIPE_CONNECTED
                                                       : GetLastError();
    if (status == ERROR_IO_PENDING) {
      HANDLE handles[2] = {connect_event, stop_event_};
      const DWORD wait = WaitForMultipleObjects(2, handles, FALSE, INFINITE);
      DWORD ignored = 0;
      if (wait != WAIT_OBJECT_0) {
        CancelIoEx(pipe, &overlapped);
        GetOverlappedResult(pipe, &overlapped, &ignored, TRUE);
        CloseHandle(pipe);
        pipe = INVALID_HANDLE_VALUE;
        break;
      }
      status = GetOverlappedResult(pipe, &overlapped, &ignored, FALSE)
                   ? ERROR_PIPE_CONNECTED
                   : GetLastError();
    }
    if (status != ERROR_PIPE_CONNECTED) {
      CloseHandle(pipe);
      pipe = INVALID_HANDLE_VALUE;
      continue;
    }

    DWORD pid = 0;
    if (!IsClientAllowed(pipe, pid)) {
      DisconnectNamedPipe(pipe);
      CloseHandle(pipe);
      pipe = INVALID_HANDLE_VALUE;
      continue;
    }

    PruneFinishedClients();
    auto client = std::make_shared<Client>(pipe, pid);
    pipe = INVALID_HANDLE_VALUE;
    {
      std::lock_guard<std::mutex> lock(clients_mutex_);
      clients_.push_back(client);
    }
    // The thread gets a raw pointer: the list keeps the client alive until the
    // thread has been joined, and a thread must never own its own Client.
    Client* raw = client.get();
    raw->thread = std::thread(
        [this, raw]() { raw->Run(handler_, stop_event_); });
  }

  if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe);
  CloseHandle(connect_event);
}

}  // namespace chrnet
