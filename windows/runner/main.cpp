#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

static const wchar_t kMutexName[]   = L"ChrNetSingleInstanceMutex";
static const wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
static const wchar_t kWindowTitle[] = L"chrnet";

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Single-instance guard
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, kMutexName);
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(kWindowClass, kWindowTitle);
    if (existing) {
      auto args = GetCommandLineArguments();
      if (!args.empty()) {
        const std::string& url = args[0];
        COPYDATASTRUCT cds = {};
        cds.dwData  = 0x43484E54;
        cds.cbData  = static_cast<DWORD>(url.size() + 1);
        cds.lpData  = const_cast<char*>(url.c_str());
        ::SendMessageW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds));
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
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
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
