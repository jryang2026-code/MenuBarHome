import Foundation

/// Video codec carried by a fragmented MP4 live stream (#97).
public enum FMP4VideoCodec: String, Equatable, Sendable {
    case h264
    case hevc
}

/// Audio codec carried by a fragmented MP4 live stream (#445).
public enum FMP4AudioCodec: String, Equatable, Sendable {
    case aac
    case alaw
    case ulaw
    case opus
    case flac
}

/// Decoder configuration for one video track, read from the `moov` init segment.
public struct FMP4VideoTrack: Equatable, Sendable {
    public var trackID: UInt32
    public var codec: FMP4VideoCodec
    public var timescale: UInt32
    public var width: Int
    public var height: Int
    /// Body of the `avcC` / `hvcC` box (the decoder configuration record).
    public var configRecord: Data
    /// Length of every NAL-unit size prefix in a sample (1, 2 or 4).
    public var nalLengthSize: Int
    /// Parameter sets from the configuration record: SPS + PPS (H.264) or VPS + SPS + PPS (HEVC).
    public var parameterSets: [Data]
}

/// Decoder configuration for one audio track, read from the `moov` init segment (#445).
public struct FMP4AudioTrack: Equatable, Sendable {
    public var trackID: UInt32
    public var codec: FMP4AudioCodec
    public var timescale: UInt32
    public var sampleRate: Double
    public var channelCount: Int
    public var bitsPerSample: Int
    /// AudioSpecificConfig (`esds`), `dOps`, or `dfLa` payload when applicable.
    public var configRecord: Data

    public init(
        trackID: UInt32,
        codec: FMP4AudioCodec,
        timescale: UInt32,
        sampleRate: Double,
        channelCount: Int,
        bitsPerSample: Int,
        configRecord: Data = Data()
    ) {
        self.trackID = trackID
        self.codec = codec
        self.timescale = timescale
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
        self.configRecord = configRecord
    }
}

/// One coded video frame (AVCC/HVCC length-prefixed NAL units).
public struct FMP4Sample: Equatable, Sendable {
    public var trackID: UInt32
    public var data: Data
    public var decodeTime: UInt64
    public var duration: UInt32
    public var compositionOffset: Int32
    public var isKeyframe: Bool
}

/// One coded audio access unit / frame from a fragmented MP4 live stream (#445).
public struct FMP4AudioSample: Equatable, Sendable {
    public var trackID: UInt32
    public var data: Data
    public var decodeTime: UInt64
    public var duration: UInt32

    public init(
        trackID: UInt32,
        data: Data,
        decodeTime: UInt64,
        duration: UInt32
    ) {
        self.trackID = trackID
        self.data = data
        self.decodeTime = decodeTime
        self.duration = duration
    }
}

public enum FMP4DemuxEvent: Equatable, Sendable {
    case videoTrack(FMP4VideoTrack)
    case audioTrack(FMP4AudioTrack)
    case sample(FMP4Sample)
    case audioSample(FMP4AudioSample)
}

public enum FMP4DemuxError: Error, Equatable {
    case malformedBox(String)
    case bufferOverflow
}

/// Incremental parser for the progressive fragmented MP4 that go2rtc serves on
/// `/api/stream.mp4` (`ftyp` + `moov`, then a `moof` + `mdat` pair per frame).
///
/// Bytes arrive in arbitrary network chunks; `append(_:)` returns every complete
/// event and keeps the partial tail for the next call. Pure Foundation so it builds
/// and tests on Linux; CoreMedia conversion lives in the app target.
public struct FragmentedMP4Demuxer: Sendable {
    private var buffer = Data()
    private var tracks: [UInt32: FMP4VideoTrack] = [:]
    private var audioTracks: [UInt32: FMP4AudioTrack] = [:]
    private var trackDefaults: [UInt32: TrackDefaults] = [:]
    private var pendingMoof: Data?
    private let maxBufferedBytes: Int

    private struct TrackDefaults: Sendable {
        var duration: UInt32 = 0
        var size: UInt32 = 0
        var flags: UInt32 = 0
    }

