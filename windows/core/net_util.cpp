#include "net_util.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <thread>

#include "string_util.h"

namespace chrnet::net {

namespace {

// DNS_INTERFACE_SETTINGS / SetInterfaceDnsSettings exist from Windows 10 2004.
// They are looked up at run time so the binaries still load on older builds,
// which fall back to the registry value the same API writes.
struct DnsInterfaceSettingsV1 {
  ULONG Version;
  ULONG64 Flags;
  PWSTR Domain;
  PWSTR NameServer;
  PWSTR SearchList;
  ULONG RegistrationEnabled;
  ULONG RegisterAdapterName;
  ULONG EnableLLMNR;
  ULONG QueryAdapterName;
  PWSTR ProfileNameServer;
};
constexpr ULONG kDnsInterfaceSettingsVersion1 = 1;
constexpr ULONG64 kDnsSettingNameServer = 0x0002;

class WinsockScope {
 public:
  WinsockScope() {
    WSADATA data = {};
    ready_ = WSAStartup(MAKEWORD(2, 2), &data) == 0;
  }
  ~WinsockScope() {
    if (ready_) WSACleanup();
  }
  bool ready() const { return ready_; }

 private:
  bool ready_ = false;
};

std::string GuidToString(const GUID& guid) {
  char buffer[64];
  snprintf(buffer, sizeof(buffer),
           "{%08lX-%04hX-%04hX-%02hhX%02hhX-%02hhX%02hhX%02hhX%02hhX%02hhX%02hhX}",
           guid.Data1, guid.Data2, guid.Data3, guid.Data4[0], guid.Data4[1],
           guid.Data4[2], guid.Data4[3], guid.Data4[4], guid.Data4[5],
           guid.Data4[6], guid.Data4[7]);
  return buffer;
}

MIB_IPFORWARD_ROW2 RouteRow(const RouteEntry& route) {
  MIB_IPFORWARD_ROW2 row;
  InitializeIpForwardEntry(&row);
  row.InterfaceIndex = route.if_index;
  row.DestinationPrefix.Prefix.si_family = AF_INET;
  row.DestinationPrefix.Prefix.Ipv4.sin_family = AF_INET;
  row.DestinationPrefix.Prefix.Ipv4.sin_addr = route.destination.address;
  row.DestinationPrefix.PrefixLength = route.destination.length;
  row.NextHop.si_family = AF_INET;
  row.NextHop.Ipv4.sin_family = AF_INET;
  row.NextHop.Ipv4.sin_addr = route.next_hop;
  // The interface metric decides between the TUN and the physical adapter;
  // the route metric itself stays at zero on both.
  row.Metric = 0;
  row.Protocol = MIB_IPPROTO_NETMGMT;
  return row;
}

}  // namespace

std::optional<IN_ADDR> ParseIpv4(const std::string& text) {
  IN_ADDR address{};
  const auto trimmed = TrimAscii(text);
  if (trimmed.empty()) return std::nullopt;
  if (InetPtonA(AF_INET, trimmed.c_str(), &address) != 1) return std::nullopt;
  return address;
}

std::optional<Ipv4Prefix> ParseIpv4Prefix(const std::string& text) {
  const auto slash = text.find('/');
  const auto address = ParseIpv4(text.substr(0, slash));
  if (!address) return std::nullopt;
  Ipv4Prefix prefix;
  prefix.address = *address;
  if (slash == std::string::npos) return prefix;
  const auto length_text = text.substr(slash + 1);
  if (length_text.empty() || length_text.size() > 2 ||
      !std::all_of(length_text.begin(), length_text.end(),
                   [](char ch) { return ch >= '0' && ch <= '9'; })) {
    return std::nullopt;
  }
  const int length = std::atoi(length_text.c_str());
  if (length < 0 || length > 32) return std::nullopt;
  prefix.length = static_cast<uint8_t>(length);
  return prefix;
}

std::string FormatIpv4(const IN_ADDR& address) {
  char buffer[INET_ADDRSTRLEN] = {};
  InetNtopA(AF_INET, &address, buffer, sizeof(buffer));
  return buffer;
}

bool IsIpv4Literal(const std::string& text) { return ParseIpv4(text).has_value(); }

bool SamePhysicalRoute(const PhysicalRoute& left, const PhysicalRoute& right) {
  return left.if_index == right.if_index &&
         left.gateway.S_un.S_addr == right.gateway.S_un.S_addr &&
         left.local_address.S_un.S_addr == right.local_address.S_un.S_addr;
}

std::optional<PhysicalRoute> FindPhysicalDefaultRoute(
    NET_IFINDEX excluded_if_index) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  if (GetIpForwardTable2(AF_INET, &table) != NO_ERROR || table == nullptr) {
    return std::nullopt;
  }

