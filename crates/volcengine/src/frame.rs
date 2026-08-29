//! The Seed-ASR bigmodel binary frame codec: Volcengine's `sauc` v3
//! wire format.
//!
//! Every frame is a small fixed header plus a big-endian `u32` payload
//! size plus the payload:
//!
//! ```text
//! byte 0  (protocol version << 4) | (header size in 4-byte units)
//! byte 1  (message type << 4)     | message flags
//! byte 2  (serialization << 4)    | compression
//! byte 3  reserved
//! bytes 4..8  payload size, big-endian u32
//! bytes 8..   payload
//! ```
//!
//! The full client request's payload is JSON, gzip-compressed; audio
//! payloads are raw PCM, gzip-compressed; the last-packet marker and
//! keepalive frames carry no payload at all. Server responses repeat
//! the same header shape (payload JSON, gzip or not per the
//! compression nibble); errors are their own message type. Everything
//! here is pure bytes in and out — deterministic by construction.

use std::io::{Read, Write};

/// Protocol version and header size nibbles: version 1, one 4-byte
/// header unit (no sequence fields ride our frames).
const HEADER_BYTE_0: u8 = (0b0001 << 4) | 0b0001;

/// Message types (the high nibble of byte 1).
pub(crate) const MESSAGE_FULL_CLIENT_REQUEST: u8 = 0b0001;
pub(crate) const MESSAGE_AUDIO_ONLY: u8 = 0b0010;
const MESSAGE_FULL_SERVER_RESPONSE: u8 = 0b1001;
const MESSAGE_SERVER_ERROR: u8 = 0b1011;
pub(crate) const MESSAGE_KEEPALIVE: u8 = 0b1111;

/// Audio-only flags (the low nibble of byte 1): `0b0010` marks the
/// stream's last packet (no timestamp rides it).
pub(crate) const FLAG_LAST_PACKET: u8 = 0b0010;

/// Serialization methods (the high nibble of byte 2).
const SERIALIZATION_NONE: u8 = 0b0000;
const SERIALIZATION_JSON: u8 = 0b0001;

/// Compression methods (the low nibble of byte 2).
const COMPRESSION_NONE: u8 = 0b0000;
const COMPRESSION_GZIP: u8 = 0b0001;

/// One decoded server frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerFrame {
    /// A full server response; the payload as UTF-8 JSON text.
    Response(String),
    /// An error frame; the payload as UTF-8 JSON text (a `code` plus a
    /// `message`).
    Error(String),
    /// A keepalive ack — nothing to act on.
    Keepalive,
}

/// A frame parse failure: the bytes were not a frame this codec knows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrameError;

/// Assemble one frame from its nibbles, size, and payload.
fn frame(
    message_type: u8,
    flags: u8,
    serialization: u8,
    compression: u8,
    payload: &[u8],
) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(8 + payload.len());
    bytes.push(HEADER_BYTE_0);
    bytes.push((message_type << 4) | flags);
    bytes.push((serialization << 4) | compression);
    bytes.push(0); // reserved
    bytes.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    bytes.extend_from_slice(payload);
    bytes
}

/// The session-opening frame: the full client request, JSON, gzip'd.
pub fn encode_full_request(json: &str) -> Vec<u8> {
    frame(
        MESSAGE_FULL_CLIENT_REQUEST,
        0,
        SERIALIZATION_JSON,
        COMPRESSION_GZIP,
        &gzip(json.as_bytes()),
    )
}

/// One audio frame: raw little-endian PCM, gzip'd, a mid-stream packet.
pub fn encode_audio(samples: &[i16]) -> Vec<u8> {
    let pcm: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
    frame(
        MESSAGE_AUDIO_ONLY,
        0,
        SERIALIZATION_NONE,
        COMPRESSION_GZIP,
        &gzip(&pcm),
    )
}

/// The stream's last packet: an audio-only frame with the last-packet
/// flag and no payload — the graceful end of one direction.
pub fn encode_last_packet() -> Vec<u8> {
    frame(
        MESSAGE_AUDIO_ONLY,
        FLAG_LAST_PACKET,
        SERIALIZATION_NONE,
        COMPRESSION_NONE,
        &[],
    )
}

