#ifndef RUNNER_SERVICE_CLIENT_H_
#define RUNNER_SERVICE_CLIENT_H_

#include <windows.h>

#include <condition_variable>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "core_backend.h"
#include "json.h"

// Talks to the ChrNet service over its named pipe. Requests are answered in
// order of arrival; status events pushed by the service are delivered to the
// listener from the reader thread.
class ServiceClient : public CoreBackend {
 public:
  ServiceClient();
  ~ServiceClient() override;
  ServiceClient(const ServiceClient&) = delete;
  ServiceClient& operator=(const ServiceClient&) = delete;

  // Connects if not connected yet. False when no service answers the pipe.
  bool EnsureConnected();
  // Asks the service control manager to start an installed but stopped
  // service and waits for its pipe. The installer grants interactive users
  // the right to do this.
  bool StartInstalledService();

  bool Start(const chrnet::StartOptions& options,
             chrnet::CoreError& error) override;
  void Stop() override;
  bool Status(chrnet::CoreStatus& status) override;
  bool Stats(chrnet::TrafficStats& stats) override;
  void SetStatusListener(StatusListener listener) override;
  const char* name() const override { return "service"; }

 private:
  struct Pending {
    bool done = false;
    std::optional<chrnet::JsonValue> response;
  };

  // Returns the response object, which may itself report a failure. Nothing
  // when the service could not be reached or did not answer in time.
  std::optional<chrnet::JsonValue> Call(const std::string& method,
                                        chrnet::JsonValue params,
                                        DWORD timeout_ms,
                                        chrnet::CoreError& error);
  void ReaderLoop();
  void CloseConnection();
  void Notify(const chrnet::CoreStatus& status);

  std::wstring pipe_name_;
  bool verify_session_ = true;

  std::mutex connection_mutex_;
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  HANDLE cancel_event_ = nullptr;
  std::thread reader_;
  bool closing_ = false;

  std::mutex pending_mutex_;
  std::condition_variable pending_cv_;
  std::map<int64_t, std::shared_ptr<Pending>> pending_;
  int64_t next_id_ = 1;
  bool connected_ = false;

  std::mutex listener_mutex_;
  StatusListener listener_;
};

chrnet::CoreStatus ParseCoreStatus(const chrnet::JsonValue& json);

#endif  // RUNNER_SERVICE_CLIENT_H_
