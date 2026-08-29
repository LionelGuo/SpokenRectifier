//! The connection seam shared by every cloud ASR adapter: production
//! WebSocket vs scripted tests.
//!
//! A [`RealtimeConnect`] hands out one [`RealtimeChannel`] per
//! connection: a sender for client messages and a receiver for server
//! messages (`Err` carries a lost connection). Which bytes a "message"
//! is depends on the vendor — DashScope speaks text JSON frames,
//! Volcengine gzip'd binary frames — so the channel is generic over the
//! message type and a [`WireCodec`] bridges to the socket. Tests script
//! both directions through plain channels, which is what keeps each
//! adapter's protocol logic deterministic.

use std::sync::Arc;

use async_trait::async_trait;
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;

/// One live realtime connection.
pub struct RealtimeChannel<M> {
    /// Client-to-server messages.
    pub tx: mpsc::Sender<M>,
    /// Server-to-client messages; `Err` means the connection is lost.
    pub rx: mpsc::Receiver<Result<M, String>>,
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
pub trait RealtimeConnect<M>: Send + Sync {
    async fn connect(&self) -> Result<RealtimeChannel<M>, ConnectError>;
}

/// How a vendor's messages ride the WebSocket: text frames (JSON
/// dialects) or binary frames (Volcengine's gzip'd protocol). Pings are
/// answered either way; other frame kinds are unused by every dialect
/// here. Codecs are stateless markers, so `Clone` is free.
pub trait WireCodec: Send + Sync + 'static + Clone {
    type Message: Send;

    /// One client message onto the socket.
    fn encode(&self, message: &Self::Message) -> tokio_tungstenite::tungstenite::Message;

    /// One server socket frame back into a message, when it is one this
    /// dialect carries (a `Ping`/`Pong`/`Close` never is).
    fn decode(&self, frame: tokio_tungstenite::tungstenite::Message) -> Option<Self::Message>;
}

/// The text-frame codec: JSON-speaking dialects (DashScope, Tencent).
#[derive(Debug, Clone, Copy, Default)]
pub struct TextWire;

impl WireCodec for TextWire {
    type Message = String;

    fn encode(&self, message: &String) -> tokio_tungstenite::tungstenite::Message {
        tokio_tungstenite::tungstenite::Message::text(message.as_str())
    }

    fn decode(&self, frame: tokio_tungstenite::tungstenite::Message) -> Option<String> {
        match frame {
            tokio_tungstenite::tungstenite::Message::Text(text) => Some(text.as_str().to_string()),
            _ => None,
        }
    }
}

/// The binary-frame codec (Volcengine's framed protocol).
#[derive(Debug, Clone, Copy, Default)]
pub struct BytesWire;

impl WireCodec for BytesWire {
    type Message = Vec<u8>;

    fn encode(&self, message: &Vec<u8>) -> tokio_tungstenite::tungstenite::Message {
        tokio_tungstenite::tungstenite::Message::binary(message.clone())
    }

    fn decode(&self, frame: tokio_tungstenite::tungstenite::Message) -> Option<Vec<u8>> {
        match frame {
            tokio_tungstenite::tungstenite::Message::Binary(bytes) => Some(bytes.to_vec()),
            _ => None,
        }
    }
}

/// Production transport: tokio-tungstenite against the vendor's
/// WebSocket endpoint. Headers are (re)built per attempt, so a
/// per-connection value (Volcengine's connect id) can vary across
/// reconnects.
pub struct TungsteniteConnect<C: WireCodec> {
    url: String,
    headers: Arc<dyn Fn() -> Vec<(String, String)> + Send + Sync>,
    codec: C,
}

impl<C: WireCodec> TungsteniteConnect<C> {
    /// Static headers (e.g. the DashScope bearer key).
    pub fn new(url: String, headers: Vec<(String, String)>, codec: C) -> Self {
        Self::with_dynamic_headers(url, Arc::new(move || headers.clone()), codec)
    }

    /// Headers built per connect attempt.
    pub fn with_dynamic_headers(
        url: String,
        headers: Arc<dyn Fn() -> Vec<(String, String)> + Send + Sync>,
        codec: C,
    ) -> Self {
        Self {
            url,
            headers,
            codec,
        }
    }
}

#[async_trait]
impl<C: WireCodec> RealtimeConnect<C::Message> for TungsteniteConnect<C> {
    async fn connect(&self) -> Result<RealtimeChannel<C::Message>, ConnectError> {
        use std::str::FromStr as _;
        use tokio_tungstenite::tungstenite::Message;
        use tokio_tungstenite::tungstenite::client::IntoClientRequest;

        let mut request = self
            .url
            .as_str()
            .into_client_request()
            .map_err(|e| ConnectError::Other(format!("bad endpoint URL: {e}")))?;
        use tokio_tungstenite::tungstenite::http::header::{HeaderName, HeaderValue};
        for (name, value) in (self.headers)() {
            let name = HeaderName::from_str(&name)
                .map_err(|_| ConnectError::Other(format!("invalid header name: {name}")))?;
            let value = HeaderValue::from_str(&value)
                .map_err(|_| ConnectError::Other(format!("invalid {name} header value")))?;
            request.headers_mut().insert(name, value);
        }

        let (ws, _response) =
            tokio_tungstenite::connect_async(request)
                .await
                .map_err(|e| match e {
                    tokio_tungstenite::tungstenite::Error::Http(resp) => {
                        let status = resp.status().as_u16();
                        // The rejection body carries the gateway's own
                        // reason (e.g. "resourceId ... is not allowed") —
                        // the status alone would hide it.
                        let body = resp
                            .body()
                            .as_ref()
                            .map(|bytes| String::from_utf8_lossy(bytes).trim().to_string())
                            .filter(|text| !text.is_empty())
                            .map(|text| format!(": {text}"))
                            .unwrap_or_default();
                        let message = format!("handshake rejected: HTTP {status}{body}");
                        if status == 401 || status == 403 {
                            ConnectError::Auth(message)
                        } else {
                            ConnectError::Other(message)
                        }
                    }
                    other => ConnectError::Other(format!("connection failed: {other}")),
                })?;

        let codec = self.codec.clone();
        let (client_tx, mut client_rx) = mpsc::channel::<C::Message>(64);
        let (server_tx, server_rx) = mpsc::channel::<Result<C::Message, String>>(64);

        // One task per connection: multiplexes our outgoing messages with
        // the socket's incoming ones, answers protocol pings, and reports
        // the first failure on the server channel.
        tokio::spawn(async move {
            let (mut sink, mut stream) = ws.split();
            loop {
                tokio::select! {
                    outgoing = client_rx.recv() => {
                        let Some(message) = outgoing else { break };
                        if sink.send(codec.encode(&message)).await.is_err() {
                            break;
                        }
                    }
                    incoming = stream.next() => {
                        match incoming {
                            Some(Ok(Message::Ping(payload))) => {
                                if sink.send(Message::Pong(payload)).await.is_err() {
                                    break;
                                }
                            }
                            Some(Ok(frame)) => {
                                if let Some(message) = codec.decode(frame)
                                    && server_tx.send(Ok(message)).await.is_err()
                                {
                                    break; // adapter side gone
                                }
                            }
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