    /// Most samples one `moof` + `mdat` pair may announce. A live fragment holds a couple of
    /// seconds of video, so even 60 fps H.264/HEVC with several runs stays under a few hundred
    /// frames; 4096 leaves two orders of magnitude of headroom while a forged `sample_count` of
    /// millions is rejected before the sample loop runs.
    static let maxSamplesPerFragment = 4_096

    public init(maxBufferedBytes: Int = 16 * 1024 * 1024) {
        self.maxBufferedBytes = maxBufferedBytes
    }

    public mutating func append(_ chunk: Data) throws -> [FMP4DemuxEvent] {
        buffer.append(chunk)
        var events: [FMP4DemuxEvent] = []
        var cursor = buffer.startIndex

        while true {
            let available = buffer.endIndex - cursor
            guard available >= 8 else { break }
            let size32 = Self.readUInt32(buffer, cursor)
            let type = Self.fourCC(buffer, cursor + 4)
            var headerSize = 8
            var boxSize: Int
            if size32 == 1 {
                guard available >= 16 else { break }
                let large = Self.readUInt64(buffer, cursor + 8)
                guard large <= UInt64(Int.max) else { throw FMP4DemuxError.malformedBox(type) }
                boxSize = Int(large)
                headerSize = 16
            } else if size32 == 0 {
                // "Extends to end of file" never terminates on a live stream.
                throw FMP4DemuxError.malformedBox(type)
            } else {
                boxSize = Int(size32)
            }
            guard boxSize >= headerSize else { throw FMP4DemuxError.malformedBox(type) }
            if boxSize > maxBufferedBytes { throw FMP4DemuxError.bufferOverflow }
            guard available >= boxSize else { break }

            let box = buffer.subdata(in: cursor..<(cursor + boxSize))
            cursor += boxSize

            switch type {
            case "moov":
                try parseMoov(box, headerSize: headerSize, into: &events)
            case "moof":
                pendingMoof = box
            case "mdat":
                if let moof = pendingMoof {
                    pendingMoof = nil
                    try parseFragment(moof: moof, mdat: box, mdatHeaderSize: headerSize, into: &events)
                }
            default:
                break // ftyp, styp, sidx, free, ...
            }
        }

        if cursor > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<cursor)
            buffer = Data(buffer) // re-base indices at 0
        }
        if buffer.count > maxBufferedBytes {
            throw FMP4DemuxError.bufferOverflow
        }
        return events
    }

    // MARK: - Init segment

    private enum ParsedTrack {
        case video(FMP4VideoTrack)
        case audio(FMP4AudioTrack)
    }

    private mutating func parseMoov(_ moov: Data, headerSize: Int, into events: inout [FMP4DemuxEvent]) throws {
        for child in Self.children(of: moov, from: headerSize) {
            switch child.type {
            case "trak":
                if let parsed = try Self.parseTrak(moov, range: child.payload) {
                    switch parsed {
                    case .video(let track):
                        tracks[track.trackID] = track
                        events.append(.videoTrack(track))
                    case .audio(let track):
                        audioTracks[track.trackID] = track
                        events.append(.audioTrack(track))
                    }
                }
            case "mvex":
                for trex in Self.children(of: moov, in: child.payload) where trex.type == "trex" {
                    let p = trex.payload.lowerBound
                    guard trex.payload.count >= 24 else { continue }
                    let trackID = Self.readUInt32(moov, p + 4)
                    trackDefaults[trackID] = TrackDefaults(
                        duration: Self.readUInt32(moov, p + 12),
                        size: Self.readUInt32(moov, p + 16),
                        flags: Self.readUInt32(moov, p + 20)
                    )
                }
            default:
                break
            }
        }
    }

    private static func parseTrak(_ data: Data, range: Range<Int>) throws -> ParsedTrack? {
        var trackID: UInt32?
        var timescale: UInt32 = 90_000
        var handlerType: String?
        var visualEntry: (codec: FMP4VideoCodec, width: Int, height: Int, config: Data)?
        var audioEntry: (codec: FMP4AudioCodec, sampleRate: Double, channels: Int, bitsPerSample: Int, config: Data)?

        for child in children(of: data, in: range) {
            switch child.type {
            case "tkhd":
                let p = child.payload.lowerBound
                guard child.payload.count >= 4 else { continue }
                let version = data[p]
                let idOffset = version == 1 ? 4 + 16 : 4 + 8
                if child.payload.count >= idOffset + 4 {
                    trackID = readUInt32(data, p + idOffset)
                }
            case "mdia":
                for m in children(of: data, in: child.payload) {
                    switch m.type {
                    case "mdhd":
                        let p = m.payload.lowerBound
                        guard m.payload.count >= 4 else { continue }
                        let version = data[p]
                        let tsOffset = version == 1 ? 4 + 16 : 4 + 8
                        if m.payload.count >= tsOffset + 4 {
                            timescale = readUInt32(data, p + tsOffset)
                        }
                    case "hdlr":
                        if m.payload.count >= 12 {
                            handlerType = fourCC(data, m.payload.lowerBound + 8)
                        }
                    case "minf":
                        visualEntry = findVisualSampleEntry(data, in: m.payload) ?? visualEntry
                        audioEntry = findAudioSampleEntry(data, in: m.payload) ?? audioEntry
                    default:
                        break
                    }
                }
            default:
                break
            }
        }

        guard let trackID else { return nil }
        if handlerType == "vide", let entry = visualEntry {
            guard let parsed = parseConfigRecord(entry.config, codec: entry.codec) else {
                throw FMP4DemuxError.malformedBox(entry.codec == .h264 ? "avcC" : "hvcC")
            }
            return .video(FMP4VideoTrack(
                trackID: trackID,
                codec: entry.codec,
                timescale: timescale == 0 ? 90_000 : timescale,
                width: entry.width,
                height: entry.height,
                configRecord: entry.config,
                nalLengthSize: parsed.nalLengthSize,
                parameterSets: parsed.parameterSets
            ))
        }
        if handlerType == "soun", let entry = audioEntry {
            let maxValidRate = 1_000_000.0
            let rawRate = entry.sampleRate
            let validEntryRate = rawRate.isFinite && rawRate >= 1 && rawRate <= maxValidRate ? rawRate : 0
            let validTimescaleRate = timescale >= 1 && Double(timescale) <= maxValidRate ? Double(timescale) : 0
            let rate = validEntryRate > 0 ? validEntryRate : validTimescaleRate
            guard rate >= 1 && rate <= maxValidRate else { return nil }
            let safeTimescale = timescale == 0 ? UInt32(rate.rounded()) : timescale
            return .audio(FMP4AudioTrack(
                trackID: trackID,
                codec: entry.codec,
                timescale: safeTimescale,
                sampleRate: rate,
                channelCount: min(max(entry.channels, 1), 32),
                bitsPerSample: entry.bitsPerSample,
                configRecord: entry.config
            ))
        }
        return nil
    }

    private static func findVisualSampleEntry(
        _ data: Data,
        in range: Range<Int>
    ) -> (codec: FMP4VideoCodec, width: Int, height: Int, config: Data)? {
        for stbl in children(of: data, in: range) where stbl.type == "stbl" {
            for stsd in children(of: data, in: stbl.payload) where stsd.type == "stsd" {
                // FullBox header (4) + entry_count (4), then sample entries.
                let entriesStart = stsd.payload.lowerBound + 8
                guard entriesStart <= stsd.payload.upperBound else { continue }
                for sampleEntry in children(of: data, in: entriesStart..<stsd.payload.upperBound) {
                    let codec: FMP4VideoCodec
                    switch sampleEntry.type {
                    case "avc1", "avc3": codec = .h264
                    case "hvc1", "hev1": codec = .hevc
                    default: continue
                    }
                    // SampleEntry (8) + VisualSampleEntry fields (70) precede child boxes.
                    let p = sampleEntry.payload.lowerBound
                    guard sampleEntry.payload.count >= 78 else { continue }
                    let width = Int(readUInt16(data, p + 24))
                    let height = Int(readUInt16(data, p + 26))
                    let configType = codec == .h264 ? "avcC" : "hvcC"
                    for box in children(of: data, in: (p + 78)..<sampleEntry.payload.upperBound) where box.type == configType {
                        return (codec, width, height, data.subdata(in: box.payload))
                    }
                }
            }
        }
        return nil
    }

    private static func findAudioSampleEntry(
        _ data: Data,
        in range: Range<Int>
    ) -> (codec: FMP4AudioCodec, sampleRate: Double, channels: Int, bitsPerSample: Int, config: Data)? {
        for stbl in children(of: data, in: range) where stbl.type == "stbl" {
            for stsd in children(of: data, in: stbl.payload) where stsd.type == "stsd" {
                let entriesStart = stsd.payload.lowerBound + 8
                guard entriesStart <= stsd.payload.upperBound else { continue }
                for sampleEntry in children(of: data, in: entriesStart..<stsd.payload.upperBound) {
                    let codec: FMP4AudioCodec
                    switch sampleEntry.type {
                    case "mp4a": codec = .aac
                    case "alaw": codec = .alaw
                    case "ulaw": codec = .ulaw
                    case "Opus": codec = .opus
                    case "fLaC": codec = .flac
                    default: continue
                    }
                    let p = sampleEntry.payload.lowerBound
                    guard sampleEntry.payload.count >= 28 else { continue }
                    let version = readUInt16(data, p + 8)
                    var channels = Int(readUInt16(data, p + 16))
                    let bitsPerSample = Int(readUInt16(data, p + 18))
                    let rawRate = readUInt32(data, p + 24)
                    var sampleRate = Double(rawRate >> 16) + Double(rawRate & 0xFFFF) / 65_536.0
                    let childStart: Int
                    switch version {
                    case 0:
                        childStart = p + 28
                    case 1:
                        childStart = p + 28 + 16
                    case 2:
                        guard sampleEntry.payload.count >= 64 else { continue }
                        let rateBits = readUInt64(data, p + 32)
                        let v2Rate = Double(bitPattern: rateBits)
                        if v2Rate.isFinite, v2Rate > 0 {
                            sampleRate = v2Rate
                        }
                        let v2Channels = Int(readUInt32(data, p + 40))
                        if v2Channels > 0 {
                            channels = v2Channels
                        }
                        childStart = p + 64
                    default:
                        childStart = p + 28
                    }
                    guard childStart <= sampleEntry.payload.upperBound else {
                        return (codec, sampleRate, channels, bitsPerSample, Data())
                    }
                    let childRange = childStart..<sampleEntry.payload.upperBound
                    var config = Data()
                    switch codec {
                    case .aac:
                        if let esds = findBox(named: "esds", in: data, range: childRange) {
                            config = parseESDSAudioSpecificConfig(data.subdata(in: esds.payload)) ?? Data()
                        } else if let wave = findBox(named: "wave", in: data, range: childRange),
                                  let esds = findBox(named: "esds", in: data, range: wave.payload) {
                            config = parseESDSAudioSpecificConfig(data.subdata(in: esds.payload)) ?? Data()
                        }
                        if let parsed = parseAudioSpecificConfig(config) {
                            if sampleRate <= 0 { sampleRate = parsed.sampleRate }
                            if channels <= 0 { channels = parsed.channelCount }
                        }
                    case .opus:
                        if let dops = findBox(named: "dOps", in: data, range: childRange) {
                            config = data.subdata(in: dops.payload)
                            if channels <= 0, config.count >= 2 {
                                channels = Int(config[1])
                            }
                        }
                        if sampleRate <= 0 { sampleRate = 48_000 }
                    case .flac:
                        if let dfla = findBox(named: "dfLa", in: data, range: childRange) {
                            config = data.subdata(in: dfla.payload)
                        }
                    case .alaw, .ulaw:
                        break
                    }
                    return (
                        codec,
                        sampleRate,
                        channels,
                        (codec == .alaw || codec == .ulaw) ? 8 : bitsPerSample,
                        config
                    )
                }
            }
        }
        return nil
    }

    private static func findBox(named type: String, in data: Data, range: Range<Int>) -> BoxRef? {
        children(of: data, in: range).first { $0.type == type }
    }

    private static let maxESDSDescriptorDepth = 8

    /// Extracts the AudioSpecificConfig payload from an ISO BMFF `esds` fullbox body.
    public static func parseESDSAudioSpecificConfig(_ esdsPayload: Data) -> Data? {
        let bytes = [UInt8](esdsPayload)
        guard bytes.count > 4 else { return nil }
        return scanESDSDescriptors(bytes, start: 4, end: bytes.count, depth: 0)
    }

    private static func scanESDSDescriptors(_ bytes: [UInt8], start: Int, end: Int, depth: Int) -> Data? {
        guard depth < maxESDSDescriptorDepth else { return nil }
        var i = start
        while i < end {
            let tag = bytes[i]
            i += 1
            var size = 0
            var lenBytes = 0
            while i < end, lenBytes < 4 {
                let b = bytes[i]
                i += 1
                lenBytes += 1
                size = (size << 7) | Int(b & 0x7F)
                if (b & 0x80) == 0 { break }
            }
            guard size >= 0, i + size <= end else { return nil }
            let payloadEnd = i + size
            switch tag {
            case 0x05: // DecoderSpecificInfo -> AudioSpecificConfig
                return Data(bytes[i..<payloadEnd])
            case 0x03: // ES_Descriptor
                guard i + 3 <= payloadEnd else { return nil }
                let flags = bytes[i + 2]
                var inner = i + 3
                if (flags & 0x80) != 0 { inner += 2 }
                if (flags & 0x40) != 0 {
                    guard inner < payloadEnd else { return nil }
                    inner += 1 + Int(bytes[inner])
                }
                if (flags & 0x20) != 0 { inner += 2 }
                guard inner <= payloadEnd else { return nil }
                if let found = scanESDSDescriptors(bytes, start: inner, end: payloadEnd, depth: depth + 1) {
                    return found
                }
            case 0x04: // DecoderConfigDescriptor
                let inner = i + 13
                guard inner <= payloadEnd else { return nil }
                if let found = scanESDSDescriptors(bytes, start: inner, end: payloadEnd, depth: depth + 1) {
                    return found
                }
            default:
                break
            }
            i = payloadEnd
        }
        return nil
    }

    private static func parseAudioSpecificConfig(_ config: Data) -> (sampleRate: Double, channelCount: Int)? {
        guard config.count >= 2 else { return nil }
        let b0 = config[config.startIndex]
        let b1 = config[config.startIndex + 1]
        let freqIndex = Int(((b0 & 0x07) << 1) | ((b1 & 0x80) >> 7))
        let channelConfig = Int((b1 & 0x78) >> 3)
        let rates: [Double] = [
            96_000, 88_200, 64_000, 48_000, 44_100, 32_000,
            24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350
        ]
        let sampleRate = freqIndex < rates.count ? rates[freqIndex] : 0
        return (sampleRate, channelConfig)
    }

    /// Parses an `avcC` / `hvcC` body into its NAL length size and parameter sets.
    public static func parseConfigRecord(
        _ record: Data,
        codec: FMP4VideoCodec
    ) -> (nalLengthSize: Int, parameterSets: [Data])? {
        let bytes = [UInt8](record)
        switch codec {
        case .h264:
            guard bytes.count >= 7 else { return nil }
            let lengthSize = Int(bytes[4] & 0x03) + 1
            var sets: [Data] = []
            var i = 5
            let spsCount = Int(bytes[i] & 0x1F)
            i += 1
            for _ in 0..<spsCount {
                guard i + 2 <= bytes.count else { return nil }
                let len = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                i += 2
                guard i + len <= bytes.count else { return nil }
                sets.append(Data(bytes[i..<(i + len)]))
                i += len
            }
            guard i < bytes.count else { return nil }
            let ppsCount = Int(bytes[i])
            i += 1
            for _ in 0..<ppsCount {
                guard i + 2 <= bytes.count else { return nil }
                let len = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                i += 2
                guard i + len <= bytes.count else { return nil }
                sets.append(Data(bytes[i..<(i + len)]))
                i += len
            }
            return (lengthSize, sets)
        case .hevc:
            guard bytes.count >= 23 else { return nil }
            let lengthSize = Int(bytes[21] & 0x03) + 1
            let arrayCount = Int(bytes[22])
            var i = 23
            var byType: [UInt8: [Data]] = [:]
            for _ in 0..<arrayCount {
                guard i + 3 <= bytes.count else { return nil }
                let nalType = bytes[i] & 0x3F
                let count = Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
                i += 3
                for _ in 0..<count {
                    guard i + 2 <= bytes.count else { return nil }
                    let len = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                    i += 2
                    guard i + len <= bytes.count else { return nil }
                    byType[nalType, default: []].append(Data(bytes[i..<(i + len)]))
                    i += len
                }
            }
            // VideoToolbox wants VPS, SPS, PPS in that order.
            let sets = (byType[32] ?? []) + (byType[33] ?? []) + (byType[34] ?? [])
            return (lengthSize, sets)
        }
    }

    // MARK: - Fragments

    private func parseFragment(
        moof: Data,
        mdat: Data,
        mdatHeaderSize: Int,
        into events: inout [FMP4DemuxEvent]
    ) throws {
        // Shared across every `traf` of this fragment: the declared counts are untrusted, so the
        // budget bounds the total work one network-supplied `moof` can ask for.
        var fragmentSampleCount = 0
        for traf in Self.children(of: moof, from: 8) where traf.type == "traf" {
            var trackID: UInt32 = 0
            var defaults = TrackDefaults()
            var baseDecodeTime: UInt64 = 0
            var runs: [Range<Int>] = []

            for box in Self.children(of: moof, in: traf.payload) {
                let p = box.payload.lowerBound
                switch box.type {
                case "tfhd":
                    guard box.payload.count >= 8 else { throw FMP4DemuxError.malformedBox("tfhd") }
                    let flags = Self.readUInt32(moof, p) & 0x00FF_FFFF
                    trackID = Self.readUInt32(moof, p + 4)
                    defaults = trackDefaults[trackID] ?? TrackDefaults()
                    var o = p + 8
                    let payloadEnd = box.payload.upperBound
                    func readField() throws -> UInt32 {
                        guard o + 4 <= payloadEnd else { throw FMP4DemuxError.malformedBox("tfhd") }
                        defer { o += 4 }
                        return Self.readUInt32(moof, o)
                    }
                    if flags & 0x01 != 0 { o += 8 } // base-data-offset (we assume moof-relative offsets)
                    if flags & 0x02 != 0 { o += 4 } // sample-description-index
                    if flags & 0x08 != 0 { defaults.duration = try readField() }
                    if flags & 0x10 != 0 { defaults.size = try readField() }
                    if flags & 0x20 != 0 { defaults.flags = try readField() }
                case "tfdt":
                    guard box.payload.count >= 8 else { throw FMP4DemuxError.malformedBox("tfdt") }
                    baseDecodeTime = moof[p] == 1 && box.payload.count >= 12
                        ? Self.readUInt64(moof, p + 4)
                        : UInt64(Self.readUInt32(moof, p + 4))
                case "trun":
                    runs.append(box.payload)
                default:
                    break
                }
            }
            let isVideoTrack = tracks[trackID] != nil
            let isAudioTrack = audioTracks[trackID] != nil
            guard isVideoTrack || isAudioTrack else { continue }

            // Sample data offsets are relative to the moof start; the mdat payload follows it.
            let mdatPayloadOffset = moof.count + mdatHeaderSize
            var nextDataOffset = mdatPayloadOffset
            var decodeTime = baseDecodeTime

            for run in runs {
                let p = run.lowerBound
                guard run.count >= 8 else { throw FMP4DemuxError.malformedBox("trun") }
                let flags = Self.readUInt32(moof, p) & 0x00FF_FFFF
                let count = Int(Self.readUInt32(moof, p + 4))
                var o = p + 8
                var dataOffset = nextDataOffset
                if flags & 0x01 != 0 {
                    guard o + 4 <= run.upperBound else { throw FMP4DemuxError.malformedBox("trun") }
                    dataOffset = Int(Int32(bitPattern: Self.readUInt32(moof, o)))
                    o += 4
                }
                var firstFlags: UInt32?
                if flags & 0x04 != 0 {
                    guard o + 4 <= run.upperBound else { throw FMP4DemuxError.malformedBox("trun") }
                    firstFlags = Self.readUInt32(moof, o)
                    o += 4
                }
                // `sample_count` is the one number in `trun` the structural checks cannot bound:
                // with no per-sample fields the payload guard below accepts any count, which a
                // forged stream turns into one empty sample per iteration. Reject up front instead.
                guard count <= Self.maxSamplesPerFragment - fragmentSampleCount else {
                    throw FMP4DemuxError.malformedBox("trun")
                }
                fragmentSampleCount += count
                let perSample = (flags & 0x100 != 0 ? 4 : 0) + (flags & 0x200 != 0 ? 4 : 0)
                    + (flags & 0x400 != 0 ? 4 : 0) + (flags & 0x800 != 0 ? 4 : 0)
                guard o + perSample * count <= run.upperBound else {
                    throw FMP4DemuxError.malformedBox("trun")
                }

                for index in 0..<count {
                    var duration = defaults.duration
                    var size = defaults.size
                    var sampleFlags = (index == 0 ? firstFlags : nil) ?? defaults.flags
                    var cto: Int32 = 0
                    if flags & 0x100 != 0 { duration = Self.readUInt32(moof, o); o += 4 }
                    if flags & 0x200 != 0 { size = Self.readUInt32(moof, o); o += 4 }
                    if flags & 0x400 != 0 { sampleFlags = Self.readUInt32(moof, o); o += 4 }
                    if flags & 0x800 != 0 { cto = Int32(bitPattern: Self.readUInt32(moof, o)); o += 4 }

                    let start = dataOffset - mdatPayloadOffset
                    let end = start + Int(size)
                    let payloadLength = mdat.count - mdatHeaderSize
                    guard start >= 0, end <= payloadLength else {
                        throw FMP4DemuxError.malformedBox("mdat")
                    }
                    // A zero-byte sample decodes to nothing; handing the player an empty access
                    // unit only costs a queue slot, so skip the event while still advancing the
                    // decode clock. The fragment budget above already bounds how many can appear.
                    if size > 0 {
                        let sampleData = mdat.subdata(in: (mdatHeaderSize + start)..<(mdatHeaderSize + end))
                        if isVideoTrack {
                            events.append(.sample(FMP4Sample(
                                trackID: trackID,
                                data: sampleData,
                                decodeTime: decodeTime,
                                duration: duration,
                                compositionOffset: cto,
                                isKeyframe: sampleFlags & 0x0001_0000 == 0
                            )))
                        } else if isAudioTrack {
                            events.append(.audioSample(FMP4AudioSample(
                                trackID: trackID,
                                data: sampleData,
                                decodeTime: decodeTime,
                                duration: duration
                            )))
                        }
                    }
                    decodeTime &+= UInt64(duration)
                    dataOffset = end + mdatPayloadOffset
                }
                nextDataOffset = dataOffset
            }
        }
    }

    // MARK: - Box helpers

    private struct BoxRef {
        let type: String
        let payload: Range<Int>
    }

    private static func children(of data: Data, from headerSize: Int) -> [BoxRef] {
        children(of: data, in: (data.startIndex + headerSize)..<data.endIndex)
    }

    private static func children(of data: Data, in range: Range<Int>) -> [BoxRef] {
        var result: [BoxRef] = []
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            let size32 = readUInt32(data, cursor)
            let type = fourCC(data, cursor + 4)
            var header = 8
            var size = Int(size32)
            if size32 == 1 {
                guard cursor + 16 <= range.upperBound else { break }
                let large = readUInt64(data, cursor + 8)
                guard large <= UInt64(range.upperBound - cursor) else { break }
                size = Int(large)
                header = 16
            } else if size32 == 0 {
                size = range.upperBound - cursor
            }
            guard size >= header, cursor + size <= range.upperBound else { break }
            result.append(BoxRef(type: type, payload: (cursor + header)..<(cursor + size)))
            cursor += size
        }
        return result
    }

    static func readUInt16(_ d: Data, _ i: Int) -> UInt16 {
        UInt16(d[i]) << 8 | UInt16(d[i + 1])
    }

    static func readUInt32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    static func readUInt64(_ d: Data, _ i: Int) -> UInt64 {
        UInt64(readUInt32(d, i)) << 32 | UInt64(readUInt32(d, i + 4))
    }

    static func fourCC(_ d: Data, _ i: Int) -> String {
        String(decoding: d[i..<(i + 4)], as: UTF8.self)
    }
}