/// A keepalive frame: header only, no payload — liveness for streams
/// the server times out when nothing arrives (error 45000081).
pub fn encode_keepalive() -> Vec<u8> {
    frame(
        MESSAGE_KEEPALIVE,
        0,
        SERIALIZATION_NONE,
        COMPRESSION_NONE,
        &[],
    )
}

/// Decode one server frame. Never trusts the stated header size or
/// payload size beyond the bytes actually present.
pub fn decode(bytes: &[u8]) -> Result<ServerFrame, FrameError> {
    if bytes.len() < 8 {
        return Err(FrameError);
    }
    let header_size = (bytes[0] & 0x0F) as usize * 4;
    let message_type = bytes[1] >> 4;
    let compression = bytes[2] & 0x0F;
    let header_end = header_size.max(4);
    // The payload size sits right after the header (sequence fields the
    // server may have added live inside the header, before it).
    let size_at = header_end;
    let payload_at = header_end + 4;
    if size_at + 4 > bytes.len() {
        return Err(FrameError);
    }
    let size = u32::from_be_bytes(
        bytes[size_at..size_at + 4]
            .try_into()
            .map_err(|_| FrameError)?,
    ) as usize;
    let Some(payload) = bytes.get(payload_at..payload_at + size) else {
        return Err(FrameError);
    };
    let payload = match compression {
        COMPRESSION_GZIP => gunzip(payload)?,
        _ => payload.to_vec(),
    };
    match message_type {
        MESSAGE_FULL_SERVER_RESPONSE => Ok(ServerFrame::Response(
            String::from_utf8(payload).map_err(|_| FrameError)?,
        )),
        MESSAGE_SERVER_ERROR => Ok(ServerFrame::Error(
            String::from_utf8(payload).map_err(|_| FrameError)?,
        )),
        MESSAGE_KEEPALIVE => Ok(ServerFrame::Keepalive),
        _ => Err(FrameError),
    }
}

fn gzip(data: &[u8]) -> Vec<u8> {
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(data).expect("gzip of a buffer");
    encoder.finish().expect("gzip of a buffer")
}

fn gunzip(data: &[u8]) -> Result<Vec<u8>, FrameError> {
    let mut decoder = flate2::read::GzDecoder::new(data);
    let mut out = Vec::new();
    decoder.read_to_end(&mut out).map_err(|_| FrameError)?;
    Ok(out)
}

/// The message type and decompressed payload of one CLIENT frame — the
/// direction `decode` refuses, which the adapter's tests still need to
/// read back.
#[cfg(test)]
pub(crate) fn client_payload(bytes: &[u8]) -> (u8, Vec<u8>) {
    assert!(bytes.len() >= 8, "short frame: {bytes:?}");
    let compression = bytes[2] & 0x0F;
    let size = u32::from_be_bytes(bytes[4..8].try_into().unwrap()) as usize;
    let payload = &bytes[8..8 + size];
    let payload = match compression {
        COMPRESSION_GZIP => gunzip(payload).unwrap(),
        _ => payload.to_vec(),
    };
    (bytes[1] >> 4, payload)
}

/// A full server response frame (JSON, gzip'd) — what the tests feed
/// the adapter from the server side.
#[cfg(test)]
pub(crate) fn encode_server_response(json: &str) -> Vec<u8> {
    frame(
        MESSAGE_FULL_SERVER_RESPONSE,
        0,
        SERIALIZATION_JSON,
        COMPRESSION_GZIP,
        &gzip(json.as_bytes()),
    )
}

