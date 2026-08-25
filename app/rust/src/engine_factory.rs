//! Production engine assembly: which LLM and which inserter the real
//! engine runs with, decided from the layered config files.
//!
//! Lives outside `api.rs` so flutter_rust_bridge's codegen (which mirrors
//! the whole api module) does not pick these types up as part of the
//! Dart-facing surface.

use std::path::Path;
use std::sync::Arc;

use anyhow::anyhow;
use spokenrectifier_engine::RectifyLlm;
use spokenrectifier_insertion::{load_insertion_config, TargetInserter};

/// Which rectify LLM the real engine runs with.
pub enum LlmChoice {
    /// The `[llm]` config resolved a key: a real OpenAI-compatible
    /// client, streaming real rectifications.
    Real(Arc<dyn RectifyLlm>),
    /// No `[llm]` key anywhere: the scripted demo LLM (pure demo mode,
    /// real transcripts must never meet it — see [`llm_choice`]).
    ScriptedDemo,
}

/// Decide the real engine's LLM from the config directory: a resolved
/// `[llm]` key means the real client; no key means the scripted demo.
///
/// One combination is an error, not a fallback: an `[asr]` key with no
/// `[llm]` key would feed real transcripts to the demo script, showing
/// fake rectifications of the user's actual speech. Fail loudly instead
/// (the same "incomplete config is an error" rule the ASR side follows).
pub fn llm_choice(dir: Option<&Path>) -> anyhow::Result<LlmChoice> {
    let llm_key = llm_config(dir).map(|config| {
        config
            .model
            .resolve_key()
            .is_some_and(|key| !key.is_empty())
    })?;
    if !llm_key {
        if asr_key_resolves(dir)? {
            return Err(anyhow!(
                "the [asr] key is set but no [llm] key resolved: real \
                 transcripts cannot be rectified by the demo script; add \
                 api_key under [llm] in spokenrectifier.local.toml (or unset \
                 the [asr] key to keep the pure demo mode)"
            ));
        }
        return Ok(LlmChoice::ScriptedDemo);
    }
    let config = llm_config(dir)?;
    let llm = spokenrectifier_llm::OpenAiCompatLlm::new(config)
        .map_err(|err| anyhow!("LLM {}", err.0))?;
    Ok(LlmChoice::Real(Arc::new(llm)))
}

/// The production inserter for the real engine: the `[insertion]` config
/// over the Win32 layer (an erroring stub off Windows).
pub fn production_inserter(dir: Option<&Path>) -> anyhow::Result<Arc<TargetInserter>> {
    let config = match dir {
        Some(dir) => load_insertion_config(dir).map_err(|err| anyhow!("insertion {}", err.0))?,
        None => Default::default(),
    };
    Ok(Arc::new(TargetInserter::production(config)))
}

fn llm_config(dir: Option<&Path>) -> anyhow::Result<spokenrectifier_llm::LlmConfig> {
    match dir {
        Some(dir) => {
            spokenrectifier_llm::load_llm_config(dir).map_err(|err| anyhow!("LLM {}", err.0))
        }
        None => Ok(spokenrectifier_llm::LlmConfig::defaults()),
    }
}

fn asr_key_resolves(dir: Option<&Path>) -> anyhow::Result<bool> {
    let config = match dir {
        Some(dir) => {
            spokenrectifier_aliyun::load_asr_config(dir).map_err(|err| anyhow!("ASR {}", err.0))?
        }
        None => spokenrectifier_aliyun::AsrConfig::defaults(),
    };
    Ok(config.resolve_key().is_some_and(|key| !key.is_empty()))
}

/// [`llm_choice`] for the app's resolved config directory.
pub fn app_llm_choice() -> anyhow::Result<LlmChoice> {
    llm_choice(crate::engine_config::config_dir()?.as_deref())
}

/// [`production_inserter`] for the app's resolved config directory.
pub fn app_production_inserter() -> anyhow::Result<Arc<TargetInserter>> {
    production_inserter(crate::engine_config::config_dir()?.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(name);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn no_keys_anywhere_keeps_the_scripted_demo() {
        // The empty dir also pins api_key_env to an unset variable, so a
        // DEEPSEEK_API_KEY in the developer's shell cannot flip the verdict.
        let empty = dir("sr-factory-empty");
        std::fs::write(
            empty.join("spokenrectifier.local.toml"),
            "[llm]\napi_key_env = \"SR_TEST_UNSET_LLM_KEY\"\n[asr]\napi_key_env = \"SR_TEST_UNSET_ASR_KEY\"\n",
        )
        .unwrap();
        assert!(matches!(
            llm_choice(Some(&empty)).unwrap(),
            LlmChoice::ScriptedDemo
        ));
        std::fs::remove_dir_all(empty).unwrap();
    }

    #[test]
    fn a_resolved_llm_key_means_the_real_client() {
        let with_key = dir("sr-factory-llm-key");
        std::fs::write(
            with_key.join("spokenrectifier.local.toml"),
            "[llm]\napi_key = \"sk-test\"\n",
        )
        .unwrap();

        assert!(matches!(
            llm_choice(Some(&with_key)).unwrap(),
            LlmChoice::Real(_)
        ));
        std::fs::remove_dir_all(with_key).unwrap();
    }

    #[test]
    fn an_asr_key_without_an_llm_key_is_an_error_not_a_demo() {
        let mixed = dir("sr-factory-mixed");
        std::fs::write(
            mixed.join("spokenrectifier.local.toml"),
            "[asr]\napi_key = \"sk-asr\"\n[llm]\napi_key_env = \"SR_TEST_UNSET_LLM_KEY\"\n",
        )
        .unwrap();

        let err = match llm_choice(Some(&mixed)) {
            Err(err) => err.to_string(),
            Ok(_) => panic!("an ASR key without an LLM key must be an error"),
        };
        assert!(err.contains("[llm]"), "got: {err}");
        assert!(err.contains("[asr]"), "got: {err}");
        std::fs::remove_dir_all(mixed).unwrap();
    }

    #[test]
    fn an_empty_llm_key_string_counts_as_absent() {
        let empty_key = dir("sr-factory-empty-key");
        std::fs::write(
            empty_key.join("spokenrectifier.local.toml"),
            "[asr]\napi_key = \"sk-asr\"\n[llm]\napi_key = \"\"\n",
        )
        .unwrap();

        // Still the mixed case: the empty string must not pass as a key.
        assert!(llm_choice(Some(&empty_key)).is_err());
        std::fs::remove_dir_all(empty_key).unwrap();
    }

    #[test]
    fn the_production_inserter_loads_its_config() {
        let typing = dir("sr-factory-insertion");
        std::fs::write(
            typing.join("spokenrectifier.toml"),
            "[insertion]\nmode = \"typing\"\n",
        )
        .unwrap();

        // Building is the assertion: a bad mode or malformed file errors.
        production_inserter(Some(&typing)).unwrap();
        production_inserter(None).unwrap();
        std::fs::remove_dir_all(typing).unwrap();
    }
}
