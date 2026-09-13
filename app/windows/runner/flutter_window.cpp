#include "flutter_window.h"

#include <cstdint>
#include <optional>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // ADR 0017: while a panel stage is open the window sits at the panel
  // growth ceiling; Dart narrows the OS window REGION to the card slot
  // (physical window pixels -- client == window on this popup). Outside
  // the region the window neither paints nor hit-tests, so clicks fall
  // through to the desktop across processes (WM_NCHITTEST +
  // HTTRANSPARENT only forwards within one thread -- probed, does not
  // pass). A region change triggers no WM_SIZE, so the engine's EGL
  // surface stays put. No arguments restores the whole window.
  hit_channel_ = std::make_unique<flutter::MethodChannel<
      flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "spokenrectifier/window",
      &flutter::StandardMethodCodec::GetInstance());
  hit_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setRegion") {
          result->NotImplemented();
          return;
        }
        HRGN region = nullptr;  // default: the whole window
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (args != nullptr) {
          const auto left = args->find(flutter::EncodableValue("left"));
          const auto top = args->find(flutter::EncodableValue("top"));
          const auto right = args->find(flutter::EncodableValue("right"));
          const auto bottom = args->find(flutter::EncodableValue("bottom"));
          if (left != args->end() && top != args->end() &&
              right != args->end() && bottom != args->end()) {
            region = CreateRectRgn(
                static_cast<int>(std::get<int32_t>(left->second)),
                static_cast<int>(std::get<int32_t>(top->second)),
                static_cast<int>(std::get<int32_t>(right->second)),
                static_cast<int>(std::get<int32_t>(bottom->second)));
          }
        }
        // On success the system owns the region; on failure we do.
        if (SetWindowRgn(GetHandle(), region, TRUE) == 0 && region != nullptr) {
          DeleteObject(region);
        }
        result->Success();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Probe (reshape ghosting, .scratch/v1/research/window-gesture-perf.md):
  // window_manager SetBounds -> SetWindowPos(..., HWND_TOP, ..., uFlags=0)
  // copies the old client flush-top-left into the new rect. The orb is
  // pinned to a corner, so growing up/left smears the previous frame.
  // Discard those bits only when the size actually changes -- orb drag is
  // position-only and must keep the copy. Must run BEFORE Flutter's
  // WindowProc so the mutated flags stick.
  if (message == WM_WINDOWPOSCHANGING && lparam != 0) {
    auto* pos = reinterpret_cast<WINDOWPOS*>(lparam);
    if ((pos->flags & SWP_NOSIZE) == 0) {
      RECT current{};
      if (GetWindowRect(hwnd, &current)) {
        const int cur_w = current.right - current.left;
        const int cur_h = current.bottom - current.top;
        if (pos->cx != cur_w || pos->cy != cur_h) {
          pos->flags |= SWP_NOCOPYBITS;
        }
      }
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
