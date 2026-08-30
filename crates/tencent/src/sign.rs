//! The signed connect URL: every query parameter but `signature` —
//! secretid, timestamp, expired, nonce, engine, voice id, the hotword
//! list… — sorted by key and appended to `host/asr/v2/<appid>` forms
//! the signing string; `Base64(HMAC-SHA1(string, SecretKey))` is
//! percent-encoded in as the `signature` parameter. The server
//! re-derives the same string from the (decoded) query it received, so
//! the URL must percent-encode values while the signature covers their
//! raw forms.
//!
//! Deterministic in every input: production passes the wall clock, a
//! fresh nonce, and a fresh voice id per attempt (the endpoint refuses
//! a reused voice id), which tests pin to fixed values.

/// How long a signature stays valid: comfortably past any session's
/// life, far inside the documented 90-day ceiling.
const SIGNATURE_TTL_SECONDS: u64 = 3600;
/// The server VAD's close-out silence. The floor of the documented
/// 500–2000 ms range, comfortably inside the send gate's 1000 ms pad —
/// the pause our pad carries is what closes the server's utterance.
const VAD_SILENCE_TIME_MS: u64 = 500;
/// The documented hotword-list limits: at most 128 terms, each at most
/// 30 characters (≈10 汉字).
const HOTWORD_MAX_TERMS: usize = 128;
const HOTWORD_MAX_TERM_CHARS: usize = 30;
/// The weight every dictionary term rides with: high, below the
/// super-hotword 11 (the engine's terms are a bias, not an override).
const HOTWORD_WEIGHT: &str = "10";

/// The per-attempt inputs the URL bakes in.
pub(crate) struct UrlInputs<'a> {
    /// The resolved endpoint: `scheme://host/asr/v2/<appid>`.
    pub endpoint: &'a str,
    pub secret_id: &'a str,
    pub secret_key: &'a str,
    /// The engine model (`engine_model_type` — this protocol's name for
    /// "which model").
    pub engine_model_type: &'a str,
    /// The stream's hotword dictionary.
    pub terms: &'a [String],
    /// The signing timestamp, unix seconds.
    pub now_unix: u64,
    /// A random positive int under the documented 10-digit ceiling.
    pub nonce: u64,
    /// A fresh UUID per connection.
    pub voice_id: &'a str,
}

/// Build the full signed WebSocket URL for one connect attempt.
pub(crate) fn signed_url(inputs: UrlInputs<'_>) -> String {
    // The signature covers exactly what follows the scheme: host, path,
    // sorted query with raw values.
    let (scheme, signed_part) = inputs
        .endpoint
        .split_once("://")
        .unwrap_or(("wss", inputs.endpoint));

    let mut params: Vec<(&str, String)> = vec![
        ("engine_model_type", inputs.engine_model_type.to_string()),
        (
            "expired",
            (inputs.now_unix + SIGNATURE_TTL_SECONDS).to_string(),
        ),
        ("needvad", "1".to_string()),
        ("nonce", inputs.nonce.to_string()),
        ("secretid", inputs.secret_id.to_string()),
        ("timestamp", inputs.now_unix.to_string()),
        ("vad_silence_time", VAD_SILENCE_TIME_MS.to_string()),
        ("voice_format", "1".to_string()), // PCM
        ("voice_id", inputs.voice_id.to_string()),
    ];
    let hotwords = hotword_list(inputs.terms);
    if !hotwords.is_empty() {
        params.push(("hotword_list", hotwords));
    }
    params.sort_by(|a, b| a.0.cmp(b.0));

    let sign_source = format!(
        "{signed_part}?{}",
        params
            .iter()
            .map(|(key, value)| format!("{key}={value}"))
            .collect::<Vec<_>>()
            .join("&")
    );
    let signature = hmac_sha1_base64(&sign_source, inputs.secret_key);

    let query = params
        .iter()
        .map(|(key, value)| format!("{key}={}", percent_encode(value)))
        .chain([format!("signature={}", percent_encode(&signature))])
        .collect::<Vec<_>>()
        .join("&");
    format!("{scheme}://{signed_part}?{query}")
}

/// The dictionary as the `hotword_list` parameter (`"词|权重,…"`):
/// terms admitted whole until one of the documented limits — never a
/// partial term, never a blank.
pub(crate) fn hotword_list(terms: &[String]) -> String {
    terms
        .iter()
        .filter_map(|term| {
            let term = term.trim();
            (!term.is_empty() && term.chars().count() <= HOTWORD_MAX_TERM_CHARS)
                .then(|| format!("{term}|{HOTWORD_WEIGHT}"))
        })
        .take(HOTWORD_MAX_TERMS)
        .collect::<Vec<_>>()
        .join(",")
}

/// The signing primitive: `Base64(HMAC-SHA1(source, SecretKey))`.
fn hmac_sha1_base64(source: &str, secret_key: &str) -> String {
    use base64::Engine as _;
    use hmac::Mac;

    let mut mac = <hmac::Hmac<sha1::Sha1> as Mac>::new_from_slice(secret_key.as_bytes())
        .expect("HMAC accepts any key length");
    mac.update(source.as_bytes());
    base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes())
}

