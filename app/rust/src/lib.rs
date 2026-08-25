//! cdylib shell for the Flutter app. All flutter_rust_bridge surface lives
//! in the `spokenrectifier-bridge` crate; this crate only wraps it into the
//! dynamic/static library cargokit links into the Windows runner.

pub use spokenrectifier_bridge::*;
