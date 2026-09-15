#ifndef CHRNET_CORE_LOG_H_
#define CHRNET_CORE_LOG_H_

#include <cstdint>
#include <filesystem>
#include <string>

namespace chrnet {

// Process-wide diagnostic log. Until InitLog is called, lines only go to the
// debugger output. The file is truncated at start when it has grown past
// |max_bytes|, which keeps a service that runs for months from filling the disk.
void InitLog(const std::filesystem::path& path, uintmax_t max_bytes = 1u << 20);
void LogInfo(const std::string& message);
void LogWarning(const std::string& message);
void LogError(const std::string& message);

}  // namespace chrnet

#endif  // CHRNET_CORE_LOG_H_
