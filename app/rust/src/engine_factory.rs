//! Production engine assembly: which LLM and which inserter the real
//! engine runs with, decided from the layered config files.
//!
//! Lives outside `api.rs` so flutter_rust_bridge's codegen (which mirrors
//! the whole api module) does not pick these types up as part of the
//! Dart-facing surface.

use std::path::PathBuf;
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

/// Decide the real engine's LLM from the layered config files among
/// `dirs` (resolved once by the caller): a resolved `[llm]` key means the
/// real client; no key means the scripted demo.
///
/// One combination is an error, not a fallback: an `[asr]` key with no
/// `[llm]` key would feed real transcripts to the demo script, showing
/// fake rectifications of the user's actual speech. Fail loudly instead
/// (the same "incomplete config is an error" rule the ASR side follows).
pub fn llm_choice(dirs: &[PathBuf]) -> anyhow::Result<LlmChoice> {
    let config = llm_config(dirs)?;
    let llm_key = config
        .model
        .resolve_key()
        .is_some_and(|key| !key.is_empty());
    if !llm_key {
        if asr_key_resolves(dirs)? {
            return Err(anyhow!(
                "the [asr] key is set but no [llm] key resolved: real \
                 transcripts cannot be rectified by the demo script; add \
                 api_key under [llm] in spokenrectifier.local.toml (or unset \
                 the [asr] key to keep the pure demo mode)"
            ));
        }
        if config.endpoint_configured {
            return Err(anyhow!(
                "the [llm] config names a model but no api key resolved: add \
                 api_key under [llm] in spokenrectifier.local.toml (or export \
                 the api_key_env variable)"
            ));
        }
        return Ok(LlmChoice::ScriptedDemo);
    }
    let llm = spokenrectifier_llm::OpenAiCompatLlm::new(config)
        .map_err(|err| anyhow!("LLM {}", err.0))?;
    Ok(LlmChoice::Real(Arc::new(llm)))
}

/// The production inserter for the real engine: the `[insertion]` config
/// over the Win32 layer (an erroring stub off Windows).
pub fn production_inserter(dirs: &[PathBuf]) -> anyhow::Result<Arc<TargetInserter>> {
    let config = load_insertion_config(dirs).map_err(|err| anyhow!("insertion {}", err.0))?;
    Ok(Arc::new(TargetInserter::production(config)))
}

fn llm_config(dirs: &[PathBuf]) -> anyhow::Result<spokenrectifier_llm::LlmConfig> {
    spokenrectifier_llm::load_llm_config(dirs).map_err(|err| anyhow!("LLM {}", err.0))
}

fn asr_key_resolves(dirs: &[PathBuf]) -> anyhow::Result<bool> {
    let config =
        spokenrectifier_aliyun::load_asr_config(dirs).map_err(|err| anyhow!("ASR {}", err.0))?;
    Ok(config.resolve_key().is_some_and(|key| !key.is_empty()))
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
            llm_choice(std::slice::from_ref(&empty)).unwrap(),
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
            llm_choice(std::slice::from_ref(&with_key)).unwrap(),
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

        let err = match llm_choice(std::slice::from_ref(&mixed)) {
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
        assert!(llm_choice(std::slice::from_ref(&empty_key)).is_err());
        std::fs::remove_dir_all(empty_key).unwrap();
    }

    /// A configured endpoint without a key must not silently fall into the
    /// demo script: the user asked for a real model and would read the
    /// scripted output as broken rectification.
    #[test]
    fn an_endpoint_without_a_key_is_an_error_not_a_demo() {
        let no_key = dir("sr-factory-no-key");
        std::fs::write(
            no_key.join("spokenrectifier.local.toml"),
            "[llm]\nmodel = \"deepseek-v4-pro\"\napi_key_env = \"SR_TEST_UNSET_LLM_KEY\"\n",
        )
        .unwrap();

        let err = match llm_choice(std::slice::from_ref(&no_key)) {
            Err(err) => err.to_string(),
            Ok(_) => panic!("a configured endpoint without a key must be an error"),
        };
        assert!(err.contains("[llm]"), "got: {err}");
        assert!(err.contains("api_key"), "got: {err}");
        assert!(err.contains("spokenrectifier.local.toml"), "got: {err}");
        std::fs::remove_dir_all(no_key).unwrap();
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
        production_inserter(std::slice::from_ref(&typing)).unwrap();
        production_inserter(&[]).unwrap();
        std::fs::remove_dir_all(typing).unwrap();
    }
}
