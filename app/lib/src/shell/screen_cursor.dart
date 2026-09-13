/// Synchronous screen-cursor read for geometry gestures.
///
/// Flutter's `PointerEvent.position` is view-relative: the origin is the
/// window's top-left. Moving that window under a held pointer therefore
/// changes the next event's coordinates even when the physical mouse is
/// still. Feeding those as deltas makes the orb lag the cursor (often
/// ~half) and bounce — the window and the event stream chase each other.
///
/// `GetCursorPos` is the screen-stable alternative: physical pixels in
/// the virtual desktop, converted with the same devicePixelRatio
/// window_manager uses for `setBounds`. Method-channel cursor reads
/// (screen_retriever) are async and would race the window the same way.
/// Null off Windows, or if the call fails — callers fall back to the
/// view-relative event position, which is what widget tests actually
/// are (`setBounds` never moves the test view).
library;

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:ui' show Offset;

import 'package:ffi/ffi.dart';

final class _Point extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

typedef _GetCursorPosNative = Int32 Function(Pointer<_Point>);
typedef _GetCursorPosDart = int Function(Pointer<_Point>);

_GetCursorPosDart? _getCursorPos;

_GetCursorPosDart? _ensure() {
  if (_getCursorPos != null) return _getCursorPos;
  if (!Platform.isWindows) return null;
  _getCursorPos = DynamicLibrary.open('user32.dll')
      .lookupFunction<_GetCursorPosNative, _GetCursorPosDart>('GetCursorPos');
  return _getCursorPos;
}

/// Logical screen coordinates of the cursor (physical ÷ [devicePixelRatio]),
/// matching window_manager's coordinate system. Null when unavailable.
Offset? logicalCursorScreen(double devicePixelRatio) {
  if (devicePixelRatio <= 0) return null;
  final fn = _ensure();
  if (fn == null) return null;
  final pt = calloc<_Point>();
  try {
    if (fn(pt) == 0) return null;
    return Offset(pt.ref.x / devicePixelRatio, pt.ref.y / devicePixelRatio);
  } finally {
    calloc.free(pt);
  }
}
