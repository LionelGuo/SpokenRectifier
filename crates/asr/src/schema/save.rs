//! The settings editor's write path: the whole `[asr]` card.

use std::path::PathBuf;

use spokenrectifier_config::section_write::{
    KeyEdit, SectionField, WriteLayer, write_section_fields,
};

use super::shape::{AsrConfigError, AsrProviderKind};

// -- the settings editor's write path (ticket 24) -----------------------------

/// One optional string field: an all-whitespace value is an absent one.
fn trimmed(value: &Option<String>) -> Option<String> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

/// `[asr.aliyun]`'s editor fields.
#[derive(Debug, Clone, PartialEq)]
pub struct AliyunEdit {
    /// A Bailian workspace id; `None` = the shared DashScope domain.
    pub workspace_id: Option<String>,
    pub region: String,
}

/// `[asr.volcengine]`'s editor fields.
#[derive(Debug, Clone, PartialEq)]
pub struct VolcengineEdit {
    /// The console app id; `None` = unset.
    pub app_id: Option<String>,
    pub resource_id: String,
    pub access_key: KeyEdit,
}

/// `[asr.tencent]`'s editor fields.
#[derive(Debug, Clone, PartialEq)]
pub struct TencentEdit {
    pub app_id: Option<String>,
    pub secret_id: KeyEdit,
    pub secret_key: KeyEdit,
}

/// `[asr.azure]`'s editor fields.
#[derive(Debug, Clone, PartialEq)]
pub struct AzureEdit {
    pub region: Option<String>,
    pub endpoint_id: Option<String>,
}

/// What the connection editor writes back: the whole `[asr]` card —
/// common fields plus every vendor sub-section, so a provider switch
/// never clears another vendor's configuration. Saving writes exactly
/// this model, so the next load returns what the user saw.
#[derive(Debug, Clone, PartialEq)]
pub struct AsrConnectionEdit {
    pub provider: AsrProviderKind,
    pub model: String,
    pub language: String,
    /// A full host override; `None` = the provider's derived endpoint.
    pub base_url: Option<String>,
    pub api_key: KeyEdit,
    pub aliyun: AliyunEdit,
    pub volcengine: VolcengineEdit,
    pub tencent: TencentEdit,
    pub azure: AzureEdit,
}

/// One required string: trimmed, and an error naming the field when the
/// editor's model carries nothing usable.
fn required(section: &str, field: &str, value: &str) -> Result<String, AsrConfigError> {
    let value = value.trim();
    if value.is_empty() {
        Err(AsrConfigError(format!(
            "[{section}] {field} is empty: name a real value"
        )))
    } else {
        Ok(value.to_string())
    }
}

/// An optional field's wire form: the trimmed value, or a reset (the
/// key leaves every layer, back to the built-in default).
fn optional(field: &str, value: Option<String>) -> SectionField {
    match trimmed(&value) {
        Some(value) => SectionField::str(field, value),
        None => SectionField::reset(field),
    }
}

