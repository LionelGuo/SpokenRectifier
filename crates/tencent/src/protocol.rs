//! The realtime-speech-recognition dialect: audio rides binary
//! WebSocket frames (raw little-endian PCM — the protocol's one
//! documented upload shape), the graceful-end notice rides a text
//! message (`{"type":"end"}`), and the server speaks JSON text only.
//! There is no session-opening message — the entire configuration,
//! credentials included, rides the signed connect URL ([`crate::sign`]).
//!
//! Results arrive as `result` objects with a `slice_type`: 2 marks a
//! slice's stable end — the engine's [`AsrEvent::Final`] — while 0/1
//! carry the growing draft of the current slice as the live
//! [`AsrEvent::Partial`]. `final: 1` on a `code: 0` message means all
//! audio is processed and the server will close: the drain's stop
//! marker. A non-zero `code` is a terminal error, folded into
//! [`AsrEvent::Failed`] feedback naming the code.
//!
//! [`AsrEvent::Final`]: spokenrectifier_engine::provider::asr::AsrEvent::Final
//! [`AsrEvent::Partial`]: spokenrectifier_engine::provider::asr::AsrEvent::Partial

use spokenrectifier_asr::session::WireProtocol;
use spokenrectifier_asr::transport::WireCodec;
use spokenrectifier_audio::FRAME_SAMPLES;
use spokenrectifier_engine::provider::asr::AsrEvent;

/// One client-to-server frame: binary for audio, text for the
/// graceful-end notice.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OutFrame {
    /// Raw little-endian PCM bytes.
    Audio(Vec<u8>),
    /// A JSON text message.
    Text(String),
}

/// The mixed-frame codec: the client's two-frame vocabulary onto the
/// socket, the server's text-only vocabulary back. Pings are answered
/// by the transport either way.
#[derive(Debug, Clone, Copy, Default)]
pub struct TencentWire;

impl WireCodec for TencentWire {
    type Message = OutFrame;

    fn encode(&self, message: &OutFrame) -> tokio_tungstenite::tungstenite::Message {
        use tokio_tungstenite::tungstenite::Message;
        match message {
            OutFrame::Audio(bytes) => Message::binary(bytes.clone()),
            OutFrame::Text(text) => Message::text(text.as_str()),
        }
    }

    fn decode(&self, frame: tokio_tungstenite::tungstenite::Message) -> Option<OutFrame> {
        match frame {
            tokio_tungstenite::tungstenite::Message::Text(text) => {
                Some(OutFrame::Text(text.as_str().to_string()))
            }
            _ => None,
        }
    }
}

/// The dialect. Stateless — the per-session configuration lives in the
/// connect URL, so there is nothing to carry.
pub(crate) struct TencentProtocol;

impl WireProtocol for TencentProtocol {
    type Message = OutFrame;

    fn opening(&self) -> Option<OutFrame> {
        // Everything rides the signed URL; there is no opening message.
        None
    }

    fn audio(&self, frame: &[i16]) -> OutFrame {
        OutFrame::Audio(frame.iter().flat_map(|s| s.to_le_bytes()).collect())
    }

