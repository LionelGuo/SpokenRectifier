//! Energy-based voice activity detection.
//!
//! One 100 ms 16 kHz mono frame in, one [`VadDecision`] out. The decision
//! carries the two things downstream consumers need:
//!
//! - `voiced` — this frame is speech. The hallucination gate: recognizers
//!   only ever see frames where this is true.
//! - `speaking` — the smoothed state (hysteresis plus hangover), used for
//!   the orb and for silence accumulation.
//!
//! The noise floor adapts while silent, so ambient hum is absorbed rather
//! than recognized. The first few frames of a session calibrate the floor
//! (the user has not started talking yet) and never count as speech, so a
//! steady room noise is silent from frame one. Known v1 limitation: steady
//! noise that ramps up *after* calibration holds `speaking` true until a
//! real pause — [`Vad`] is the single swap point if a model-based VAD
//! becomes necessary.

use crate::convert::TARGET_RATE;

/// VAD frame duration. 100 ms matches the chunk interval cloud realtime
/// ASR protocols expect, and is fine enough for the engine's silence
/// thresholds (>= 1200 ms).
pub const FRAME_MS: u64 = 100;
/// Samples per [`FRAME_MS`] at [`TARGET_RATE`].
pub const FRAME_SAMPLES: usize = TARGET_RATE as usize * FRAME_MS as usize / 1000;
/// Frames spent calibrating the initial noise floor at session open.
const CALIBRATION_FRAMES: u32 = 4;

/// Tuning knobs; [`VadConfig::default`] is the supported setting.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VadConfig {
    /// RMS above `floor * open_ratio` starts speech.
    pub open_ratio: f32,
    /// Hysteresis: RMS below `floor * close_ratio` (while speaking) lets a
    /// silence run start.
    pub close_ratio: f32,
    /// Lower bound for the adapted noise floor (quiet-room floor).
    pub min_floor: f32,
    /// Upper bound for the adapted noise floor — keeps the open gate within
    /// reach of normal speech even in a loud room.
    pub max_floor: f32,
    /// Per-frame EMA weight of the floor while silent.
    pub adapt_alpha: f32,
    /// Per-frame EMA weight of the floor while calibrating.
    pub calibrate_alpha: f32,
    /// Grace after the last voiced frame before `speaking` turns off.
    pub hangover_ms: u64,
}

impl Default for VadConfig {
    fn default() -> Self {
        Self {
            open_ratio: 3.0,
            close_ratio: 1.6,
            min_floor: 1e-3,
            max_floor: 2e-2,
            adapt_alpha: 0.05,
            calibrate_alpha: 0.3,
            hangover_ms: 240,
        }
    }
}

/// What one analyzed frame says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VadDecision {
    /// This frame is speech energy (the hallucination gate).
    pub voiced: bool,
    /// The smoothed speaking state, after hangover.
    pub speaking: bool,
    /// Cumulative silence since the last voiced frame.
    pub silence_ms: u64,
}

pub struct Vad {
    config: VadConfig,
    floor: f32,
    speaking: bool,
    silence_ms: u64,
    frames_seen: u32,
}

impl Vad {
    pub fn new(config: VadConfig) -> Self {
        Self {
            floor: config.min_floor,
            config,
            speaking: false,
            silence_ms: 0,
            frames_seen: 0,
        }
    }

    /// Analyze one [`FRAME_SAMPLES`]-long frame of 16 kHz mono s16.
    pub fn push(&mut self, frame: &[i16]) -> VadDecision {
        let rms = frame_rms(frame);
        self.frames_seen += 1;

        if self.frames_seen <= CALIBRATION_FRAMES {
            // Session open: learn the room, never report speech.
            self.adapt_floor(rms, self.config.calibrate_alpha);
            self.silence_ms += FRAME_MS;
            return VadDecision {
                voiced: false,
                speaking: false,
                silence_ms: self.silence_ms,
            };
        }

        let voiced = if self.speaking {
            rms > self.floor * self.config.close_ratio
        } else {
            rms > self.floor * self.config.open_ratio
        };

        if voiced {
            // Speech resets the silence clock; the floor stays frozen so
            // the voice itself cannot raise the bar against it.
            self.silence_ms = 0;
            self.speaking = true;
        } else {
            self.silence_ms += FRAME_MS;
            if self.speaking && self.silence_ms > self.config.hangover_ms {
                self.speaking = false;
            }
            if !self.speaking {
                self.adapt_floor(rms, self.config.adapt_alpha);
            }
        }

        VadDecision {
            voiced,
            speaking: self.speaking,
            silence_ms: self.silence_ms,
        }
    }