  std::optional<PhysicalRoute> best;
  ULONG best_metric = 0;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const auto& row = table->Table[i];
    if (row.DestinationPrefix.PrefixLength != 0) continue;
    if (row.InterfaceIndex == excluded_if_index) continue;
    if (row.NextHop.Ipv4.sin_addr.S_un.S_addr == 0) continue;
    if (row.Loopback) continue;

    MIB_IPINTERFACE_ROW interface_row;
    InitializeIpInterfaceEntry(&interface_row);
    interface_row.Family = AF_INET;
    interface_row.InterfaceLuid = row.InterfaceLuid;
    if (GetIpInterfaceEntry(&interface_row) != NO_ERROR) continue;
    if (!interface_row.Connected) continue;

    const ULONG metric = row.Metric + interface_row.Metric;
    if (best.has_value() && metric >= best_metric) continue;

    PhysicalRoute candidate;
    candidate.if_index = row.InterfaceIndex;
    candidate.luid = row.InterfaceLuid;
    candidate.gateway = row.NextHop.Ipv4.sin_addr;
    best = candidate;
    best_metric = metric;
  }
  FreeMibTable(table);
  if (!best) return std::nullopt;

  // Ask the stack which source address it would use on that interface, so a
  // secondary or APIPA address never ends up as the bind address.
  SOCKADDR_INET destination{};
  destination.si_family = AF_INET;
  destination.Ipv4.sin_family = AF_INET;
  InetPtonA(AF_INET, "1.1.1.1", &destination.Ipv4.sin_addr);
  MIB_IPFORWARD_ROW2 best_row;
  SOCKADDR_INET source{};
  if (GetBestRoute2(&best->luid, 0, nullptr, &destination, 0, &best_row,
                    &source) != NO_ERROR ||
      source.si_family != AF_INET) {
    return std::nullopt;
  }
  best->local_address = source.Ipv4.sin_addr;
  return best;
}

std::optional<AdapterInfo> FindAdapterByName(const std::wstring& friendly_name) {
  ULONG size = 16 * 1024;
  std::vector<BYTE> buffer;
  ULONG status = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 4 && status == ERROR_BUFFER_OVERFLOW;
       ++attempt) {
    buffer.resize(size);
    status = GetAdaptersAddresses(
        AF_UNSPEC,
        GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
            GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_SKIP_UNICAST,
        nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()), &size);
  }
  if (status != NO_ERROR) return std::nullopt;

  for (auto* adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
       adapter != nullptr; adapter = adapter->Next) {
    if (adapter->FriendlyName == nullptr ||
        friendly_name != adapter->FriendlyName) {
      continue;
    }
    AdapterInfo info;
    info.if_index = adapter->IfIndex != 0 ? adapter->IfIndex : adapter->Ipv6IfIndex;
    info.luid = adapter->Luid;
    if (ConvertInterfaceLuidToGuid(&adapter->Luid, &info.guid) != NO_ERROR) {
      return std::nullopt;
    }
    return info;
  }
  return std::nullopt;
}

