#include "pipe_protocol.h"

namespace chrnet::pipe {

namespace {

IoResult ClassifyError(DWORD error) {
  switch (error) {
    case ERROR_BROKEN_PIPE:
    case ERROR_PIPE_NOT_CONNECTED:
    case ERROR_NO_DATA:
    case ERROR_OPERATION_ABORTED:
      return IoResult::kClosed;
    default:
      return IoResult::kError;
  }
}

class EventHandle {
 public:
  EventHandle() : handle_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}
  ~EventHandle() {
    if (handle_ != nullptr) CloseHandle(handle_);
  }
  EventHandle(const EventHandle&) = delete;
  EventHandle& operator=(const EventHandle&) = delete;
  HANDLE get() const { return handle_; }

 private:
  HANDLE handle_;
};

// One overlapped read or write of up to |size| bytes. |transferred| receives
// the byte count; a zero-byte successful read means the peer closed the pipe.
IoResult Transfer(HANDLE pipe, bool write, char* buffer, DWORD size,
                  HANDLE cancel_event, DWORD timeout_ms, DWORD& transferred) {
  EventHandle done;
  if (done.get() == nullptr) return IoResult::kError;
  OVERLAPPED overlapped = {};
  overlapped.hEvent = done.get();
  transferred = 0;

  const BOOL started =
      write ? WriteFile(pipe, buffer, size, nullptr, &overlapped)
            : ReadFile(pipe, buffer, size, nullptr, &overlapped);
  if (!started) {
    const DWORD error = GetLastError();
    if (error != ERROR_IO_PENDING) return ClassifyError(error);

    HANDLE handles[2] = {done.get(), cancel_event};
    const DWORD count = cancel_event != nullptr ? 2 : 1;
    const DWORD wait = WaitForMultipleObjects(count, handles, FALSE, timeout_ms);
    if (wait != WAIT_OBJECT_0) {
      CancelIoEx(pipe, &overlapped);
      GetOverlappedResult(pipe, &overlapped, &transferred, TRUE);
      if (wait == WAIT_OBJECT_0 + 1) return IoResult::kCancelled;
      if (wait == WAIT_TIMEOUT) return IoResult::kTimeout;
      return IoResult::kError;
    }
  }
  if (!GetOverlappedResult(pipe, &overlapped, &transferred, FALSE)) {
    return ClassifyError(GetLastError());
  }
  return IoResult::kOk;
}

IoResult ReadExact(HANDLE pipe, HANDLE cancel_event, char* buffer,
                   DWORD size) {
  DWORD total = 0;
  while (total < size) {
    DWORD read = 0;
    const auto result = Transfer(pipe, false, buffer + total, size - total,
                                 cancel_event, INFINITE, read);
    if (result != IoResult::kOk) return result;
    if (read == 0) return IoResult::kClosed;
    total += read;
  }
  return IoResult::kOk;
}

}  // namespace

IoResult ReadMessage(HANDLE pipe, HANDLE cancel_event, std::string& message) {
  char header[4];
  auto result = ReadExact(pipe, cancel_event, header, sizeof(header));
  if (result != IoResult::kOk) return result;
  const uint32_t length =
      static_cast<uint32_t>(static_cast<unsigned char>(header[0])) |
      (static_cast<uint32_t>(static_cast<unsigned char>(header[1])) << 8) |
      (static_cast<uint32_t>(static_cast<unsigned char>(header[2])) << 16) |
      (static_cast<uint32_t>(static_cast<unsigned char>(header[3])) << 24);
  if (length > kMaxMessageBytes) return IoResult::kError;
  message.assign(length, '\0');
  if (length == 0) return IoResult::kOk;
  return ReadExact(pipe, cancel_event, message.data(), length);
}

IoResult WriteMessage(HANDLE pipe, const std::string& message,
                      DWORD timeout_ms) {
  if (message.size() > kMaxMessageBytes) return IoResult::kError;
  const auto length = static_cast<uint32_t>(message.size());
  std::string frame;
  frame.reserve(message.size() + 4);
  frame.push_back(static_cast<char>(length & 0xFF));
  frame.push_back(static_cast<char>((length >> 8) & 0xFF));
  frame.push_back(static_cast<char>((length >> 16) & 0xFF));
  frame.push_back(static_cast<char>((length >> 24) & 0xFF));
  frame += message;

  DWORD total = 0;
  const auto frame_size = static_cast<DWORD>(frame.size());
  while (total < frame_size) {
    DWORD written = 0;
    const auto result = Transfer(pipe, true, frame.data() + total,
                                 frame_size - total, nullptr, timeout_ms,
                                 written);
    if (result != IoResult::kOk) return result;
    if (written == 0) return IoResult::kError;
    total += written;
  }
  return IoResult::kOk;
}

}  // namespace chrnet::pipe
