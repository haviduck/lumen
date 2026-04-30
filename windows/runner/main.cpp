#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shobjidl.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // **AppUserModelID — Windows taskbar identity.**
  // Without an explicit AUMID, Windows uses the .exe path as the
  // taskbar grouping key and shows the .exe filename as the
  // jumplist label (which is why an unrenamed binary would show
  // "duckoff" even after we set Lumen everywhere else). Setting a
  // stable reverse-DNS-style AUMID here means:
  //   - All Lumen processes group under one taskbar slot (debug,
  //     release, installed copy — all merge), and
  //   - Windows reads the displayed name from this process's
  //     version resource (`FileDescription` / `ProductName` in
  //     Runner.rc, both of which already say "Lumen") instead of
  //     falling back to the .exe filename.
  // Must be called BEFORE the first window is created.
  ::SetCurrentProcessExplicitAppUserModelID(L"Lumen.IDE");

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // 1280x720 is just the fallback size if maximize fails for some
  // reason (e.g. a future hypothetical no-monitor edge case).
  // Actual launch size is monitor-fill — Win32Window::Show()
  // uses SW_SHOWMAXIMIZED, applied on first show before any
  // Flutter frame is rendered, so the welcome screen doesn't get
  // a small-then-grown layout flash.
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Lumen", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