bool AssignIpv4Address(NET_IFINDEX if_index, const IN_ADDR& address,
                       uint8_t prefix_length, std::string& error) {
  MIB_UNICASTIPADDRESS_ROW row;
  InitializeUnicastIpAddressEntry(&row);
  row.InterfaceIndex = if_index;
  row.Address.si_family = AF_INET;
  row.Address.Ipv4.sin_family = AF_INET;
  row.Address.Ipv4.sin_addr = address;
  row.OnLinkPrefixLength = prefix_length;
  // A point-to-point TUN cannot fail duplicate address detection, so the
  // address is marked usable immediately instead of waiting for DAD.
  row.DadState = IpDadStatePreferred;
  const auto status = CreateUnicastIpAddressEntry(&row);
  if (status == NO_ERROR || status == ERROR_OBJECT_ALREADY_EXISTS) return true;
  error = "CreateUnicastIpAddressEntry: " + Win32ErrorMessage(status);
  return false;
}

bool IsIpv4AddressReady(NET_IFINDEX if_index, const IN_ADDR& address) {
  MIB_UNICASTIPADDRESS_ROW row;
  InitializeUnicastIpAddressEntry(&row);
  row.InterfaceIndex = if_index;
  row.Address.si_family = AF_INET;
  row.Address.Ipv4.sin_family = AF_INET;
  row.Address.Ipv4.sin_addr = address;
  return GetUnicastIpAddressEntry(&row) == NO_ERROR &&
         row.DadState == IpDadStatePreferred;
}

bool SetInterfaceMetric(NET_IFINDEX if_index, ULONG metric,
                        std::string& error) {
  MIB_IPINTERFACE_ROW row;
  InitializeIpInterfaceEntry(&row);
  row.Family = AF_INET;
  row.InterfaceIndex = if_index;
  auto status = GetIpInterfaceEntry(&row);
  if (status != NO_ERROR) {
    error = "GetIpInterfaceEntry: " + Win32ErrorMessage(status);
    return false;
  }
  row.UseAutomaticMetric = FALSE;
  row.Metric = metric;
  // SetIpInterfaceEntry rejects IPv4 rows unless this is zero.
  row.SitePrefixLength = 0;
  status = SetIpInterfaceEntry(&row);
  if (status != NO_ERROR) {
    error = "SetIpInterfaceEntry: " + Win32ErrorMessage(status);
    return false;
  }
  return true;
}

bool SetInterfaceDnsServers(const GUID& adapter_guid,
                            const std::wstring& servers, std::string& error) {
  using SetDnsFn = DWORD(WINAPI*)(GUID, DnsInterfaceSettingsV1*);
  HMODULE iphlpapi = GetModuleHandleW(L"iphlpapi.dll");
  const auto set_dns = iphlpapi == nullptr
                           ? nullptr
                           : reinterpret_cast<SetDnsFn>(GetProcAddress(
                                 iphlpapi, "SetInterfaceDnsSettings"));
  if (set_dns != nullptr) {
    std::wstring buffer = servers;
    DnsInterfaceSettingsV1 settings = {};
    settings.Version = kDnsInterfaceSettingsVersion1;
    settings.Flags = kDnsSettingNameServer;
    settings.NameServer = buffer.data();
    const DWORD status = set_dns(adapter_guid, &settings);
    if (status == NO_ERROR) return true;
    error = "SetInterfaceDnsSettings: " + Win32ErrorMessage(status);
  }

  const std::wstring key =
      L"SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters\\Interfaces\\" +
      Utf8ToWide(GuidToString(adapter_guid));
  const LSTATUS status = RegSetKeyValueW(
      HKEY_LOCAL_MACHINE, key.c_str(), L"NameServer", REG_SZ, servers.c_str(),
      static_cast<DWORD>((servers.size() + 1) * sizeof(wchar_t)));
  if (status != ERROR_SUCCESS) {
    error += (error.empty() ? "" : "; ") + std::string("registry NameServer: ") +
             Win32ErrorMessage(static_cast<DWORD>(status));
    return false;
  }
  FlushDnsCache();
  return true;
}

