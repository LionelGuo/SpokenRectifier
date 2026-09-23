//! Test helpers shared by the three submodules' test modules.

use std::path::PathBuf;

use serde_json::Value;

use super::shape::LlmConfig;
use crate::assembly::request_body;

pub(crate) fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn prompt() -> crate::prompt::ChatPrompt {
    crate::prompt::ChatPrompt {
        system: "sys".into(),
        user: "usr".into(),
    }
}

/// The golden-body helper: the effective request body under both
/// thinking policies, serialized — the byte-level comparison the
/// grandfather and ratchet must survive.
pub(crate) fn bodies(config: &LlmConfig) -> [String; 2] {
    [
        serde_json::to_string(&request_body(&config.model, &prompt(), true)).unwrap(),
        serde_json::to_string(&request_body(&config.model, &prompt(), false)).unwrap(),
    ]
}

/// The pre-0019 request body the golden tests compare against: the
/// skeleton plus the thinking-era keys, exactly as the old client
/// assembled them (skeleton → dialect pairs → custom overlay →
/// hold, all flattened here into one key set).
pub(crate) fn json_skeleton(model: &str, extra: Value) -> Value {
    let mut body = serde_json::json!({
        "model": model,
        "messages": [
            {"role": "system", "content": "sys"},
            {"role": "user", "content": "usr"},
        ],
        "stream": true,
        "temperature": 0.2,
    });
    let map = body.as_object_mut().unwrap();
    for (key, value) in extra.as_object().unwrap() {
        map.insert(key.clone(), value.clone());
    }
    body
}
