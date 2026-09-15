#include "log.h"

#include <windows.h>

#include <cstdio>
#include <mutex>

#include "string_util.h"

namespace chrnet {

namespace {

std::mutex& LogMutex() {
  static std::mutex mutex;
  return mutex;
}

HANDLE& LogFile() {
  static HANDLE file = INVALID_HANDLE_VALUE;
  return file;
}

void Write(const char* level, const std::string& message) {
  SYSTEMTIME now;
  GetLocalTime(&now);
  char prefix[64];
  snprintf(prefix, sizeof(prefix), "%04u-%02u-%02u %02u:%02u:%02u.%03u [%s] ",
           static_cast<unsigned>(now.wYear), static_cast<unsigned>(now.wMonth),
           static_cast<unsigned>(now.wDay), static_cast<unsigned>(now.wHour),
           static_cast<unsigned>(now.wMinute),
           static_cast<unsigned>(now.wSecond),
           static_cast<unsigned>(now.wMilliseconds), level);
  std::string line = std::string(prefix) + message + "\r\n";

  std::lock_guard<std::mutex> lock(LogMutex());
  OutputDebugStringW(Utf8ToWide(line).c_str());
  HANDLE file = LogFile();
  if (file != INVALID_HANDLE_VALUE) {
    DWORD written = 0;
    WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written,
              nullptr);
  }
}

}  // namespace

void InitLog(const std::filesystem::path& path, uintmax_t max_bytes) {
  std::error_code ec;
  std::filesystem::create_directories(path.parent_path(), ec);
  const auto size = std::filesystem::file_size(path, ec);
  const bool truncate = !ec && size > max_bytes;

  std::lock_guard<std::mutex> lock(LogMutex());
  HANDLE& file = LogFile();
  if (file != INVALID_HANDLE_VALUE) {
    CloseHandle(file);
    file = INVALID_HANDLE_VALUE;
  }
  file = CreateFileW(path.wstring().c_str(), FILE_APPEND_DATA,
                     FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                     truncate ? CREATE_ALWAYS : OPEN_ALWAYS,
                     FILE_ATTRIBUTE_NORMAL, nullptr);
}

void LogInfo(const std::string& message) { Write("INFO", message); }

void LogWarning(const std::string& message) { Write("WARN", message); }

void LogError(const std::string& message) { Write("ERROR", message); }

}  // namespace chrnet
