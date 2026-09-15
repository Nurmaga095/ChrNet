#include "service_check.h"

#include <windows.h>

#include <cstdio>
#include <string>

#include "core_controller.h"
#include "service_client.h"

namespace {

// Proxy-only, no server needed: enough to exercise start, stats and stop
// through the service without touching the machine's routing.
constexpr char kProbeConfig[] =
    R"({"log":{"loglevel":"warning"},)"
    R"("stats":{},"policy":{"system":{"statsOutboundDownlink":true,)"
    R"("statsOutboundUplink":true}},)"
    R"("metrics":{"tag":"metrics","listen":"127.0.0.1:38213"},)"
    R"("inbounds":[{"tag":"http-in","listen":"127.0.0.1","port":38281,)"
    R"("protocol":"http","settings":{}}],)"
    R"("outbounds":[{"tag":"proxy","protocol":"freedom"},)"
    R"({"tag":"block","protocol":"blackhole"}]})";

void PrintStatus(const char* label, const chrnet::CoreStatus& status) {
  printf("%s: state=%s tunnel=%d startedAt=%lld error=%s\n", label,
         chrnet::CoreStateName(status.state), status.tunnel ? 1 : 0,
         static_cast<long long>(status.started_at_ms), status.error.c_str());
}

}  // namespace

int RunServiceCheck(bool start_test) {
  ServiceClient client;
  bool connected = client.EnsureConnected();
  if (!connected) {
    printf("pipe: not reachable, asking the service manager to start it\n");
    connected = client.StartInstalledService() && client.EnsureConnected();
  }
  if (!connected) {
    printf("pipe: not reachable\n");
    return 2;
  }
  printf("pipe: connected\n");

  chrnet::CoreStatus status;
  if (!client.Status(status)) {
    printf("status: no answer\n");
    return 3;
  }
  PrintStatus("status", status);
  if (!start_test) return 0;

  chrnet::StartOptions options;
  options.config_json = kProbeConfig;
  options.tunnel = false;
  options.proxy_tags = {"proxy"};
  options.socks_port = 38280;
  options.http_port = 38281;
  options.metrics_port = 38213;
  chrnet::CoreError error;
  if (!client.Start(options, error)) {
    printf("start: failed [%s] %s\n", error.code.c_str(), error.message.c_str());
    return 4;
  }
  client.Status(status);
  PrintStatus("after start", status);

  Sleep(1500);
  chrnet::TrafficStats stats;
  const bool have_stats = client.Stats(stats);
  printf("stats: available=%d up=%lld down=%lld\n", have_stats ? 1 : 0,
         static_cast<long long>(stats.uplink),
         static_cast<long long>(stats.downlink));

  client.Stop();
  client.Status(status);
  PrintStatus("after stop", status);
  return status.state == chrnet::CoreState::kStopped ? 0 : 5;
}
