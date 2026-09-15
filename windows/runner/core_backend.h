#ifndef RUNNER_CORE_BACKEND_H_
#define RUNNER_CORE_BACKEND_H_

#include <functional>
#include <memory>
#include <string>

#include "core_controller.h"

// Where the VPN core runs. Normally that is the ChrNet service, which needs no
// administrator rights from the app. A development build or a copy without
// the service falls back to running the core inside the app, which works for
// system proxy mode and, when the app is elevated, for tunnel mode too.
class CoreBackend {
 public:
  using StatusListener = std::function<void(const chrnet::CoreStatus&)>;

  virtual ~CoreBackend() = default;

  virtual bool Start(const chrnet::StartOptions& options,
                     chrnet::CoreError& error) = 0;
  virtual void Stop() = 0;
  // False when the backend cannot be reached at all.
  virtual bool Status(chrnet::CoreStatus& status) = 0;
  virtual bool Stats(chrnet::TrafficStats& stats) = 0;
  // Called from a background thread.
  virtual void SetStatusListener(StatusListener listener) = 0;
  virtual const char* name() const = 0;
};

std::unique_ptr<CoreBackend> CreateInProcessBackend();

#endif  // RUNNER_CORE_BACKEND_H_
