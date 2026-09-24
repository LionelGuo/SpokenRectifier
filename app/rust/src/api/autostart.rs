//! The autostart domain (ticket 06, the oss-release map): the settings
//! window's 开机自启 switch over the one mechanism every Windows
//! per-user tool shares — the HKCU Run key. The registry IS the state:
//! the installer's checkbox and this switch write the same value, so
//! there is no second copy to drift (03 号票's single-source ruling).
//!
//! The written command is the bare exe, quoted — no arguments: login
//! boots exactly the app a double-click does (the orb per its own
//! ui.toml visibility). Windows-only by nature; elsewhere the switch
//! reads off and writes nowhere.

#[cfg(windows)]
use anyhow::anyhow;

#[cfg(windows)]
use windows::core::PCWSTR;
#[cfg(windows)]
use windows::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS, WIN32_ERROR};
#[cfg(windows)]
use windows::Win32::System::Registry::{
    RegCloseKey, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW, HKEY,
    HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_SAM_FLAGS, REG_SZ,
};

/// The Run subkey every autostart entry lives under.
#[cfg_attr(not(windows), allow(dead_code))]
const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";

/// The value name shared with the installer's task checkbox.
#[cfg_attr(not(windows), allow(dead_code))]
const VALUE_NAME: &str = "SpokenRectifier";

/// The value's name as UTF-16 — the registry's string currency on
/// Windows, unused elsewhere.
#[cfg(windows)]
fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain([0]).collect()
}

/// The Run value for an exe path: quoted, so a path with spaces stays
/// one command. Pure so the tests (and any platform) can check it.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn run_value(exe: &str) -> String {
    format!("\"{exe}\"")
}

/// Whether the Run key currently carries our value — the switch's
/// truth. Presence is the whole test: whatever data it holds was a
/// write someone meant. An unopenable key reads off (the switch can be
/// re-armed, not trusted).
pub fn autostart_enabled() -> bool {
    #[cfg(windows)]
    {
        with_run_key(KEY_QUERY_VALUE, |key| unsafe {
            let name: Vec<u16> = VALUE_NAME.encode_utf16().collect();
            RegQueryValueExW(key, PCWSTR::from_raw(name.as_ptr()), None, None, None, None).0
                == ERROR_SUCCESS.0
        })
        .unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// Turn autostart on (write the quoted exe) or off (delete the value).
/// Off is idempotent — a value already gone is the off we asked for.
/// Returns the re-read state, the switch's next paint.
pub fn set_autostart(enabled: bool) -> anyhow::Result<bool> {
    #[cfg(windows)]
    {
        if enabled {
            let exe = std::env::current_exe()
                .map_err(|err| anyhow!("cannot resolve the exe path: {err}"))?;
            // UTF-16 with the terminating NUL REG_SZ is read to, then
            // viewed as bytes for the wide write API.
            let value = wide(&run_value(&exe.display().to_string()));
            let bytes =
                unsafe { std::slice::from_raw_parts(value.as_ptr().cast::<u8>(), value.len() * 2) };
            with_run_key(KEY_SET_VALUE, |key| unsafe {
                let status = RegSetValueExW(
                    key,
                    PCWSTR::from_raw(wide(VALUE_NAME).as_ptr()),
                    None,
                    REG_SZ,
                    Some(bytes),
                );
                check(status, "cannot write the Run value")
            })??;
        } else {
            with_run_key(KEY_SET_VALUE, |key| unsafe {
                let status = RegDeleteValueW(key, PCWSTR::from_raw(wide(VALUE_NAME).as_ptr()));
                if status != ERROR_FILE_NOT_FOUND {
                    check(status, "cannot delete the Run value")?;
                }
                anyhow::Ok(())
            })??;
        }
        Ok(autostart_enabled())
    }
    #[cfg(not(windows))]
    {
        let _ = enabled;
        // Not this platform's feature: the switch reads off and stays
        // off (the returned state says so) instead of failing a toggle
        // the platform could never honor anyway.
        Ok(false)
    }
}

/// Run `body` against the Run subkey opened for `access`, closing it on
/// the way out whatever happened inside. The open itself is the one
/// error the caller sees flat; the body's own result rides inside.
#[cfg(windows)]
fn with_run_key<T>(
    access: REG_SAM_FLAGS,
    body: impl FnOnce(HKEY) -> T,
) -> Result<T, anyhow::Error> {
    let mut key = HKEY::default();
    let status = unsafe {
        RegOpenKeyExW(
            HKEY_CURRENT_USER,
            PCWSTR::from_raw(wide(RUN_KEY).as_ptr()),
            None,
            access,
            &mut key,
        )
    };
    check(status, "cannot open the Run key")?;
    let out = body(key);
    // Best effort: a close failure leaks one handle until process exit
    // — nothing downstream depends on noticing it.
    let _ = unsafe { RegCloseKey(key) };
    Ok(out)
}

/// A registry call's status: zero is success, anything else is an error
/// worth the code (the message stays actionable for the log).
#[cfg(windows)]
fn check(status: WIN32_ERROR, what: &str) -> Result<(), anyhow::Error> {
    if status.0 == ERROR_SUCCESS.0 {
        Ok(())
    } else {
        Err(anyhow!("{what}: error {}", status.0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_run_value_is_the_quoted_path() {
        // A space-bearing install path must stay one command.
        assert_eq!(
            run_value(r"C:\Users\某\AppData\Local\Programs\SpokenRectifier\spokenrectifier.exe"),
            r#""C:\Users\某\AppData\Local\Programs\SpokenRectifier\spokenrectifier.exe""#,
        );
    }

    #[cfg(not(windows))]
    #[test]
    fn off_platform_the_state_reads_off_and_stays_off() {
        assert!(!autostart_enabled());
        assert!(!set_autostart(true).unwrap());
    }
}