void FlushDnsCache() {
  // Undocumented but stable export of dnsapi.dll, the same call behind
  // "ipconfig /flushdns".
  HMODULE dnsapi = LoadLibraryW(L"dnsapi.dll");
  if (dnsapi == nullptr) return;
  using FlushFn = BOOL(WINAPI*)();
  const auto flush =
      reinterpret_cast<FlushFn>(GetProcAddress(dnsapi, "DnsFlushResolverCache"));
  if (flush != nullptr) flush();
  FreeLibrary(dnsapi);
}

AddRouteResult AddRoute(const RouteEntry& route, std::string& error) {
  auto row = RouteRow(route);
  const auto status = CreateIpForwardEntry2(&row);
  if (status == NO_ERROR) return AddRouteResult::kAdded;
  if (status == ERROR_OBJECT_ALREADY_EXISTS) return AddRouteResult::kAlreadyExists;
  error = "CreateIpForwardEntry2(" + DescribeRoute(route) +
          "): " + Win32ErrorMessage(status);
  return AddRouteResult::kFailed;
}

bool DeleteRoute(const RouteEntry& route) {
  auto row = RouteRow(route);
  const auto status = DeleteIpForwardEntry2(&row);
  return status == NO_ERROR || status == ERROR_NOT_FOUND ||
         status == ERROR_FILE_NOT_FOUND;
}

std::string DescribeRoute(const RouteEntry& route) {
  std::ostringstream out;
  out << FormatIpv4(route.destination.address) << '/'
      << static_cast<int>(route.destination.length) << " via "
      << (route.next_hop.S_un.S_addr == 0 ? std::string("on-link")
                                          : FormatIpv4(route.next_hop))
      << " if " << route.if_index;
  return out.str();
}

std::vector<std::string> ResolveHostIpv4(const std::string& host) {
  std::vector<std::string> result;
  const auto trimmed = TrimAscii(host);
  if (trimmed.empty()) return result;
  if (IsIpv4Literal(trimmed)) {
    result.push_back(trimmed);
    return result;
  }
  // An IPv6 literal has nothing to route in an IPv4 tunnel.
  if (trimmed.find(':') != std::string::npos) return result;

  WinsockScope winsock;
  if (!winsock.ready()) return result;

  ADDRINFOW hints = {};
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  ADDRINFOW* addresses = nullptr;
  if (GetAddrInfoW(Utf8ToWide(trimmed).c_str(), nullptr, &hints, &addresses) !=
      0) {
    return result;
  }
  for (auto* entry = addresses; entry != nullptr; entry = entry->ai_next) {
    if (entry->ai_family != AF_INET || entry->ai_addr == nullptr) continue;
    const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(entry->ai_addr);
    const auto text = FormatIpv4(ipv4->sin_addr);
    if (std::find(result.begin(), result.end(), text) == result.end()) {
      result.push_back(text);
    }
  }
  FreeAddrInfoW(addresses);
  return result;
}

std::vector<DWORD> FindTcpListeners(uint16_t port) {
  std::vector<DWORD> owners;
  std::vector<BYTE> buffer;
  ULONG size = 0;
  DWORD status = ERROR_INSUFFICIENT_BUFFER;
  // The table can grow between the size query and the read, so retry.
  for (int attempt = 0; attempt < 4 && status == ERROR_INSUFFICIENT_BUFFER;
       ++attempt) {
    buffer.resize(size);
    status = GetExtendedTcpTable(buffer.empty() ? nullptr : buffer.data(),
                                 &size, FALSE, AF_INET,
                                 TCP_TABLE_OWNER_PID_LISTENER, 0);
  }
  if (status != NO_ERROR || buffer.empty()) return owners;

  const auto* table = reinterpret_cast<MIB_TCPTABLE_OWNER_PID*>(buffer.data());
  for (DWORD i = 0; i < table->dwNumEntries; ++i) {
    const auto& row = table->table[i];
    if (ntohs(static_cast<u_short>(row.dwLocalPort)) == port) {
      owners.push_back(row.dwOwningPid);
    }
  }
  return owners;
}

