//! Microphone capture and VAD for SpokenRectifier.
//!
//! This crate is the audio side of the [`AsrProvider`] seam: real audio in,
//! [`AsrEvent`]s out. Until the cloud ASR adapter lands, [`MicVadAsr`] is
//! the provider the shell runs — it recognizes no text, but carries the
//! session semantics that do not need text: speech activity (the orb's
//! speaking state), silence accumulation (paragraph marks / auto-end), and
//! device failure feedback.
//!
//! The hallucination gate: a frame is only ever handed to a recognizer when
//! the VAD classifies it as speech. [`Vad`] exposes that per-frame
//! `voiced` decision; the cloud adapter will forward frames by it, so
//! long silence and ambient noise never become recognition input (the
//! classic " Whisper-at-the-void hallucination" failure mode).
//!
//! VAD approach: energy (RMS) with an adaptive noise floor, hysteresis, and
//! a hangover — chosen over a model-based VAD (e.g. Silero) to keep the
//! dependency graph native-pure and the tests deterministic on synthetic
//! PCM. If quality proves insufficient in the field, [`Vad`] is the single
//! swap point.
//!
//! [`AsrProvider`]: spokenrectifier_engine::AsrProvider
//! [`AsrEvent`]: spokenrectifier_engine::AsrEvent

mod convert;
mod mic;
mod provider;
mod vad;

pub use convert::{Resampler, TARGET_RATE};
pub use mic::{MicEvent, open as open_mic};
pub use provider::{FrameSource, FrameStream, MicVadAsr};
pub use vad::{FRAME_MS, FRAME_SAMPLES, Vad, VadConfig, VadDecision};
