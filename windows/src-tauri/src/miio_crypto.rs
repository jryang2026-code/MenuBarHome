//! miIO packet encoding/decoding, RustCrypto MD5 & AES-128-CBC + PKCS7,
//! RFC1918 IPv4 endpoint validation, and malformed firmware JSON sanitization.
//!
//! Mirrors `Sources/MijiaCore/MiCloud/MiIOCryptoAndPacket.swift` and is verified
//! against `Tests/Fixtures/miio_protocol_golden.json`.

#![allow(dead_code)]

use aes::Aes128;
use cbc::cipher::{block_padding::Pkcs7, BlockModeDecrypt, BlockModeEncrypt, KeyIvInit};
use md5::{Digest, Md5};
use serde::Serialize;
use std::fmt;

pub(crate) const MIIO_MAGIC: u16 = 0x2131;
pub(crate) const MIIO_HEADER_SIZE: usize = 32;
pub(crate) const DEFAULT_MAX_BATCH_SIZE: usize = 12;

/// 32-byte miIO discovery / handshake HELLO datagram (`21310020ffffffff...`).
pub(crate) const HELLO_PACKET: [u8; 32] = [
    0x21, 0x31, 0x00, 0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
];

/// Errors produced by local miIO protocol and UDP transport operations.
/// Never embeds device tokens in error strings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum MiIOError {
    InvalidToken,
    InvalidAddress(String),
    MalformedPacket,
    PayloadTooLarge,
    ChecksumMismatch,
    UnsupportedNonNumericDeviceId,
    HandshakeFailed,
    Timeout,
    ShutDown,
    EncryptionFailed,
    DecryptionFailed,
    TransportUnavailable,
    LocalNetworkDenied,
    SendFailed,
    AmbiguousActionOutcome,
    AmbiguousWriteOutcome,
    WriteNotSent(Box<MiIOError>),
    DeviceError { code: i64, message: String },
    UnsupportedLocalMiot { code: i64, message: String },
}

impl MiIOError {
    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::InvalidToken => "invalid_token",
            Self::InvalidAddress(_) => "invalid_address",
            Self::MalformedPacket => "malformed_packet",
            Self::PayloadTooLarge => "payload_too_large",
            Self::ChecksumMismatch => "checksum_mismatch",
            Self::UnsupportedNonNumericDeviceId => "unsupported_non_numeric_device_id",
            Self::HandshakeFailed => "handshake_failed",
            Self::Timeout => "timeout",
            Self::ShutDown => "shut_down",
            Self::EncryptionFailed => "encryption_failed",
            Self::DecryptionFailed => "decryption_failed",
            Self::TransportUnavailable => "transport_unavailable",
            Self::LocalNetworkDenied => "local_network_denied",
            Self::SendFailed => "send_failed",
            Self::AmbiguousActionOutcome => "ambiguous_action_outcome",
            Self::AmbiguousWriteOutcome => "ambiguous_write_outcome",
            Self::WriteNotSent(_) => "write_not_sent",
            Self::DeviceError { .. } => "device_error",
            Self::UnsupportedLocalMiot { .. } => "unsupported_local_miot",
        }
    }

    pub(crate) fn is_retryable(&self) -> bool {
        match self {
            Self::WriteNotSent(cause) => cause.is_retryable(),
            _ => matches!(self, Self::Timeout | Self::HandshakeFailed | Self::MalformedPacket),
        }
    }

    pub(crate) fn proves_packet_crossed_permission_boundary(&self) -> bool {
        matches!(
            self,
            Self::Timeout
                | Self::HandshakeFailed
                | Self::MalformedPacket
                | Self::ChecksumMismatch
                | Self::DecryptionFailed
                | Self::UnsupportedNonNumericDeviceId
                | Self::DeviceError { .. }
                | Self::UnsupportedLocalMiot { .. }
        )
    }

    pub(crate) fn to_command_error(&self) -> MiIOCommandError {
        let device_code = match self {
            Self::DeviceError { code, .. } | Self::UnsupportedLocalMiot { code, .. } => Some(*code),
            _ => None,
        };
        MiIOCommandError {
            code: self.code().to_string(),
            message: self.to_string(),
            device_code,
        }
    }
}

