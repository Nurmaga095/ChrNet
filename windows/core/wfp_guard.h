#ifndef CHRNET_CORE_WFP_GUARD_H_
#define CHRNET_CORE_WFP_GUARD_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <string>

namespace chrnet {

// Keeps name resolution inside the tunnel while it is up, the way Happ's DNS
// protection does. Outbound DNS is blocked on every interface except the TUN,
// and global IPv6, which the IPv4-only tunnel cannot carry, is blocked outside
// the TUN so applications fall back to IPv4 instead of leaking around it. Xray
// itself and loopback stay exempt.
//
// The filters live in a dynamic WFP session: they vanish when Remove() closes
// it or when the process dies, so a crash can never leave the machine without
// DNS.
class LeakGuard {
 public:
  struct Options {
    uint64_t tun_luid = 0;
    std::filesystem::path xray_path;
    uint16_t dns_port = 53;
    bool block_ipv6 = true;
  };

  LeakGuard() = default;
  LeakGuard(const LeakGuard&) = delete;
  LeakGuard& operator=(const LeakGuard&) = delete;
  ~LeakGuard();

  bool Install(const Options& options, std::string& error);
  void Remove();
  bool installed() const { return engine_ != nullptr; }

 private:
  HANDLE engine_ = nullptr;
};

}  // namespace chrnet

#endif  // CHRNET_CORE_WFP_GUARD_H_
