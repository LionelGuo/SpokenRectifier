//! The primary-hotkey hold watcher (ADR-0020): poll the chord with
//! `GetAsyncKeyState`, upgrade past 400 ms, and on a confirmed upgrade
//! stop the session when any key of the chord comes up.
//!
//! Why a watcher, not the plugin's `keyUpHandler`: Windows `RegisterHotKey`
//! has no release event, and auto-repeat delivers more `WM_HOTKEY`s for
//! the same physical hold. Why not a second `WH_KEYBOARD_LL`: Esc already
//! owns that slot; this path only reads key state, like the insertion
//! paste-gate. Why not a field on `StartSession`: the orb click shares
//! that command and must not start a watch (球左键不跟).
//!
//! The one pure decision ([`HoldState::step`]) is cfg-free so its table
//! runs on the dev host. The poller is Windows-only; off Windows the
//! watcher never starts and Dart keeps today's tap path.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;

use spokenrectifier_engine::Engine;
use tokio::runtime::Runtime;

/// Fixed threshold (ADR-0020): not in settings, not per-chord.
#[cfg(any(windows, test))]
pub(crate) const HOLD_THRESHOLD_MS: u64 = 400;

/// Same cadence as the insertion paste-gate's modifier wait.
#[cfg(windows)]
const POLL_MS: u64 = 10;

static HOLDING: AtomicBool = AtomicBool::new(false);
static GENERATION: AtomicU64 = AtomicU64::new(0);
static START: Mutex<()> = Mutex::new(());

/// Whether a watch is live — Dart swallows `WM_HOTKEY` repeats off this.
pub(crate) fn is_holding() -> bool {
    HOLDING.load(Ordering::SeqCst)
}

/// Drop the current watch, if any. Idempotent; the subscribe loop calls
/// this the moment the session leaves Recording (cancel, auto-end, a
/// stop we issued ourselves). Does not talk to the engine: the session
/// is already moving.
pub(crate) fn stop() {
    HOLDING.store(false, Ordering::SeqCst);
    GENERATION.fetch_add(1, Ordering::SeqCst);
}

/// Arm a watch for `vks`. Returns whether a watch is live afterwards:
/// true if one was already running (a repeat of the same hold — do not
/// restart the timer) or if this call started one. The caller has already
/// checked the master switch, the session state, and the vk set.
///
/// Off Windows this is a no-op: there is no `GetAsyncKeyState` to poll,
/// and the product's first platform is Windows.
pub(crate) fn start(
    vks: Vec<u32>,
    stop_on_early_release: bool,
    engine: Engine,
    rt: &Runtime,
) -> bool {
    let _guard = START.lock().unwrap();
    if HOLDING.load(Ordering::SeqCst) {
        return true;
    }
    #[cfg(not(windows))]
    {
        let _ = (vks, stop_on_early_release, engine, rt);
        false
    }
    #[cfg(windows)]
    {
        let gen = GENERATION.load(Ordering::SeqCst);
        HOLDING.store(true, Ordering::SeqCst);
        rt.spawn(async move {
            run_watch(gen, vks, stop_on_early_release, engine).await;
        });
        true
    }
}

#[cfg(windows)]
fn physical_down(vk: u32) -> bool {
    use windows::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState;
    (unsafe { GetAsyncKeyState(vk as i32) }) < 0
}

#[cfg(any(windows, test))]
fn chord_is_down(vks: &[u32], is_down: impl Fn(u32) -> bool) -> bool {
    !vks.is_empty() && vks.iter().copied().all(is_down)
}

