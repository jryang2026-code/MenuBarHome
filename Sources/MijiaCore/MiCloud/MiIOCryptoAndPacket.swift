import CryptoKit
import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// MARK: - Errors & Packet Header

public enum MiIOError: Error, Equatable, Sendable {
    case invalidToken
    case invalidAddress(String)
    case malformedPacket
    case payloadTooLarge
    case checksumMismatch
    case unsupportedNonNumericDeviceId
    case handshakeFailed
    case timeout
    case shutDown
    case encryptionFailed
    case decryptionFailed
    case transportUnavailable
    case ambiguousActionOutcome
    case deviceError(code: Int, message: String)
}

extension MiIOError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            return L10n.tr("无效的米家设备本地 Token", "Invalid local Xiaomi device token")
        case .invalidAddress(let host):
            return L10n.tr("无效的设备局域网地址：\(host)", "Invalid local device address: \(host)")
        case .malformedPacket:
            return L10n.tr("局域网设备返回了无效的 miIO 数据包", "Device returned a malformed miIO packet")
        case .payloadTooLarge:
            return L10n.tr("局域网 UDP 请求负载过大", "miIO UDP request payload exceeds packet limit")
        case .checksumMismatch:
            return L10n.tr("设备 Token 校验失败或响应签名不匹配", "miIO packet checksum mismatch (token may be invalid)")
        case .unsupportedNonNumericDeviceId:
            return L10n.tr("设备 DID 不支持本地 miIO 二进制协议", "Device DID is not numeric and unsupported by miIO binary packets")
        case .handshakeFailed:
            return L10n.tr("局域网 miIO 握手失败", "Local miIO handshake failed")
        case .timeout:
            return L10n.tr("局域网 miIO 请求超时", "Local miIO UDP request timed out")
        case .shutDown:
            return L10n.tr("本地 miIO 客户端已停止", "Local miIO client has shut down")
        case .encryptionFailed:
            return L10n.tr("miIO 数据包加密失败", "miIO payload encryption failed")
        case .decryptionFailed:
            return L10n.tr("miIO 数据包解密失败", "miIO payload decryption failed")
        case .transportUnavailable:
            return L10n.tr("当前平台不支持本地 UDP 传输", "Local UDP transport is unavailable on this platform")
        case .ambiguousActionOutcome:
            return L10n.tr("局域网动作结果未确认，请检查设备状态后再试", "Local action outcome could not be confirmed; check device state before retrying")
        case .deviceError(let code, let message):
            return L10n.tr("设备局域网返回错误 (\(code))：\(message)", "Local device error (\(code)): \(message)")
        }
    }
}

public struct MiIOPacketHeader: Equatable, Sendable {
    public var magic: UInt16
    public var length: UInt16
    public var unknown: UInt32
    public var deviceId: UInt32
    public var stamp: UInt32
    public var checksum: Data

    public init(
        magic: UInt16 = MiIOPacket.magic,
        length: UInt16,
        unknown: UInt32 = 0,
        deviceId: UInt32,
        stamp: UInt32,
        checksum: Data
    ) {
        self.magic = magic
        self.length = length
        self.unknown = unknown
        self.deviceId = deviceId
        self.stamp = stamp
        self.checksum = checksum
    }
}

// MARK: - Packet Encoding / Decoding & Batching

public enum MiIOPacket {
    public static let magic: UInt16 = 0x2131
    public static let headerSize = 32
    public static let defaultMaxBatchSize = 12

    /// 32-byte miIO discovery / handshake HELLO datagram (`21310020ffffffff...`).
    public static let helloPacket: Data = {
        var data = Data([0x21, 0x31, 0x00, 0x20])
        data.append(contentsOf: repeatElement(UInt8(0xFF), count: 28))
        return data
    }()

