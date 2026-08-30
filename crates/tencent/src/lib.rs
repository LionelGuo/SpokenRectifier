//! Tencent Cloud ASR adapter for SpokenRectifier.
//!
//! This crate is the cloud half of the [`AsrProvider`] seam: realtime
//! speech recognition over the `asr/v2` WebSocket — the whole
//! configuration riding a per-attempt HMAC-SHA1-signed URL
//! (app id in the path, SecretId/timestamp/nonce/voice id in the
//! query, SecretKey as the signing key), audio as binary PCM frames,
//! the graceful end as one text message, results as JSON text with
//! `slice_type` marking each slice's stability.
//!
//! The `[asr]` config it reads (common segment plus the
//! `[asr.tencent]` sub-section) lives in `spokenrectifier-asr`, the
//! schema owner; the session machinery (mic capture through the local
//! VAD, the hallucination send gate, bounded reconnects, the graceful
//! drain) lives there too. What remains here is the dialect: the URL
//! signing ([`sign`]) and the protocol translation ([`protocol`]) —
//! server slices folding onto
//! [`AsrEvent::Partial`]/[`AsrEvent::Final`], which the engine folds
//! into the live transcript exactly like every other provider's text.
//!
//! The connection is an injectable seam ([`RealtimeConnect`]):
//! production speaks tokio-tungstenite, tests script both directions
//! through plain channels, keeping the protocol logic deterministic.
//!
//! [`AsrProvider`]: spokenrectifier_engine::AsrProvider
//! [`AsrEvent::Partial`]: spokenrectifier_engine::provider::asr::AsrEvent::Partial
//! [`AsrEvent::Final`]: spokenrectifier_engine::provider::asr::AsrEvent::Final

mod protocol;
mod provider;
mod sign;

pub use protocol::{OutFrame, TencentWire};
pub use provider::TencentAsr;
pub use spokenrectifier_asr::transport::{ConnectError, RealtimeChannel, RealtimeConnect};

/// Synthetic 100 ms frame builders for the crate's deterministic tests —
/// the same shape the audio crate's tests use, kept local because its
/// helpers are `pub(crate)`.
#[cfg(test)]
pub(crate) mod test_support {
    use spokenrectifier_audio::{FRAME_SAMPLES, TARGET_RATE};

    /// `count` consecutive 440 Hz tone frames at `amplitude`; phase
    /// continues across frames so bursts look like one signal.
    pub(crate) fn tone_frames(amplitude: f32, count: usize) -> Vec<Vec<i16>> {
        (0..count).map(|i| tone_frame(amplitude, i)).collect()
    }

    fn tone_frame(amplitude: f32, frame_index: usize) -> Vec<i16> {
        (0..FRAME_SAMPLES)
            .map(|k| {
                let t = (frame_index * FRAME_SAMPLES + k) as f32 / TARGET_RATE as f32;
                let v = amplitude * (2.0 * std::f32::consts::PI * 440.0 * t).sin();
                (v * 32_768.0).round().clamp(-32_768.0, 32_767.0) as i16
            })
            .collect()
    }

    /// `count` silent frames.
    pub(crate) fn zero_frames(count: usize) -> Vec<Vec<i16>> {
        vec![vec![0; FRAME_SAMPLES]; count]
    }
}