#[cfg(windows)]
async fn run_watch(gen: u64, vks: Vec<u32>, stop_on_early_release: bool, engine: Engine) {
    use spokenrectifier_engine::Command;
    use std::time::{Duration, Instant};
    let mut state = HoldState::new(stop_on_early_release);
    let origin = Instant::now();
    loop {
        if !still_live(gen) {
            break;
        }
        let all_down = chord_is_down(&vks, physical_down);
        let now_ms = origin.elapsed().as_millis() as u64;
        let tick = state.step(now_ms, all_down);
        if let Some(held) = tick.gate {
            if !still_live(gen) {
                break;
            }
            let _ = engine.execute(Command::HoldGate { held }).await;
        }
        if tick.mark {
            if !still_live(gen) {
                break;
            }
            let _ = engine.execute(Command::MarkQuick).await;
            // Synchronous: mark_quick sets the flag before execute
            // returns, so a pin-refusal is visible here — do not treat
            // "we called MarkQuick" as "the session upgraded".
            if engine.is_quick() {
                state.upgraded = true;
            }
        }
        if tick.stop {
            if still_live(gen) {
                HOLDING.store(false, Ordering::SeqCst);
                let _ = engine.execute(Command::StopSession).await;
            }
            break;
        }
        if tick.end {
            HOLDING.store(false, Ordering::SeqCst);
            break;
        }
        tokio::time::sleep(Duration::from_millis(POLL_MS)).await;
    }
}

#[cfg(windows)]
fn still_live(gen: u64) -> bool {
    HOLDING.load(Ordering::SeqCst) && GENERATION.load(Ordering::SeqCst) == gen
}

/// What one poll should send. Several flags can be set together (a
/// release that had gated the silence auto-end both lowers the gate and
/// ends the watch).
#[cfg(any(windows, test))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct HoldTick {
    /// `Some(true)` when the chord first goes fully down, `Some(false)`
    /// when it breaks; `None` when the gate does not change this tick.
    gate: Option<bool>,
    mark: bool,
    stop: bool,
    end: bool,
}

/// The cfg-free decision: given the chord's current down-ness and a
/// monotonic clock, what does the watcher do.
///
/// `stop_on_early_release` distinguishes the opening hold (the press that
/// started the session: a short release keeps recording) from a later
/// press while already recording (that press's release is today's
/// tap-to-stop). The orb never sets this — it still stops on click.
#[cfg(any(windows, test))]
struct HoldState {
    down_since_ms: Option<u64>,
    marked: bool,
    upgraded: bool,
    stop_on_early_release: bool,
    gated: bool,
}

#[cfg(any(windows, test))]
impl HoldState {
    fn new(stop_on_early_release: bool) -> Self {
        Self {
            down_since_ms: None,
            marked: false,
            upgraded: false,
            stop_on_early_release,
            gated: false,
        }
    }

    fn step(&mut self, now_ms: u64, all_down: bool) -> HoldTick {
        if all_down {
            let mut tick = HoldTick::default();
            if self.down_since_ms.is_none() {
                self.down_since_ms = Some(now_ms);
                self.gated = true;
                tick.gate = Some(true);
            }
            if !self.marked {
                if let Some(start) = self.down_since_ms {
                    if now_ms.saturating_sub(start) >= HOLD_THRESHOLD_MS {
                        self.marked = true;
                        tick.mark = true;
                    }
                }
            }
            tick
        } else {
            self.release_tick()
        }
    }

