use std::sync::Mutex;

use spokenrectifier_engine::{EngineEvent, EventEnvelope, SessionState};

use super::connection::llm_view;
use super::rectify::{parse_policy, rectify_view};
use super::state::global;
use super::*;

/// The bridge is a process-wide singleton: serialize the tests.
static TEST_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn the_endpoint_preview_matches_the_loaded_derivation() {
    // The form's live preview must be exactly what a load would
    // paint: the default aliyun URL carries the typed model.
    let preview = asr_endpoint_preview(
        "aliyun".into(),
        "my-engine".into(),
        None,
        None,
        "cn-beijing".into(),
        None,
    )
    .unwrap();
    assert_eq!(
        preview.as_deref(),
        Some("wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=my-engine")
    );

    // A base_url override wins; whitespace-only is no override.
    let preview = asr_endpoint_preview(
        "volcengine".into(),
        "bigmodel".into(),
        Some("  ".into()),
        None,
        String::new(),
        None,
    )
    .unwrap();
    assert_eq!(
        preview.as_deref(),
        Some("wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")
    );

    // Tencent: the app id rides the URL path — with one typed, the
    // preview is the connect base the adapter signs around; an
    // absent one leaves the path open.
    let preview = asr_endpoint_preview(
        "tencent".into(),
        "16k_zh_en".into(),
        None,
        None,
        String::new(),
        Some("1250012548".into()),
    )
    .unwrap();
    assert_eq!(
        preview.as_deref(),
        Some("wss://asr.cloud.tencent.com/asr/v2/1250012548")
    );

    // The unadapted providers promise no URL.
    let preview = asr_endpoint_preview(
        "openai".into(),
        "gpt-4o-transcribe".into(),
        None,
        None,
        String::new(),
        None,
    )
    .unwrap();
    assert_eq!(preview, None);

    assert!(
        asr_endpoint_preview("wat".into(), String::new(), None, None, String::new(), None)
            .unwrap_err()
            .to_string()
            .contains("provider")
    );
}

async fn wait_for<F>(
    rx: &mut tokio::sync::broadcast::Receiver<EventEnvelope>,
    predicate: F,
) -> EventEnvelope
where
    F: Fn(&EngineEvent) -> bool,
{
    loop {
        let envelope = tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv())
            .await
            .expect("event within timeout")
            .expect("channel open");
        if predicate(&envelope.event) {
            return envelope;
        }
    }
}

async fn wait_state(rx: &mut tokio::sync::broadcast::Receiver<EventEnvelope>, want: SessionState) {
    wait_for(
        rx,
        |event| matches!(event, EngineEvent::SessionStateChanged { to, .. } if *to == want),
    )
    .await;
}

/// Wait on the bridge's own runtime: the tests run on plain threads so
/// the bridge's `block_on` calls never nest inside another runtime.
fn block_on<F: std::future::Future>(future: F) -> F::Output {
    global().unwrap().rt.block_on(future)
}

fn setup() {
    // One shared engine for all tests: queue enough scripted LLM
    // responses for every session any test will run.
    create_fake_engine(vec!["修正后的书面文本".to_string(); 16]).unwrap();
}

#[test]
fn full_flow_through_the_bridge_api() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    let mut rx = global().unwrap().engine.subscribe();

    fake_begin_session().unwrap();
    execute(BridgeCommand::StartSession).unwrap();
    fake_say("嗯那个原话".into()).unwrap();
    fake_silence(1300).unwrap();
    block_on(wait_for(
        &mut rx,
        |event| matches!(event, EngineEvent::LiveTranscriptUpdated { text } if text.contains("嗯那个原话")),
    ));

    execute(BridgeCommand::StopSession).unwrap();
    block_on(wait_state(&mut rx, SessionState::Preview));

    execute(BridgeCommand::ConfirmInsert {
        placeholders: Vec::new(),
    })
    .unwrap();
    block_on(wait_state(&mut rx, SessionState::Idle));

    // The inserter is shared across tests: assert the latest entry.
    assert_eq!(
        inserted_texts().unwrap().last(),
        Some(&"修正后的书面文本".to_string())
    );
    assert_eq!(state().unwrap(), BridgeSessionState::Idle);
}

#[test]
fn commands_rejected_outside_the_bridge_report_errors() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    let err = execute(BridgeCommand::StopSession).unwrap_err().to_string();
    assert!(err.contains("rejected"), "got: {err}");
    assert_eq!(state().unwrap(), BridgeSessionState::Idle);
}

