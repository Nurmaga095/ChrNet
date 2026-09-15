#ifndef CHRNET_CORE_PROXY_SETTINGS_H_
#define CHRNET_CORE_PROXY_SETTINGS_H_

#include <windows.h>

#include <cstdint>
#include <string>

namespace chrnet::proxy {

// The current user's WinINet proxy configuration, the one browsers and most
// applications follow. It is per user, so only the app (never the service,
// which runs as SYSTEM) touches it.
struct Settings {
  DWORD flags = 0x00000001;  // PROXY_TYPE_DIRECT
  std::wstring server;
  std::wstring bypass;
  std::wstring autoconfig_url;
};

bool Read(Settings& out);
bool Apply(const Settings& settings);

// Whether |settings| send traffic through ChrNet's local HTTP inbound.
bool IsChrNetProxy(const Settings& settings, uint16_t http_port);

// Points the system proxy at 127.0.0.1:|http_port|. The user's own settings are
// saved under HKCU first, so they come back even when the app is killed before
// it disconnects.
bool EnableForChrNet(uint16_t http_port, std::string& error);

// Puts the saved settings back if the current ones are still ChrNet's, then
// forgets the backup. Settings the user changed in the meantime are left alone.
void RestoreAfterChrNet(uint16_t http_port);

// True while a backup is waiting to be restored.
bool HasPendingRestore();

}  // namespace chrnet::proxy

#endif  // CHRNET_CORE_PROXY_SETTINGS_H_