    fn release_tick(&mut self) -> HoldTick {
        let mut tick = HoldTick {
            end: true,
            ..HoldTick::default()
        };
        if self.gated {
            tick.gate = Some(false);
            self.gated = false;
        }
        // A confirmed upgrade always stops on release. A later press
        // (stop_on_early_release) stops even when short or when MarkQuick
        // was refused — that press is the tap-to-stop. The opening hold
        // of a pinned / un-upgraded session does not.
        if self.upgraded || self.stop_on_early_release {
            tick.stop = true;
        }
        tick
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gate_true() -> HoldTick {
        HoldTick {
            gate: Some(true),
            ..HoldTick::default()
        }
    }

    #[test]
    fn the_threshold_is_the_adr_constant() {
        assert_eq!(HOLD_THRESHOLD_MS, 400);
    }

    #[test]
    fn any_key_of_the_chord_up_is_a_release() {
        let vks = [0x11, 0x12, 0x56];
        assert!(chord_is_down(&vks, |_| true));
        assert!(!chord_is_down(&vks, |vk| vk != 0x56));
        assert!(!chord_is_down(&vks, |_| false));
        // An empty chord never counts as held — watch_hold rejects it
        // before a poller starts; this keeps a bug from waiting forever.
        assert!(!chord_is_down(&[], |_| true));
    }

    #[test]
    fn the_first_all_down_tick_opens_the_gate_and_starts_the_clock() {
        let mut state = HoldState::new(false);
        assert_eq!(state.step(0, true), gate_true());
        assert_eq!(state.down_since_ms, Some(0));
    }

    #[test]
    fn crossing_the_threshold_marks_once() {
        let mut state = HoldState::new(false);
        assert!(!state.step(0, true).mark);
        assert!(!state.step(399, true).mark);
        assert!(state.step(400, true).mark);
        assert!(!state.step(800, true).mark);
    }

    #[test]
    fn the_clock_starts_when_the_chord_is_fully_down_not_at_arm() {
        // RegisterHotKey already fired, but we still wait for the poll
        // to see every vk down before counting — the arm can land a few
        // milliseconds after the press.
        let mut state = HoldState::new(false);
        let tick = state.step(250, true);
        assert_eq!(tick.gate, Some(true));
        assert!(!tick.mark);
        assert!(!state.step(649, true).mark); // 250 + 399
        assert!(state.step(650, true).mark); // 250 + 400
    }

    #[test]
    fn an_opening_release_before_the_threshold_keeps_recording() {
        let mut state = HoldState::new(false);
        state.step(0, true);
        let tick = state.step(200, false);
        assert_eq!(
            tick,
            HoldTick {
                gate: Some(false),
                mark: false,
                stop: false,
                end: true,
            }
        );
    }

    #[test]
    fn a_pinned_opening_hold_does_not_stop_on_release() {
        // MarkQuick was issued but the engine refused (already pinned):
        // upgraded stays false, so this is still the opening hold of an
        // ordinary session — release must not end it.
        let mut state = HoldState::new(false);
        state.step(0, true);
        assert!(state.step(400, true).mark);
        let tick = state.step(410, false);
        assert!(!tick.stop);
        assert!(tick.end);
        assert_eq!(tick.gate, Some(false));
    }

    #[test]
    fn an_opening_release_after_a_confirmed_upgrade_stops() {
        let mut state = HoldState::new(false);
        state.step(0, true);
        state.step(400, true);
        state.upgraded = true;
        let tick = state.step(410, false);
        assert!(tick.stop);
        assert!(tick.end);
        assert_eq!(tick.gate, Some(false));
    }

    #[test]
    fn a_later_press_stops_on_release_even_when_short() {
        let mut state = HoldState::new(true);
        state.step(0, true);
        let tick = state.step(50, false);
        assert!(tick.stop);
        assert!(tick.end);
    }

    #[test]
    fn a_later_press_already_up_stops_immediately() {
        // The WM_HOTKEY that armed us raced the release: first poll
        // sees the chord up. This press was the tap-to-stop.
        let mut state = HoldState::new(true);
        let tick = state.step(0, false);
        assert!(tick.stop);
        assert!(tick.end);
        assert_eq!(tick.gate, None);
    }

    #[test]
    fn an_opening_press_already_up_just_ends() {
        let mut state = HoldState::new(false);
        let tick = state.step(0, false);
        assert!(!tick.stop);
        assert!(tick.end);
        assert_eq!(tick.gate, None);
    }

    #[test]
    fn a_later_press_that_crosses_the_threshold_still_stops_on_release() {
        let mut state = HoldState::new(true);
        state.step(0, true);
        state.step(400, true);
        state.upgraded = true;
        let tick = state.step(410, false);
        assert!(tick.stop);
    }

    #[test]
    fn a_later_press_refused_as_quick_still_stops_on_release() {
        // Pinned mid-session, then a long second press: MarkQuick no-ops,
        // but this press is still the tap-to-stop of an ordinary session.
        let mut state = HoldState::new(true);
        state.step(0, true);
        state.step(400, true);
        let tick = state.step(410, false);
        assert!(tick.stop);
        assert!(!state.upgraded);
    }
}
