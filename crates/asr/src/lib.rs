//! The ASR layer shared by every cloud adapter: the `[asr]` config
//! schema (common segment + one sub-section per vendor, ADR-0009) and
//! the streaming session machinery the adapters run on.
//!
//! The schema ([`schema`]) is the single owner of the `[asr]` section's
//! shape — the vendor crates read the folded [`AsrConfig`] and take the
//! pieces that are theirs (their sub-section plus the common fields
//! their protocol uses); the settings editor's whole-card write path
//! lives here too. Secret-shaped fields (`api_key`, any `*_key`,
//! `secret_id`) are local-layer-only: the loader's guard rejects them
//! in the shared file and the save path writes them to the local file.
//!
//! The session machinery ([`session`], [`gate`], [`transport`]) is
//! vendor-blind: mic capture through the local VAD, the hallucination
//! send gate, bounded reconnects with an offline audio buffer, a
//! graceful drain on session end. Each adapter supplies its dialect as
//! a [`WireProtocol`] — one module of pure payload translation per
//! vendor (DashScope JSON in `spokenrectifier-aliyun`, Volcengine's
//! gzip'd binary frames in `spokenrectifier-volcengine`).

pub mod gate;
pub mod schema;
pub mod session;
pub mod transport;

pub use gate::{PAD_MS, SendGate};
pub use schema::{
    ActiveCredentials, AliyunConfig, AliyunEdit, AsrConfig, AsrConfigError, AsrConnectionEdit,
    AsrProviderKind, AzureConfig, AzureEdit, TencentConfig, TencentEdit, VolcengineConfig,
    VolcengineEdit, load_asr_config, save_asr_connection,
};
pub use session::{SessionParams, WireProtocol, open_session};
pub use transport::{
    BytesWire, ConnectError, RealtimeChannel, RealtimeConnect, TextWire, TungsteniteConnect,
    WireCodec,
};

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
