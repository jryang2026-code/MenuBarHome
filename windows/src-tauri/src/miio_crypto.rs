//! Pure-Rust miIO packet encoding/decoding, MD5, FIPS-197 AES-128-CBC + PKCS7,
//! RFC1918 IPv4 endpoint validation, and malformed firmware JSON sanitization.
//!
//! Mirrors `Sources/MijiaCore/MiCloud/MiIOCryptoAndPacket.swift` and is verified
//! against `Tests/Fixtures/miio_protocol_golden.json`.

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
    DeviceError { code: i64, message: String },
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
            Self::DeviceError { .. } => "device_error",
        }
    }

    pub(crate) fn is_retryable(&self) -> bool {
        matches!(self, Self::Timeout | Self::HandshakeFailed | Self::MalformedPacket)
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
        )
    }

    pub(crate) fn to_command_error(&self) -> MiIOCommandError {
        let device_code = match self {
            Self::DeviceError { code, .. } => Some(*code),
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
            Self::DeviceError { code, message } => {
                write!(f, "Local device error ({code}): {message}")
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

// MARK: - RFC 1321 MD5

pub(crate) fn md5(data: &[u8]) -> [u8; 16] {
    const S: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5,
        9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10,
        15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    const K: [u32; 64] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613,
        0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193,
        0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d,
        0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
        0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
        0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244,
        0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb,
        0xeb86d391,
    ];

    let mut a0: u32 = 0x67452301;
    let mut b0: u32 = 0xefcdab89;
    let mut c0: u32 = 0x98badcfe;
    let mut d0: u32 = 0x10325476;

    let bit_len = (data.len() as u64).wrapping_mul(8);
    let mut msg = Vec::with_capacity(data.len() + 72);
    msg.extend_from_slice(data);
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_le_bytes());

    for chunk in msg.chunks_exact(64) {
        let mut m = [0u32; 16];
        for i in 0..16 {
            m[i] = u32::from_le_bytes([
                chunk[i * 4],
                chunk[i * 4 + 1],
                chunk[i * 4 + 2],
                chunk[i * 4 + 3],
            ]);
        }
        let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
        for i in 0..64 {
            let (f, g) = match i {
                0..=15 => ((b & c) | (!b & d), i),
                16..=31 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                32..=47 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | !d), (7 * i) % 16),
            };
            let temp = d;
            d = c;
            c = b;
            let sum = a.wrapping_add(f).wrapping_add(K[i]).wrapping_add(m[g]);
            b = b.wrapping_add(sum.rotate_left(S[i]));
            a = temp;
        }
        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }

    let mut digest = [0u8; 16];
    digest[0..4].copy_from_slice(&a0.to_le_bytes());
    digest[4..8].copy_from_slice(&b0.to_le_bytes());
    digest[8..12].copy_from_slice(&c0.to_le_bytes());
    digest[12..16].copy_from_slice(&d0.to_le_bytes());
    digest
}

// MARK: - FIPS-197 AES-128-CBC + PKCS7

const AES_SBOX: [u8; 256] = [
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
];