/// The pin command rides the wire with the engine's semantics
/// (ticket 21's bridge seam; the engine's own behavior is locked by
/// the engine tests): rejected outside recording, and inside it the
/// sentinel surfaces through the live transcript event at once —
/// a pin-only session rides the whole machine to insertion.
#[test]
fn pin_placeholder_rides_the_wire() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    let mut rx = global().unwrap().engine.subscribe();

    // Outside listening the wire reports the engine's rejection.
    let err = execute(BridgeCommand::PinPlaceholder)
        .unwrap_err()
        .to_string();
    assert!(err.contains("rejected"), "got: {err}");

    // While listening: the sentinel appears in the live transcript.
    fake_begin_session().unwrap();
    execute(BridgeCommand::StartSession).unwrap();
    execute(BridgeCommand::PinPlaceholder).unwrap();
    block_on(wait_for(&mut rx, |event| {
        matches!(
            event,
            EngineEvent::LiveTranscriptUpdated { text } if text.contains('‡')
        )
    }));

    // The pin-only session survives the recording end and inserts.
    execute(BridgeCommand::StopSession).unwrap();
    block_on(wait_state(&mut rx, SessionState::Preview));
    execute(BridgeCommand::ConfirmInsert {
        placeholders: Vec::new(),
    })
    .unwrap();
    block_on(wait_state(&mut rx, SessionState::Idle));
}

/// A style directive rides the wire any time (no state machine role):
/// the engine accepts it and the default-register reset alike.
#[test]
fn style_directive_commands_are_valid_any_time() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    execute(BridgeCommand::SetStyleDirective {
        directive: Some("以 Markdown 分条输出".into()),
        scenario: Some("以 Markdown 分条".into()),
    })
    .unwrap();
    execute(BridgeCommand::SetStyleDirective {
        directive: None,
        scenario: None,
    })
    .unwrap();
    // The global directive rides the same seam (ticket 22), with the
    // same any-time semantics and reset.
    execute(BridgeCommand::SetGlobalDirective {
        directive: Some("全部输出以简体中文书写".into()),
    })
    .unwrap();
    execute(BridgeCommand::SetGlobalDirective { directive: None }).unwrap();
}

/// The passage-mode switch rides the wire any time and reads back
/// through the panel's getter (config default: on).
#[test]
fn passage_mode_round_trips_the_wire() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    assert!(passage_mode().unwrap());
    execute(BridgeCommand::SetPassageMode { on: false }).unwrap();
    assert!(!passage_mode().unwrap());
    execute(BridgeCommand::SetPassageMode { on: true }).unwrap();
    assert!(passage_mode().unwrap());
}

/// The advanced form's engine-timings switch rides the wire any
/// time (the settings window sends it right after the file write)
/// and reads back through the engine's getter.
#[test]
fn engine_timings_ride_the_wire_any_time() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    let defaults = global().unwrap().engine.engine_timings();
    execute(BridgeCommand::SetEngineTimings {
        paragraph_silence_ms: 1500,
        session_end_silence_ms: 2500,
        rectify_timeout_ms: 30_000,
    })
    .unwrap();
    let switched = global().unwrap().engine.engine_timings();
    assert_eq!(switched.paragraph_silence_ms, 1500);
    assert_eq!(switched.session_end_silence_ms, 2500);
    assert_eq!(switched.rectify_timeout_ms, 30_000);
    // Back to the seeded values so later tests see the defaults.
    execute(BridgeCommand::SetEngineTimings {
        paragraph_silence_ms: defaults.paragraph_silence_ms,
        session_end_silence_ms: defaults.session_end_silence_ms,
        rectify_timeout_ms: defaults.rectify_timeout_ms,
    })
    .unwrap();
}

/// The connection re-adoption is a quiet no-op on the fake engine:
/// tests and demos hold no production collaborators to swap, and no
/// config files are touched (the real path's refusals are tested in
/// `engine_factory`, its swap semantics in the engine's live_swap
/// tests).
#[test]
fn apply_connection_configs_is_a_noop_on_the_fake_engine() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    apply_connection_configs().unwrap();
}

