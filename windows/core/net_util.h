#ifndef CHRNET_CORE_NET_UTIL_H_
#define CHRNET_CORE_NET_UTIL_H_

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>

#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace chrnet::net {

struct Ipv4Prefix {
  IN_ADDR address{};
  uint8_t length = 32;
};

std::optional<IN_ADDR> ParseIpv4(const std::string& text);
// Accepts "a.b.c.d/nn" or a bare address (a /32).
std::optional<Ipv4Prefix> ParseIpv4Prefix(const std::string& text);
std::string FormatIpv4(const IN_ADDR& address);
bool IsIpv4Literal(const std::string& text);

struct PhysicalRoute {
  NET_IFINDEX if_index = 0;
  NET_LUID luid{};
  IN_ADDR gateway{};
  IN_ADDR local_address{};
};
bool SamePhysicalRoute(const PhysicalRoute& left, const PhysicalRoute& right);

// The IPv4 default route traffic leaves through when the tunnel is not in the
// way: the lowest route + interface metric among default routes with a real
// gateway, skipping |excluded_if_index| (the TUN). The local address is the
// source Windows picks on that interface.
std::optional<PhysicalRoute> FindPhysicalDefaultRoute(
    NET_IFINDEX excluded_if_index = 0);

struct AdapterInfo {
  NET_IFINDEX if_index = 0;
  NET_LUID luid{};
  GUID guid{};
};
std::optional<AdapterInfo> FindAdapterByName(const std::wstring& friendly_name);

bool AssignIpv4Address(NET_IFINDEX if_index, const IN_ADDR& address,
                       uint8_t prefix_length, std::string& error);
bool IsIpv4AddressReady(NET_IFINDEX if_index, const IN_ADDR& address);
bool SetInterfaceMetric(NET_IFINDEX if_index, ULONG metric, std::string& error);
// |servers| is a comma-separated list; an empty string clears the setting.
bool SetInterfaceDnsServers(const GUID& adapter_guid,
                            const std::wstring& servers, std::string& error);
void FlushDnsCache();

// A route exactly as created, so the same row can be deleted later.
struct RouteEntry {
  NET_IFINDEX if_index = 0;
  Ipv4Prefix destination;
  IN_ADDR next_hop{};  // 0.0.0.0 means on-link.
};

enum class AddRouteResult { kAdded, kAlreadyExists, kFailed };
AddRouteResult AddRoute(const RouteEntry& route, std::string& error);
bool DeleteRoute(const RouteEntry& route);
std::string DescribeRoute(const RouteEntry& route);

// Resolves through the system resolver; IPv4 literals are returned as-is.
std::vector<std::string> ResolveHostIpv4(const std::string& host);

// PIDs of the processes listening on the IPv4 TCP port. Reads the TCP table
// instead of probing with connect(): a connect() to a closed loopback port
// takes about two seconds to fail on Windows because the SYN is retried.
std::vector<DWORD> FindTcpListeners(uint16_t port);
bool WaitForProcessListener(uint16_t port, HANDLE process, DWORD pid,
                            std::chrono::milliseconds timeout);

// A minimal HTTP/1.0 GET against 127.0.0.1 returning the response body.
std::optional<std::string> HttpGetLocal(uint16_t port, const std::string& path,
                                        std::chrono::milliseconds timeout);

std::string Win32ErrorMessage(DWORD code);

}  // namespace chrnet::net

#endif  // CHRNET_CORE_NET_UTIL_H_
