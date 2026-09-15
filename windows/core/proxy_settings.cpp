#include "proxy_settings.h"

#include <wininet.h>

#include <vector>

#include "log.h"

namespace chrnet::proxy {

namespace {

constexpr wchar_t kBackupKey[] = L"Software\\ChrNet\\ProxyBackup";

// Local destinations never go through the proxy. Xray would route them direct
// anyway; skipping it saves a hop and keeps LAN tools that dislike proxies
// working.
constexpr wchar_t kChrNetBypass[] =
    L"localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;"
    L"172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;"
    L"172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>";

std::wstring TakeString(LPWSTR value) {
  std::wstring out = value != nullptr ? value : L"";
  if (value != nullptr) GlobalFree(value);
  return out;
}

bool QueryOptions(Settings& out, DWORD flags_option) {
  INTERNET_PER_CONN_OPTIONW options[4] = {};
  options[0].dwOption = flags_option;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;

  INTERNET_PER_CONN_OPTION_LISTW list = {};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 4;
  list.pOptions = options;
  DWORD size = sizeof(list);
  if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                            &list, &size)) {
    return false;
  }
  out.flags = options[0].Value.dwValue;
  out.server = TakeString(options[1].Value.pszValue);
  out.bypass = TakeString(options[2].Value.pszValue);
  out.autoconfig_url = TakeString(options[3].Value.pszValue);
  return true;
}

std::wstring ReadRegString(HKEY key, const wchar_t* name) {
  DWORD size = 0;
  if (RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, nullptr, nullptr,
                   &size) != ERROR_SUCCESS ||
      size == 0) {
    return L"";
  }
  std::vector<wchar_t> buffer(size / sizeof(wchar_t) + 1);
  if (RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, nullptr, buffer.data(),
                   &size) != ERROR_SUCCESS) {
    return L"";
  }
  return buffer.data();
}

void WriteRegString(HKEY key, const wchar_t* name, const std::wstring& value) {
  RegSetValueExW(key, name, 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(value.c_str()),
                 static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
}

bool SaveBackup(const Settings& settings) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kBackupKey, 0, nullptr, 0, KEY_WRITE,
                      nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const DWORD flags = settings.flags;
  RegSetValueExW(key, L"Flags", 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&flags), sizeof(flags));
  WriteRegString(key, L"Server", settings.server);
  WriteRegString(key, L"Bypass", settings.bypass);
  WriteRegString(key, L"AutoConfigUrl", settings.autoconfig_url);
  RegCloseKey(key);
  return true;
}

bool LoadBackup(Settings& out) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kBackupKey, 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return false;
  }
  DWORD flags = 0;
  DWORD size = sizeof(flags);
  const bool has_flags =
      RegGetValueW(key, nullptr, L"Flags", RRF_RT_REG_DWORD, nullptr, &flags,
                   &size) == ERROR_SUCCESS;
  if (has_flags) {
    out.flags = flags;
    out.server = ReadRegString(key, L"Server");
    out.bypass = ReadRegString(key, L"Bypass");
    out.autoconfig_url = ReadRegString(key, L"AutoConfigUrl");
  }
  RegCloseKey(key);
  return has_flags;
}

void ClearBackup() { RegDeleteTreeW(HKEY_CURRENT_USER, kBackupKey); }

}  // namespace

bool Read(Settings& out) {
  // FLAGS_UI reports auto-detect the way the Settings app shows it; older
  // systems only know FLAGS.
  return QueryOptions(out, INTERNET_PER_CONN_FLAGS_UI) ||
         QueryOptions(out, INTERNET_PER_CONN_FLAGS);
}

bool Apply(const Settings& settings) {
  std::wstring server = settings.server;
  std::wstring bypass = settings.bypass;
  std::wstring autoconfig_url = settings.autoconfig_url;

  INTERNET_PER_CONN_OPTIONW options[4] = {};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = settings.flags;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = server.data();
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = bypass.data();
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[3].Value.pszValue = autoconfig_url.data();

  INTERNET_PER_CONN_OPTION_LISTW list = {};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 4;
  list.pOptions = options;
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list,
                          sizeof(list))) {
    return false;
  }
  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
  return true;
}

bool IsChrNetProxy(const Settings& settings, uint16_t http_port) {
  if ((settings.flags & PROXY_TYPE_PROXY) == 0) return false;
  const std::wstring endpoint = L"127.0.0.1:" + std::to_wstring(http_port);
  return settings.server.find(endpoint) != std::wstring::npos;
}

bool HasPendingRestore() {
  Settings ignored;
  return LoadBackup(ignored);
}

bool EnableForChrNet(uint16_t http_port, std::string& error) {
  Settings current;
  if (!Read(current)) {
    error = "Не удалось прочитать настройки прокси Windows";
    return false;
  }

  // A backup left by a session that never disconnected already holds the
  // user's real settings; the current ones are ChrNet's own.
  if (!HasPendingRestore()) {
    const Settings original =
        IsChrNetProxy(current, http_port) ? Settings{} : current;
    if (!SaveBackup(original)) {
      error = "Не удалось сохранить настройки прокси Windows";
      return false;
    }
  }

  Settings chrnet;
  chrnet.flags = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
  chrnet.server = L"127.0.0.1:" + std::to_wstring(http_port);
  chrnet.bypass = kChrNetBypass;
  if (!Apply(chrnet)) {
    error = "Не удалось включить системный прокси Windows";
    return false;
  }
  return true;
}

void RestoreAfterChrNet(uint16_t http_port) {
  Settings backup;
  const bool has_backup = LoadBackup(backup);

  Settings current;
  if (Read(current) && IsChrNetProxy(current, http_port)) {
    if (!Apply(has_backup ? backup : Settings{})) {
      LogWarning("Failed to restore the Windows proxy settings");
      return;
    }
    LogInfo("Windows proxy settings restored");
  }
  if (has_backup) ClearBackup();
}

}  // namespace chrnet::proxy
