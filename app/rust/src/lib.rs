//! The flutter_rust_bridge seam between the Flutter shell and the engine,
//! compiled as the cdylib the app loads (see `api.rs` for the surface).

mod api;
mod engine_config;
mod engine_factory;
mod history;

pub use api::*;

mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
