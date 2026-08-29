//! Aliyun cloud ASR adapter for SpokenRectifier.
//!
//! This crate is the cloud half of the [`AsrProvider`] seam: the
//! qwen3-asr-flash-realtime model over DashScope's private realtime
//! WebSocket protocol (OpenAI-Realtime-shaped events, but a DashScope
//! endpoint and auth — deliberately not an OpenAI-compatible
//! assumption).
//!
//! The `[asr]` config the adapter reads (common segment plus this
//! vendor's `[asr.aliyun]` sub-section) lives in `spokenrectifier-asr`,
//! the schema owner; the session machinery (mic capture through the
//! local VAD, the hallucination send gate, bounded reconnects, the
//! graceful drain) lives there too. What remains here is the DashScope
//! dialect: the `session.update` that opens a recognition session (the
//! hotword dictionary riding as the transcription corpus), the
//! base64-PCM `input_audio_buffer.append` frames, and the server events
//! folding onto [`AsrEvent::Partial`] / [`AsrEvent::Final`], which the
//! engine folds into the live transcript exactly like the fake
//! providers' scripted text.
//!
//! The connection is an injectable seam ([`RealtimeConnect`]): production
//! speaks tokio-tungstenite, tests script both directions through plain
//! channels, keeping the protocol logic deterministic.
//!
//! [`AsrProvider`]: spokenrectifier_engine::AsrProvider
//! [`AsrEvent::Partial`]: spokenrectifier_engine::provider::asr::AsrEvent::Partial
//! [`AsrEvent::Final`]: spokenrectifier_engine::provider::asr::AsrEvent::Final
//! [`AsrEvent::Failed`]: spokenrectifier_engine::provider::asr::AsrEvent::Failed

mod provider;

pub use provider::AliyunAsr;

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
