//! The send gate: which frames may ever reach the recognizer.
//!
//! The hallucination gate from the audio crate, applied to the wire: speech
//! frames travel, plus a bounded pad of quiet frames after the last voiced
//! one (the server's VAD needs to observe silence to close an utterance),
//! and nothing else. Long silence and ambient noise never become
//! recognition input — a session left open in a quiet room sends no audio
//! at all.

use spokenrectifier_audio::VadDecision;

/// How long quiet frames keep flowing after the last voiced one, so the
/// server's `server_vad` sees the pause that closes the utterance. Must
/// stay comfortably above the server-side `silence_duration_ms` we
/// configure (400 ms).
pub const PAD_MS: u64 = 1000;

pub struct SendGate {
    pad_ms: u64,
    active: bool,
}

impl SendGate {
    pub fn new(pad_ms: u64) -> Self {
        Self {
            pad_ms,
            active: false,
        }
    }

    /// Decide for one frame given its VAD decision: `true` means the frame
    /// belongs on the wire.
    pub fn push(&mut self, decision: &VadDecision) -> bool {
        if decision.voiced {
            self.active = true;
            return true;
        }
        // Quiet frame: travels only while it stays inside the post-speech
        // pad — `silence_ms` is cumulative since the last voiced frame.
        self.active = self.active && decision.silence_ms <= self.pad_ms;
        self.active
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{tone_frames as tone, zero_frames as zeros};

    fn gate() -> SendGate {
        SendGate::new(PAD_MS)
    }

    /// Drive the gate with a frames script (tone = speech), collecting the
    /// send decisions.
    fn run(frames: &[Vec<i16>]) -> Vec<bool> {
        let mut vad = spokenrectifier_audio::Vad::new(Default::default());
        let mut gate = gate();
        frames.iter().map(|f| gate.push(&vad.push(f))).collect()
    }

    #[test]
    fn idle_session_sends_nothing() {
        // Calibration plus a long quiet stay: no frame ever travels.
        let sent = run(&zeros(30));
        assert!(sent.iter().all(|&s| !s), "got {sent:?}");
    }

    #[test]
    fn speech_opens_the_gate_and_quiet_pads_then_closes_it() {
        let mut frames = zeros(4); // calibration
        frames.extend(tone(0.6, 3)); // speech: frames 4-6
        frames.extend(zeros(20)); // long quiet after
        let sent = run(&frames);

        let opened = sent.iter().position(|&s| s).expect("speech sends");
        assert_eq!(opened, 4, "first voiced frame travels");
        // Speech (3) + pad (PAD_MS / 100) frames travel, then the gate shuts.
        let sent_count = sent.iter().filter(|&&s| s).count();
        assert_eq!(sent_count, 3 + PAD_MS as usize / 100);
        // And it stays shut for the rest of the long quiet.
        assert!(sent[sent.len() - 1..].iter().all(|&s| !s));
    }

    #[test]
    fn speech_after_a_long_pause_reopens_the_gate() {
        let mut frames = zeros(4);
        frames.extend(tone(0.6, 2));
        frames.extend(zeros(20)); // gate closed here
        frames.extend(tone(0.6, 1)); // fresh speech
        let sent = run(&frames);
        assert!(
            *sent.last().expect("one decision per frame"),
            "new speech travels again"
        );
    }
}
