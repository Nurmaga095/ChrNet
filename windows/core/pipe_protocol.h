#ifndef CHRNET_CORE_PIPE_PROTOCOL_H_
#define CHRNET_CORE_PIPE_PROTOCOL_H_

#include <windows.h>

#include <cstdint>
#include <string>

namespace chrnet::pipe {

// The app talks to the ChrNet service over this pipe. Every message is a JSON
// document preceded by its length as a little-endian uint32.
//
//   request  {"id":1,"method":"start","params":{...}}
//   response {"id":1,"ok":true,"result":{...}}
//            {"id":1,"ok":false,"error":"...","code":"..."}
//   event    {"event":"status","status":{...}}
inline constexpr wchar_t kServicePipeName[] = L"\\\\.\\pipe\\ChrNetService";
inline constexpr wchar_t kServiceName[] = L"ChrNetService";
inline constexpr int kProtocolVersion = 1;
inline constexpr uint32_t kMaxMessageBytes = 16u << 20;

enum class IoResult { kOk, kClosed, kCancelled, kTimeout, kError };

// Both work on a handle opened with FILE_FLAG_OVERLAPPED, so one thread can
// wait for incoming messages while another writes. |cancel_event| may be null;
// signalling it makes a pending read return kCancelled.
IoResult ReadMessage(HANDLE pipe, HANDLE cancel_event, std::string& message);
IoResult WriteMessage(HANDLE pipe, const std::string& message,
                      DWORD timeout_ms);

}  // namespace chrnet::pipe

#endif  // CHRNET_CORE_PIPE_PROTOCOL_H_