    /// Decodes a 32-hex-character miIO token into 16 raw bytes, rejecting empty, all-00, and all-ff tokens.
    public static func validateToken(_ rawHex: String) -> Data? {
        let trimmed = rawHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 32 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var idx = trimmed.startIndex
        for _ in 0..<16 {
            let next = trimmed.index(idx, offsetBy: 2)
            guard let byte = UInt8(trimmed[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        if bytes.allSatisfy({ $0 == 0x00 }) || bytes.allSatisfy({ $0 == 0xFF }) {
            return nil
        }
        return Data(bytes)
    }

    public static func decodeHeader(_ data: Data) throws -> MiIOPacketHeader {
        guard data.count >= headerSize else { throw MiIOError.malformedPacket }
        let base = data.startIndex
        let magic = readUInt16BE(data, at: base)
        let length = readUInt16BE(data, at: base + 2)
        guard magic == Self.magic, Int(length) >= headerSize, Int(length) <= data.count else {
            throw MiIOError.malformedPacket
        }
        let unknown = readUInt32BE(data, at: base + 4)
        let deviceId = readUInt32BE(data, at: base + 8)
        let stamp = readUInt32BE(data, at: base + 12)
        let checksum = Data(data[(base + 16)..<(base + 32)])
        return MiIOPacketHeader(
            magic: magic,
            length: length,
            unknown: unknown,
            deviceId: deviceId,
            stamp: stamp,
            checksum: checksum
        )
    }

    public static func encode(
        deviceId: UInt32,
        stamp: UInt32,
        token: Data,
        payload: Data,
        unknown: UInt32 = 0
    ) throws -> Data {
        guard token.count == 16 else { throw MiIOError.invalidToken }
        let (key, iv) = try MiIOCrypto.deriveKeyAndIV(token: token)
        let ciphertext = payload.isEmpty
            ? Data()
            : try MiIOCrypto.encryptAES128CBC(payload, key: key, iv: iv)
        let totalLength = headerSize + ciphertext.count
        guard totalLength <= Int(UInt16.max) else { throw MiIOError.payloadTooLarge }

        var prefix = Data()
        prefix.reserveCapacity(16)
        appendUInt16BE(magic, to: &prefix)
        appendUInt16BE(UInt16(totalLength), to: &prefix)
        appendUInt32BE(unknown, to: &prefix)
        appendUInt32BE(deviceId, to: &prefix)
        appendUInt32BE(stamp, to: &prefix)

        var checksumInput = Data()
        checksumInput.reserveCapacity(16 + 16 + ciphertext.count)
        checksumInput.append(prefix)
        checksumInput.append(token)
        checksumInput.append(ciphertext)
        let checksum = Data(Insecure.MD5.hash(data: checksumInput))

        var packet = Data()
        packet.reserveCapacity(totalLength)
        packet.append(prefix)
        packet.append(checksum)
        packet.append(ciphertext)
        return packet
    }

    public static func decode(_ data: Data, token: Data) throws -> (header: MiIOPacketHeader, payload: Data) {
        guard token.count == 16 else { throw MiIOError.invalidToken }
        let header = try decodeHeader(data)
        let base = data.startIndex
        let end = base + Int(header.length)
        let prefix = data[base..<(base + 16)]
        let ciphertext = data[(base + headerSize)..<end]

        var checksumInput = Data()
        checksumInput.reserveCapacity(16 + 16 + ciphertext.count)
        checksumInput.append(prefix)
        checksumInput.append(token)
        checksumInput.append(ciphertext)
        let expected = Data(Insecure.MD5.hash(data: checksumInput))
        guard expected == header.checksum else {
            throw MiIOError.checksumMismatch
        }

        if ciphertext.isEmpty {
            return (header, Data())
        }
        let (key, iv) = try MiIOCrypto.deriveKeyAndIV(token: token)
        let plaintext = try MiIOCrypto.decryptAES128CBC(Data(ciphertext), key: key, iv: iv)
        return (header, plaintext)
    }

    /// Splits a property read/write batch into MTU-safe chunks (10–14 items, default 12).
    public static func chunked<T>(_ items: [T], maxBatchSize: Int = defaultMaxBatchSize) -> [[T]] {
        guard !items.isEmpty else { return [] }
        let size = max(1, maxBatchSize)
        var chunks: [[T]] = []
        chunks.reserveCapacity((items.count + size - 1) / size)
        var start = 0
        while start < items.count {
            let end = min(start + size, items.count)
            chunks.append(Array(items[start..<end]))
            start = end
        }
        return chunks
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

// MARK: - miIO Key/IV Derivation & AES-128-CBC (CommonCrypto + Pure-Swift Fallback)

public enum MiIOCrypto {
    public static func deriveKeyAndIV(token: Data) throws -> (key: Data, iv: Data) {
        guard token.count == 16 else { throw MiIOError.invalidToken }
        let key = Data(Insecure.MD5.hash(data: token))
        var ivMaterial = Data()
        ivMaterial.reserveCapacity(32)
        ivMaterial.append(key)
        ivMaterial.append(token)
        let iv = Data(Insecure.MD5.hash(data: ivMaterial))
        return (key, iv)
    }

    public static func encryptAES128CBC(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16, iv.count == 16 else { throw MiIOError.encryptionFailed }
        #if canImport(CommonCrypto)
        return try commonCryptoAES128CBC(plaintext, key: key, iv: iv, encrypt: true)
        #else
        return try pureSwiftEncryptAES128CBC(plaintext, key: key, iv: iv)
        #endif
    }

    public static func decryptAES128CBC(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16, iv.count == 16, !ciphertext.isEmpty, ciphertext.count % 16 == 0 else {
            throw MiIOError.decryptionFailed
        }
        #if canImport(CommonCrypto)
        return try commonCryptoAES128CBC(ciphertext, key: key, iv: iv, encrypt: false)
        #else
        return try pureSwiftDecryptAES128CBC(ciphertext, key: key, iv: iv)
        #endif
    }

    #if canImport(CommonCrypto)
    private static func commonCryptoAES128CBC(_ input: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        var outBytes = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var outLength = 0
        let operation = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                input.withUnsafeBytes { inputPtr in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress, kCCKeySizeAES128,
                        ivPtr.baseAddress,
                        inputPtr.baseAddress, input.count,
                        &outBytes, outBytes.count,
                        &outLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw encrypt ? MiIOError.encryptionFailed : MiIOError.decryptionFailed
        }
        return Data(outBytes.prefix(outLength))
    }
    #endif

    // MARK: Pure-Swift FIPS-197 AES-128-CBC + PKCS7 (used on Linux and directly tested on macOS)

    static func pureSwiftEncryptAES128CBC(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16, iv.count == 16 else { throw MiIOError.encryptionFailed }
        let roundKeys = expandAES128Key([UInt8](key))
        var padded = [UInt8](plaintext)
        let padLen = 16 - (padded.count % 16)
        padded.append(contentsOf: repeatElement(UInt8(padLen), count: padLen))

        var out = [UInt8]()
        out.reserveCapacity(padded.count)
        var prev = [UInt8](iv)
        var block = [UInt8](repeating: 0, count: 16)

        for offset in stride(from: 0, to: padded.count, by: 16) {
            for j in 0..<16 {
                block[j] = padded[offset + j] ^ prev[j]
            }
            let encrypted = encryptAES128Block(block, roundKeys: roundKeys)
            out.append(contentsOf: encrypted)
            prev = encrypted
        }
        return Data(out)
    }

    static func pureSwiftDecryptAES128CBC(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16, iv.count == 16, !ciphertext.isEmpty, ciphertext.count % 16 == 0 else {
            throw MiIOError.decryptionFailed
        }
        let roundKeys = expandAES128Key([UInt8](key))
        let input = [UInt8](ciphertext)
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        var prev = [UInt8](iv)

        for offset in stride(from: 0, to: input.count, by: 16) {
            let block = Array(input[offset..<(offset + 16)])
            var dec = decryptAES128Block(block, roundKeys: roundKeys)
            for j in 0..<16 {
                dec[j] ^= prev[j]
            }
            out.append(contentsOf: dec)
            prev = block
        }

        guard let lastByte = out.last else { throw MiIOError.decryptionFailed }
        let padLen = Int(lastByte)
        guard padLen >= 1, padLen <= 16, out.count >= padLen else {
            throw MiIOError.decryptionFailed
        }
        var validPad: UInt8 = 0
        for i in (out.count - padLen)..<out.count {
            validPad |= out[i] ^ lastByte
        }
        guard validPad == 0 else { throw MiIOError.decryptionFailed }
        return Data(out.prefix(out.count - padLen))
    }

    private static let aesSBox: [UInt8] = [
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
    ]

    private static let aesInvSBox: [UInt8] = [
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
    ]

    private static let rcon: [UInt8] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]

    private static func expandAES128Key(_ key: [UInt8]) -> [UInt8] {
        var expanded = [UInt8](repeating: 0, count: 176)
        for i in 0..<16 { expanded[i] = key[i] }
        var bytesGenerated = 16
        var rconIdx = 0
        var temp = [UInt8](repeating: 0, count: 4)

        while bytesGenerated < 176 {
            for i in 0..<4 { temp[i] = expanded[bytesGenerated - 4 + i] }
            if bytesGenerated % 16 == 0 {
                let t = temp[0]
                temp[0] = aesSBox[Int(temp[1])] ^ rcon[rconIdx]
                temp[1] = aesSBox[Int(temp[2])]
                temp[2] = aesSBox[Int(temp[3])]
                temp[3] = aesSBox[Int(t)]
                rconIdx += 1
            }
            for i in 0..<4 {
                expanded[bytesGenerated] = expanded[bytesGenerated - 16] ^ temp[i]
                bytesGenerated += 1
            }
        }
        return expanded
    }

    private static func xtime(_ a: UInt8) -> UInt8 {
        (a << 1) ^ ((a & 0x80) != 0 ? 0x1B : 0x00)
    }

    private static func gfMul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var p: UInt8 = 0
        var x = a
        var y = b
        for _ in 0..<8 {
            if (y & 1) != 0 { p ^= x }
            x = xtime(x)
            y >>= 1
        }
        return p
    }

    private static func addRoundKey(_ state: inout [UInt8], roundKeys: [UInt8], round: Int) {
        let base = round * 16
        for i in 0..<16 {
            state[i] ^= roundKeys[base + i]
        }
    }

    private static func encryptAES128Block(_ input: [UInt8], roundKeys: [UInt8]) -> [UInt8] {
        var s = input
        addRoundKey(&s, roundKeys: roundKeys, round: 0)
        for round in 1...10 {
            for i in 0..<16 { s[i] = aesSBox[Int(s[i])] }
            // ShiftRows
            let t1 = s[1]; s[1] = s[5]; s[5] = s[9]; s[9] = s[13]; s[13] = t1
            let t2 = s[2]; s[2] = s[10]; s[10] = t2
            let t6 = s[6]; s[6] = s[14]; s[14] = t6
            let t3 = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = s[3]; s[3] = t3

            if round < 10 {
                for c in 0..<4 {
                    let i = c * 4
                    let a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3]
                    let xorAll = a0 ^ a1 ^ a2 ^ a3
                    s[i] = a0 ^ xorAll ^ xtime(a0 ^ a1)
                    s[i + 1] = a1 ^ xorAll ^ xtime(a1 ^ a2)
                    s[i + 2] = a2 ^ xorAll ^ xtime(a2 ^ a3)
                    s[i + 3] = a3 ^ xorAll ^ xtime(a3 ^ a0)
                }
            }
            addRoundKey(&s, roundKeys: roundKeys, round: round)
        }
        return s
    }

    private static func decryptAES128Block(_ input: [UInt8], roundKeys: [UInt8]) -> [UInt8] {
        var s = input
        addRoundKey(&s, roundKeys: roundKeys, round: 10)
        for round in stride(from: 9, through: 0, by: -1) {
            // InvShiftRows
            let t1 = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = s[1]; s[1] = t1
            let t2 = s[2]; s[2] = s[10]; s[10] = t2
            let t6 = s[6]; s[6] = s[14]; s[14] = t6
            let t3 = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t3

            for i in 0..<16 { s[i] = aesInvSBox[Int(s[i])] }
            addRoundKey(&s, roundKeys: roundKeys, round: round)

            if round > 0 {
                for c in 0..<4 {
                    let i = c * 4
                    let a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3]
                    s[i] = gfMul(a0, 0x0E) ^ gfMul(a1, 0x0B) ^ gfMul(a2, 0x0D) ^ gfMul(a3, 0x09)
                    s[i + 1] = gfMul(a0, 0x09) ^ gfMul(a1, 0x0E) ^ gfMul(a2, 0x0B) ^ gfMul(a3, 0x0D)
                    s[i + 2] = gfMul(a0, 0x0D) ^ gfMul(a1, 0x09) ^ gfMul(a2, 0x0E) ^ gfMul(a3, 0x0B)
                    s[i + 3] = gfMul(a0, 0x0B) ^ gfMul(a1, 0x0D) ^ gfMul(a2, 0x09) ^ gfMul(a3, 0x0E)
                }
            }
        }
        return s
    }
}

// MARK: - Malformed Firmware JSON Sanitizer

/// Cleans common Xiaomi/ecosystem firmware JSON malformations outside string literals
/// (trailing null/control bytes, trailing commas before `}`/`]`, consecutive commas `,,`,
/// missing values after `:`, and leading-zero octal-style numbers such as `:00`) without
/// ever modifying valid string literal contents.
public func cleanMalformedFirmwareJSON(_ raw: String) -> String {
    let trimSet = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    let trimmed = raw.trimmingCharacters(in: trimSet)
    guard !trimmed.isEmpty else { return "" }

    enum Token: Equatable {
        case ws(String)
        case lbrace
        case rbrace
        case lbracket
        case rbracket
        case colon
        case comma
        case value(String)
    }

    enum ContainerKind {
        case object
        case array
    }

    var tokens: [Token] = []
    let chars = Array(trimmed)
    var idx = 0

    while idx < chars.count {
        let ch = chars[idx]
        switch ch {
        case " ", "\t", "\r", "\n":
            var end = idx + 1
            while end < chars.count, [" ", "\t", "\r", "\n"].contains(chars[end]) {
                end += 1
            }
            tokens.append(.ws(String(chars[idx..<end])))
            idx = end

        case "\0":
            idx += 1

        case _ where ch.unicodeScalars.allSatisfy({ $0.value < 0x20 }):
            idx += 1

        case "\"":
            var end = idx + 1
            var escaped = false
            while end < chars.count {
                let c = chars[end]
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    end += 1
                    break
                }
                end += 1
            }
            tokens.append(.value(String(chars[idx..<end])))
            idx = end

        case "{":
            tokens.append(.lbrace)
            idx += 1

        case "}":
            tokens.append(.rbrace)
            idx += 1

        case "[":
            tokens.append(.lbracket)
            idx += 1

        case "]":
            tokens.append(.rbracket)
            idx += 1

        case ":":
            tokens.append(.colon)
            idx += 1

        case ",":
            tokens.append(.comma)
            idx += 1

        case "0"..."9", "-":
            if ch == "-", (idx + 1 >= chars.count || !(chars[idx + 1] >= "0" && chars[idx + 1] <= "9")) {
                tokens.append(.value("-"))
                idx += 1
                continue
            }
            let start = idx
            var cursor = idx
            var sign = ""
            if chars[cursor] == "-" {
                sign = "-"
                cursor += 1
            }
            let intStart = cursor
            while cursor < chars.count, chars[cursor] >= "0", chars[cursor] <= "9" {
                cursor += 1
            }
            var intPart = String(chars[intStart..<cursor])
            while intPart.count > 1, intPart.first == "0" {
                intPart.removeFirst()
            }
            var tail = ""
            if cursor < chars.count, chars[cursor] == "." {
                let dotStart = cursor
                cursor += 1
                while cursor < chars.count, chars[cursor] >= "0", chars[cursor] <= "9" {
                    cursor += 1
                }
                tail += String(chars[dotStart..<cursor])
            }
            if cursor < chars.count, chars[cursor] == "e" || chars[cursor] == "E" {
                let expStart = cursor
                cursor += 1
                if cursor < chars.count, chars[cursor] == "+" || chars[cursor] == "-" {
                    cursor += 1
                }
                while cursor < chars.count, chars[cursor] >= "0", chars[cursor] <= "9" {
                    cursor += 1
                }
                tail += String(chars[expStart..<cursor])
            }
            if intPart.isEmpty {
                tokens.append(.value(String(chars[start..<cursor])))
            } else {
                tokens.append(.value(sign + intPart + tail))
            }
            idx = cursor

        default:
            var end = idx + 1
            while end < chars.count {
                let c = chars[end]
                if [" ", "\t", "\r", "\n", "\0", "{", "}", "[", "]", ":", ",", "\""].contains(c)
                    || c.unicodeScalars.allSatisfy({ $0.value < 0x20 }) {
                    break
                }
                end += 1
            }
            tokens.append(.value(String(chars[idx..<end])))
            idx = end
        }
    }

