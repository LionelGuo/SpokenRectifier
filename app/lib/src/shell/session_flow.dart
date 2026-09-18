/// The orb-position session flow as one pure function — the single
/// source both the orb clicks and the hotkey (and Enter/Esc) route
/// through (球位状态机:单一来源纯函数,与热键主流程同构).
///
/// The engine stays authoritative for the phase itself (state-change
/// events mirror back); this table only decides which engine command a
/// user input maps to, so the orb, the hotkey and the keyboard can
/// never drift apart.
///
/// Esc cancels from every active phase, recording included (ticket 15);
/// the orb is disabled while rectifying (ignore, no spinner click).

library;

import '../rust/api.dart' show BridgeSessionState;

/// A user input at the orb position. `primary` is the orb's left click
/// and the hotkey press — the same step. `secondary` is the orb's right
/// click (quick panel, idle-only — a stage concern, never a session
/// command).
enum SessionInput { primary, secondary, enter, escape }

/// The engine command an input maps to, or null for "ignored".
enum SessionCommand { start, stop, confirm, cancel }

/// The input-to-command table. Null = ignored.
SessionCommand? flowAction(BridgeSessionState phase, SessionInput input) {
  switch (phase) {
    case BridgeSessionState.idle:
      if (input == SessionInput.primary) return SessionCommand.start;
      return null;
    case BridgeSessionState.recording:
      switch (input) {
        case SessionInput.primary:
          // The orb's left click. The primary hotkey does not use this
          // cell while a hold watch is live (ADR-0020: release stops,
          // not keyDown); with the switch off it still does.
          return SessionCommand.stop;
        case SessionInput.escape:
          return SessionCommand.cancel;
        case SessionInput.enter:
        case SessionInput.secondary:
          return null;
      }
    case BridgeSessionState.rectifying:
      if (input == SessionInput.escape) return SessionCommand.cancel;
      return null; // primary ignored: disabled while rectifying
    case BridgeSessionState.preview:
      switch (input) {
        case SessionInput.primary:
        case SessionInput.enter:
          return SessionCommand.confirm;
        case SessionInput.escape:
          return SessionCommand.cancel;
        case SessionInput.secondary:
          return null;
      }
    case BridgeSessionState.inserted:
    case BridgeSessionState.cancelled:
      // Transient feedback: the engine already continues to idle.
      return null;
  }
}

/// Which surface the morphing window shows. Session and quick share one
/// footprint, one position, and mutual exclusivity (同形同位互斥); the
/// quick panel only exists while idle (会话期无右键).
enum StageKind { orb, session, quick }

/// The stage for a phase. Defensive by construction: an active session
/// wins over a stale quick-open flag.
StageKind stageFor(BridgeSessionState phase, bool quickOpen) {
  switch (phase) {
    case BridgeSessionState.recording:
    case BridgeSessionState.rectifying:
    case BridgeSessionState.preview:
      return StageKind.session;
    case BridgeSessionState.idle:
    case BridgeSessionState.inserted:
    case BridgeSessionState.cancelled:
      return quickOpen ? StageKind.quick : StageKind.orb;
  }
}