    fn adapt_floor(&mut self, rms: f32, alpha: f32) {
        self.floor = (self.floor + alpha * (rms - self.floor))
            .clamp(self.config.min_floor, self.config.max_floor);
    }
}

fn frame_rms(frame: &[i16]) -> f32 {
    if frame.is_empty() {
        return 0.0;
    }
    let sum = frame
        .iter()
        .map(|s| {
            let v = f32::from(*s) / 32_768.0;
            v * v
        })
        .sum::<f32>();
    (sum / frame.len() as f32).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic 440 Hz tone frames at the given amplitude.
    fn tone(amplitude: f32, frames: usize) -> Vec<Vec<i16>> {
        (0..frames)
            .map(|i| {
                (0..FRAME_SAMPLES)
                    .map(|k| {
                        let t = (i * FRAME_SAMPLES + k) as f32 / TARGET_RATE as f32;
                        to_test_s16(amplitude * (2.0 * std::f32::consts::PI * 440.0 * t).sin())
                    })
                    .collect()
            })
            .collect()
    }

    fn zeros(frames: usize) -> Vec<Vec<i16>> {
        vec![vec![0; FRAME_SAMPLES]; frames]
    }

    fn to_test_s16(v: f32) -> i16 {
        (v.clamp(-1.0, 1.0) * 32_767.0).round() as i16
    }

    fn decisions(config: VadConfig, frames: &[Vec<i16>]) -> Vec<VadDecision> {
        let mut vad = Vad::new(config);
        frames.iter().map(|f| vad.push(f)).collect()
    }

    #[test]
    fn pure_silence_stays_silent_and_accumulates() {
        let out = decisions(VadConfig::default(), &zeros(8));
        assert!(out.iter().all(|d| !d.voiced && !d.speaking));
        // Silence accumulates in frame steps: 100, 200, ...
        assert_eq!(out[3].silence_ms, 400);
        assert_eq!(out[7].silence_ms, 800);
    }

    #[test]
    fn calibration_absorbs_steady_noise_from_session_start() {
        // Fan-level noise from frame one: the calibration frames learn it,
        // and it never counts as speech.
        let noise = tone(0.014, 20); // sine RMS = 0.014 / sqrt(2) ≈ 0.010
        let out = decisions(VadConfig::default(), &noise);
        assert!(
            out.iter().all(|d| !d.speaking),
            "steady noise must stay silent, got {:?}",
            out.iter().map(|d| d.speaking).collect::<Vec<_>>()
        );
    }

    #[test]
    fn speech_over_calibrated_noise_is_detected() {
        let config = VadConfig::default();
        let mut frames = tone(0.014, 6); // noise level first
        frames.extend(tone(0.6, 3)); // speech far above the floor
        let out = decisions(config, &frames);
        assert!(out[6].voiced, "speech frame counts as voiced");
        assert!(out[6].speaking, "speech opens the speaking state");
        assert_eq!(out[6].silence_ms, 0);
    }

    #[test]
    fn hangover_bridges_short_gaps_inside_speech() {
        let config = VadConfig::default();
        let mut frames = zeros(4); // calibration
        frames.extend(tone(0.6, 3)); // speaking: frames 4-6
        frames.extend(zeros(2)); // 200 ms gap < 240 ms hangover: frames 7-8
        frames.extend(tone(0.6, 1)); // resume: frame 9
        let out = decisions(config, &frames);
        assert!(
            out[7].speaking && out[8].speaking,
            "gap shorter than the hangover bridges"
        );
        assert_eq!(out[8].silence_ms, 200, "silence tracks but does not close");
        assert!(out[9].speaking);
        assert_eq!(out[9].silence_ms, 0);
    }

    #[test]
    fn silence_past_hangover_closes_the_speaking_state() {
        let config = VadConfig::default();
        let mut frames = zeros(4);
        frames.extend(tone(0.6, 3)); // frames 4-6
        frames.extend(zeros(6)); // frames 7-12: 600 ms ≫ 240 ms hangover
        let out = decisions(config, &frames);
        // Gap frames at 100 and 200 ms still speak; 300 ms closes.
        assert!(out[7].speaking && out[8].speaking);
        assert!(!out[9].speaking, "300 ms of silence closes the state");
        assert_eq!(out[12].silence_ms, 600);
    }

    #[test]
    fn resuming_speech_resets_the_silence_clock() {
        let config = VadConfig::default();
        let mut frames = zeros(4);
        frames.extend(tone(0.6, 2));
        frames.extend(zeros(5)); // close the state (500 ms)
        frames.extend(tone(0.6, 1));
        let out = decisions(config, &frames);
        assert!(!out[8].speaking);
        assert!(out[11].speaking);
        assert_eq!(out[11].silence_ms, 0, "silence restarts from zero");
        assert!(out[11].voiced);
    }
}
