#include "core_backend.h"

#include <windows.h>

#include <filesystem>

namespace {

std::filesystem::path ResolveXrayPath() {
  wchar_t env_path[1024] = {};
  const DWORD env_length =
      GetEnvironmentVariableW(L"CHRNET_XRAY_PATH", env_path, 1024);
  std::error_code ec;
  if (env_length > 0 && env_length < 1024) {
    std::filesystem::path candidate(env_path);
    if (std::filesystem::exists(candidate, ec)) return candidate;
  }

  wchar_t exe_path[MAX_PATH * 2] = {};
  const DWORD length = GetModuleFileNameW(nullptr, exe_path, MAX_PATH * 2);
  const auto exe_dir =
      std::filesystem::path(std::wstring(exe_path, length)).parent_path();
  const auto beside_exe = exe_dir / "xray.exe";
  if (std::filesystem::exists(beside_exe, ec)) return beside_exe;
  const auto in_assets = exe_dir / "data" / "flutter_assets" / "assets" / "xray.exe";
  if (std::filesystem::exists(in_assets, ec)) return in_assets;
  return beside_exe;
}

std::filesystem::path ResolveRuntimeDir() {
  wchar_t local_app_data[MAX_PATH] = {};
  const DWORD length =
      GetEnvironmentVariableW(L"LOCALAPPDATA", local_app_data, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    return std::filesystem::path(local_app_data) / "ChrNet" / "xray";
  }
  std::error_code ec;
  return std::filesystem::temp_directory_path(ec) / "ChrNet" / "xray";
}

class InProcessBackend : public CoreBackend {
 public:
  InProcessBackend() {
    chrnet::ControllerPaths paths;
    paths.xray_exe = ResolveXrayPath();
    paths.runtime_dir = ResolveRuntimeDir();
    paths.log_dir = paths.runtime_dir;
    controller_ = std::make_unique<chrnet::CoreController>(paths);
    if (chrnet::IsProcessElevated()) controller_->CleanupLeftovers();
  }

  bool Start(const chrnet::StartOptions& options,
             chrnet::CoreError& error) override {
    return controller_->Start(options, error);
  }

  void Stop() override { controller_->Stop(); }

  bool Status(chrnet::CoreStatus& status) override {
    status = controller_->Status();
    return true;
  }

  bool Stats(chrnet::TrafficStats& stats) override {
    return controller_->QueryStats(stats);
  }

  void SetStatusListener(StatusListener listener) override {
    controller_->SetStatusListener(std::move(listener));
  }

  const char* name() const override { return "in-process"; }

 private:
  std::unique_ptr<chrnet::CoreController> controller_;
};

}  // namespace

std::unique_ptr<CoreBackend> CreateInProcessBackend() {
  return std::make_unique<InProcessBackend>();
}