impl fmt::Display for MiIOError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidToken => write!(f, "Invalid local Xiaomi device token"),
            Self::InvalidAddress(host) => write!(f, "Invalid local device address: {host}"),
            Self::MalformedPacket => write!(f, "Device returned a malformed miIO packet"),
            Self::PayloadTooLarge => write!(f, "miIO UDP request payload exceeds packet limit"),
            Self::ChecksumMismatch => {
                write!(f, "miIO packet checksum mismatch (token may be invalid)")
            }
            Self::UnsupportedNonNumericDeviceId => {
                write!(f, "Device DID is not numeric and unsupported by miIO binary packets")
            }
            Self::HandshakeFailed => write!(f, "Local miIO handshake failed"),
            Self::Timeout => write!(f, "Local miIO UDP request timed out"),
            Self::ShutDown => write!(f, "Local miIO client has shut down"),
            Self::EncryptionFailed => write!(f, "miIO payload encryption failed"),
            Self::DecryptionFailed => write!(f, "miIO payload decryption failed"),
            Self::TransportUnavailable => write!(f, "Local UDP transport is unavailable"),
            Self::LocalNetworkDenied => write!(f, "Local network access is blocked"),
            Self::SendFailed => write!(f, "Failed to send local miIO UDP packet"),
            Self::AmbiguousActionOutcome => {
                write!(f, "Local action outcome could not be confirmed")
            }
            Self::AmbiguousWriteOutcome => {
                write!(f, "Local property write outcome could not be confirmed")
            }
            Self::WriteNotSent(_) => write!(f, "Local write could not be sent"),
            Self::DeviceError { code, message } => {
                write!(f, "Local device error ({code}): {message}")
            }
            Self::UnsupportedLocalMiot { code, message } => {
                write!(f, "Device does not support local MIoT RPC ({code}): {message}")
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MiIOCommandError {
    pub(crate) code: String,
    pub(crate) message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) device_code: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MiIOPacketHeader {
    pub(crate) magic: u16,
    pub(crate) length: u16,
    pub(crate) unknown: u32,
    pub(crate) device_id: u32,
    pub(crate) stamp: u32,
    pub(crate) checksum: [u8; 16],
}

impl MiIOPacketHeader {
    pub(crate) fn device_id64(&self) -> u64 {
        ((self.unknown as u64) << 32) | (self.device_id as u64)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HelloChecksumVerdict {
    Md5Match,
    TokenEcho,
    Inconclusive,
    Mismatch,
}

/// Decodes a 32-hex-character miIO token into 16 raw bytes, rejecting empty, all-00, and all-ff tokens.
pub(crate) fn validate_token(raw_hex: &str) -> Option<[u8; 16]> {
    let trimmed = raw_hex.trim();
    if trimmed.len() != 32 || !trimmed.is_ascii() {
        return None;
    }
    let bytes = trimmed.as_bytes();
    let mut out = [0u8; 16];
    for i in 0..16 {
        let hi = hex_nibble(bytes[i * 2])?;
        let lo = hex_nibble(bytes[i * 2 + 1])?;
        out[i] = (hi << 4) | lo;
    }
    if out.iter().all(|&b| b == 0x00) || out.iter().all(|&b| b == 0xFF) {
        return None;
    }
    Some(out)
}

fn hex_nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Strict RFC1918 private IPv4 validation matching `LocalMiIOClient.isPrivateRFC1918IPv4`.
/// Rejects public IPs, loopback, link-local, CGNAT, broadcast, leading zeros, and hostnames.
pub(crate) fn is_private_rfc1918_ipv4(ip: &str) -> bool {
    let trimmed = ip.trim();
    let mut octets = [0u8; 4];
    let mut count = 0usize;
    for part in trimmed.split('.') {
        if count >= 4 || part.is_empty() || part.len() > 3 {
            return false;
        }
        if part.len() > 1 && part.starts_with('0') {
            return false;
        }
        if !part.bytes().all(|b| b.is_ascii_digit()) {
            return false;
        }
        let Ok(val) = part.parse::<u8>() else {
            return false;
        };
        octets[count] = val;
        count += 1;
    }
    if count != 4 {
        return false;
    }
    let [a, b, _, _] = octets;
    a == 10 || (a == 172 && (16..=31).contains(&b)) || (a == 192 && b == 168)
}

pub(crate) fn derive_key_and_iv(token: &[u8; 16]) -> ([u8; 16], [u8; 16]) {
    let key = md5(token);
    let mut iv_material = [0u8; 32];
    iv_material[..16].copy_from_slice(&key);
    iv_material[16..].copy_from_slice(token);
    let iv = md5(&iv_material);
    (key, iv)
}

pub(crate) fn decode_header(data: &[u8]) -> Result<MiIOPacketHeader, MiIOError> {
    if data.len() < MIIO_HEADER_SIZE {
        return Err(MiIOError::MalformedPacket);
    }
    let magic = u16::from_be_bytes([data[0], data[1]]);
    let length = u16::from_be_bytes([data[2], data[3]]);
    if magic != MIIO_MAGIC || (length as usize) < MIIO_HEADER_SIZE || (length as usize) > data.len()
    {
        return Err(MiIOError::MalformedPacket);
    }
    let unknown = u32::from_be_bytes([data[4], data[5], data[6], data[7]]);
    let device_id = u32::from_be_bytes([data[8], data[9], data[10], data[11]]);
    let stamp = u32::from_be_bytes([data[12], data[13], data[14], data[15]]);
    let mut checksum = [0u8; 16];
    checksum.copy_from_slice(&data[16..32]);
    Ok(MiIOPacketHeader { magic, length, unknown, device_id, stamp, checksum })
}

pub(crate) fn hello_checksum_verdict(packet: &[u8], token: &[u8; 16]) -> HelloChecksumVerdict {
    let Ok(header) = decode_header(packet) else {
        return HelloChecksumVerdict::Inconclusive;
    };
    if &header.checksum == token {
        return HelloChecksumVerdict::TokenEcho;
    }
    if header.checksum.iter().all(|&b| b == 0xFF) || header.checksum.iter().all(|&b| b == 0x00) {
        return HelloChecksumVerdict::Inconclusive;
    }
    let mut input = [0u8; 32];
    input[..16].copy_from_slice(&packet[..16]);
    input[16..].copy_from_slice(token);
    if md5(&input) == header.checksum {
        HelloChecksumVerdict::Md5Match
    } else {
        HelloChecksumVerdict::Mismatch
    }
}

pub(crate) fn encode_packet(
    device_id: u32,
    stamp: u32,
    token: &[u8; 16],
    payload: &[u8],
    unknown: u32,
) -> Result<Vec<u8>, MiIOError> {
    let (key, iv) = derive_key_and_iv(token);
    let ciphertext = if payload.is_empty() {
        Vec::new()
    } else {
        encrypt_aes128_cbc(payload, &key, &iv)
    };
    let total_length = MIIO_HEADER_SIZE + ciphertext.len();
    if total_length > u16::MAX as usize {
        return Err(MiIOError::PayloadTooLarge);
    }

    let mut prefix = [0u8; 16];
    prefix[0..2].copy_from_slice(&MIIO_MAGIC.to_be_bytes());
    prefix[2..4].copy_from_slice(&(total_length as u16).to_be_bytes());
    prefix[4..8].copy_from_slice(&unknown.to_be_bytes());
    prefix[8..12].copy_from_slice(&device_id.to_be_bytes());
    prefix[12..16].copy_from_slice(&stamp.to_be_bytes());

    let mut checksum_input = Vec::with_capacity(32 + ciphertext.len());
    checksum_input.extend_from_slice(&prefix);
    checksum_input.extend_from_slice(token);
    checksum_input.extend_from_slice(&ciphertext);
    let checksum = md5(&checksum_input);

    let mut packet = Vec::with_capacity(total_length);
    packet.extend_from_slice(&prefix);
    packet.extend_from_slice(&checksum);
    packet.extend_from_slice(&ciphertext);
    Ok(packet)
}

pub(crate) fn decode_packet(
    data: &[u8],
    token: &[u8; 16],
) -> Result<(MiIOPacketHeader, Vec<u8>), MiIOError> {
    let header = decode_header(data)?;
    let end = header.length as usize;
    let prefix = &data[..16];
    let ciphertext = &data[MIIO_HEADER_SIZE..end];

    let mut checksum_input = Vec::with_capacity(32 + ciphertext.len());
    checksum_input.extend_from_slice(prefix);
    checksum_input.extend_from_slice(token);
    checksum_input.extend_from_slice(ciphertext);
    if md5(&checksum_input) != header.checksum {
        return Err(MiIOError::ChecksumMismatch);
    }

    if ciphertext.is_empty() {
        return Ok((header, Vec::new()));
    }
    let (key, iv) = derive_key_and_iv(token);
    let plaintext = decrypt_aes128_cbc(ciphertext, &key, &iv)?;
    Ok((header, plaintext))
}

// MARK: - RustCrypto MD5 & AES-128-CBC + PKCS7

type Aes128CbcEnc = cbc::Encryptor<Aes128>;
type Aes128CbcDec = cbc::Decryptor<Aes128>;

pub(crate) fn md5(data: &[u8]) -> [u8; 16] {
    Md5::digest(data).into()
}

pub(crate) fn encrypt_aes128_cbc(plaintext: &[u8], key: &[u8; 16], iv: &[u8; 16]) -> Vec<u8> {
    Aes128CbcEnc::new(key.into(), iv.into()).encrypt_padded_vec::<Pkcs7>(plaintext)
}

pub(crate) fn decrypt_aes128_cbc(
    ciphertext: &[u8],
    key: &[u8; 16],
    iv: &[u8; 16],
) -> Result<Vec<u8>, MiIOError> {
    if ciphertext.is_empty() || ciphertext.len() % 16 != 0 {
        return Err(MiIOError::DecryptionFailed);
    }
    Aes128CbcDec::new(key.into(), iv.into())
        .decrypt_padded_vec::<Pkcs7>(ciphertext)
        .map_err(|_| MiIOError::DecryptionFailed)
}

// MARK: - Malformed Firmware JSON Sanitizer

/// Cleans common Xiaomi/ecosystem firmware JSON malformations outside string literals
/// (trailing null/control bytes, trailing commas before `}`/`]`, consecutive commas `,,`,
/// missing values after `:`, and leading-zero octal-style numbers such as `:00`).
pub(crate) fn clean_malformed_firmware_json(raw: &str) -> String {
    let trimmed = raw.trim_matches(|c: char| c.is_whitespace() || c.is_control());
    if trimmed.is_empty() {
        return String::new();
    }

    #[derive(Clone, PartialEq, Eq)]
    enum Tok { Ws(String), LBrace, RBrace, LBracket, RBracket, Colon, Comma, Val(String) }
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Kind { Obj, Arr }

    let chars: Vec<char> = trimmed.chars().collect();
    let mut tokens = Vec::new();
    let mut idx = 0usize;

    while idx < chars.len() {
        match chars[idx] {
            ' ' | '\t' | '\r' | '\n' => {
                let start = idx;
                while idx < chars.len() && matches!(chars[idx], ' ' | '\t' | '\r' | '\n') { idx += 1; }
                tokens.push(Tok::Ws(chars[start..idx].iter().collect()));
            }
            c if c == '\0' || (c as u32) < 0x20 => idx += 1,
            '"' => {
                let start = idx;
                idx += 1;
                let mut esc = false;
                while idx < chars.len() {
                    let c = chars[idx];
                    idx += 1;
                    if esc { esc = false; } else if c == '\\' { esc = true; } else if c == '"' { break; }
                }
                tokens.push(Tok::Val(chars[start..idx].iter().collect()));
            }
            '{' => { tokens.push(Tok::LBrace); idx += 1; }
            '}' => { tokens.push(Tok::RBrace); idx += 1; }
            '[' => { tokens.push(Tok::LBracket); idx += 1; }
            ']' => { tokens.push(Tok::RBracket); idx += 1; }
            ':' => { tokens.push(Tok::Colon); idx += 1; }
            ',' => { tokens.push(Tok::Comma); idx += 1; }
            ch @ ('0'..='9' | '-') => {
                if ch == '-' && !chars.get(idx + 1).is_some_and(|c| c.is_ascii_digit()) {
                    tokens.push(Tok::Val("-".into()));
                    idx += 1;
                    continue;
                }
                let start = idx;
                let sign = if chars[idx] == '-' { idx += 1; "-" } else { "" };
                let int_start = idx;
                while idx < chars.len() && chars[idx].is_ascii_digit() { idx += 1; }
                let mut int_part: String = chars[int_start..idx].iter().collect();
                while int_part.len() > 1 && int_part.starts_with('0') { int_part.remove(0); }
                let tail_start = idx;
                if chars.get(idx) == Some(&'.') {
                    idx += 1;
                    while idx < chars.len() && chars[idx].is_ascii_digit() { idx += 1; }
                }
                if chars.get(idx).is_some_and(|c| matches!(c, 'e' | 'E')) {
                    idx += 1;
                    if chars.get(idx).is_some_and(|c| matches!(c, '+' | '-')) { idx += 1; }
                    while idx < chars.len() && chars[idx].is_ascii_digit() { idx += 1; }
                }
                let tail: String = chars[tail_start..idx].iter().collect();
                let val = if int_part.is_empty() { chars[start..idx].iter().collect() } else { format!("{sign}{int_part}{tail}") };
                tokens.push(Tok::Val(val));
            }
            _ => {
                let start = idx;
                idx += 1;
                while idx < chars.len()
                    && !matches!(chars[idx], ' ' | '\t' | '\r' | '\n' | '\0' | '{' | '}' | '[' | ']' | ':' | ',' | '"')
                    && (chars[idx] as u32) >= 0x20
                {
                    idx += 1;
                }
                tokens.push(Tok::Val(chars[start..idx].iter().collect()));
            }
        }
    }

    let next_non_ws = |after: usize| tokens[after + 1..].iter().find(|t| !matches!(t, Tok::Ws(_)));
    let next_non_comma = |from: usize| {
        let (mut j, mut count, mut last_comma) = (from, 0usize, from);
        while j < tokens.len() {
            match &tokens[j] {
                Tok::Ws(_) => j += 1,
                Tok::Comma => { count += 1; last_comma = j; j += 1; }
                other => return (Some(other), count, last_comma),
            }
        }
        (None, count, last_comma)
    };

    let mut out = String::with_capacity(trimmed.len());
    let mut stack = Vec::new();
    let mut prev: Option<Tok> = None;
    let mut i = 0usize;
    while i < tokens.len() {
        match &tokens[i] {
            Tok::Ws(s) => out.push_str(s),
            Tok::LBrace => { out.push('{'); stack.push(Kind::Obj); prev = Some(Tok::LBrace); }
            Tok::LBracket => { out.push('['); stack.push(Kind::Arr); prev = Some(Tok::LBracket); }
            Tok::RBrace => {
                if prev == Some(Tok::Colon) { out.push_str("null"); }
                out.push('}');
                if stack.last() == Some(&Kind::Obj) { stack.pop(); }
                prev = Some(Tok::RBrace);
            }
            Tok::RBracket => {
                out.push(']');
                if stack.last() == Some(&Kind::Arr) { stack.pop(); }
                prev = Some(Tok::RBracket);
            }
            Tok::Colon => { out.push(':'); prev = Some(Tok::Colon); }
            Tok::Comma => {
                if prev == Some(Tok::Colon) {
                    out.push_str("null");
                    prev = Some(Tok::Val("null".into()));
                }
                let next = next_non_ws(i);
                match stack.last() {
                    Some(Kind::Obj) => {
                        if prev != Some(Tok::LBrace) && !matches!(next, Some(Tok::Comma | Tok::RBrace) | None) {
                            out.push(',');
                            prev = Some(Tok::Comma);
                        }
                    }
                    Some(Kind::Arr) => {
                        let (tok, commas, last_idx) = next_non_comma(i);
                        if prev == Some(Tok::LBracket) {
                            if tok == Some(&Tok::RBracket) {
                                out.push_str(&vec!["null"; commas + 1].join(","));
                                prev = Some(Tok::Val("null".into()));
                                i = last_idx;
                            } else {
                                out.push_str("null,");
                                prev = Some(Tok::Comma);
                            }
                        } else if prev == Some(Tok::Comma) {
                            if !matches!(tok, Some(Tok::RBracket) | None) {
                                out.push_str("null,");
                                prev = Some(Tok::Comma);
                            }
                        } else if !matches!(tok, Some(Tok::RBracket) | None) {
                            out.push(',');
                            prev = Some(Tok::Comma);
                        }
                    }
                    None => {
                        if !matches!(next, Some(Tok::Comma) | None) {
                            out.push(',');
                            prev = Some(Tok::Comma);
                        }
                    }
                }
            }
            Tok::Val(s) => { out.push_str(s); prev = Some(Tok::Val(s.clone())); }
        }
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn hex_decode(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    fn hex_encode(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn golden_corpus_matches_rust_implementation() {
        let raw = include_str!("../../../Tests/Fixtures/miio_protocol_golden.json");
        let doc: Value = serde_json::from_str(raw).expect("valid golden json");
        assert_eq!(hex_encode(&HELLO_PACKET), doc["helloPacket"].as_str().unwrap());

        for vec in doc["packetVectors"].as_array().unwrap() {
            let name = vec["name"].as_str().unwrap();
            let token = validate_token(vec["token"].as_str().unwrap()).expect(name);
            let (key, iv) = derive_key_and_iv(&token);
            assert_eq!(hex_encode(&key), vec["key"].as_str().unwrap(), "{name} key");
            assert_eq!(hex_encode(&iv), vec["iv"].as_str().unwrap(), "{name} iv");

            let device_id = vec["deviceId"].as_u64().unwrap() as u32;
            let stamp = vec["stamp"].as_u64().unwrap() as u32;
            let unknown = vec["unknown"].as_u64().unwrap() as u32;
            let payload = vec["payload"].as_str().unwrap().as_bytes();
            let encoded = encode_packet(device_id, stamp, &token, payload, unknown).expect(name);
            assert_eq!(hex_encode(&encoded), vec["packet"].as_str().unwrap(), "{name} encode");

            let (hdr, decoded) = decode_packet(&encoded, &token).expect(name);
            assert_eq!(hdr.device_id, device_id, "{name} device_id");
            assert_eq!(hdr.stamp, stamp, "{name} stamp");
            assert_eq!(hdr.unknown, unknown, "{name} unknown");
            assert_eq!(hex_encode(&hdr.checksum), vec["checksum"].as_str().unwrap(), "{name} checksum");
            assert_eq!(decoded, payload, "{name} decode");

            let mut tampered = encoded.clone();
            tampered[16] ^= 0xFF;
            assert_eq!(decode_packet(&tampered, &token).unwrap_err(), MiIOError::ChecksumMismatch);
        }

        for case in doc["helloChecksumCases"].as_array().unwrap() {
            let token = validate_token(case["token"].as_str().unwrap()).unwrap();
            let packet = hex_decode(case["packet"].as_str().unwrap());
            let expected = match case["verdict"].as_str().unwrap() {
                "md5Match" => HelloChecksumVerdict::Md5Match,
                "tokenEcho" => HelloChecksumVerdict::TokenEcho,
                "inconclusive" => HelloChecksumVerdict::Inconclusive,
                "mismatch" => HelloChecksumVerdict::Mismatch,
                other => panic!("unexpected verdict: {other}"),
            };
            assert_eq!(hello_checksum_verdict(&packet, &token), expected);
        }

        for case in doc["tokenCases"].as_array().unwrap() {
            let raw = case["raw"].as_str().unwrap();
            assert_eq!(validate_token(raw).is_some(), case["valid"].as_bool().unwrap(), "token: {raw}");
        }

        for case in doc["privateIpCases"].as_array().unwrap() {
            let ip = case["ip"].as_str().unwrap();
            assert_eq!(is_private_rfc1918_ipv4(ip), case["valid"].as_bool().unwrap(), "ip: {ip}");
        }

        for case in doc["malformedJsonCases"].as_array().unwrap() {
            assert_eq!(
                clean_malformed_firmware_json(case["input"].as_str().unwrap()),
                case["expected"].as_str().unwrap()
            );
        }
    }

    #[test]
    fn errors_never_format_tokens() {
        let token_hex = "0123456789abcdef0123456789abcdef";
        for err in [
            MiIOError::InvalidToken,
            MiIOError::ChecksumMismatch,
            MiIOError::DecryptionFailed,
            MiIOError::EncryptionFailed,
        ] {
            assert!(!err.to_string().contains(token_hex));
            assert!(!err.to_command_error().message.contains(token_hex));
        }
    }
}
