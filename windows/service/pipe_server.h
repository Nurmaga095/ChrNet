#ifndef CHRNET_SERVICE_PIPE_SERVER_H_
#define CHRNET_SERVICE_PIPE_SERVER_H_

#include <windows.h>

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "json.h"

namespace chrnet {

// Accepts app connections on the service pipe. Every client is served by its
// own thread; |handler| answers requests and Broadcast pushes events to all
// connected clients.
class PipeServer {
 public:
  using RequestHandler =
      std::function<JsonValue(const JsonValue& request, DWORD client_pid)>;

  struct Options {
    std::wstring pipe_name;
    // Directory the connecting chrnet.exe must live in. Empty accepts any
    // client the pipe's ACL lets through.
    std::wstring allowed_client_dir;
  };

  PipeServer(Options options, RequestHandler handler);
  ~PipeServer();
  PipeServer(const PipeServer&) = delete;
  PipeServer& operator=(const PipeServer&) = delete;

  bool Start(std::string& error);
  void Stop();
  void Broadcast(const JsonValue& event);

 private:
  class Client;

  HANDLE CreateInstance(bool first);
  void AcceptLoop();
  bool IsClientAllowed(HANDLE pipe, DWORD& pid);
  void PruneFinishedClients();

  Options options_;
  RequestHandler handler_;
  PSECURITY_DESCRIPTOR security_descriptor_ = nullptr;
  HANDLE stop_event_ = nullptr;
  HANDLE first_instance_ = INVALID_HANDLE_VALUE;
  std::thread accept_thread_;
  std::atomic<bool> running_{false};

  std::mutex clients_mutex_;
  std::vector<std::shared_ptr<Client>> clients_;
};

}  // namespace chrnet

#endif  // CHRNET_SERVICE_PIPE_SERVER_H_