/// Write the connection editor's model back into the layer files. The
/// non-secret fields land in the layer that owns their section
/// (section-preserving, per section: common and each sub-section
/// independently); every secret-shaped field lands in the local file
/// only — never the committable shared file, whose loader rejects the
/// whole ASR field set outright (the layering ironclad, ADR-0009).
pub fn save_asr_connection(
    dirs: &[PathBuf],
    edit: &AsrConnectionEdit,
) -> Result<(), AsrConfigError> {
    let model = required("asr", "model", &edit.model)?;
    let language = required("asr", "language", &edit.language)?;
    let region = required("asr.aliyun", "region", &edit.aliyun.region)?;
    let resource_id = required(
        "asr.volcengine",
        "resource_id",
        &edit.volcengine.resource_id,
    )?;

    let write = |section: &str, fields: &[SectionField]| {
        write_section_fields(dirs, section, fields, WriteLayer::Owning)
            .map_err(|err| AsrConfigError(err.0))
    };

    write(
        "asr",
        &[
            SectionField::str("provider", edit.provider.as_str()),
            SectionField::str("model", model),
            SectionField::str("language", language),
            optional("base_url", edit.base_url.clone()),
        ],
    )?;
    write(
        "asr.aliyun",
        &[
            optional("workspace_id", edit.aliyun.workspace_id.clone()),
            SectionField::str("region", region),
        ],
    )?;
    write(
        "asr.volcengine",
        &[
            optional("app_id", edit.volcengine.app_id.clone()),
            SectionField::str("resource_id", resource_id),
        ],
    )?;
    edit.volcengine
        .access_key
        .clone()
        .write_to_local(dirs, "asr.volcengine", "access_key")
        .map_err(|err| AsrConfigError(err.0))?;
    write(
        "asr.tencent",
        &[optional("app_id", edit.tencent.app_id.clone())],
    )?;
    for (field, edit_value) in [
        ("secret_id", &edit.tencent.secret_id),
        ("secret_key", &edit.tencent.secret_key),
    ] {
        edit_value
            .clone()
            .write_to_local(dirs, "asr.tencent", field)
            .map_err(|err| AsrConfigError(err.0))?;
    }
    write(
        "asr.azure",
        &[
            optional("region", edit.azure.region.clone()),
            optional("endpoint_id", edit.azure.endpoint_id.clone()),
        ],
    )?;
    edit.api_key
        .clone()
        .write_to_local(dirs, "asr", "api_key")
        .map_err(|err| AsrConfigError(err.0))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::load::load_asr_config;
    use crate::schema::testutil::scratch;
    use spokenrectifier_config::{LOCAL_FILE, SHARED_FILE};

    fn edit() -> AsrConnectionEdit {
        AsrConnectionEdit {
            provider: AsrProviderKind::Aliyun,
            model: "qwen3-asr-flash-realtime".into(),
            language: "zh".into(),
            base_url: None,
            api_key: KeyEdit::Keep,
            aliyun: AliyunEdit {
                workspace_id: None,
                region: "cn-beijing".into(),
            },
            volcengine: VolcengineEdit {
                app_id: None,
                resource_id: "volc.seedasr.sauc.duration".into(),
                access_key: KeyEdit::Keep,
            },
            tencent: TencentEdit {
                app_id: None,
                secret_id: KeyEdit::Keep,
                secret_key: KeyEdit::Keep,
            },
            azure: AzureEdit {
                region: None,
                endpoint_id: None,
            },
        }
    }

    // -- the settings editor's write path (ticket 24) ----------------------
    #[test]
    fn a_volcengine_save_writes_the_sub_sections_and_keeps_the_key_local() {
        let dir = scratch("sr-asr-save-volcengine");
        let mut model = edit();
        model.provider = AsrProviderKind::Volcengine;
        model.model = "volc.seedasr.sauc.duration".into();
        model.volcengine.app_id = Some("42".into());
        model.volcengine.access_key = KeyEdit::Set("volc-secret".into());
        model.tencent.secret_id = KeyEdit::Set("tencent-id".into());

        save_asr_connection(std::slice::from_ref(&dir), &model).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(
            shared.contains("provider = \"volcengine\""),
            "got: {shared}"
        );
        assert!(shared.contains("[asr.aliyun]"), "got: {shared}");
        assert!(shared.contains("region = \"cn-beijing\""), "got: {shared}");
        assert!(shared.contains("[asr.volcengine]"), "got: {shared}");
        assert!(shared.contains("app_id = \"42\""), "got: {shared}");
        assert!(shared.contains("resource_id"), "got: {shared}");
        assert!(!shared.contains("access_key"), "secret leaked: {shared}");
        assert!(!shared.contains("secret_id"), "secret leaked: {shared}");

        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(
            local.contains("[asr.volcengine]"),
            "sub-section not local: {local}"
        );
        assert!(
            local.contains("access_key = \"volc-secret\""),
            "got: {local}"
        );
        assert!(local.contains("[asr.tencent]"), "got: {local}");
        assert!(local.contains("secret_id = \"tencent-id\""), "got: {local}");

        // The load passes the guard and returns the saved world.
        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.provider, AsrProviderKind::Volcengine);
        assert_eq!(config.volcengine.app_id.as_deref(), Some("42"));
        assert_eq!(config.volcengine.access_key.as_deref(), Some("volc-secret"));
        assert_eq!(config.tencent.secret_id.as_deref(), Some("tencent-id"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The ironclad for the extended field set: a GUI save may never
    /// leave an ASR credential in the committable shared file — and
    /// whatever it writes must still load (the loader's guard would
    /// reject the file outright).
    #[test]
    fn a_saved_secret_never_lands_in_shared_however_the_layers_sit() {
        let dir = scratch("sr-asr-save-ironclad");
        // Shared owns every ASR section (no local file exists): the
        // owning writes target shared, the secret writes must not follow.
        std::fs::write(
            dir.join(SHARED_FILE),
            "[asr]\nmodel = \"m\"\n[asr.volcengine]\napp_id = \"42\"\n",
        )
        .unwrap();

        let mut model = edit();
        model.volcengine.access_key = KeyEdit::Set("volc-secret".into());
        model.tencent.secret_key = KeyEdit::Set("signing".into());
        save_asr_connection(std::slice::from_ref(&dir), &model).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(!shared.contains("access_key"), "leaked: {shared}");
        assert!(!shared.contains("secret_key"), "leaked: {shared}");
        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(
            local.contains("access_key = \"volc-secret\""),
            "got: {local}"
        );
        assert!(local.contains("secret_key = \"signing\""), "got: {local}");
        load_asr_config(std::slice::from_ref(&dir)).unwrap();
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_key_keep_touches_no_local_file_and_a_clear_strips_it() {
        let dir = scratch("sr-asr-save-keep");
        save_asr_connection(std::slice::from_ref(&dir), &edit()).unwrap();
        assert!(dir.join(SHARED_FILE).is_file());
        assert!(!dir.join(LOCAL_FILE).exists(), "keep created a local file");

        let dir = scratch("sr-asr-save-clear");
        std::fs::write(
            dir.join(LOCAL_FILE),
            "[asr]\napi_key = \"sk-old\"\n[asr.volcengine]\naccess_key = \"volc-old\"\n",
        )
        .unwrap();
        let mut model = edit();
        model.api_key = KeyEdit::Clear;
        model.volcengine.access_key = KeyEdit::Clear;
        save_asr_connection(std::slice::from_ref(&dir), &model).unwrap();

        let local = std::fs::read_to_string(dir.join(LOCAL_FILE)).unwrap();
        assert!(!local.contains("api_key"), "not cleared: {local}");
        assert!(!local.contains("access_key"), "not cleared: {local}");
        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.api_key, None);
        assert_eq!(config.volcengine.access_key, None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_cleared_optional_sub_field_resets_in_every_layer() {
        let dir = scratch("sr-asr-save-reset");
        std::fs::write(
            dir.join(SHARED_FILE),
            "[asr]\nbase_url = \"wss://old.example.com\"\n[asr.aliyun]\nworkspace_id = \"llm-x\"\n",
        )
        .unwrap();
        let mut model = edit();
        model.base_url = Some("   ".into()); // whitespace = reset
        save_asr_connection(std::slice::from_ref(&dir), &model).unwrap();

        let shared = std::fs::read_to_string(dir.join(SHARED_FILE)).unwrap();
        assert!(!shared.contains("base_url"), "not reset: {shared}");
        assert!(!shared.contains("workspace_id"), "not reset: {shared}");
        let config = load_asr_config(std::slice::from_ref(&dir)).unwrap();
        assert_eq!(config.base_url, None);
        assert_eq!(config.aliyun.workspace_id, None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_empty_required_field_is_refused_and_writes_nothing() {
        for (field, broken) in [("model", "  "), ("language", "")] {
            let dir = scratch("sr-asr-save-empty");
            let mut model = edit();
            match field {
                "model" => model.model = broken.into(),
                _ => model.language = broken.into(),
            }
            let err = save_asr_connection(std::slice::from_ref(&dir), &model)
                .unwrap_err()
                .0;
            assert!(err.contains(field), "got: {err}");
            assert!(!dir.join(SHARED_FILE).exists(), "wrote on a refused save");
            assert!(!dir.join(LOCAL_FILE).exists());
            std::fs::remove_dir_all(&dir).unwrap();
        }

        let dir = scratch("sr-asr-save-empty-resource");
        let mut model = edit();
        model.volcengine.resource_id = " ".into();
        let err = save_asr_connection(std::slice::from_ref(&dir), &model)
            .unwrap_err()
            .0;
        assert!(err.contains("resource_id"), "got: {err}");
        assert!(!dir.join(SHARED_FILE).exists(), "wrote on a refused save");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