const AES_INV_SBOX: [u8; 256] = [
    0x52, 0x09, 0x6A, 0xD5, 0x30, 0x36, 0xA5, 0x38, 0xBF, 0x40, 0xA3, 0x9E, 0x81, 0xF3, 0xD7, 0xFB,
    0x7C, 0xE3, 0x39, 0x82, 0x9B, 0x2F, 0xFF, 0x87, 0x34, 0x8E, 0x43, 0x44, 0xC4, 0xDE, 0xE9, 0xCB,
    0x54, 0x7B, 0x94, 0x32, 0xA6, 0xC2, 0x23, 0x3D, 0xEE, 0x4C, 0x95, 0x0B, 0x42, 0xFA, 0xC3, 0x4E,
    0x08, 0x2E, 0xA1, 0x66, 0x28, 0xD9, 0x24, 0xB2, 0x76, 0x5B, 0xA2, 0x49, 0x6D, 0x8B, 0xD1, 0x25,
    0x72, 0xF8, 0xF6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xD4, 0xA4, 0x5C, 0xCC, 0x5D, 0x65, 0xB6, 0x92,
    0x6C, 0x70, 0x48, 0x50, 0xFD, 0xED, 0xB9, 0xDA, 0x5E, 0x15, 0x46, 0x57, 0xA7, 0x8D, 0x9D, 0x84,
    0x90, 0xD8, 0xAB, 0x00, 0x8C, 0xBC, 0xD3, 0x0A, 0xF7, 0xE4, 0x58, 0x05, 0xB8, 0xB3, 0x45, 0x06,
    0xD0, 0x2C, 0x1E, 0x8F, 0xCA, 0x3F, 0x0F, 0x02, 0xC1, 0xAF, 0xBD, 0x03, 0x01, 0x13, 0x8A, 0x6B,
    0x3A, 0x91, 0x11, 0x41, 0x4F, 0x67, 0xDC, 0xEA, 0x97, 0xF2, 0xCF, 0xCE, 0xF0, 0xB4, 0xE6, 0x73,
    0x96, 0xAC, 0x74, 0x22, 0xE7, 0xAD, 0x35, 0x85, 0xE2, 0xF9, 0x37, 0xE8, 0x1C, 0x75, 0xDF, 0x6E,
    0x47, 0xF1, 0x1A, 0x71, 0x1D, 0x29, 0xC5, 0x89, 0x6F, 0xB7, 0x62, 0x0E, 0xAA, 0x18, 0xBE, 0x1B,
    0xFC, 0x56, 0x3E, 0x4B, 0xC6, 0xD2, 0x79, 0x20, 0x9A, 0xDB, 0xC0, 0xFE, 0x78, 0xCD, 0x5A, 0xF4,
    0x1F, 0xDD, 0xA8, 0x33, 0x88, 0x07, 0xC7, 0x31, 0xB1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xEC, 0x5F,
    0x60, 0x51, 0x7F, 0xA9, 0x19, 0xB5, 0x4A, 0x0D, 0x2D, 0xE5, 0x7A, 0x9F, 0x93, 0xC9, 0x9C, 0xEF,
    0xA0, 0xE0, 0x3B, 0x4D, 0xAE, 0x2A, 0xF5, 0xB0, 0xC8, 0xEB, 0xBB, 0x3C, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2B, 0x04, 0x7E, 0xBA, 0x77, 0xD6, 0x26, 0xE1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0C, 0x7D,
];

const RCON: [u8; 10] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36];

fn expand_aes128_key(key: &[u8; 16]) -> [u8; 176] {
    let mut expanded = [0u8; 176];
    expanded[..16].copy_from_slice(key);
    let mut bytes_generated = 16usize;
    let mut rcon_idx = 0usize;
    while bytes_generated < 176 {
        let mut temp = [
            expanded[bytes_generated - 4],
            expanded[bytes_generated - 3],
            expanded[bytes_generated - 2],
            expanded[bytes_generated - 1],
        ];
        if bytes_generated % 16 == 0 {
            let t = temp[0];
            temp[0] = AES_SBOX[temp[1] as usize] ^ RCON[rcon_idx];
            temp[1] = AES_SBOX[temp[2] as usize];
            temp[2] = AES_SBOX[temp[3] as usize];
            temp[3] = AES_SBOX[t as usize];
            rcon_idx += 1;
        }
        for i in 0..4 {
            expanded[bytes_generated] = expanded[bytes_generated - 16] ^ temp[i];
            bytes_generated += 1;
        }
    }
    expanded
}

#[inline]
fn xtime(a: u8) -> u8 {
    (a << 1) ^ if (a & 0x80) != 0 { 0x1B } else { 0x00 }
}

fn gf_mul(mut a: u8, mut b: u8) -> u8 {
    let mut p = 0u8;
    for _ in 0..8 {
        if (b & 1) != 0 {
            p ^= a;
        }
        a = xtime(a);
        b >>= 1;
    }
    p
}

fn add_round_key(state: &mut [u8; 16], round_keys: &[u8; 176], round: usize) {
    let base = round * 16;
    for i in 0..16 {
        state[i] ^= round_keys[base + i];
    }
}

