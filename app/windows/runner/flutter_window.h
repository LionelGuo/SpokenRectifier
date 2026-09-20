#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // ADR 0017: receives the card-slot window region ("setRegion",
  // logical window pixels scaled here by the live dpr, or no arguments
  // for the whole window) while a panel stage holds the window at the
  // panel growth ceiling, and the physical-faithful seating
  // ("setBoundsPhysical", ticket 17).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      hit_channel_;

  // The window's CURRENT dpr straight from the OS (ticket 17): the
  // Flutter view's devicePixelRatio lags a monitor hop, so every
  // logical<->physical conversion on this channel uses this instead.
  double LiveDpr();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