/// The rectify pane's wire mirror maps every config field, the
/// policies as their lowercase strings, and the extra directive
/// as-is (the file-touching paths are tested at the llm crate's
/// config layer; this locks the bridge mapping itself).
#[test]
fn the_rectify_view_mirrors_the_config_field_by_field() {
    use spokenrectifier_llm::{
        LightTouchConfig, QuickConfig, RectifyConfig, RectifyTier, ThinkingPolicy,
    };
    let rectify = RectifyConfig {
        full: RectifyTier {
            thinking_policy: ThinkingPolicy::Placeholders,
            prefill: false,
        },
        light_touch: LightTouchConfig {
            enabled: false,
            max_chars: 12,
            tier: RectifyTier {
                thinking_policy: ThinkingPolicy::Off,
                prefill: true,
            },
            extra_directive: Some("短句保留节奏".into()),
        },
        quick: QuickConfig {
            enabled: true,
            rectify: false,
            extra_directive: Some("快速短句保留节奏".into()),
        },
    };
    let mut config = spokenrectifier_llm::LlmConfig::defaults();
    config.rectify = rectify;
    let view = rectify_view(&config);
    assert_eq!(view.full_thinking_policy, "placeholders");
    assert!(!view.full_prefill);
    assert!(!view.light_touch_enabled);
    assert_eq!(view.light_touch_max_chars, 12);
    assert_eq!(view.light_touch_thinking_policy, "off");
    assert!(view.light_touch_prefill);
    assert_eq!(
        view.light_touch_extra_directive.as_deref(),
        Some("短句保留节奏")
    );
    // The quick sub-section (ADR-0020) rides the same mirror.
    assert!(view.quick_enabled);
    assert!(!view.quick_rectify);
    assert_eq!(
        view.quick_extra_directive.as_deref(),
        Some("快速短句保留节奏")
    );
    // The connection's reading rides the same view: the cards'
    // disable condition (ADR-0019 item 3). The default is `on`.
    assert_eq!(view.connection_thinking, "on");
    config.model.thinking.state = spokenrectifier_llm::ThinkingState::Unconfigured;
    assert_eq!(rectify_view(&config).connection_thinking, "unconfigured");
    // An unknown policy name is refused naming the section — the
    // wire never accepts a fourth tier.
    let err = parse_policy("rectify.full", "sometimes")
        .unwrap_err()
        .to_string();
    assert!(err.contains("rectify.full"), "got: {err}");
    assert!(err.contains("sometimes"), "got: {err}");
}

