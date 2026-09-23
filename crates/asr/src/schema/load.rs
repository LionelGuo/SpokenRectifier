//! The layered read: defaults, then `spokenrectifier.toml`, then
//! `spokenrectifier.local.toml`.

use std::path::PathBuf;

use serde::Deserialize;
use spokenrectifier_config::load_section_layers;

use super::shape::{AsrConfig, AsrConfigError, AsrProviderKind};

// -- file layering ----------------------------------------------------------

/// The `[asr]` overlay: the config crate loads it, this crate folds it.
/// Sub-sections overlay as whole tables (an overlay replaces the fields
/// it names, field by field, like every other section).
#[derive(Debug, Default, Deserialize)]
struct AsrSection {
    provider: Option<AsrProviderKind>,
    model: Option<String>,
    language: Option<String>,
    api_key: Option<String>,
    api_key_env: Option<String>,
    base_url: Option<String>,
    aliyun: Option<AliyunOverlay>,
    volcengine: Option<VolcengineOverlay>,
    tencent: Option<TencentOverlay>,
    azure: Option<AzureOverlay>,
}

#[derive(Debug, Default, Deserialize)]
struct AliyunOverlay {
    workspace_id: Option<String>,
    region: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct VolcengineOverlay {
    app_id: Option<String>,
    access_key: Option<String>,
    resource_id: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct TencentOverlay {
    app_id: Option<String>,
    secret_id: Option<String>,
    secret_key: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct AzureOverlay {
    region: Option<String>,
    endpoint_id: Option<String>,
}

/// Load the `[asr]` config from the layer files, wherever they live
/// among `dirs`: defaults, overlaid with `spokenrectifier.toml`, then
/// `spokenrectifier.local.toml` (which wins, and is the only layer a
/// secret may come from). Missing files are fine; malformed ones are an
/// error naming the file.
pub fn load_asr_config(dirs: &[PathBuf]) -> Result<AsrConfig, AsrConfigError> {
    let mut config = AsrConfig::defaults();
    let layers =
        load_section_layers::<AsrSection>(dirs, "asr").map_err(|err| AsrConfigError(err.0))?;
    for layer in layers {
        fold(&mut config, layer.value);
    }
    if config.model.trim().is_empty() {
        return Err(AsrConfigError(
            "[asr] model is empty: remove the field or name a real model".into(),
        ));
    }
    if config.language.trim().is_empty() {
        return Err(AsrConfigError(
            "[asr] language is empty: remove the field or name a real language".into(),
        ));
    }
    Ok(config)
}

/// Fold one overlay onto the defaults, field by field, sub-sections
/// included.
fn fold(config: &mut AsrConfig, section: AsrSection) {
    let AsrSection {
        provider,
        model,
        language,
        api_key,
        api_key_env,
        base_url,
        aliyun,
        volcengine,
        tencent,
        azure,
    } = section;
    if let Some(v) = provider {
        config.provider = v;
    }
    if let Some(v) = model {
        config.model = v;
    }
    if let Some(v) = language {
        config.language = v;
    }
    if let Some(v) = api_key {
        config.api_key = Some(v);
    }
    if let Some(v) = api_key_env {
        config.api_key_env = Some(v);
    }
    if let Some(v) = base_url {
        config.base_url = Some(v);
    }
    if let Some(overlay) = aliyun {
        if let Some(v) = overlay.workspace_id {
            config.aliyun.workspace_id = Some(v);
        }
        if let Some(v) = overlay.region {
            config.aliyun.region = v;
        }
    }
    if let Some(overlay) = volcengine {
        if let Some(v) = overlay.app_id {
            config.volcengine.app_id = Some(v);
        }
        if let Some(v) = overlay.access_key {
            config.volcengine.access_key = Some(v);
        }
        if let Some(v) = overlay.resource_id {
            config.volcengine.resource_id = v;
        }
    }
    if let Some(overlay) = tencent {
        if let Some(v) = overlay.app_id {
            config.tencent.app_id = Some(v);
        }
        if let Some(v) = overlay.secret_id {
            config.tencent.secret_id = Some(v);
        }
        if let Some(v) = overlay.secret_key {
            config.tencent.secret_key = Some(v);
        }
    }
    if let Some(overlay) = azure {
        if let Some(v) = overlay.region {
            config.azure.region = Some(v);
        }
        if let Some(v) = overlay.endpoint_id {
            config.azure.endpoint_id = Some(v);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::testutil::scratch;
    use spokenrectifier_config::{LOCAL_FILE, SHARED_FILE};

    #[test]
    fn common_and_sub_section_layers_override_field_by_field() {
        let dir = scratch("sr-asr-schema-layers");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[asr]\nprovider = \"volcengine\"\nmodel = \"big\"\n\
             [asr.aliyun]\nworkspace_id = \"llm-shared\"\nregion = \"cn-beijing\"\n",
        )
        .unwrap();
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[asr]\napi_key = \"sk-local\"\nlanguage = \"en\"\n\
             [asr.volcengine]\naccess_key = \"volc-secret\"\napp_id = \"42\"\n",
        )
        .unwrap();

        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.provider, AsrProviderKind::Volcengine);
        assert_eq!(config.model, "big");
        assert_eq!(config.language, "en");
        assert_eq!(config.api_key.as_deref(), Some("sk-local"));
        // Sub-sections fold from both files, each field on its own.
        assert_eq!(config.aliyun.workspace_id.as_deref(), Some("llm-shared"));
        assert_eq!(config.volcengine.access_key.as_deref(), Some("volc-secret"));
        assert_eq!(config.volcengine.app_id.as_deref(), Some("42"));
        // Untouched fields keep their defaults.
        assert_eq!(config.volcengine.resource_id, "volc.seedasr.sauc.duration");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_unknown_provider_is_a_load_error_naming_the_section() {
        let dir = scratch("sr-asr-schema-unknown-provider");
        std::fs::write(dir.join(SHARED_FILE), "[asr]\nprovider = \"wat\"\n").unwrap();

        let err = load_asr_config(std::slice::from_ref(&dir)).unwrap_err().0;
        assert!(err.contains("asr"), "got: {err}");
        assert!(err.contains("provider"), "got: {err}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_explicitly_emptied_model_or_language_is_a_load_error() {
        for field in ["model", "language"] {
            let dir = scratch("sr-asr-schema-empty");
            std::fs::write(dir.join(SHARED_FILE), format!("[asr]\n{field} = \"\"\n")).unwrap();
            let err = load_asr_config(std::slice::from_ref(&dir)).unwrap_err().0;
            assert!(err.contains(field), "{field}: got: {err}");
            std::fs::remove_dir_all(&dir).unwrap();
        }
    }
}
