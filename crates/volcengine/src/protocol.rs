//! The Seed-ASR bigmodel dialect: what one session says when it opens,
//! how audio rides, and how server responses fold back onto the
//! engine's events.
//!
//! The opening full client request fixes the audio shape (PCM 16 kHz
//! 16-bit mono — the only shape this endpoint takes) and asks for
//! utterance-level results: `result.utterances[]` marks each segment
//! `definite` once settled, which maps exactly onto the engine's
//! [`AsrEvent::Final`] (a settled segment) with the not-yet-definite
//! tail as the live [`AsrEvent::Partial`]. Language is deliberately
//! NOT sent: the default engine is mixed Chinese-English plus five
//! dialects, and `audio.language` exists only on the nostream mode.
//!
//! The hotword dictionary rides as `request.corpus.context.hotwords` —
//! context passed straight into recognition, injected per connection
//! (runtime, no console-prebuilt tables) and outranking any server-side
//! word list. The bidirectional stream budgets ~100 tokens of context,
//! so the dictionary is capped at 100 characters (terms admitted whole
//! until the budget runs out; the tail biases nothing).
//!
//! [`AsrEvent::Final`]: spokenrectifier_engine::provider::asr::AsrEvent::Final
//! [`AsrEvent::Partial`]: spokenrectifier_engine::provider::asr::AsrEvent::Partial

use spokenrectifier_asr::session::WireProtocol;
use spokenrectifier_engine::provider::asr::AsrEvent;

use crate::frame::{
    ServerFrame, decode, encode_audio, encode_full_request, encode_keepalive, encode_last_packet,
};

/// The context budget the bidirectional stream documents (~100 tokens;
/// one Chinese character ≈ one token, so characters are the honest
/// unit to cap by).
const HOTWORD_CONTEXT_CHARS: usize = 100;

/// The dialect, built per session (it carries the dictionary and the
/// per-connection definite-utterance bookkeeping).
pub(crate) struct VolcengineProtocol {
    terms: Vec<String>,
    /// How many utterances have already been emitted as finals — the
    /// responses repeat the whole utterance list, so the position is
    /// what tells settled from new.
    definite_emitted: usize,
}

impl VolcengineProtocol {
    pub(crate) fn new(terms: Vec<String>) -> Self {
        Self {
            terms,
            definite_emitted: 0,
        }
    }
}

impl WireProtocol for VolcengineProtocol {
    type Message = Vec<u8>;

    fn opening(&self) -> Vec<u8> {
        encode_full_request(&full_request_json(&self.terms))
    }

    fn audio(&self, frame: &[i16]) -> Vec<u8> {
        encode_audio(frame)
    }

    fn finish(&self) -> Vec<u8> {
        encode_last_packet()
    }

    fn keepalive(&self) -> Option<Vec<u8>> {
        Some(encode_keepalive())
    }

    fn parse(&mut self, message: &Vec<u8>) -> Vec<AsrEvent> {
        match decode(message) {
            Ok(ServerFrame::Response(json)) => self.parse_response(json),
            Ok(ServerFrame::Error(json)) => vec![parse_error(&json)],
            Ok(ServerFrame::Keepalive) | Err(_) => Vec::new(),
        }
    }

    fn session_over(&self, _message: &Vec<u8>) -> bool {
        // No confirmed end marker in this dialect: the drain runs to
        // its deadline after the last packet.
        false
    }
}

/// The full client request's JSON body.
fn full_request_json(terms: &[String]) -> String {
    let mut request = serde_json::json!({
        // Fixed by the bigmodel endpoint: the resource id (the auth
        // header) selects generation and billing; model_name is
        // literally "bigmodel".
        "model_name": "bigmodel",
        // ITN (inverse text normalization) and punctuation on by
        // default server-side; stating them keeps the request explicit.
        "enable_itn": true,
        "enable_punc": true,
        // Utterance-level results are what we translate into
        // finals/partials; without this only the cumulative text
        // arrives.
        "show_utterances": true,
        // The engine's own paragraph semantics (local VAD + silence
        // thresholds) drive segmentation; the server's semantic
        // segmentation stays at its default.
    });
    let hotwords = capped_hotwords(terms);
    if !hotwords.is_empty() {
        request["corpus"] = serde_json::json!({
            "context": { "hotwords": hotwords }
        });
    }
    serde_json::json!({
        "user": { "uid": "spokenrectifier" },
        "audio": {
            "format": "pcm",
            "rate": 16000,
            "bits": 16,
            "channel": 1,
        },
        "request": request,
    })
    .to_string()
}