fn encrypt_aes128_block(mut s: [u8; 16], round_keys: &[u8; 176]) -> [u8; 16] {
    add_round_key(&mut s, round_keys, 0);
    for round in 1..=10 {
        for b in &mut s {
            *b = AES_SBOX[*b as usize];
        }
        let t1 = s[1]; s[1] = s[5]; s[5] = s[9]; s[9] = s[13]; s[13] = t1;
        s.swap(2, 10);
        s.swap(6, 14);
        let t3 = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = s[3]; s[3] = t3;
        if round < 10 {
            for c in 0..4 {
                let i = c * 4;
                let (a0, a1, a2, a3) = (s[i], s[i + 1], s[i + 2], s[i + 3]);
                let xor_all = a0 ^ a1 ^ a2 ^ a3;
                s[i] = a0 ^ xor_all ^ xtime(a0 ^ a1);
                s[i + 1] = a1 ^ xor_all ^ xtime(a1 ^ a2);
                s[i + 2] = a2 ^ xor_all ^ xtime(a2 ^ a3);
                s[i + 3] = a3 ^ xor_all ^ xtime(a3 ^ a0);
            }
        }
        add_round_key(&mut s, round_keys, round);
    }
    s
}

fn decrypt_aes128_block(mut s: [u8; 16], round_keys: &[u8; 176]) -> [u8; 16] {
    add_round_key(&mut s, round_keys, 10);
    for round in (0..10).rev() {
        let t1 = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = s[1]; s[1] = t1;
        s.swap(2, 10);
        s.swap(6, 14);
        let t3 = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t3;
        for b in &mut s {
            *b = AES_INV_SBOX[*b as usize];
        }
        add_round_key(&mut s, round_keys, round);
        if round > 0 {
            for c in 0..4 {
                let i = c * 4;
                let (a0, a1, a2, a3) = (s[i], s[i + 1], s[i + 2], s[i + 3]);
                s[i] = gf_mul(a0, 0x0E) ^ gf_mul(a1, 0x0B) ^ gf_mul(a2, 0x0D) ^ gf_mul(a3, 0x09);
                s[i + 1] = gf_mul(a0, 0x09) ^ gf_mul(a1, 0x0E) ^ gf_mul(a2, 0x0B) ^ gf_mul(a3, 0x0D);
                s[i + 2] = gf_mul(a0, 0x0D) ^ gf_mul(a1, 0x09) ^ gf_mul(a2, 0x0E) ^ gf_mul(a3, 0x0B);
                s[i + 3] = gf_mul(a0, 0x0B) ^ gf_mul(a1, 0x0D) ^ gf_mul(a2, 0x09) ^ gf_mul(a3, 0x0E);
            }
        }
    }
    s
}

pub(crate) fn encrypt_aes128_cbc(plaintext: &[u8], key: &[u8; 16], iv: &[u8; 16]) -> Vec<u8> {
    let round_keys = expand_aes128_key(key);
    let pad_len = 16 - (plaintext.len() % 16);
    let mut padded = Vec::with_capacity(plaintext.len() + pad_len);
    padded.extend_from_slice(plaintext);
    padded.resize(plaintext.len() + pad_len, pad_len as u8);

    let mut out = Vec::with_capacity(padded.len());
    let mut prev = *iv;
    for chunk in padded.chunks_exact(16) {
        let mut block = [0u8; 16];
        for j in 0..16 {
            block[j] = chunk[j] ^ prev[j];
        }
        let encrypted = encrypt_aes128_block(block, &round_keys);
        out.extend_from_slice(&encrypted);
        prev = encrypted;
    }
    out
}

