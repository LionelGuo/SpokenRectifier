//! The `[asr]` section's shape: one common segment plus one sub-section
//! per vendor (ADR-0009). The common segment carries every decision all
//! providers share — `provider` (which sub-section is live), `model`,
//! `language`, the Bearer-style `api_key`/`api_key_env`, and `base_url`;
//! each vendor sub-section carries only its own fields, matching the
//! adapter crate boundaries. Switching `provider` never clears another
//! vendor's configuration.
//!
//! Layered like every section: defaults, then `spokenrectifier.toml`,
//! then `spokenrectifier.local.toml` (git-ignored; the only place a
//! secret-shaped field may live — the loader's guard rejects `api_key`,
//! any `*_key`, and `secret_id` in the shared file, and the save path
//! here writes them to the local file only).
//!
//! No compatibility layer (v1 unreleased): the old flat `[asr]`
//! `workspace_id`/`region` moved into `[asr.aliyun]` — an existing file
//! hand-edits once, per the ADR.
//!
//! Three submodules, one responsibility each: [`shape`] (the folded
//! types and their defaults), [`load`] (the layered read), and [`save`]
//! (the settings editor's write path). This module re-exports their
//! public surface unchanged.

mod load;
mod save;
mod shape;

#[cfg(test)]
mod testutil;

pub use load::load_asr_config;
pub use save::{
    AliyunEdit, AsrConnectionEdit, AzureEdit, TencentEdit, VolcengineEdit, save_asr_connection,
};
pub use shape::{
    ActiveCredentials, AliyunConfig, AsrConfig, AsrConfigError, AsrProviderKind, AzureConfig,
    TencentConfig, VolcengineConfig,
};