/// The dictionary as hotword entries, capped to the stream's context
/// budget: terms admitted whole while they fit, never a partial term.
fn capped_hotwords(terms: &[String]) -> Vec<serde_json::Value> {
    let mut used = 0;
    terms
        .iter()
        .filter_map(|term| {
            let term = term.trim();
            if term.is_empty() {
                return None;
            }
            let cost = term.chars().count();
            if used + cost > HOTWORD_CONTEXT_CHARS {
                return None; // the budget is spent; the tail biases nothing
            }
            used += cost;
            Some(serde_json::json!({ "word": term }))
        })
        .collect()
}

impl VolcengineProtocol {
    /// Fold one full server response into events: finals for newly
    /// settled utterances, then the unsettled tail as the partial.
    fn parse_response(&mut self, json: String) -> Vec<AsrEvent> {
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&json) else {
            return Vec::new();
        };
        let Some(utterances) = value["result"]["utterances"].as_array() else {
            // No utterance detail (the request's show_utterances
            // ignored): at least keep the live text moving.
            let text = value["result"]["text"].as_str().unwrap_or_default();
            return (!text.is_empty())
                .then_some(AsrEvent::Partial {
                    text: text.to_string(),
                })
                .into_iter()
                .collect();
        };

        let mut events = Vec::new();
        let mut last_definite: Option<usize> = None;
        for (index, utterance) in utterances.iter().enumerate() {
            let definite = utterance["definite"].as_bool().unwrap_or(false);
            if definite && index >= self.definite_emitted {
                if let Some(text) = utterance["text"].as_str() {
                    events.push(AsrEvent::Final {
                        text: text.to_string(),
                    });
                }
                last_definite = Some(index);
            } else if definite {
                last_definite = Some(index);
            }
        }
        if let Some(index) = last_definite {
            self.definite_emitted = self.definite_emitted.max(index + 1);
        }
        // The live draft: everything after the last settled utterance.
        let tail_start = last_definite.map_or(0, |index| index + 1);
        let tail: String = utterances[tail_start..]
            .iter()
            .filter_map(|utterance| utterance["text"].as_str())
            .collect();
        if !tail.is_empty() {
            events.push(AsrEvent::Partial { text: tail });
        }
        events
    }
}

