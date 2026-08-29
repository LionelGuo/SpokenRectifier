//! A one-shot handshake probe against the real Seed-ASR endpoint —
//! the volcengine twin of the aliyun probe: connect with the
//! production headers, send the production full request plus a
//! second of silence and the last packet, and report exactly what
//! the server says. Raw tungstenite (not the app's transport) so a
//! rejected handshake's response body and log id are visible — the
//! gateway writes the reason there. Credentials come from the
//! environment (`VOLC_APP_ID`, `VOLC_ACCESS_KEY`, optional
//! `VOLC_RESOURCE_ID`, `VOLC_URL`, `VOLC_NO_APP_KEY`) and are never
//! printed.

use std::str::FromStr;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};

use spokenrectifier_volcengine::{decode, encode_audio, encode_full_request, encode_last_packet};

/// Mirrors `protocol::full_request_json` (crate-private) with no
/// hotwords — the same wire shape the adapter sends.
fn full_request_json() -> String {
    serde_json::json!({
        "user": { "uid": "spokenrectifier" },
        "audio": {
            "format": "pcm",
            "rate": 16000,
            "bits": 16,
            "channel": 1,
        },
        "request": {
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "show_utterances": true,
        },
    })
    .to_string()
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let app_id = std::env::var("VOLC_APP_ID").expect("VOLC_APP_ID");
    let access_key = std::env::var("VOLC_ACCESS_KEY").expect("VOLC_ACCESS_KEY");
    let resource_id =
        std::env::var("VOLC_RESOURCE_ID").unwrap_or_else(|_| "volc.seedasr.sauc.duration".into());
    let endpoint = std::env::var("VOLC_URL")
        .unwrap_or_else(|_| "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel".into());

    let mut request = endpoint.clone().into_client_request().unwrap();
    let headers = request.headers_mut();
    let mut add = |name: &str, value: String| {
        headers.insert(
            HeaderName::from_str(name).unwrap(),
            HeaderValue::from_str(&value).unwrap(),
        );
    };
    if std::env::var_os("VOLC_NO_APP_KEY").is_none() {
        add("X-Api-App-Key", app_id.clone());
    }
    add("X-Api-Access-Key", access_key.clone());
    add("X-Api-Resource-Id", resource_id.clone());
    add("X-Api-Connect-Id", uuid::Uuid::new_v4().to_string());

    println!("probe: connecting {endpoint}");
    let (mut ws, response) = match tokio_tungstenite::connect_async(request).await {
        Ok((ws, response)) => (ws, response),
        Err(err) => {
            println!("probe: HANDSHAKE FAILED: {err}");
            if let tokio_tungstenite::tungstenite::Error::Http(response) = err {
                println!("probe: status {}", response.status());
                for (name, value) in response.headers().iter() {
                    println!("probe: response header {name}: {value:?}");
                }
                if let Some(body) = response.body() {
                    println!("probe: response body: {}", String::from_utf8_lossy(body));
                }
            }
            std::process::exit(2);
        }
    };
    println!("probe: handshake ok ({})", response.status());
    for (name, value) in response.headers().iter() {
        if name.as_str().starts_with("x-tt-") {
            println!("probe: response header {name}: {value:?}");
        }
    }

    let json = full_request_json();
    ws.send(Message::Binary(encode_full_request(&json).into()))
        .await
        .unwrap();
    println!("probe: full request sent ({} bytes json)", json.len());

    // A second of silence, paced, then the last packet.
    let silence = vec![0i16; 1600]; // 100 ms at 16 kHz
    for _ in 0..10 {
        ws.send(Message::Binary(encode_audio(&silence).into()))
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        if let Ok(Some(frame)) = tokio::time::timeout(Duration::from_millis(1), ws.next()).await {
            report(frame);
        }
    }
    ws.send(Message::Binary(encode_last_packet().into()))
        .await
        .unwrap();
    println!("probe: last packet sent");

    // Whatever the server says from here decides the verdict.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < deadline {
        let wait = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(wait, ws.next()).await {
            Ok(Some(frame)) => report(frame),
            Ok(None) => break, // server closed
            Err(_) => break,   // idle: nothing more coming
        }
    }
    println!("probe: done");
}

fn report(frame: Result<Message, tokio_tungstenite::tungstenite::Error>) {
    match frame {
        Ok(Message::Binary(bytes)) => match decode(&bytes) {
            Ok(spokenrectifier_volcengine::ServerFrame::Response(text)) => {
                println!("probe: server response: {text}")
            }
            Ok(spokenrectifier_volcengine::ServerFrame::Error(text)) => {
                println!("probe: SERVER ERROR FRAME: {text}");
                std::process::exit(3);
            }
            Ok(spokenrectifier_volcengine::ServerFrame::Keepalive) => {
                println!("probe: keepalive ack")
            }
            Err(err) => println!("probe: undecodable frame ({err:?}): {} bytes", bytes.len()),
        },
        Ok(other) => println!("probe: unexpected message: {other:?}"),
        Err(err) => {
            println!("probe: CONNECTION LOST: {err}");
            std::process::exit(4);
        }
    }
}