pub(crate) fn decrypt_aes128_cbc(
    ciphertext: &[u8],
    key: &[u8; 16],
    iv: &[u8; 16],
) -> Result<Vec<u8>, MiIOError> {
    if ciphertext.is_empty() || ciphertext.len() % 16 != 0 {
        return Err(MiIOError::DecryptionFailed);
    }
    let round_keys = expand_aes128_key(key);
    let mut out = Vec::with_capacity(ciphertext.len());
    let mut prev = *iv;
    for chunk in ciphertext.chunks_exact(16) {
        let mut block = [0u8; 16];
        block.copy_from_slice(chunk);
        let mut dec = decrypt_aes128_block(block, &round_keys);
        for j in 0..16 {
            dec[j] ^= prev[j];
        }
        out.extend_from_slice(&dec);
        prev = block;
    }
    let Some(&last_byte) = out.last() else {
        return Err(MiIOError::DecryptionFailed);
    };
    let pad_len = last_byte as usize;
    if pad_len == 0 || pad_len > 16 || out.len() < pad_len {
        return Err(MiIOError::DecryptionFailed);
    }
    let mut valid_pad = 0u8;
    for &b in &out[out.len() - pad_len..] {
        valid_pad |= b ^ last_byte;
    }
    if valid_pad != 0 {
        return Err(MiIOError::DecryptionFailed);
    }
    out.truncate(out.len() - pad_len);
    Ok(out)
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
    enum Token {
        Ws(String),
        LBrace,
        RBrace,
        LBracket,
        RBracket,
        Colon,
        Comma,
        Value(String),
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
    enum ContainerKind {
        Object,
        Array,
    }

    let chars: Vec<char> = trimmed.chars().collect();
    let mut tokens: Vec<Token> = Vec::new();
    let mut idx = 0usize;

    while idx < chars.len() {
        let ch = chars[idx];
        match ch {
            ' ' | '\t' | '\r' | '\n' => {
                let mut end = idx + 1;
                while end < chars.len() && matches!(chars[end], ' ' | '\t' | '\r' | '\n') {
                    end += 1;
                }
                tokens.push(Token::Ws(chars[idx..end].iter().collect()));
                idx = end;
            }
            '\0' => idx += 1,
            c if (c as u32) < 0x20 => idx += 1,
            '"' => {
                let mut end = idx + 1;
                let mut escaped = false;
                while end < chars.len() {
                    let c = chars[end];
                    if escaped {
                        escaped = false;
                    } else if c == '\\' {
                        escaped = true;
                    } else if c == '"' {
                        end += 1;
                        break;
                    }
                    end += 1;
                }
                tokens.push(Token::Value(chars[idx..end].iter().collect()));
                idx = end;
            }
            '{' => {
                tokens.push(Token::LBrace);
                idx += 1;
            }
            '}' => {
                tokens.push(Token::RBrace);
                idx += 1;
            }
            '[' => {
                tokens.push(Token::LBracket);
                idx += 1;
            }
            ']' => {
                tokens.push(Token::RBracket);
                idx += 1;
            }
            ':' => {
                tokens.push(Token::Colon);
                idx += 1;
            }
            ',' => {
                tokens.push(Token::Comma);
                idx += 1;
            }
            '0'..='9' | '-' => {
                if ch == '-'
                    && (idx + 1 >= chars.len() || !matches!(chars[idx + 1], '0'..='9'))
                {
                    tokens.push(Token::Value("-".to_string()));
                    idx += 1;
                    continue;
                }
                let start = idx;
                let mut cursor = idx;
                let sign = if chars[cursor] == '-' {
                    cursor += 1;
                    "-"
                } else {
                    ""
                };
                let int_start = cursor;
                while cursor < chars.len() && matches!(chars[cursor], '0'..='9') {
                    cursor += 1;
                }
                let mut int_part: String = chars[int_start..cursor].iter().collect();
                while int_part.len() > 1 && int_part.starts_with('0') {
                    int_part.remove(0);
                }
                let mut tail = String::new();
                if cursor < chars.len() && chars[cursor] == '.' {
                    let dot_start = cursor;
                    cursor += 1;
                    while cursor < chars.len() && matches!(chars[cursor], '0'..='9') {
                        cursor += 1;
                    }
                    tail.extend(&chars[dot_start..cursor]);
                }
                if cursor < chars.len() && matches!(chars[cursor], 'e' | 'E') {
                    let exp_start = cursor;
                    cursor += 1;
                    if cursor < chars.len() && matches!(chars[cursor], '+' | '-') {
                        cursor += 1;
                    }
                    while cursor < chars.len() && matches!(chars[cursor], '0'..='9') {
                        cursor += 1;
                    }
                    tail.extend(&chars[exp_start..cursor]);
                }
                if int_part.is_empty() {
                    tokens.push(Token::Value(chars[start..cursor].iter().collect()));
                } else {
                    tokens.push(Token::Value(format!("{sign}{int_part}{tail}")));
                }
                idx = cursor;
            }
            _ => {
                let mut end = idx + 1;
                while end < chars.len() {
                    let c = chars[end];
                    if matches!(
                        c,
                        ' ' | '\t' | '\r' | '\n' | '\0' | '{' | '}' | '[' | ']' | ':' | ',' | '"'
                    ) || (c as u32) < 0x20
                    {
                        break;
                    }
                    end += 1;
                }
                tokens.push(Token::Value(chars[idx..end].iter().collect()));
                idx = end;
            }
        }
    }

    let next_non_ws = |after: usize| -> Option<&Token> {
        let mut j = after + 1;
        while j < tokens.len() {
            if matches!(tokens[j], Token::Ws(_)) {
                j += 1;
                continue;
            }
            return Some(&tokens[j]);
        }
        None
    };

    let next_non_comma_info = |from: usize| -> (Option<&Token>, usize, usize) {
        let mut j = from;
        let mut count = 0usize;
        let mut last_comma = from;
        while j < tokens.len() {
            match &tokens[j] {
                Token::Ws(_) => j += 1,
                Token::Comma => {
                    count += 1;
                    last_comma = j;
                    j += 1;
                }
                other => return (Some(other), count, last_comma),
            }
        }
        (None, count, last_comma)
    };

    let mut out = String::with_capacity(trimmed.len());
    let mut stack: Vec<ContainerKind> = Vec::new();
    let mut prev_sig: Option<Token> = None;
    let mut i = 0usize;

    while i < tokens.len() {
        match &tokens[i] {
            Token::Ws(s) => out.push_str(s),
            Token::LBrace => {
                out.push('{');
                stack.push(ContainerKind::Object);
                prev_sig = Some(Token::LBrace);
            }
            Token::LBracket => {
                out.push('[');
                stack.push(ContainerKind::Array);
                prev_sig = Some(Token::LBracket);
            }
            Token::RBrace => {
                if prev_sig == Some(Token::Colon) {
                    out.push_str("null");
                }
                out.push('}');
                if stack.last() == Some(&ContainerKind::Object) {
                    stack.pop();
                }
                prev_sig = Some(Token::RBrace);
            }
            Token::RBracket => {
                out.push(']');
                if stack.last() == Some(&ContainerKind::Array) {
                    stack.pop();
                }
                prev_sig = Some(Token::RBracket);
            }
            Token::Colon => {
                out.push(':');
                prev_sig = Some(Token::Colon);
            }
            Token::Comma => {
                if prev_sig == Some(Token::Colon) {
                    out.push_str("null");
                    prev_sig = Some(Token::Value("null".to_string()));
                }
                let next_sig = next_non_ws(i);
                match stack.last() {
                    Some(ContainerKind::Object) => {
                        if prev_sig != Some(Token::LBrace)
                            && !matches!(next_sig, Some(Token::Comma) | Some(Token::RBrace) | None)
                        {
                            out.push(',');
                            prev_sig = Some(Token::Comma);
                        }
                    }
                    Some(ContainerKind::Array) => {
                        let (token, comma_count, last_comma_idx) = next_non_comma_info(i);
                        if prev_sig == Some(Token::LBracket) {
                            if token == Some(&Token::RBracket) {
                                let nulls = vec!["null"; comma_count + 1].join(",");
                                out.push_str(&nulls);
                                prev_sig = Some(Token::Value("null".to_string()));
                                i = last_comma_idx;
                            } else {
                                out.push_str("null,");
                                prev_sig = Some(Token::Comma);
                            }
                        } else if prev_sig == Some(Token::Comma) {
                            if !matches!(token, Some(Token::RBracket) | None) {
                                out.push_str("null,");
                                prev_sig = Some(Token::Comma);
                            }
                        } else if !matches!(token, Some(Token::RBracket) | None) {
                            out.push(',');
                            prev_sig = Some(Token::Comma);
                        }
                    }
                    None => {
                        if !matches!(next_sig, Some(Token::Comma) | None) {
                            out.push(',');
                            prev_sig = Some(Token::Comma);
                        }
                    }
                }
            }
            Token::Value(s) => {
                out.push_str(s);
                prev_sig = Some(Token::Value(s.clone()));
            }
        }
        i += 1;
    }

    out
}