/// The connection view mirrors the open shape field by field
/// (ADR-0019): the format axis, the thinking group's four-state
/// reading with its broken detail, the three boxes as pretty JSON,
/// and a key entry for every vendor slot.
#[test]
fn the_llm_view_mirrors_the_open_shape_field_by_field() {
    let mut config = spokenrectifier_llm::LlmConfig::defaults();
    config.model.format = spokenrectifier_llm::Format::Gemini;
    config.model.thinking.overlays.body =
        Some(serde_json::from_str(r#"{"temperature": 0.1}"#).unwrap());
    let view = llm_view(config);
    assert_eq!(view.format, "gemini");
    assert_eq!(view.thinking_state, "on");
    assert_eq!(view.thinking_detail, None);
    let body = view.body_json.expect("the resident share paints");
    assert!(body.contains("\"temperature\": 0.1"), "got: {body}");
    assert!(body.contains('\n'), "not pretty: {body}");
    assert!(view.thinking_on_json.is_some(), "the default on-share");
    assert!(
        view.keys.iter().any(|key| key.vendor == "custom"),
        "custom key entry missing"
    );

    // The broken branch carries its detail, and the group reads inert.
    let mut broken = spokenrectifier_llm::LlmConfig::defaults();
    broken.model.thinking.state =
        spokenrectifier_llm::ThinkingState::Broken("f.toml: [llm]: thinking_fields".into());
    broken.model.thinking.overlays = Default::default();
    let view = llm_view(broken);
    assert_eq!(view.thinking_state, "broken");
    assert_eq!(
        view.thinking_detail.as_deref(),
        Some("f.toml: [llm]: thinking_fields")
    );
    assert_eq!(view.thinking_on_json, None);
    assert_eq!(view.thinking_off_json, None);
}

/// The preset port carries the engine-side table (ADR-0019 item 5):
/// six named chips, the custom seventh is the pane's own, and every
/// share rides as JSON text the boxes can take verbatim.
#[test]
fn the_preset_port_carries_the_engine_table() {
    let presets = llm_presets();
    assert_eq!(presets.len(), 6, "custom is the pane's blank seventh");
    let row = |name: &str| {
        presets
            .iter()
            .find(|preset| preset.name == name)
            .unwrap_or_else(|| panic!("{name} missing"))
    };
    let anthropic = row("anthropic");
    assert_eq!(anthropic.format, "anthropic");
    assert_eq!(anthropic.base_url, "https://api.anthropic.com");
    assert!(anthropic.thinking_fields);
    assert!(anthropic.thinking_on_json.contains("adaptive"));
    let gemini = row("gemini");
    assert_eq!(gemini.format, "gemini");
    assert!(gemini.thinking_on_json.contains("includeThoughts"));
    // Every row's JSON parses back to an object — the boxes hold text.
    for preset in &presets {
        for json in [&preset.thinking_on_json, &preset.thinking_off_json] {
            let value: serde_json::Value = serde_json::from_str(json).unwrap();
            assert!(value.is_object(), "{}: {json}", preset.name);
        }
    }
    // The names are the vendor slot names the edit sends back.
    for preset in &presets {
        assert!(
            spokenrectifier_llm::Vendor::from_str_name(&preset.name).is_some(),
            "{} names no slot",
            preset.name
        );
    }
}

/// The quick panel's close-restore is a quiet no-op on the fake
/// engine (tests and demos hold no target window).
#[test]
fn restore_focus_is_a_noop_on_the_fake_engine() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    restore_focus().unwrap();
}

/// The demo host runs indefinitely: sessions keep working no matter how
/// many rectify attempts came before. Past the scripted queue, a failed
/// rectify surfaces as an Error event (never Preview), then Idle.
#[test]
fn repeated_sessions_never_run_dry() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    let mut rx = global().unwrap().engine.subscribe();

    // More sessions than the queued script count (setup queues 16).
    for session in 1..=20 {
        fake_begin_session().unwrap();
        execute(BridgeCommand::StartSession).unwrap();
        fake_say("第几场".into()).unwrap();
        fake_silence(1300).unwrap();
        block_on(wait_for(
            &mut rx,
            |event| matches!(event, EngineEvent::LiveTranscriptUpdated { text } if text.contains("第几场")),
        ));

        execute(BridgeCommand::StopSession).unwrap();
        let outcome = block_on(wait_for(&mut rx, |event| {
            matches!(
                event,
                EngineEvent::SessionStateChanged {
                    to: SessionState::Preview,
                    ..
                } | EngineEvent::Error { .. }
            )
        }));
        if let EngineEvent::Error { message } = outcome.event {
            panic!("session {session} failed after stop: {message}");
        }

        execute(BridgeCommand::ConfirmInsert {
            placeholders: Vec::new(),
        })
        .unwrap();
        block_on(wait_state(&mut rx, SessionState::Idle));
    }
    assert_eq!(
        inserted_texts().unwrap().last(),
        Some(&"修正后的书面文本".to_string())
    );
}

#[test]
fn fake_say_without_a_session_is_an_error() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    assert!(fake_say("没人听".into()).is_err());
}

#[test]
fn create_is_idempotent() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    create_fake_engine(vec!["第二次".into()]).unwrap();
    // The first engine's queue is still in effect.
    let mut rx = global().unwrap().engine.subscribe();
    fake_begin_session().unwrap();
    execute(BridgeCommand::StartSession).unwrap();
    fake_say("话".into()).unwrap();
    block_on(wait_for(
        &mut rx,
        |event| matches!(event, EngineEvent::LiveTranscriptUpdated { text } if text == "话"),
    ));
    execute(BridgeCommand::StopSession).unwrap();
    block_on(wait_state(&mut rx, SessionState::Preview));
    execute(BridgeCommand::ConfirmInsert {
        placeholders: Vec::new(),
    })
    .unwrap();
    block_on(wait_state(&mut rx, SessionState::Idle));
    assert_eq!(
        inserted_texts().unwrap().last(),
        Some(&"修正后的书面文本".to_string())
    );
}

