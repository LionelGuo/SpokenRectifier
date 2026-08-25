//! Shared event formatting for the CLI drivers.

use spokenrectifier_engine::EngineEvent;

/// One-line rendering of an engine event, stable across the drivers.
pub fn fmt_event(event: &EngineEvent) -> String {
    match event {
        EngineEvent::SessionStateChanged { from, to } => format!("state {from} -> {to}"),
        EngineEvent::LiveTranscriptUpdated { text } => format!("live {text:?}"),
        EngineEvent::ParagraphMarked => "paragraph marked".to_string(),
        EngineEvent::RectifiedTextChunk { delta } => format!("chunk {delta:?}"),
        EngineEvent::PreviewTextUpdated { text } => format!("preview -> {text:?}"),
        EngineEvent::TextInserted { text } => format!("inserted {text:?}"),
        EngineEvent::Error { message } => format!("error {message:?}"),
    }
}
