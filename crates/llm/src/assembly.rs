//! Request-body assembly (ADR-0019 items 1/2/3): the format axis picks
//! the skeleton (path slots live on [`Format`]; the body carries the
//! prompt), then the resident overlay, then the selected thinking share.
//! Protected keys are snapshotted from the skeleton and written last so
//! an overlay cannot keep them. Anthropic's required `max_tokens` is a
//! skeleton fallback — an overlay that names it wins.
//!
//! Object shares deep-merge so a Gemini thinking share under
//! `generationConfig.thinkingConfig` does not wipe a resident
//! `generationConfig.temperature`. Arrays and scalars replace.

use serde_json::{Map, Value, json};

use crate::config::{ModelConfig, ThinkingState};
use crate::format::Format;
use crate::prompt::ChatPrompt;

/// Anthropic requires `max_tokens`; the skeleton supplies this when the
/// overlay does not (ADR-0019 item 2). The number is a software default,
/// not a user knob — overlay values, including smaller ones, win.
pub(crate) const ANTHROPIC_MAX_TOKENS_FALLBACK: u64 = 8192;

/// The request body under the fixed merge order (ADR-0019 item 2):
/// skeleton, then the resident share, then the selected thinking share
/// — the thinking share keeps the last word at every nested key.
/// The connection domain's thinking state gates the thinking shares:
/// off, unconfigured, or broken sends no thinking keys at all, leaving
/// the endpoint on its own default (ADR-0019 item 3). Overlaid onto a
/// legacy (grandfathered) openai_chat config this reproduces the
/// pre-0019 body byte for byte — the shares compose in the old
/// precedence (dialect, custom overlay, hold) at load.
pub(crate) fn request_body(model: &ModelConfig, prompt: &ChatPrompt, thinking: bool) -> Value {
    let mut body = skeleton(model.format, &model.model, prompt);
    let protected: Vec<(String, Value)> = model
        .format
        .protected_keys()
        .iter()
        .filter_map(|key| {
            body.get(*key)
                .cloned()
                .map(|value| ((*key).to_string(), value))
        })
        .collect();

    let group = &model.thinking;
    if let Some(resident) = &group.overlays.body {
        merge_map(
            body.as_object_mut().expect("skeleton is an object"),
            resident,
        );
    }
    if group.state == ThinkingState::On {
        let share = if thinking {
            &group.overlays.thinking_on
        } else {
            &group.overlays.thinking_off
        };
        if let Some(share) = share {
            merge_map(body.as_object_mut().expect("skeleton is an object"), share);
        }
    }

    let map = body.as_object_mut().expect("skeleton is an object");
    for (key, value) in protected {
        map.insert(key, value);
    }
    body
}

fn skeleton(format: Format, model: &str, prompt: &ChatPrompt) -> Value {
    match format {
        Format::OpenaiChat => json!({
            "model": model,
            "messages": [
                {"role": "system", "content": prompt.system},
                {"role": "user", "content": prompt.user},
            ],
            "stream": true,
            // Rewriting wants stable output, not creativity.
            "temperature": 0.2,
        }),
        Format::Anthropic => json!({
            "model": model,
            "system": prompt.system,
            "messages": [
                {"role": "user", "content": prompt.user},
            ],
            "stream": true,
            "temperature": 0.2,
            "max_tokens": ANTHROPIC_MAX_TOKENS_FALLBACK,
        }),
        Format::Gemini => json!({
            "systemInstruction": {
                "parts": [{"text": prompt.system}],
            },
            "contents": [
                {"role": "user", "parts": [{"text": prompt.user}]},
            ],
            "generationConfig": {"temperature": 0.2},
        }),
    }
}

