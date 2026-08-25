//! The connection seam: production WebSocket vs scripted tests.
//!
//! A [`RealtimeConnect`] hands out one [`RealtimeChannel`] per connection:
//! a sender for client text events and a receiver for server events
//! (`Err` carries a lost connection). Production speaks
//! tokio-tungstenite against the DashScope realtime endpoint; tests
//! script both directions through plain channels, which is what keeps the
//! adapter's protocol logic deterministic.

use async_trait::async_trait;
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;

/// One live realtime connection.
pub struct RealtimeChannel {
    /// Client-to-server text events (JSON strings).
    pub tx: mpsc::Sender<String>,
    /// Server-to-client text events; `Err` means the connection is lost.
    pub rx: mpsc::Receiver<Result<String, String>>,
}

/// Why a connect attempt failed.
#[derive(Debug, Clone)]
pub enum ConnectError {
    /// Credentials rejected (HTTP 401/403): retrying will not help.
    Auth(String),
    /// Anything else — unreachable, timed out, protocol trouble.
    Other(String),
}

impl std::fmt::Display for ConnectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnectError::Auth(message) | ConnectError::Other(message) => f.write_str(message),
        }
    }
}

/// Factory for realtime connections; injectable so tests script the
/// server. `Err` from `connect` failed before the session began (auth,
/// unreachable endpoint).
#[async_trait]
pub trait RealtimeConnect: Send + Sync {
    async fn connect(&self) -> Result<RealtimeChannel, ConnectError>;
}

/// Production transport: tokio-tungstenite against the DashScope realtime
/// WebSocket, authenticated with the Bailian API key.
pub struct TungsteniteConnect {
    url: String,
    api_key: String,
}

impl TungsteniteConnect {
    pub fn new(url: String, api_key: String) -> Self {
        Self { url, api_key }
    }
}

#[async_trait]
impl RealtimeConnect for TungsteniteConnect {
    async fn connect(&self) -> Result<RealtimeChannel, ConnectError> {
        use tokio_tungstenite::tungstenite::Message;
        use tokio_tungstenite::tungstenite::client::IntoClientRequest;
        use tokio_tungstenite::tungstenite::http::header::AUTHORIZATION;

        let mut request = self
            .url
            .as_str()
            .into_client_request()
            .map_err(|e| ConnectError::Other(format!("bad endpoint URL: {e}")))?;
        request.headers_mut().insert(
            AUTHORIZATION,
            format!("Bearer {}", self.api_key)
                .parse()
                .map_err(|_| ConnectError::Other("invalid api key".to_string()))?,
        );

        let (ws, _response) =
            tokio_tungstenite::connect_async(request)
                .await
                .map_err(|e| match e {
                    tokio_tungstenite::tungstenite::Error::Http(resp) => {
                        let status = resp.status().as_u16();
                        let message = format!("handshake rejected: HTTP {status}");
                        if status == 401 || status == 403 {
                            ConnectError::Auth(message)
                        } else {
                            ConnectError::Other(message)
                        }
                    }
                    other => ConnectError::Other(format!("connection failed: {other}")),
                })?;

        let (client_tx, mut client_rx) = mpsc::channel::<String>(64);
        let (server_tx, server_rx) = mpsc::channel::<Result<String, String>>(64);

        // One task per connection: multiplexes our outgoing events with the
        // socket's incoming ones, answers protocol pings, and reports the
        // first failure on the server channel.
        tokio::spawn(async move {
            let (mut sink, mut stream) = ws.split();
            loop {
                tokio::select! {
                    outgoing = client_rx.recv() => {
                        let Some(text) = outgoing else { break };
                        if sink.send(Message::text(text)).await.is_err() {
                            break;
                        }
                    }
                    incoming = stream.next() => {
                        match incoming {
                            Some(Ok(Message::Text(text))) => {
                                if server_tx.send(Ok(text.as_str().to_string())).await.is_err() {
                                    break; // adapter side gone
                                }
                            }
                            Some(Ok(Message::Ping(payload))) => {
                                if sink.send(Message::Pong(payload)).await.is_err() {
                                    break;
                                }
                            }
                            Some(Ok(_)) => {} // binary/pong/close frames unused here
                            Some(Err(e)) => {
                                let _ = server_tx.send(Err(format!("connection lost: {e}"))).await;
                                break;
                            }
                            None => {
                                let _ = server_tx
                                    .send(Err("connection closed by server".into()))
                                    .await;
                                break;
                            }
                        }
                    }
                }
            }
            // Dropping `sink`/`stream` here closes the socket.
        });

        Ok(RealtimeChannel {
            tx: client_tx,
            rx: server_rx,
        })
    }
}
