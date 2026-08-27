//! Text insertion collaborator (glossary: 预览窗 → 目标输入框).
//!
//! The real adapter pastes at the cursor (clipboard save/restore) with a
//! type-out fallback; the engine only hands over the confirmed text.

use async_trait::async_trait;

#[derive(Debug, thiserror::Error)]
#[error("text insertion failed: {0}")]
pub struct InsertError(pub String);

#[async_trait]
pub trait TextInserter: Send + Sync + 'static {
    async fn insert(&self, text: &str) -> Result<(), InsertError>;

    /// Hand the keyboard back to the remembered target when a session
    /// ends without inserting (cancel, rectify failure): the panel
    /// borrowed the foreground for its affordances, and the user types
    /// straight back into their document instead of clicking it first.
    /// Best-effort and self-guarding — implementations must leave the
    /// focus alone unless they are the ones holding it.
    fn restore_focus(&self) {}
}
