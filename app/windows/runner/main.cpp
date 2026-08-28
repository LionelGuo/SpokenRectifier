#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <screen_retriever_windows/screen_retriever_windows_plugin_c_api.h>
#include <window_manager/window_manager_plugin.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// desktop_multi_window spawns each sub-window as a bare engine that
// carries only its own internal channel registration - every other
// plugin is missing there, so the settings window's window_manager
// calls would die with MissingPluginException (spike 2026-08-28: a
// sub-engine crashed exactly there). The plugin exposes this creation
// callback so the host can register what its sub-engines need:
// window_manager plus screen_retriever (its position math calls it).
// The tray, the hotkey and the rest stay single-instance by never being
// registered in a sub-engine.
void OnSubWindowCreated(void *flutter_view_controller) {
  auto *controller =
      reinterpret_cast<flutter::FlutterViewController *>(flutter_view_controller);
  WindowManagerPluginRegisterWithRegistrar(
      controller->engine()->GetRegistrarForPlugin("WindowManagerPlugin"));
  ScreenRetrieverWindowsPluginCApiRegisterWithRegistrar(
      controller->engine()->GetRegistrarForPlugin("ScreenRetrieverWindowsPluginCApi"));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Sub-windows (the settings window) get window_manager registered at
  // engine birth via the callback above.
  DesktopMultiWindowSetWindowCreatedCallback(OnSubWindowCreated);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"spokenrectifier_app", origin, size)) {
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
