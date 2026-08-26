//! One-off handshake probe: load the `[asr]` config from a directory and
//! try a raw production-shaped connect once, printing the HTTP error body
//! on rejection. Never prints the key. Diagnostic tool for ticket 04.
//! Pass a second argument to also send a User-Agent header.

use spokenrectifier_aliyun::load_asr_config;
use tokio_tungstenite::tungstenite::Error as WsError;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let dir = std::env::args()
        .nth(1)
        .expect("usage: probe <config-dir> [with-user-agent]");
    let with_ua = std::env::args().nth(2).is_some();
    let config = load_asr_config(&[dir.into()]).expect("config loads");
    let endpoint = config.endpoint();
    println!("endpoint: {endpoint}");
    let key = config.resolve_key().expect("key resolves");
    println!("key: present ({} chars), user-agent: {with_ua}", key.len());
    println!("connecting...");

    let mut request = endpoint.as_str().into_client_request().unwrap();
    request
        .headers_mut()
        .insert("Authorization", format!("Bearer {key}").parse().unwrap());
    if with_ua {
        request
            .headers_mut()
            .insert("User-Agent", "spokenrectifier-probe".parse().unwrap());
    }
    match tokio_tungstenite::connect_async(request).await {
        Ok((_ws, resp)) => println!("RESULT: HANDSHAKE OK ({:?})", resp.status()),
        Err(WsError::Http(resp)) => {
            println!("RESULT: HTTP {} body: {:?}", resp.status(), resp.body())
        }
        Err(other) => println!("RESULT: HANDSHAKE FAILED: {other}"),
    }
}
