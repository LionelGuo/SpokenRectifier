//! The about domain (关于, ticket 19): the version/license card and the
//! shared config file's editor entry.

use anyhow::anyhow;

/// What the about pane paints. The version is the app crate's manifest
/// (kept in step with the Flutter `pubspec.yaml` — bump both together).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeAbout {
    pub version: String,
    pub license: String,
    /// The public repository; absent until the open-source packaging
    /// (ticket 11) names one.
    pub repo_url: Option<String>,
}

/// The about pane's one read (version, license, repository).
pub fn about() -> BridgeAbout {
    BridgeAbout {
        version: env!("CARGO_PKG_VERSION").to_string(),
        license: "Apache-2.0".to_string(),
        repo_url: None,
    }
}

/// Open the shared config file in the system text editor — the tray's
/// settings entry. Creates a commented stub first when no config file
/// exists yet (see `settings::ensure_shared_config` for where). Returns
/// the path that was opened.
pub fn open_config_file() -> anyhow::Result<String> {
    let dirs = spokenrectifier_config::search_dirs();
    let path = crate::settings::ensure_shared_config(&dirs)
        .map_err(|err| anyhow!("cannot create the config file: {err}"))?;
    launch_editor(&path)?;
    Ok(path.display().to_string())
}

/// Hand the file to the platform's editor: Notepad ships with every
/// Windows, `xdg-open` covers the development desktops.
fn launch_editor(path: &std::path::Path) -> anyhow::Result<()> {
    #[cfg(windows)]
    let mut command = std::process::Command::new("notepad");
    #[cfg(not(windows))]
    let mut command = std::process::Command::new("xdg-open");
    command
        .arg(path)
        .spawn()
        .map_err(|err| anyhow!("cannot open an editor for {}: {err}", path.display()))?;
    Ok(())
}
