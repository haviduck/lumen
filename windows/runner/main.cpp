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
  // The window opens at the welcome-panel size (700x560) so the IDE
  // doesn't launch as a maximised void with a small panel floating
  // in the middle. The Dart side (`lib/services/window_chrome.dart`,
  // wired through `window_manager`) maximises the window the moment
  // the user opens a workspace and shrinks it back if they ever
  // return to the welcome screen.
  //
  // Earlier this used 1280x720 + SW_SHOWMAXIMIZED (welcome panel
  // centred inside an empty maximised window). That made the
  // "open the IDE just to pick a project" UX feel like a load
  // screen with nothing on it. Don't reintroduce SW_SHOWMAXIMIZED
  // unconditionally — Dart owns the welcome→workspace size
  // transition now.
  Win32Window::Size size(700, 560);
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
