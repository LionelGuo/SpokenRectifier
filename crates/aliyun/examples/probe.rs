//! One-off handshake probe: load the `[asr]` config from a directory and
//! try a raw production-shaped connect once, printing the HTTP error body
//! on rejection. Never prints the key. Diagnostic tool for ticket 04.
//! Pass a second argument to also send a User-Agent header.

use spokenrectifier_asr::schema::{AsrProviderKind, load_asr_config};
use spokenrectifier_asr::transport::{TextWire, TungsteniteConnect};
use spokenrectifier_asr::{ConnectError, RealtimeConnect};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let dir = std::env::args()
        .nth(1)
        .expect("usage: probe <config-dir> [with-user-agent]");
    let with_ua = std::env::args().nth(2).is_some();
    let config = load_asr_config(&[dir.into()]).expect("config loads");
    assert_eq!(
        config.provider,
        AsrProviderKind::Aliyun,
        "probe is aliyun-only"
    );
    let endpoint = config.endpoint().expect("endpoint resolves");
    println!("endpoint: {endpoint}");
    let key = config
        .resolve_common_key()
        .expect("key resolves (api_key or DASHSCOPE_API_KEY)");
    println!("key: present ({} chars), user-agent: {with_ua}", key.len());
    println!("connecting...");

    let mut headers = vec![("Authorization".to_string(), format!("Bearer {key}"))];
    if with_ua {
        headers.push(("User-Agent".to_string(), "spokenrectifier-probe".into()));
    }
    let connect = TungsteniteConnect::new(endpoint, headers, TextWire);
    match connect.connect().await {
        Ok(_channel) => println!("RESULT: HANDSHAKE OK"),
        Err(ConnectError::Auth(message)) => println!("RESULT: AUTH REJECTED: {message}"),
        Err(ConnectError::Other(message)) => println!("RESULT: HANDSHAKE FAILED: {message}"),
    }
}