/// An error frame (uncompressed JSON, the documented shape).
#[cfg(test)]
pub(crate) fn encode_server_error(json: &str) -> Vec<u8> {
    frame(
        MESSAGE_SERVER_ERROR,
        0,
        SERIALIZATION_JSON,
        COMPRESSION_NONE,
        json.as_bytes(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Read a frame's nibbles back out, for asserting what went on the
    /// wire byte-for-byte.
    fn nibbles(bytes: &[u8]) -> (u8, u8, u8) {
        (bytes[1], bytes[2], bytes[3])
    }

    #[test]
    fn the_full_request_is_gzip_json_with_the_documented_nibbles() {
        let frame = encode_full_request(r#"{"request":{}}"#);
        assert_eq!(nibbles(&frame), ((0b0001 << 4), (0b0001 << 4) | 0b0001, 0));
        let (message_type, payload) = client_payload(&frame);
        assert_eq!(message_type, MESSAGE_FULL_CLIENT_REQUEST);
        assert_eq!(String::from_utf8(payload).unwrap(), r#"{"request":{}}"#);
        // A client request never decodes as a server frame.
        assert_eq!(decode(&frame), Err(FrameError));
    }

    #[test]
    fn audio_frames_carry_gzip_pcm_as_mid_stream_packets() {
        let frame = encode_audio(&[0i16, -1, 256]);
        // Audio-only type, no flags (mid-stream), no serialization,
        // gzip.
        assert_eq!(nibbles(&frame), ((0b0010 << 4), 0b0001, 0));
        let size = u32::from_be_bytes(frame[4..8].try_into().unwrap()) as usize;
        let pcm = gunzip(&frame[8..8 + size]).unwrap();
        assert_eq!(pcm, vec![0, 0, 0xFF, 0xFF, 0, 1]);
    }

    #[test]
    fn the_last_packet_and_keepalive_are_header_only() {
        let last = encode_last_packet();
        // Audio-only + last-packet flag, nothing serialized, nothing
        // compressed, no payload.
        assert_eq!(nibbles(&last), ((0b0010 << 4) | 0b0010, 0, 0));
        assert_eq!(last.len(), 8);
        assert_eq!(u32::from_be_bytes(last[4..8].try_into().unwrap()), 0);

        let keepalive = encode_keepalive();
        assert_eq!(nibbles(&keepalive), ((0b1111 << 4), 0, 0));
        assert_eq!(keepalive.len(), 8);
    }

    #[test]
    fn server_error_frames_decode_uncompressed_or_gzip() {
        // The docs' error frames ride uncompressed JSON.
        let raw = frame(
            MESSAGE_SERVER_ERROR,
            0,
            SERIALIZATION_JSON,
            COMPRESSION_NONE,
            br#"{"code":45000001,"message":"invalid parameter"}"#,
        );
        assert_eq!(
            decode(&raw).unwrap(),
            ServerFrame::Error(r#"{"code":45000001,"message":"invalid parameter"}"#.into())
        );

        // But a gzip'd one (the same shape as full responses) decodes
        // too.
        let zipped = frame(
            MESSAGE_SERVER_ERROR,
            0,
            SERIALIZATION_JSON,
            COMPRESSION_GZIP,
            &gzip(br#"{"code":55000031,"message":"busy"}"#),
        );
        assert_eq!(
            decode(&zipped).unwrap(),
            ServerFrame::Error(r#"{"code":55000031,"message":"busy"}"#.into())
        );
    }

    #[test]
    fn a_header_size_over_four_units_places_the_size_after_it() {
        // The server added a positive-sequence field: header grows a
        // unit, and the payload size moves with it.
        let payload = br#"{"result":{"text":"x"}}"#;
        let mut bytes = vec![
            (0b0001 << 4) | 0b0010,
            (MESSAGE_FULL_SERVER_RESPONSE << 4) | 0b0001, // +sequence
            (SERIALIZATION_JSON << 4) | COMPRESSION_NONE,
            0,
        ];
        bytes.extend_from_slice(&7u32.to_be_bytes()); // the sequence
        bytes.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        bytes.extend_from_slice(payload);
        assert_eq!(
            decode(&bytes).unwrap(),
            ServerFrame::Response(r#"{"result":{"text":"x"}}"#.into())
        );
    }

    #[test]
    fn truncated_or_lying_frames_are_errors_not_panics() {
        assert_eq!(decode(&[]), Err(FrameError));
        assert_eq!(decode(&[0x11, 0x90, 0x10, 0]), Err(FrameError)); // < 8 bytes
        // States 200 payload bytes but carries none.
        let lying = frame(
            MESSAGE_FULL_SERVER_RESPONSE,
            0,
            SERIALIZATION_JSON,
            COMPRESSION_NONE,
            &[],
        );
        let mut lying = lying;
        lying[4..8].copy_from_slice(&200u32.to_be_bytes());
        assert_eq!(decode(&lying), Err(FrameError));
        // A client-only message type never comes back as a server frame.
        assert_eq!(decode(&encode_audio(&[0])), Err(FrameError));
    }
}