/// One error frame into feedback: the code names the failure class
/// (45000001 bad parameter, 45000081 wait-packet timeout, 55000031
/// busy…), the message says what broke.
fn parse_error(json: &str) -> AsrEvent {
    let code = serde_json::from_str::<serde_json::Value>(json)
        .ok()
        .and_then(|value| {
            value["code"]
                .as_u64()
                .or_else(|| value["error_code"].as_u64())
        });
    let message = serde_json::from_str::<serde_json::Value>(json)
        .ok()
        .and_then(|value| {
            value["message"]
                .as_str()
                .or_else(|| value["msg"].as_str())
                .map(str::to_string)
        })
        .unwrap_or_else(|| "server error".into());
    match code {
        Some(code) => AsrEvent::Failed {
            message: format!("ASR {code}: {message}"),
        },
        None => AsrEvent::Failed { message },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn response_json(utterances: serde_json::Value) -> String {
        serde_json::json!({ "result": { "text": "ignored", "utterances": utterances } }).to_string()
    }

    fn utterance(text: &str, definite: bool) -> serde_json::Value {
        serde_json::json!({ "text": text, "definite": definite })
    }

    /// Decode one raw server response frame into events.
    fn parse_raw(protocol: &mut VolcengineProtocol, json: String) -> Vec<AsrEvent> {
        protocol.parse(&crate::frame::encode_server_response(&json))
    }

    #[test]
    fn the_full_request_pins_the_audio_shape_and_model() {
        let frame = VolcengineProtocol::new(vec![]).opening();
        let (message_type, payload) = crate::frame::client_payload(&frame);
        assert_eq!(message_type, crate::frame::MESSAGE_FULL_CLIENT_REQUEST);
        let request: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(
            request["audio"],
            serde_json::json!({
                "format": "pcm", "rate": 16000, "bits": 16, "channel": 1
            })
        );
        assert_eq!(request["request"]["model_name"], "bigmodel");
        assert_eq!(request["request"]["show_utterances"], true);
        assert!(request["request"].get("corpus").is_none());
    }

    #[test]
    fn the_dictionary_rides_as_context_hotwords_capped_to_the_budget() {
        // A dictionary well inside the budget rides whole.
        let terms: Vec<String> = ["SpokenRectifier", "语音实验室"]
            .iter()
            .map(|t| t.to_string())
            .collect();
        let frame = VolcengineProtocol::new(terms).opening();
        let (_, payload) = crate::frame::client_payload(&frame);
        let request: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(
            request["request"]["corpus"]["context"]["hotwords"],
            serde_json::json!([{ "word": "SpokenRectifier" }, { "word": "语音实验室" }])
        );

        // A dictionary past the budget admits whole terms until it runs
        // out — never a partial term, never the tail.
        let many: Vec<String> = (0..30).map(|i| format!("术语编号{i}")).collect();
        let frame = VolcengineProtocol::new(many).opening();
        let (_, payload) = crate::frame::client_payload(&frame);
        let request: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        let hotwords = request["request"]["corpus"]["context"]["hotwords"]
            .as_array()
            .unwrap();
        let chars: usize = hotwords
            .iter()
            .map(|hotword| hotword["word"].as_str().unwrap().chars().count())
            .sum();
        assert!(chars <= HOTWORD_CONTEXT_CHARS, "budget blown: {chars}");
        assert!(hotwords.len() >= 12, "over-truncated: {hotwords:?}");
        // Blank terms never ride.
        let blank: Vec<String> = ["", "  "].iter().map(|t| t.to_string()).collect();
        let frame = VolcengineProtocol::new(blank).opening();
        let (_, payload) = crate::frame::client_payload(&frame);
        let request: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert!(request["request"].get("corpus").is_none());
    }

    #[test]
    fn settled_utterances_fold_into_finals_with_the_tail_as_partial() {
        let mut protocol = VolcengineProtocol::new(vec![]);

        // A draft only: partial.
        let events = parse_raw(
            &mut protocol,
            response_json(serde_json::json!([utterance("你好", false)])),
        );
        assert_eq!(
            events,
            vec![AsrEvent::Partial {
                text: "你好".into()
            }]
        );

        // The same utterance settles, a new draft begins: the final for
        // the settled one, the draft as the partial.
        let events = parse_raw(
            &mut protocol,
            response_json(serde_json::json!([
                utterance("你好世界", true),
                utterance("语音", false),
            ])),
        );
        assert_eq!(
            events,
            vec![
                AsrEvent::Final {
                    text: "你好世界".into()
                },
                AsrEvent::Partial {
                    text: "语音".into()
                },
            ]
        );

        // The next response repeats the whole list (settled unchanged)
        // plus one more settled segment: only the NEW final arrives —
        // no replay of the old one.
        let events = parse_raw(
            &mut protocol,
            response_json(serde_json::json!([
                utterance("你好世界", true),
                utterance("语音实验室", true),
            ])),
        );
        assert_eq!(
            events,
            vec![AsrEvent::Final {
                text: "语音实验室".into()
            }]
        );
    }

    #[test]
    fn a_response_without_utterances_keeps_the_live_text_moving() {
        let mut protocol = VolcengineProtocol::new(vec![]);
        let events = parse_raw(
            &mut protocol,
            serde_json::json!({ "result": { "text": "全量文本" } }).to_string(),
        );
        assert_eq!(
            events,
            vec![AsrEvent::Partial {
                text: "全量文本".into()
            }]
        );
    }

    #[test]
    fn error_frames_become_feedback_naming_the_code() {
        let mut protocol = VolcengineProtocol::new(vec![]);
        let frame = crate::frame::encode_server_error(
            r#"{"code":45000081,"message":"wait packet timeout"}"#,
        );
        let events = protocol.parse(&frame);
        assert_eq!(
            events,
            vec![AsrEvent::Failed {
                message: "ASR 45000081: wait packet timeout".into()
            }]
        );

        // An error frame that is not JSON still fails loudly, not as
        // garbage.
        let frame = crate::frame::encode_server_error("not json");
        let events = protocol.parse(&frame);
        assert_eq!(
            events,
            vec![AsrEvent::Failed {
                message: "server error".into()
            }]
        );
    }

    #[test]
    fn keepalives_and_unparseable_frames_produce_no_events() {
        let mut protocol = VolcengineProtocol::new(vec![]);
        assert_eq!(protocol.parse(&crate::frame::encode_keepalive()), vec![]);
        assert_eq!(protocol.parse(&vec![0x11, 0x90, 0x00, 0x00]), vec![]);
    }
}
