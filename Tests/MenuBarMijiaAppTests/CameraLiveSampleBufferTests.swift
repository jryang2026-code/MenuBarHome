import CoreMedia
import Foundation
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

struct CameraLiveSampleBufferTests {
    @Test("Frames on the playback clock are not marked display-immediately")
    func playbackClockDoesNotDisplayImmediately() throws {
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_422YpCbCr8,
            width: 16,
            height: 16,
            extensions: nil,
            formatDescriptionOut: &format
        )
        let description = try #require(status == noErr ? format : nil)
        let sample = FMP4Sample(
            trackID: 1,
            data: Data([0x01, 0x02, 0x03, 0x04]),
            decodeTime: 0,
            duration: 3_000,
            compositionOffset: 0,
            isKeyframe: false
        )
        let buffer = try #require(CameraLiveVideoPlayer.makeSampleBuffer(
            units: [Data([0x01, 0x02, 0x03, 0x04])],
            format: description,
            sample: sample,
            timescale: 90_000,
            isKeyframe: false,
            displayImmediately: false
        ))
        #expect(Self.attachesDisplayImmediately(buffer) == false)

        let immediate = try #require(CameraLiveVideoPlayer.makeSampleBuffer(
            units: [Data([0x01, 0x02, 0x03, 0x04])],
            format: description,
            sample: sample,
            timescale: 90_000,
            isKeyframe: true,
            displayImmediately: true
        ))
        #expect(Self.attachesDisplayImmediately(immediate))
    }

    @MainActor
    @Test("Builds audio format descriptions and sample buffers for AAC, A-law, and Opus tracks and detects moov audio tracks")
    func buildsAudioSampleBuffersAndDetectsAudioTracks() throws {
        let aacTrack = FMP4AudioTrack(
            trackID: 2,
            codec: .aac,
            timescale: 16_000,
            sampleRate: 16_000,
            channelCount: 1,
            bitsPerSample: 16,
            configRecord: Data([0x14, 0x08])
        )
        let aacFormat = try #require(CameraLiveVideoPlayer.makeAudioFormatDescription(for: aacTrack))
        let aacSample = FMP4AudioSample(trackID: 2, data: Data([0x21, 0x10, 0x04]), decodeTime: 0, duration: 1024)
        #expect(CameraLiveVideoPlayer.makeAudioSampleBuffer(sample: aacSample, format: aacFormat, track: aacTrack) != nil)

        let alawTrack = FMP4AudioTrack(
            trackID: 3,
            codec: .alaw,
            timescale: 8_000,
            sampleRate: 8_000,
            channelCount: 1,
            bitsPerSample: 8
        )
        let alawFormat = try #require(CameraLiveVideoPlayer.makeAudioFormatDescription(for: alawTrack))
        let alawSample = FMP4AudioSample(trackID: 3, data: Data(repeating: 0xD5, count: 160), decodeTime: 0, duration: 160)
        #expect(CameraLiveVideoPlayer.makeAudioSampleBuffer(sample: alawSample, format: alawFormat, track: alawTrack) != nil)

        // Variable-length FLAC packet (8 kHz, 160 frames = 20 ms, NOT 4096 frames = 512 ms)
        let flacTrack = FMP4AudioTrack(
            trackID: 4,
            codec: .flac,
            timescale: 8_000,
            sampleRate: 8_000,
            channelCount: 1,
            bitsPerSample: 16
        )
        let flacFormat = try #require(CameraLiveVideoPlayer.makeAudioFormatDescription(for: flacTrack))
        // FLAC frame header with bsCode=6 (8-bit blocksize = 159 -> 160 frames)
        let flacData = Data([0xFF, 0xF8, 0x64, 0x08, 0x00, 0x9F, 0x00, 0x00])
        let flacSample = FMP4AudioSample(trackID: 4, data: flacData, decodeTime: 0, duration: 160)
        let flacBuf = try #require(CameraLiveVideoPlayer.makeAudioSampleBuffer(sample: flacSample, format: flacFormat, track: flacTrack))
        let flacDur = CMSampleBufferGetDuration(flacBuf)
        #expect(abs(CMTimeGetSeconds(flacDur) - 0.02) < 0.001)

        // Variable-length 40 ms Opus packet (config=2 -> 1920 frames @ 48 kHz = 40 ms)
        let opusTrack = FMP4AudioTrack(
            trackID: 5,
            codec: .opus,
            timescale: 48_000,
            sampleRate: 48_000,
            channelCount: 1,
            bitsPerSample: 16
        )
        let opusFormat = try #require(CameraLiveVideoPlayer.makeAudioFormatDescription(for: opusTrack))
        let opusData = Data([0x10, 0x01, 0x02])
        let opusSample = FMP4AudioSample(trackID: 5, data: opusData, decodeTime: 0, duration: 1920)
        let opusBuf = try #require(CameraLiveVideoPlayer.makeAudioSampleBuffer(sample: opusSample, format: opusFormat, track: opusTrack))
        let opusDur = CMSampleBufferGetOutputDuration(opusBuf)
        #expect(abs(CMTimeGetSeconds(opusDur) - 0.04) < 0.001)

        let player = CameraLiveVideoPlayer()
        let videoTrack = FMP4VideoTrack(
            trackID: 1,
            codec: .h264,
            timescale: 90_000,
            width: 640,
            height: 360,
            configRecord: Data(),
            nalLengthSize: 4,
            parameterSets: []
        )
        player.processDemuxEvents([.videoTrack(videoTrack)])
        #expect(player.detectedAudioTrack == false)

        let playerWithAudio = CameraLiveVideoPlayer()
        playerWithAudio.processDemuxEvents([.videoTrack(videoTrack), .audioTrack(aacTrack)])
        #expect(playerWithAudio.detectedAudioTrack == true)
    }

    private static func attachesDisplayImmediately(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else {
            return false
        }
        let dict = Unmanaged<CFDictionary>.fromOpaque(
            CFArrayGetValueAtIndex(attachments, 0)
        ).takeUnretainedValue()
        return CFDictionaryContainsKey(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
        )
    }
}