// MARK: - NAL unit helpers

public enum VideoNALUnits {
    /// Splits a length-prefixed (AVCC/HVCC) sample into NAL units.
    public static func split(_ sample: Data, lengthSize: Int) -> [Data]? {
        guard (1...4).contains(lengthSize) else { return nil }
        let bytes = [UInt8](sample)
        var units: [Data] = []
        var i = 0
        while i < bytes.count {
            guard i + lengthSize <= bytes.count else { return nil }
            var len = 0
            for k in 0..<lengthSize { len = len << 8 | Int(bytes[i + k]) }
            i += lengthSize
            guard len > 0, i + len <= bytes.count else { return nil }
            units.append(Data(bytes[i..<(i + len)]))
            i += len
        }
        return units
    }

    /// Converts an Annex-B sample (start-code delimited) into 4-byte length-prefixed form.
    /// Returns nil when the sample does not start with a start code.
    public static func annexBToLengthPrefixed(_ sample: Data) -> Data? {
        let bytes = [UInt8](sample)
        guard bytes.count >= 4,
              (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1)
                || (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 1) else {
            return nil
        }
        var starts: [(codeStart: Int, nalStart: Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                let codeStart = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                starts.append((codeStart, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var out = Data()
        for (index, s) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].codeStart : bytes.count
            guard end > s.nalStart else { continue }
            let len = UInt32(end - s.nalStart)
            out.append(contentsOf: [UInt8(len >> 24), UInt8(len >> 16 & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len & 0xFF)])
            out.append(contentsOf: bytes[s.nalStart..<end])
        }
        return out
    }

    /// NAL unit type of the first header byte.
    public static func nalType(_ unit: Data, codec: FMP4VideoCodec) -> UInt8 {
        guard let first = unit.first else { return 0 }
        switch codec {
        case .h264: return first & 0x1F
        case .hevc: return (first >> 1) & 0x3F
        }
    }

    /// In-band parameter sets in decoder order, or nil if the sample carries an incomplete set.
    public static func parameterSets(in units: [Data], codec: FMP4VideoCodec) -> [Data]? {
        switch codec {
        case .h264:
            let sps = units.first { nalType($0, codec: .h264) == 7 }
            let pps = units.first { nalType($0, codec: .h264) == 8 }
            guard let sps, let pps else { return nil }
            return [sps, pps]
        case .hevc:
            let vps = units.first { nalType($0, codec: .hevc) == 32 }
            let sps = units.first { nalType($0, codec: .hevc) == 33 }
            let pps = units.first { nalType($0, codec: .hevc) == 34 }
            guard let vps, let sps, let pps else { return nil }
            return [vps, sps, pps]
        }
    }

    /// True when the sample holds an IDR / IRAP picture.
    public static func containsKeyframe(_ units: [Data], codec: FMP4VideoCodec) -> Bool {
        units.contains { unit in
            let type = nalType(unit, codec: codec)
            switch codec {
            case .h264: return type == 5
            case .hevc: return (16...23).contains(type)
            }
        }
    }
}