    func nextNonWS(after index: Int) -> Token? {
        var j = index + 1
        while j < tokens.count {
            if case .ws = tokens[j] {
                j += 1
                continue
            }
            return tokens[j]
        }
        return nil
    }

    func nextNonCommaInfo(from index: Int) -> (token: Token?, commaCount: Int, lastCommaIndex: Int) {
        var j = index
        var count = 0
        var lastComma = index
        while j < tokens.count {
            switch tokens[j] {
            case .ws:
                j += 1
            case .comma:
                count += 1
                lastComma = j
                j += 1
            default:
                return (tokens[j], count, lastComma)
            }
        }
        return (nil, count, lastComma)
    }

    var out = ""
    out.reserveCapacity(trimmed.count)
    var stack: [ContainerKind] = []
    var prevSig: Token? = nil
    var i = 0

    while i < tokens.count {
        let token = tokens[i]
        switch token {
        case .ws(let s):
            out += s

        case .lbrace:
            out += "{"
            stack.append(.object)
            prevSig = .lbrace

        case .lbracket:
            out += "["
            stack.append(.array)
            prevSig = .lbracket

        case .rbrace:
            if prevSig == .colon {
                out += "null"
            }
            out += "}"
            if stack.last == .object { _ = stack.popLast() }
            prevSig = .rbrace

        case .rbracket:
            out += "]"
            if stack.last == .array { _ = stack.popLast() }
            prevSig = .rbracket

        case .colon:
            out += ":"
            prevSig = .colon

        case .comma:
            if prevSig == .colon {
                out += "null"
                prevSig = .value("null")
            }
            let nextSig = nextNonWS(after: i)
            switch stack.last {
            case .object:
                if prevSig == .lbrace || nextSig == .comma || nextSig == .rbrace || nextSig == nil {
                    break
                }
                out += ","
                prevSig = .comma

            case .array:
                let info = nextNonCommaInfo(from: i)
                if prevSig == .lbracket {
                    if info.token == .rbracket {
                        let nulls = Array(repeating: "null", count: info.commaCount + 1).joined(separator: ",")
                        out += nulls
                        prevSig = .value("null")
                        i = info.lastCommaIndex
                    } else {
                        out += "null,"
                        prevSig = .comma
                    }
                } else if prevSig == .comma {
                    if info.token == .rbracket || info.token == nil {
                        break
                    }
                    out += "null,"
                    prevSig = .comma
                } else {
                    if info.token == .rbracket || info.token == nil {
                        break
                    }
                    out += ","
                    prevSig = .comma
                }

            case nil:
                if nextSig != .comma && nextSig != nil {
                    out += ","
                    prevSig = .comma
                }
            }

        case .value(let s):
            out += s
            prevSig = .value(s)
        }
        i += 1
    }

    return out
}
