//! Capture-format PCM to recognizer-format PCM: 16 kHz mono s16.
//!
//! Cloud ASR protocols (and the VAD) want one fixed format; capture
//! devices give whatever the OS negotiated (e.g. 48 kHz stereo f32 via
//! WASAPI shared mode). [`Resampler`] bridges the two, streaming chunk by
//! chunk with phase continuity — cpal delivers audio in arbitrary buffer
//! sizes, never aligned to output boundaries.

/// The one output format every consumer downstream of capture agrees on.
pub const TARGET_RATE: u32 = 16_000;

/// Streaming converter: downmix to mono and resample to
/// [`TARGET_RATE`] with linear interpolation.
pub struct Resampler {
    channels: usize,
    /// Input frames per output step (input_rate / target_rate).
    step: f64,
    /// Frames of downmixed mono audio not yet consumed, anchor frame first.
    mono: Vec<f32>,
    /// Position of the next output sample within `mono`, in frames.
    pos: f64,
}

impl Resampler {
    /// `channels` and `rate` describe the capture stream to convert from.
    pub fn new(channels: u16, rate: u32) -> Self {
        Self {
            channels: channels.max(1) as usize,
            step: f64::from(rate) / f64::from(TARGET_RATE),
            mono: Vec::new(),
            pos: 0.0,
        }
    }

    /// Feed one chunk of interleaved input samples; returns the output
    /// samples produced (possibly empty for short chunks).
    pub fn push(&mut self, interleaved: &[f32]) -> Vec<i16> {
        self.mono.extend(
            interleaved
                .chunks(self.channels)
                .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32),
        );
        let mut out = Vec::new();
        loop {
            let i = self.pos.floor() as usize;
            let frac = self.pos - self.pos.floor();
            // Interpolation needs mono[i + 1] unless we sit exactly on a
            // frame boundary; the last frame of a chunk otherwise waits
            // for the next chunk to arrive.
            if i >= self.mono.len() || (frac > 0.0 && i + 1 >= self.mono.len()) {
                break;
            }
            let value = if frac == 0.0 {
                self.mono[i]
            } else {
                self.mono[i] + (frac as f32) * (self.mono[i + 1] - self.mono[i])
            };
            out.push(to_s16(value));
            self.pos += self.step;
        }
        // Everything before the anchor frame of the next interpolation is
        // consumed; `pos` may legitimately have stepped past the buffered
        // frames (upsampling), so clamp.
        let consumed = (self.pos.floor() as usize).min(self.mono.len());
        self.mono.drain(..consumed);
        self.pos -= consumed as f64;
        out
    }
}

/// Map a [-1, 1] float sample to s16 with saturation.
fn to_s16(value: f32) -> i16 {
    (value.clamp(-1.0, 1.0) * 32_767.0).round() as i16
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Push 48 kHz stereo f32 (the typical WASAPI shared-mode capture
    /// format) through a fresh resampler and return all 16 kHz mono s16.
    fn stereo48(chunks: &[&[(f32, f32)]]) -> Vec<i16> {
        let mut r = Resampler::new(2, 48_000);
        let mut out = Vec::new();
        for chunk in chunks {
            let flat: Vec<f32> = chunk.iter().flat_map(|(l, rr)| [*l, *rr]).collect();
            out.extend(r.push(&flat));
        }
        out
    }

    #[test]
    fn passthrough_at_target_format_is_identity() {
        let mut r = Resampler::new(1, TARGET_RATE);
        let input: Vec<f32> = (0..16).map(|i| (i as f32) / 32.0 - 0.25).collect();
        let out = r.push(&input);
        // 16 in, 16 out: nothing is dropped at the tail.
        assert_eq!(out.len(), 16);
        let expected: Vec<i16> = input.iter().map(|v| to_s16(*v)).collect();
        assert_eq!(out, expected);
    }

    #[test]
    fn stereo_downmixes_to_the_channel_average() {
        // Left full-scale up, right full-scale down: silence out.
        let frames: Vec<(f32, f32)> = (0..4800).map(|_| (1.0, -1.0)).collect();
        let out = stereo48(&[&frames]);
        assert!(out.iter().all(|s| s.abs() <= 1), "got {:?}", &out[..8]);
        // And the 3:1 rate drop holds: 4800 in → 1600 out.
        assert_eq!(out.len(), 1600);
    }

    #[test]
    fn dc_level_survives_resampling() {
        let frames: Vec<(f32, f32)> = (0..9600).map(|_| (0.5, 0.5)).collect();
        let out = stereo48(&[&frames]);
        assert_eq!(out.len(), 3200);
        assert!(
            out.iter()
                .all(|s| (*s as i32 - to_s16(0.5) as i32).abs() <= 1)
        );
    }

    #[test]
    fn resampling_matches_the_reference_waveform() {
        // 100 Hz sine pushed through at capture rate, compared sample by
        // sample against the same signal synthesized directly at 16 kHz
        // (f64 reference; f32 phase error at this argument magnitude stays
        // within a couple of LSB).
        for rate in [48_000u32, 44_100] {
            let mut r = Resampler::new(1, rate);
            let mut out = Vec::new();
            for block in (0..rate as usize).step_by(960) {
                let end = (block + 960).min(rate as usize);
                let chunk: Vec<f32> = (block..end)
                    .map(|n| {
                        (2.0 * std::f32::consts::PI * 100.0 * n as f32 / rate as f32).sin() * 0.8
                    })
                    .collect();
                out.extend(r.push(&chunk));
            }
            assert_eq!(out.len(), 16_000, "one second out at {rate} in");
            for (n, sample) in out.iter().enumerate() {
                let reference =
                    (2.0 * std::f64::consts::PI * 100.0 * n as f64 / 16_000.0).sin() * 0.8;
                let expected = (reference * 32_767.0).round() as i32;
                assert!(
                    (*sample as i32 - expected).abs() <= 3,
                    "rate {rate}, sample {n}: {sample} vs {expected}"
                );
            }
        }
    }

    #[test]
    fn chunking_does_not_change_the_output() {
        // Arbitrary chunk boundaries vs one big push: identical samples.
        let input: Vec<f32> = (0..9_600)
            .map(|n| (2.0 * std::f32::consts::PI * 300.0 * n as f32 / 48_000.0).sin() * 0.5)
            .collect();
        let mut whole = Resampler::new(1, 48_000);
        let expected = whole.push(&input);

        let mut pieced = Resampler::new(1, 48_000);
        let mut actual = Vec::new();
        let mut i = 0;
        for size in [7usize, 1, 480, 13, 9_099, 4_000] {
            let end = (i + size).min(input.len());
            if i >= end {
                break;
            }
            actual.extend(pieced.push(&input[i..end]));
            i = end;
            if i >= input.len() {
                break;
            }
        }
        assert_eq!(actual.len(), expected.len());
        assert_eq!(actual, expected);
    }
}