fn merge_map(dst: &mut Map<String, Value>, src: &Map<String, Value>) {
    for (key, value) in src {
        if let (Some(Value::Object(dst_obj)), Value::Object(src_obj)) = (dst.get_mut(key), value) {
            merge_map(dst_obj, src_obj);
        } else {
            dst.insert(key.clone(), value.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{ConnectionThinking, LlmConfig, Overlays, ThinkingState};
    use crate::format::Format;
    use crate::presets;

    fn prompt() -> ChatPrompt {
        ChatPrompt {
            system: "sys".into(),
            user: "usr".into(),
        }
    }

    fn object(text: &str) -> Map<String, Value> {
        serde_json::from_str::<Value>(text)
            .unwrap()
            .as_object()
            .unwrap()
            .clone()
    }

    #[test]
    fn openai_chat_skeleton_matches_the_pre_0019_shape() {
        let model = LlmConfig::defaults().model;
        let body = request_body(&model, &prompt(), false);
        assert_eq!(body["model"], "deepseek-flash");
        assert_eq!(body["stream"], true);
        assert_eq!(body["temperature"], 0.2);
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][0]["content"], "sys");
        assert_eq!(body["messages"][1]["content"], "usr");
        assert_eq!(body["thinking"], json!({"type": "disabled"}));
    }

    #[test]
    fn anthropic_skeleton_puts_system_on_top_and_falls_back_max_tokens() {
        let mut model = LlmConfig::defaults().model;
        model.format = Format::Anthropic;
        model.thinking = ConnectionThinking {
            state: ThinkingState::On,
            overlays: Overlays {
                body: None,
                thinking_on: Some(object(r#"{"thinking":{"type":"adaptive"}}"#)),
                thinking_off: Some(object(r#"{"thinking":{"type":"disabled"}}"#)),
            },
        };
        let off = request_body(&model, &prompt(), false);
        assert_eq!(off["system"], "sys");
        assert_eq!(off["messages"][0]["role"], "user");
        assert_eq!(off["messages"][0]["content"], "usr");
        assert!(off.get("messages").unwrap().as_array().unwrap().len() == 1);
        assert_eq!(off["stream"], true);
        assert_eq!(off["max_tokens"], ANTHROPIC_MAX_TOKENS_FALLBACK);
        assert_eq!(off["thinking"], json!({"type": "disabled"}));
        assert!(off.get("temperature").is_some());

        model.thinking.overlays.body = Some(object(r#"{"max_tokens": 1024}"#));
        let overlaid = request_body(&model, &prompt(), false);
        assert_eq!(overlaid["max_tokens"], 1024, "an overlay max_tokens wins");
    }

    #[test]
    fn gemini_skeleton_puts_the_prompt_in_system_instruction_and_contents() {
        let mut model = LlmConfig::defaults().model;
        model.format = Format::Gemini;
        model.model = "gemini-3.8-flash".into();
        model.thinking = ConnectionThinking {
            state: ThinkingState::On,
            overlays: Overlays {
                body: None,
                thinking_on: Some(presets::by_name("gemini").unwrap().thinking_on),
                thinking_off: Some(presets::by_name("gemini").unwrap().thinking_off),
            },
        };
        let on = request_body(&model, &prompt(), true);
        assert_eq!(on["systemInstruction"]["parts"][0]["text"], "sys");
        assert_eq!(on["contents"][0]["role"], "user");
        assert_eq!(on["contents"][0]["parts"][0]["text"], "usr");
        assert!(
            on.get("model").is_none(),
            "gemini's model rides in the path"
        );
        assert!(on.get("stream").is_none(), "gemini streams via alt=sse");
        assert_eq!(on["generationConfig"]["temperature"], 0.2);
        assert_eq!(
            on["generationConfig"]["thinkingConfig"]["thinkingLevel"],
            "medium"
        );
        assert_eq!(
            on["generationConfig"]["thinkingConfig"]["includeThoughts"],
            true
        );

        let off = request_body(&model, &prompt(), false);
        assert_eq!(
            off["generationConfig"]["thinkingConfig"]["thinkingLevel"],
            "low"
        );
        assert!(
            off["generationConfig"]["thinkingConfig"]
                .get("includeThoughts")
                .is_none()
        );
        assert_eq!(
            off["generationConfig"]["temperature"], 0.2,
            "the thinking share must not wipe the skeleton temperature"
        );
    }

    #[test]
    fn the_thinking_share_keeps_the_last_word_over_the_resident() {
        let mut model = LlmConfig::defaults().model;
        model.thinking.overlays.body =
            Some(object(r#"{"top_p": 0.9, "thinking": {"type": "enabled"}}"#));
        let off = request_body(&model, &prompt(), false);
        assert_eq!(off["top_p"], 0.9);
        assert_eq!(off["thinking"], json!({"type": "disabled"}));
        let on = request_body(&model, &prompt(), true);
        assert_eq!(
            on["thinking"],
            json!({"type": "enabled"}),
            "the on-share keeps the last word over the resident share"
        );
        assert_eq!(on["reasoning_effort"], "low");
    }

    #[test]
    fn a_disabled_thinking_state_sends_no_thinking_keys() {
        let mut model = LlmConfig::defaults().model;
        model.thinking.overlays.body = Some(object(r#"{"top_p": 0.9}"#));
        for state in [
            ThinkingState::Off,
            ThinkingState::Unconfigured,
            ThinkingState::Broken("spokenrectifier.toml: [llm.overlays]: must be a table".into()),
        ] {
            model.thinking.state = state.clone();
            for thinking in [true, false] {
                let body = request_body(&model, &prompt(), thinking);
                assert!(
                    body.get("thinking").is_none() && body.get("reasoning_effort").is_none(),
                    "{state:?} thinking={thinking}: thinking keys leaked: {body}"
                );
                assert_eq!(body["top_p"], 0.9, "the resident share still merges");
            }
        }
    }

    #[test]
    fn protected_keys_cannot_be_overlaid() {
        let mut model = LlmConfig::defaults().model;
        model.thinking.overlays.body = Some(object(
            r#"{"model":"hacked","messages":[],"stream":false,"temperature":0.9}"#,
        ));
        let body = request_body(&model, &prompt(), false);
        assert_eq!(body["model"], "deepseek-flash");
        assert_eq!(body["stream"], true);
        assert_eq!(body["messages"][0]["content"], "sys");
        assert_eq!(body["temperature"], 0.9, "unprotected keys do overlay");

        model.format = Format::Anthropic;
        model.thinking.overlays.body = Some(object(
            r#"{"system":"nope","messages":[{"role":"assistant","content":"x"}],"stream":false,"model":"hacked"}"#,
        ));
        let body = request_body(&model, &prompt(), false);
        assert_eq!(body["system"], "sys");
        assert_eq!(body["messages"][0]["role"], "user");
        assert_eq!(body["stream"], true);
        assert_eq!(body["model"], "deepseek-flash");

        model.format = Format::Gemini;
        model.thinking.overlays.body = Some(object(
            r#"{"systemInstruction":{"parts":[{"text":"nope"}]},"contents":[]}"#,
        ));
        let body = request_body(&model, &prompt(), false);
        assert_eq!(body["systemInstruction"]["parts"][0]["text"], "sys");
        assert_eq!(body["contents"][0]["role"], "user");
    }

    #[test]
    fn object_shares_deep_merge_nested_keys() {
        let mut model = LlmConfig::defaults().model;
        model.format = Format::Gemini;
        model.thinking.state = ThinkingState::On;
        model.thinking.overlays.body = Some(object(
            r#"{"generationConfig":{"topP":0.9,"thinkingConfig":{"keep":true}}}"#,
        ));
        model.thinking.overlays.thinking_on = Some(object(
            r#"{"generationConfig":{"thinkingConfig":{"thinkingLevel":"medium"}}}"#,
        ));
        let body = request_body(&model, &prompt(), true);
        assert_eq!(body["generationConfig"]["temperature"], 0.2);
        assert_eq!(body["generationConfig"]["topP"], 0.9);
        assert_eq!(body["generationConfig"]["thinkingConfig"]["keep"], true);
        assert_eq!(
            body["generationConfig"]["thinkingConfig"]["thinkingLevel"],
            "medium"
        );
    }
}