bool WaitForProcessListener(uint16_t port, HANDLE process, DWORD pid,
                            std::chrono::milliseconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (true) {
    const auto owners = FindTcpListeners(port);
    if (std::find(owners.begin(), owners.end(), pid) != owners.end()) {
      return true;
    }
    if (WaitForSingleObject(process, 0) != WAIT_TIMEOUT) return false;
    if (std::chrono::steady_clock::now() >= deadline) return false;
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
}

std::optional<std::string> HttpGetLocal(uint16_t port, const std::string& path,
                                        std::chrono::milliseconds timeout) {
  WinsockScope winsock;
  if (!winsock.ready()) return std::nullopt;

  SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (sock == INVALID_SOCKET) return std::nullopt;

  u_long non_blocking = 1;
  ioctlsocket(sock, FIONBIO, &non_blocking);
  sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_port = htons(port);
  address.sin_addr.S_un.S_addr = htonl(INADDR_LOOPBACK);
  connect(sock, reinterpret_cast<sockaddr*>(&address), sizeof(address));

  fd_set write_set;
  FD_ZERO(&write_set);
  FD_SET(sock, &write_set);
  fd_set error_set = write_set;
  timeval wait = {};
  wait.tv_sec = static_cast<long>(timeout.count() / 1000);
  wait.tv_usec = static_cast<long>((timeout.count() % 1000) * 1000);
  if (select(0, nullptr, &write_set, &error_set, &wait) <= 0 ||
      FD_ISSET(sock, &error_set)) {
    closesocket(sock);
    return std::nullopt;
  }

  non_blocking = 0;
  ioctlsocket(sock, FIONBIO, &non_blocking);
  const DWORD io_timeout = static_cast<DWORD>(timeout.count());
  setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
             reinterpret_cast<const char*>(&io_timeout), sizeof(io_timeout));
  setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO,
             reinterpret_cast<const char*>(&io_timeout), sizeof(io_timeout));

  const std::string request = "GET " + path +
                              " HTTP/1.0\r\nHost: 127.0.0.1\r\n"
                              "Connection: close\r\n\r\n";
  if (send(sock, request.data(), static_cast<int>(request.size()), 0) !=
      static_cast<int>(request.size())) {
    closesocket(sock);
    return std::nullopt;
  }

  std::string response;
  char chunk[4096];
  while (response.size() < (4u << 20)) {
    const int received = recv(sock, chunk, sizeof(chunk), 0);
    if (received <= 0) break;
    response.append(chunk, static_cast<size_t>(received));
  }
  closesocket(sock);

  if (response.compare(0, 9, "HTTP/1.0 ") != 0 &&
      response.compare(0, 9, "HTTP/1.1 ") != 0) {
    return std::nullopt;
  }
  if (response.compare(9, 3, "200") != 0) return std::nullopt;
  const auto body = response.find("\r\n\r\n");
  if (body == std::string::npos) return std::nullopt;
  return response.substr(body + 4);
}

std::string Win32ErrorMessage(DWORD code) {
  wchar_t* buffer = nullptr;
  const DWORD length = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, code, MAKELANGID(LANG_ENGLISH, SUBLANG_ENGLISH_US),
      reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
  std::string message = "error " + std::to_string(code);
  if (length > 0 && buffer != nullptr) {
    message += " (" + TrimAscii(WideToUtf8(std::wstring(buffer, length))) + ")";
  }
  if (buffer != nullptr) LocalFree(buffer);
  return message;
}

}  // namespace chrnet::net