    fn finish(&self) -> OutFrame {
        OutFrame::Text(r#"{"type":"end"}"#.into())
    }

    /// A silence frame keeps the connection counted as live while the
    /// send gate holds audio back: the endpoint disconnects a stream
    /// whose audio gaps run past ~6 s (error 4008 at 15 s). One 100 ms
    /// slice of zeros every keepalive interval is inaudible to the
    /// recognizer and far inside the pacing ceiling (3 s of audio per
    /// wall second).
    fn keepalive(&self) -> Option<OutFrame> {
        Some(OutFrame::Audio(vec![0u8; FRAME_SAMPLES * 2]))
    }

    fn parse(&mut self, message: &OutFrame) -> Vec<AsrEvent> {
        let OutFrame::Text(text) = message else {
            return Vec::new();
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
            return Vec::new();
        };
        let code = value["code"].as_i64().unwrap_or(0);
        if code != 0 {
            return vec![error_feedback(code, value["message"].as_str())];
        }
        let text = value["result"]["voice_text_str"]
            .as_str()
            .unwrap_or_default();
        if text.is_empty() {
            return Vec::new();
        }
        match value["result"]["slice_type"].as_i64() {
            Some(2) => vec![AsrEvent::Final {
                text: text.to_string(),
            }],
            _ => vec![AsrEvent::Partial {
                text: text.to_string(),
            }],
        }
    }

    fn session_over(&self, message: &OutFrame) -> bool {
        let OutFrame::Text(text) = message else {
            return false;
        };
        serde_json::from_str::<serde_json::Value>(text)
            .map(|value| value["code"].as_i64() == Some(0) && value["final"].as_i64() == Some(1))
            .unwrap_or(false)
    }
}

/// One server error into feedback. 6001 (an off-shore call hitting the
/// China endpoint) gets the proxy hint — the common cause on a proxied
/// machine is the missing direct-route exception.
fn error_feedback(code: i64, message: Option<&str>) -> AsrEvent {
    let mut text = format!("ASR {code}: {}", message.unwrap_or("server error"));
    if code == 6001 {
        text.push_str("（国内站不接受境外代理：为 asr.cloud.tencent.com 配置直连例外）");
    }
    AsrEvent::Failed { message: text }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server(json: serde_json::Value) -> OutFrame {
        OutFrame::Text(json.to_string())
    }

    #[test]
    fn there_is_no_opening_message_and_audio_rides_binary_pcm() {
        let protocol = TencentProtocol;
        assert_eq!(protocol.opening(), None);

        let frame = vec![1i16, -2, 3];
        assert_eq!(
            protocol.audio(&frame),
            OutFrame::Audio(vec![1, 0, 0xFE, 0xFF, 3, 0])
        );

        // The keepalive is one silence slice — zeros, the frame size.
        let OutFrame::Audio(keepalive) = protocol.keepalive().unwrap() else {
            panic!("the dialect needs a keepalive");
        };
        assert_eq!(keepalive, vec![0u8; FRAME_SAMPLES * 2]);

        assert_eq!(
            protocol.finish(),
            OutFrame::Text(r#"{"type":"end"}"#.into())
        );
    }

    #[test]
    fn slice_types_fold_into_partials_and_finals() {
        let mut protocol = TencentProtocol;

        // A draft (slice start or interim) is the live partial.
        for slice_type in [0, 1] {
            let events = protocol.parse(&server(serde_json::json!({
                "code": 0, "result": { "slice_type": slice_type, "index": 0,
                                       "voice_text_str": "实时" }
            })));
            assert_eq!(
                events,
                vec![AsrEvent::Partial {
                    text: "实时".into()
                }]
            );
        }

        // The stable slice end is a final.
        let events = protocol.parse(&server(serde_json::json!({
            "code": 0, "result": { "slice_type": 2, "index": 0,
                                   "voice_text_str": "实时语音识别" }
        })));
        assert_eq!(
            events,
            vec![AsrEvent::Final {
                text: "实时语音识别".into()
            }]
        );

        // The next slice's drafts are partials of the live tail only —
        // each slice's text stands on its own, like the settled list
        // the Volcengine dialect tracks.
        let events = protocol.parse(&server(serde_json::json!({
            "code": 0, "result": { "slice_type": 1, "index": 1,
                                   "voice_text_str": "下一句" }
        })));
        assert_eq!(
            events,
            vec![AsrEvent::Partial {
                text: "下一句".into()
            }]
        );
    }

    #[test]
    fn chatter_produces_no_events() {
        let mut protocol = TencentProtocol;
        // The handshake ack, an empty-text result, the all-done notice,
        // a non-JSON text, and any binary frame.
        assert_eq!(
            protocol.parse(&server(
                serde_json::json!({ "code": 0, "message": "success" })
            )),
            vec![]
        );
        assert_eq!(
            protocol.parse(&server(serde_json::json!({
                "code": 0, "result": { "slice_type": 1, "voice_text_str": "" }
            }))),
            vec![]
        );
        assert_eq!(
            protocol.parse(&server(serde_json::json!({ "code": 0, "final": 1 }))),
            vec![]
        );
        assert_eq!(protocol.parse(&OutFrame::Text("not json".into())), vec![]);
        assert_eq!(protocol.parse(&OutFrame::Audio(vec![1, 2, 3])), vec![]);
    }

    #[test]
    fn final_one_with_code_zero_is_the_session_over_marker() {
        let protocol = TencentProtocol;
        assert!(protocol.session_over(&server(serde_json::json!({ "code": 0, "final": 1 }))));
        // Near misses are not: final 0, a final riding an error, an
        // unparseable text, a binary frame.
        assert!(!protocol.session_over(&server(serde_json::json!({ "code": 0, "final": 0 }))));
        assert!(!protocol.session_over(&server(serde_json::json!({ "code": 4002, "final": 1 }))));
        assert!(!protocol.session_over(&OutFrame::Text("not json".into())));
        assert!(!protocol.session_over(&OutFrame::Audio(vec![1])));
    }

    #[test]
    fn server_errors_become_feedback_naming_the_code() {
        let mut protocol = TencentProtocol;
        let events = protocol.parse(&server(serde_json::json!({
            "code": 4002, "message": "鉴权失败"
        })));
        assert_eq!(
            events,
            vec![AsrEvent::Failed {
                message: "ASR 4002: 鉴权失败".into()
            }]
        );

        // 6001 carries the direct-connection hint — the proxied
        // machine's likely cause.
        let events = protocol.parse(&server(serde_json::json!({
            "code": 6001, "message": "境外调用请前往腾讯云国际站开通服务"
        })));
        let AsrEvent::Failed { message } = &events[0] else {
            panic!("got {events:?}");
        };
        assert!(message.starts_with("ASR 6001:"), "got: {message}");
        assert!(message.contains("直连例外"), "got: {message}");

        // A missing message degrades to the generic wording.
        let events = protocol.parse(&server(serde_json::json!({ "code": 4009 })));
        assert_eq!(
            events,
            vec![AsrEvent::Failed {
                message: "ASR 4009: server error".into()
            }]
        );
    }
}
