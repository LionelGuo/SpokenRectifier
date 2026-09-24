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
  //
  // Ticket 17: the rect arrives in LOGICAL window coordinates and is
  // scaled here by the window's LIVE dpr (GetDpiForWindow) -- a
  // Dart-side multiplication would ride the Flutter view's dpr, which
  // lags a monitor hop and put the region outside the seated window
  // (invisible, unclickable orb). setBoundsPhysical moves the window
  // in GLOBAL PHYSICAL pixels for the same reason: window_manager's
  // setBounds converts through that same lagging dpr, which is how a
  // mixed-DPI monitor crossing used to land the window misplaced. Its
  // reply reports the landed rect in the POST-move logical space, the
  // truth Dart adopts.
  hit_channel_ = std::make_unique<flutter::MethodChannel<
      flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "spokenrectifier/window",
      &flutter::StandardMethodCodec::GetInstance());
  hit_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() == "setRegion") {
          HRGN region = nullptr;  // default: the whole window
          if (args != nullptr) {
            const auto left = args->find(flutter::EncodableValue("left"));
            const auto top = args->find(flutter::EncodableValue("top"));
            const auto right = args->find(flutter::EncodableValue("right"));
            const auto bottom = args->find(flutter::EncodableValue("bottom"));
            if (left != args->end() && top != args->end() &&
                right != args->end() && bottom != args->end()) {
              const double dpr = LiveDpr();
              const auto scale = [&dpr](const flutter::EncodableValue& v) {
                const double logical = std::get<double>(v);
                return static_cast<int>(logical * dpr +
                                        (logical >= 0 ? 0.5 : -0.5));
              };
              // Small-fix 23 (ADR-0017 revision): an optional "shape"
              // narrows the same box to its inscribed ellipse - the
              // idle orb's footprint square is visually empty past the
              // glow (alpha hits exact zero 2px inside the box) yet
              // its corners swallowed clicks meant for windows below.
              // Absent or any other value keeps the rect every panel
              // and gesture pushes.
              const auto shape = args->find(flutter::EncodableValue("shape"));
              const bool ellipse =
                  shape != args->end() &&
                  shape->second == flutter::EncodableValue("ellipse");
              region = ellipse
                           ? CreateEllipticRgn(scale(left->second),
                                               scale(top->second),
                                               scale(right->second),
                                               scale(bottom->second))
                           : CreateRectRgn(scale(left->second),
                                           scale(top->second),
                                           scale(right->second),
                                           scale(bottom->second));
            }
          }
          // On success the system owns the region; on failure we do.
          if (SetWindowRgn(GetHandle(), region, TRUE) == 0 &&
              region != nullptr) {
            DeleteObject(region);
          }
          result->Success();
        } else if (call.method_name() == "setBoundsPhysical") {
          if (args == nullptr) {
            result->Error("bad_args");
            return;
          }
          const auto read = [&args](const char* key) -> std::optional<int> {
            const auto it = args->find(flutter::EncodableValue(key));
            if (it == args->end()) return std::nullopt;
            return std::get<int32_t>(it->second);
          };
          const auto left = read("left");
          const auto top = read("top");
          const auto right = read("right");
          const auto bottom = read("bottom");
          if (!left || !top || !right || !bottom) {
            result->Error("bad_args");
            return;
          }
          SetWindowPos(GetHandle(), HWND_TOP, *left, *top, *right - *left,
                       *bottom - *top, 0);
          // Report the LANDED rect in the post-move logical space;
          // GetDpiForWindow already reflects the monitor we just
          // seated on.
          RECT rc{};
          GetWindowRect(GetHandle(), &rc);
          const double dpr = LiveDpr();
          flutter::EncodableMap landed;
          landed[flutter::EncodableValue("left")] =
              flutter::EncodableValue(rc.left / dpr);
          landed[flutter::EncodableValue("top")] =
              flutter::EncodableValue(rc.top / dpr);
          landed[flutter::EncodableValue("width")] =
              flutter::EncodableValue((rc.right - rc.left) / dpr);
          landed[flutter::EncodableValue("height")] =
              flutter::EncodableValue((rc.bottom - rc.top) / dpr);
          result->Success(flutter::EncodableValue(landed));
        } else {
          result->NotImplemented();
        }
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

double FlutterWindow::LiveDpr() {
  const UINT dpi = GetDpiForWindow(GetHandle());
  return dpi > 0 ? dpi / 96.0 : 1.0;
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
