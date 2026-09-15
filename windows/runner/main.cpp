#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <cstdio>

#include "flutter_window.h"
#include "service_check.h"
#include "utils.h"

static const wchar_t kMutexName[]   = L"ChrNetSingleInstanceMutex";
static const wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
static const wchar_t kWindowTitle[] = L"chrnet";

namespace {

bool HasArgument(const std::vector<std::string>& args, const char* flag) {
  return std::find(args.begin(), args.end(), flag) != args.end();
}

bool IsDeepLink(const std::string& arg) {
  static constexpr char kScheme[] = "chrnet://";
  if (arg.size() < sizeof(kScheme) - 1) return false;
  for (size_t i = 0; i < sizeof(kScheme) - 1; ++i) {
    const char ch = arg[i];
    const char lower =
        (ch >= 'A' && ch <= 'Z') ? static_cast<char>(ch - 'A' + 'a') : ch;
    if (lower != kScheme[i]) return false;
  }
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  // The installer runs "chrnet.exe --cleanup" before it replaces or removes
  // the app, to put back proxy settings that an instance it had to kill left
  // pointing at a core that is gone.
  if (HasArgument(command_line_arguments, "--cleanup")) {
    VpnServiceBridge::RestoreStaleSystemProxy();
    return EXIT_SUCCESS;
  }

  if (HasArgument(command_line_arguments, "--service-check")) {
    const int code =
        RunServiceCheck(HasArgument(command_line_arguments, "--start-test"));
    fflush(stdout);
    return code;
  }

  // Set by the Windows startup entry: the app starts in the tray.
  const bool start_hidden = HasArgument(command_line_arguments, "--minimized");

  // Single-instance guard
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, kMutexName);
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(kWindowClass, kWindowTitle);
    if (existing && !start_hidden) {
      for (const auto& url : command_line_arguments) {
        if (!IsDeepLink(url)) continue;
        COPYDATASTRUCT cds = {};
        cds.dwData  = 0x43484E54;
        cds.cbData  = static_cast<DWORD>(url.size() + 1);
        cds.lpData  = const_cast<char*>(url.c_str());
        ::SendMessageW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds));
        break;
      }
      if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
      ::ShowWindow(existing, SW_SHOW);
      ::SetForegroundWindow(existing);
    }
    if (mutex) { ::ReleaseMutex(mutex); ::CloseHandle(mutex); }
    return 0;
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(500, 900);
  if (!window.Create(L"chrnet", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (mutex) { ::ReleaseMutex(mutex); ::CloseHandle(mutex); }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