/// History retrieval re-runs an utterance without a microphone: the
/// command goes through the wire, the machine runs to preview, and
/// the insert lands like any session's.
#[test]
fn rectify_text_through_the_bridge() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    let mut rx = global().unwrap().engine.subscribe();

    execute(BridgeCommand::RectifyText {
        raw_transcript: "历史上的原话".into(),
        style: BridgeSessionStyle::Live,
        source_session_id: None,
    })
    .unwrap();
    block_on(wait_state(&mut rx, SessionState::Preview));
    execute(BridgeCommand::ConfirmInsert {
        placeholders: Vec::new(),
    })
    .unwrap();
    block_on(wait_state(&mut rx, SessionState::Idle));
    assert_eq!(
        inserted_texts().unwrap().last(),
        Some(&"修正后的书面文本".to_string())
    );
}

/// The fake engine keeps no history file: the panel reads an empty
/// list and clear is a no-op, never an error.
#[test]
fn the_fake_engine_keeps_no_history() {
    let _guard = TEST_LOCK.lock().unwrap();
    setup();
    assert!(history_list(BridgeHistoryFilter::All).unwrap().is_empty());
    history_clear().unwrap();
    assert!(history_list(BridgeHistoryFilter::All).unwrap().is_empty());
}

#[test]
fn wire_types_mirror_every_engine_variant() {
    // One representative of each engine event maps onto the wire.
    let cases = vec![
        EngineEvent::SessionStateChanged {
            from: SessionState::Idle,
            to: SessionState::Recording,
        },
        EngineEvent::LiveTranscriptUpdated {
            text: "你好".into(),
        },
        EngineEvent::ParagraphMarked,
        EngineEvent::QuickMarked,
        EngineEvent::SpeechActivityChanged { speaking: true },
        EngineEvent::RectifiedTextChunk {
            delta: "好".into()
        },
        EngineEvent::RectifyThinkingDelta {
            delta: "想".into()
        },
        EngineEvent::PreviewPrefills {
            prefills: vec![spokenrectifier_engine::prefill::PrefillRow {
                number: 1,
                value: "张三".into(),
            }],
        },
        EngineEvent::PreviewTextUpdated {
            text: "好的".into(),
        },
        EngineEvent::TextInserted {
            text: "好的".into(),
        },
        EngineEvent::Error {
            message: "挂了".into(),
        },
    ];
    for event in cases {
        // Every variant maps without panicking; names stay 1:1.
        let _bridge: BridgeEvent = event.into();
    }
    // Spot-check the two variants whose payloads can drift silently.
    let mapped: BridgeEvent = EngineEvent::SessionStateChanged {
        from: SessionState::Recording,
        to: SessionState::Rectifying,
    }
    .into();
    assert_eq!(
        mapped,
        BridgeEvent::SessionStateChanged {
            from: BridgeSessionState::Recording,
            to: BridgeSessionState::Rectifying,
        }
    );
    let mapped: BridgeEvent = EngineEvent::RectifiedTextChunk {
        delta: "字".into()
    }
    .into();
    assert_eq!(
        mapped,
        BridgeEvent::RectifiedTextChunk {
            delta: "字".into()
        }
    );
    // The thinking channel maps onto its own wire variant (14 号票):
    // the marquee's feed, a sibling of the body chunk — never a part
    // of it.
    let mapped: BridgeEvent = EngineEvent::RectifyThinkingDelta {
        delta: "想".into()
    }
    .into();
    assert_eq!(
        mapped,
        BridgeEvent::RectifyThinkingDelta {
            delta: "想".into()
        }
    );
    // The prefill table's rows map field by field (ticket 18).
    let mapped: BridgeEvent = EngineEvent::PreviewPrefills {
        prefills: vec![
            spokenrectifier_engine::prefill::PrefillRow {
                number: 1,
                value: "张三".into(),
            },
            spokenrectifier_engine::prefill::PrefillRow {
                number: 10,
                value: String::new(),
            },
        ],
    }
    .into();
    assert_eq!(
        mapped,
        BridgeEvent::PreviewPrefills {
            prefills: vec![
                BridgePrefillRow {
                    number: 1,
                    value: "张三".into()
                },
                BridgePrefillRow {
                    number: 10,
                    value: String::new()
                },
            ]
        }
    );
    let envelope = EventEnvelope {
        seq: 7,
        session_id: spokenrectifier_engine::SessionId(3),
        at_ms: 1_000,
        event: EngineEvent::ParagraphMarked,
    };
    let bridge: BridgeEventEnvelope = envelope.into();
    assert_eq!(bridge.seq, 7);
    assert_eq!(bridge.session_id, 3);
    assert_eq!(bridge.at_ms, 1_000);
    assert_eq!(bridge.event, BridgeEvent::ParagraphMarked);
}
