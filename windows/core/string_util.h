#ifndef CHRNET_CORE_STRING_UTIL_H_
#define CHRNET_CORE_STRING_UTIL_H_

#include <windows.h>

#include <algorithm>
#include <string>
#include <string_view>

namespace chrnet {

inline std::wstring Utf8ToWide(std::string_view value) {
  if (value.empty()) return std::wstring();
  const int length = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      out.data(), length);
  return out;
}

inline std::string WideToUtf8(std::wstring_view value) {
  if (value.empty()) return std::string();
  const int length = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0, nullptr, nullptr);
  if (length <= 0) return std::string();
  std::string out(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      out.data(), length, nullptr, nullptr);
  return out;
}

inline std::wstring ToLowerAscii(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t ch) {
    return (ch >= L'A' && ch <= L'Z') ? static_cast<wchar_t>(ch - L'A' + L'a')
                                      : ch;
  });
  return value;
}

inline bool EqualsIgnoreCase(std::wstring_view left, std::wstring_view right) {
  return ToLowerAscii(std::wstring(left)) == ToLowerAscii(std::wstring(right));
}

inline std::string TrimAscii(std::string_view value) {
  size_t begin = 0;
  size_t end = value.size();
  while (begin < end && (value[begin] == ' ' || value[begin] == '\t' ||
                         value[begin] == '\r' || value[begin] == '\n')) {
    ++begin;
  }
  while (end > begin && (value[end - 1] == ' ' || value[end - 1] == '\t' ||
                         value[end - 1] == '\r' || value[end - 1] == '\n')) {
    --end;
  }
  return std::string(value.substr(begin, end - begin));
}

}  // namespace chrnet

#endif  // CHRNET_CORE_STRING_UTIL_H_