/// RFC 3986 percent-encoding (unreserved: alphanumeric and `-._~`) —
/// the base64 signature's `+/=` and the hotword list's `|,` and CJK
/// all need it.
fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(*byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inputs<'a>(terms: &'a [String]) -> UrlInputs<'a> {
        UrlInputs {
            endpoint: "wss://asr.cloud.tencent.com/asr/v2/1250012548",
            secret_id: "AKIDtestsecretid",
            secret_key: "test-secret-key",
            engine_model_type: "16k_zh_en",
            terms,
            now_unix: 1_700_000_000,
            nonce: 12345,
            voice_id: "aaaa-bbbb-cccc-dddd",
        }
    }

    #[test]
    fn the_url_matches_the_independently_computed_golden_form() {
        let terms: Vec<String> = ["语音实验室", "SpokenRectifier"]
            .iter()
            .map(|t| t.to_string())
            .collect();
        let url = signed_url(inputs(&terms));
        assert_eq!(
            url,
            "wss://asr.cloud.tencent.com/asr/v2/1250012548\
             ?engine_model_type=16k_zh_en\
             &expired=1700003600\
             &hotword_list=%E8%AF%AD%E9%9F%B3%E5%AE%9E%E9%AA%8C%E5%AE%A4%7C10%2CSpokenRectifier%7C10\
             &needvad=1\
             &nonce=12345\
             &secretid=AKIDtestsecretid\
             &timestamp=1700000000\
             &vad_silence_time=500\
             &voice_format=1\
             &voice_id=aaaa-bbbb-cccc-dddd\
             &signature=Ks3TzLaujG2Y6CCglyRNNSu81g8%3D"
        );
    }

    /// The URL the builder emits must verify against its own contents:
    /// decode the query, re-derive the signing string from the raw
    /// values, re-sign it. (A golden string pins one shape; this pins
    /// the recipe.)
    #[test]
    fn the_emitted_url_verifies_against_its_own_query() {
        let url = signed_url(inputs(&[]));
        let (part, query) = url.split_once('?').unwrap();
        let mut params: Vec<(String, String)> = query
            .split('&')
            .map(|pair| pair.split_once('=').unwrap())
            .map(|(k, v)| (k.to_string(), percent_decode(v)))
            .collect();
        let signature = params.remove(params.len() - 1).1;
        params.sort();
        let sign_source = format!(
            "{}?{}",
            part.trim_start_matches("wss://"),
            params
                .iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>()
                .join("&")
        );
        assert_eq!(hmac_sha1_base64(&sign_source, "test-secret-key"), signature);
        // The raw values survive the round trip — what was signed is
        // what the server will decode.
        assert!(params.contains(&("needvad".into(), "1".into())));
        assert!(params.contains(&("expired".into(), "1700003600".into())));
    }

    #[test]
    fn every_freshness_field_changes_the_url() {
        let base = signed_url(inputs(&[]));
        let mut varied = inputs(&[]);
        varied.now_unix += 1;
        assert_ne!(signed_url(varied), base);
        let mut varied = inputs(&[]);
        varied.nonce += 1;
        assert_ne!(signed_url(varied), base);
        let mut varied = inputs(&[]);
        varied.voice_id = "eeee-ffff-gggg-hhhh";
        assert_ne!(signed_url(varied), base);
        // The same inputs sign the same URL — determinism is what makes
        // the golden form above meaningful.
        assert_eq!(signed_url(inputs(&[])), base);
    }

    #[test]
    fn the_dictionary_rides_capped_to_the_documented_limits() {
        let terms: Vec<String> = ["语音实验室", "SpokenRectifier"]
            .iter()
            .map(|t| t.to_string())
            .collect();
        assert_eq!(hotword_list(&terms), "语音实验室|10,SpokenRectifier|10");

        // Blanks never ride; an over-long term is skipped whole (a
        // partial term would bias nothing).
        let over_long = format!("超长术词语{}", "语".repeat(HOTWORD_MAX_TERM_CHARS));
        assert!(over_long.chars().count() > HOTWORD_MAX_TERM_CHARS);
        let mixed: Vec<String> = ["", "  ", over_long.as_str()]
            .iter()
            .map(|t| t.to_string())
            .collect();
        assert_eq!(hotword_list(&mixed), "");
        assert_eq!(hotword_list(&[]), "");

        // The 128-term cap: head admitted, tail dropped.
        let many: Vec<String> = (0..200).map(|i| format!("术语{i}")).collect();
        let list = hotword_list(&many);
        assert_eq!(list.split(',').count(), HOTWORD_MAX_TERMS);
        assert!(list.starts_with("术语0|10,术语1|10,"));
        assert!(!list.contains("术语128"));

        // An empty dictionary leaves the parameter out entirely.
        let url = signed_url(inputs(&[]));
        assert!(!url.contains("hotword_list"));
    }

    fn percent_decode(text: &str) -> String {
        let bytes = text.as_bytes();
        let mut out = Vec::new();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'%' && i + 2 < bytes.len() {
                out.push(u8::from_str_radix(&text[i + 1..i + 3], 16).unwrap());
                i += 3;
            } else {
                out.push(bytes[i]);
                i += 1;
            }
        }
        String::from_utf8(out).unwrap()
    }
}
