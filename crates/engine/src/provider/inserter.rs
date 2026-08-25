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
}
