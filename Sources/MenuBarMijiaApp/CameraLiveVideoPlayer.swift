import AppKit
import AVFoundation
import AVKit
import CoreMedia
import MijiaCore
import os
import SwiftUI

// MARK: - Native fMP4 Live Video Player (#97)

/// Plays go2rtc's progressive fragmented MP4 (`/api/stream.mp4`) with hardware decoding.
///
/// Network chunks are demuxed on a private serial queue and every coded frame is enqueued
/// into an `AVSampleBufferDisplayLayer` whose timebase follows the stream, so the picture
/// stays live without FFmpeg transcoding, JPEG decoding or SwiftUI re-renders.
final class CameraLiveVideoPlayer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Outcome: Sendable {
        var framesDecoded: Int
        var failure: String?
    }

    let displayLayer: AVSampleBufferDisplayLayer
    /// The layer's renderer, captured on the main actor; enqueue/flush are thread-safe.
    private let renderer: AVSampleBufferVideoRenderer

    /// Called on the main actor when the first frame of a connection reaches the renderer.
    var onFirstFrame: (@MainActor @Sendable () -> Void)?
    var onAudioAvailabilityChanged: (@MainActor @Sendable (Bool) -> Void)?
    var onPlaybackPauseChanged: (@MainActor @Sendable (Bool) -> Void)?
    var playOverride: (@MainActor @Sendable (URL, CameraLiveVideoPlayer) async -> Outcome)?
    var stopOverride: (@MainActor @Sendable (String?) -> Void)?

    struct DecodedFrameTimestamps: Sendable {
        var firstFrameUptimeNs: UInt64 = 0
        var lastFrameUptimeNs: UInt64 = 0
    }

    private let frameTimestampsLock = OSAllocatedUnfairLock(initialState: DecodedFrameTimestamps())

    func resetFrameTimestamps() {
        frameTimestampsLock.withLock { $0 = DecodedFrameTimestamps() }
    }

    func recordDecodedFrameTimestamp(_ uptimeNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let safeNs = max(uptimeNs, 1)
        frameTimestampsLock.withLock { state in
            if state.firstFrameUptimeNs == 0 {
                state.firstFrameUptimeNs = safeNs
            }
            state.lastFrameUptimeNs = safeNs
        }
    }

    func touchLastFrameTimestamp(_ uptimeNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let safeNs = max(uptimeNs, 1)
        frameTimestampsLock.withLock { state in
            if state.lastFrameUptimeNs != 0 {
                state.lastFrameUptimeNs = safeNs
            }
        }
    }

    func decodedFrameTimestamps() -> DecodedFrameTimestamps {
        frameTimestampsLock.withLock { $0 }
    }

    private final class PlayToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "CameraLiveVideo")
    private let queue = DispatchQueue(label: "com.jryang1997.MenuBarMijia.camera-fmp4", qos: .userInteractive)
    private let delegateQueue: OperationQueue
    private let audioStateLock = NSLock()
    private var mutedState = true
    private var detectedAudioTrackState: Bool?
    /// Output-only synchronizer shared between the video display layer and the optional
    /// listen-only audio renderer. Never opens an audio input device / microphone (#445).
    private var renderSynchronizer: AVSampleBufferRenderSynchronizer?

    var detectedAudioTrack: Bool? {
        audioStateLock.withLock { detectedAudioTrackState }
    }

    // Everything below is only touched on `queue`.
    private var activeToken: PlayToken?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var demuxer = FragmentedMP4Demuxer()
    private var track: FMP4VideoTrack?
    private var audioTrack: FMP4AudioTrack?
    private var formatDescription: CMVideoFormatDescription?
    private var audioFormatDescription: CMAudioFormatDescription?
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var didReportAudioAvailability = false
    private var activeParameterSets: [Data] = []
    private var waitingForKeyframe = true
    private var framesDecoded = 0
    private var failure: String?
    private var statsWindowStart = Date()
    private var statsWindowFrames = 0
    private var playbackPaused = false
    private var playbackClock = CameraLivePlaybackClock()

    @MainActor
    override init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        displayLayer = layer
        renderer = layer.sampleBufferRenderer
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        super.init()
        delegateQueue.underlyingQueue = queue
        installLiveSynchronizer()
    }

    @MainActor
    private func installLiveSynchronizer() {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.setRate(0, time: .invalid)
        synchronizer.addRenderer(renderer)
        renderSynchronizer = synchronizer
    }

    func setMuted(_ muted: Bool) {
        audioStateLock.withLock { mutedState = muted }
        queue.async {
            if muted {
                self.teardownAudioRenderer()
            } else {
                self.ensureAudioRendererIfNeeded()
            }
        }
    }

    private func ensureAudioRendererIfNeeded() {
        let isMuted = audioStateLock.withLock { mutedState }
        guard !isMuted, !playbackPaused, audioTrack != nil, audioFormatDescription != nil else { return }
        if audioRenderer == nil {
            let newAudioRenderer = AVSampleBufferAudioRenderer()
            newAudioRenderer.isMuted = false
            newAudioRenderer.volume = 1.0
            renderSynchronizer?.addRenderer(newAudioRenderer)
            audioRenderer = newAudioRenderer
        } else {
            audioRenderer?.isMuted = false
            audioRenderer?.volume = 1.0
        }
    }

    private func teardownAudioRenderer() {
        guard let existing = audioRenderer else { return }
        existing.isMuted = true
        existing.flush()
        renderSynchronizer?.removeRenderer(existing, at: .invalid)
        audioRenderer = nil
    }

    /// Streams one HTTP connection until it ends, fails, or the calling task is cancelled.
    func play(url: URL) async -> Outcome {
        if let playOverride {
            return await playOverride(url, self)
        }
        let token = PlayToken()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
                queue.async { self.begin(url: url, token: token, continuation: cont) }
            }
        } onCancel: {
            token.cancel()
            self.queue.async {
                if self.activeToken === token { self.finish(failure: nil) }
            }
        }
    }

    func stop(failure reason: String? = nil) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.onPlaybackPauseChanged?(false)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.onPlaybackPauseChanged?(false)
            }
        }
        if let stopOverride {
            Task { @MainActor in stopOverride(reason) }
        }
        queue.async {
            self.playbackPaused = false
            self.renderer.flush()
            self.teardownAudioRenderer()
            self.finish(failure: reason)
        }
    }

    @MainActor
    func notifyDecodedFrame(_ count: Int) {
        recordDecodedFrameTimestamp()
        if count == 1 {
            onFirstFrame?()
        }
    }

    func setPlaybackPaused(_ paused: Bool) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.onPlaybackPauseChanged?(paused)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.onPlaybackPauseChanged?(paused)
            }
        }
        queue.async {
            let resumed = self.playbackPaused && !paused
            self.playbackPaused = paused
            if paused {
                self.teardownAudioRenderer()
                if let sync = self.renderSynchronizer {
                    sync.setRate(0, time: sync.currentTime())
                }
            } else if resumed {
                self.resumeFromNextKeyframe()
                self.ensureAudioRendererIfNeeded()
            }
        }
    }

    private func resumeFromNextKeyframe() {
        renderer.flush()
        waitingForKeyframe = true
        playbackClock.reset()
    }

    // MARK: - Connection lifecycle (queue)

    private func begin(url: URL, token: PlayToken, continuation cont: CheckedContinuation<Outcome, Never>) {
        finish(failure: nil)
        guard !token.isCancelled else {
            cont.resume(returning: Outcome(framesDecoded: 0, failure: nil))
            return
        }
        activeToken = token
        continuation = cont
        demuxer = FragmentedMP4Demuxer()
        track = nil
        audioTrack = nil
        audioFormatDescription = nil
        didReportAudioAvailability = false
        audioStateLock.withLock { detectedAudioTrackState = nil }
        teardownAudioRenderer()
        // A new connection may carry different parameter sets; keep nothing from the last one.
        formatDescription = nil
        activeParameterSets = []
        waitingForKeyframe = true
        framesDecoded = 0
        resetFrameTimestamps()
        failure = nil
        statsWindowStart = Date()
        statsWindowFrames = 0
        playbackClock.reset()
        renderSynchronizer?.setRate(0, time: .invalid)
        renderer.flush()

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 0
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        session.dataTask(with: XiaomiCameraBridge.authorizedURLRequest(for: url)).resume()
    }

    private func finish(failure reason: String?) {
        if let reason, failure == nil { failure = reason }
        teardownAudioRenderer()
        session?.invalidateAndCancel()
        session = nil
        activeToken = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: Outcome(framesDecoded: framesDecoded, failure: failure))
        }
    }

    // MARK: - URLSessionDataDelegate (queue)

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = "HTTP \(http.statusCode)"
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === self.session else { return }
        let events: [FMP4DemuxEvent]
        do {
            events = try demuxer.append(data)
        } catch {
            finish(failure: "fMP4 demux error: \(error)")
            return
        }
        processDemuxEvents(events)
    }

    func processDemuxEvents(_ events: [FMP4DemuxEvent]) {
        var sawVideoTrackInBatch = false
        var sawAudioTrackInBatch = false
        for event in events {
            switch event {
            case .videoTrack(let newTrack):
                sawVideoTrackInBatch = true
                if track == nil {
                    track = newTrack
                    logger.info("camera fMP4 track \(newTrack.codec.rawValue, privacy: .public) \(newTrack.width)x\(newTrack.height) timescale \(newTrack.timescale)")
                }
            case .audioTrack(let newAudioTrack):
                sawAudioTrackInBatch = true
                if audioTrack == nil {
                    audioTrack = newAudioTrack
                    audioFormatDescription = Self.makeAudioFormatDescription(for: newAudioTrack)
                    let supported = audioFormatDescription != nil
                    reportAudioAvailability(supported)
                    if supported {
                        ensureAudioRendererIfNeeded()
                    }
                    logger.info("camera fMP4 audio track \(newAudioTrack.codec.rawValue, privacy: .public) \(Int(newAudioTrack.sampleRate))Hz ch=\(newAudioTrack.channelCount) supported=\(supported)")
                }
            case .sample(let sample):
                guard let track, sample.trackID == track.trackID else { continue }
                enqueue(sample, track: track)
                if self.session == nil { return } // a fatal enqueue error closed the connection
            case .audioSample(let sample):
                guard let audioTrack, sample.trackID == audioTrack.trackID else { continue }
                enqueueAudio(sample, track: audioTrack)
            }
        }
        if sawVideoTrackInBatch, !sawAudioTrackInBatch, !didReportAudioAvailability {
            reportAudioAvailability(false)
        }
    }

    private func reportAudioAvailability(_ available: Bool) {
        didReportAudioAvailability = true
        audioStateLock.withLock { detectedAudioTrackState = available }
        if let callback = onAudioAvailabilityChanged {
            Task { @MainActor in
                callback(available)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session else { return }
        let reason: String? = {
            guard let error else { return failure ?? "stream ended" }
            if (error as NSError).code == NSURLErrorCancelled { return failure }
            return error.localizedDescription
        }()
        finish(failure: reason)
    }

    // MARK: - Decoding (queue)

    private func enqueue(_ sample: FMP4Sample, track: FMP4VideoTrack) {
        guard let units = Self.nalUnits(of: sample.data, lengthSize: track.nalLengthSize) else { return }
        let isKeyframe = sample.isKeyframe || VideoNALUnits.containsKeyframe(units, codec: track.codec)

        if let inBand = VideoNALUnits.parameterSets(in: units, codec: track.codec), inBand != activeParameterSets {
            installFormat(parameterSets: inBand, codec: track.codec)
        } else if formatDescription == nil, isKeyframe {
            installFormat(parameterSets: track.parameterSets, codec: track.codec)
        }

        if waitingForKeyframe {
            guard isKeyframe, formatDescription != nil else { return }
            waitingForKeyframe = false
        }
        guard let formatDescription else { return }
        if playbackPaused { return }

        if !renderer.isReadyForMoreMediaData {
            renderer.flush()
            waitingForKeyframe = true
            guard isKeyframe else { return }
            waitingForKeyframe = false
        }

        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            logger.error("camera renderer failed: \(String(describing: self.renderer.error), privacy: .public); waiting for next keyframe")
            renderer.flush()
            waitingForKeyframe = true
            guard isKeyframe else { return }
            waitingForKeyframe = false
        }

        // Parameter sets travel in the format description; the frame keeps only slice/SEI units.
        let payloadUnits = units.filter { !Self.isParameterSet($0, codec: track.codec) }
        guard !payloadUnits.isEmpty else { return }
        let scale = CMTimeScale(clamping: track.timescale == 0 ? 90_000 : track.timescale)
        let dts = CMTime(value: CMTimeValue(clamping: sample.decodeTime), timescale: scale)
        let mediaPTS = CMTimeAdd(dts, CMTime(value: CMTimeValue(sample.compositionOffset), timescale: scale))
        let mediaSeconds = CMTimeGetSeconds(mediaPTS)
        let hostNow = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        if renderSynchronizer != nil, mediaSeconds.isFinite, hostNow.isFinite {
            alignPlaybackClock(mediaSeconds: mediaSeconds, hostNowSeconds: hostNow)
        }
        guard let sampleBuffer = Self.makeSampleBuffer(
            units: payloadUnits,
            format: formatDescription,
            sample: sample,
            timescale: track.timescale,
            isKeyframe: isKeyframe,
            displayImmediately: renderSynchronizer == nil
        ) else { return }

        renderer.enqueue(sampleBuffer)
        framesDecoded += 1
        statsWindowFrames += 1
        recordDecodedFrameTimestamp()
        if framesDecoded == 1, let firstFrameCallback = onFirstFrame {
            Task { @MainActor in
                firstFrameCallback()
            }
        }
        let elapsed = Date().timeIntervalSince(statsWindowStart)
        if elapsed >= 5 {
            let fps = Double(statsWindowFrames) / elapsed
            logger.info("camera fMP4 \(String(format: "%.1f", fps), privacy: .public) fps over \(String(format: "%.1f", elapsed), privacy: .public)s (total \(self.framesDecoded))")
            statsWindowStart = Date()
            statsWindowFrames = 0
        }
    }

    private func alignPlaybackClock(mediaSeconds: Double, hostNowSeconds: Double) {
        guard let renderSynchronizer else { return }
        switch playbackClock.step(mediaSeconds: mediaSeconds, hostNowSeconds: hostNowSeconds) {
        case .start(let origin), .reanchor(let origin):
            let time = CMTime(seconds: origin, preferredTimescale: 90_000)
            renderSynchronizer.setRate(1, time: time)
        case .follow:
            break
        }
    }

    private func enqueueAudio(_ sample: FMP4AudioSample, track: FMP4AudioTrack) {
        let isMuted = audioStateLock.withLock { mutedState }
        guard !isMuted, !playbackPaused, let audioFormatDescription else { return }
        ensureAudioRendererIfNeeded()
        guard let audioRenderer else { return }
        if !audioRenderer.isReadyForMoreMediaData {
            return
        }
        if audioRenderer.status == .failed {
            audioRenderer.flush()
        }
        let scale = CMTimeScale(clamping: track.timescale == 0 ? 48_000 : track.timescale)
        let pts = CMTime(value: CMTimeValue(clamping: sample.decodeTime), timescale: scale)
        let mediaSeconds = CMTimeGetSeconds(pts)
        let hostNow = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        if self.track == nil, mediaSeconds.isFinite, hostNow.isFinite {
            alignPlaybackClock(mediaSeconds: mediaSeconds, hostNowSeconds: hostNow)
        }
        guard let buffer = Self.makeAudioSampleBuffer(
            sample: sample,
            format: audioFormatDescription,
            track: track
        ) else { return }
        audioRenderer.enqueue(buffer)
    }

    static func makeAudioFormatDescription(for track: FMP4AudioTrack) -> CMAudioFormatDescription? {
        let sampleRate = track.sampleRate > 0 ? track.sampleRate : 16_000
        let channels = UInt32(max(track.channelCount, 1))
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = sampleRate
        asbd.mChannelsPerFrame = channels
        var magicCookie = track.configRecord

        switch track.codec {
        case .aac:
            asbd.mFormatID = kAudioFormatMPEG4AAC
            asbd.mFormatFlags = 0
            asbd.mFramesPerPacket = 1024
        case .alaw:
            asbd.mFormatID = kAudioFormatALaw
            asbd.mBitsPerChannel = 8
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerFrame = channels
            asbd.mBytesPerPacket = channels
            magicCookie = Data()
        case .ulaw:
            asbd.mFormatID = kAudioFormatULaw
            asbd.mBitsPerChannel = 8
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerFrame = channels
            asbd.mBytesPerPacket = channels
            magicCookie = Data()
        case .opus:
            asbd.mFormatID = kAudioFormatOpus
            asbd.mSampleRate = track.sampleRate > 0 ? track.sampleRate : 48_000
            asbd.mFramesPerPacket = 960
            if magicCookie.count >= 10, magicCookie.prefix(8) != Data("OpusHead".utf8) {
                magicCookie = opusHeadCookie(fromDOps: magicCookie, channels: UInt8(clamping: channels))
            }
        case .flac:
            asbd.mFormatID = kAudioFormatFLAC
            asbd.mFramesPerPacket = 4096
        }

        var format: CMAudioFormatDescription?
        let status: OSStatus
        if magicCookie.isEmpty {
            status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &format
            )
        } else {
            status = magicCookie.withUnsafeBytes { rawBuf in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: magicCookie.count,
                    magicCookie: rawBuf.baseAddress,
                    extensions: nil,
                    formatDescriptionOut: &format
                )
            }
        }
        return status == noErr ? format : nil
    }

    private static func opusHeadCookie(fromDOps dops: Data, channels: UInt8) -> Data {
        var head = Data("OpusHead".utf8)
        let ch = dops.count >= 2 ? dops[1] : channels
        let preSkipLo: UInt8 = dops.count >= 4 ? dops[3] : 0
        let preSkipHi: UInt8 = dops.count >= 4 ? dops[2] : 0
        let rateB0: UInt8 = dops.count >= 8 ? dops[7] : 0x80
        let rateB1: UInt8 = dops.count >= 8 ? dops[6] : 0xBB
        let rateB2: UInt8 = dops.count >= 8 ? dops[5] : 0x00
        let rateB3: UInt8 = dops.count >= 8 ? dops[4] : 0x00
        let gainLo: UInt8 = dops.count >= 10 ? dops[9] : 0
        let gainHi: UInt8 = dops.count >= 10 ? dops[8] : 0
        let family: UInt8 = dops.count >= 11 ? dops[10] : 0
        head.append(contentsOf: [1, ch, preSkipLo, preSkipHi, rateB0, rateB1, rateB2, rateB3, gainLo, gainHi, family])
        return head
    }

    static func makeAudioSampleBuffer(
        sample: FMP4AudioSample,
        format: CMAudioFormatDescription,
        track: FMP4AudioTrack
    ) -> CMSampleBuffer? {
        guard !sample.data.isEmpty else { return nil }
        var block: CMBlockBuffer?
        let status = sample.data.withUnsafeBytes { rawBuf -> OSStatus in
            guard let base = rawBuf.baseAddress else { return -1 }
            var temp: CMBlockBuffer?
            let createStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: sample.data.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: sample.data.count,
                flags: 0,
                blockBufferOut: &temp
            )
            guard createStatus == kCMBlockBufferNoErr, let temp else { return createStatus }
            let replaceStatus = CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: temp,
                offsetIntoDestination: 0,
                dataLength: sample.data.count
            )
            guard replaceStatus == kCMBlockBufferNoErr else { return replaceStatus }
            block = temp
            return noErr
        }
        guard status == noErr, let block else { return nil }

        let timescale = CMTimeScale(clamping: track.timescale == 0 ? 48_000 : track.timescale)
        let pts = CMTime(value: CMTimeValue(clamping: sample.decodeTime), timescale: timescale)
        let numSamples: CMItemCount
        var sampleBuffer: CMSampleBuffer?
        switch track.codec {
        case .alaw, .ulaw:
            let bytesPerFrame = max(track.channelCount, 1)
            numSamples = CMItemCount(max(sample.data.count / bytesPerFrame, 1))
            let createStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: format,
                sampleCount: numSamples,
                presentationTimeStamp: pts,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer
            )
            return createStatus == noErr ? sampleBuffer : nil
        case .aac, .opus, .flac:
            var packetDesc = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(sample.data.count)
            )
            let createStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: format,
                sampleCount: 1,
                presentationTimeStamp: pts,
                packetDescriptions: &packetDesc,
                sampleBufferOut: &sampleBuffer
            )
            return createStatus == noErr ? sampleBuffer : nil
        }
    }

    private func installFormat(parameterSets: [Data], codec: FMP4VideoCodec) {
        guard let format = Self.makeFormatDescription(parameterSets: parameterSets, codec: codec) else {
            logger.error("camera format description rejected for \(codec.rawValue, privacy: .public)")
            return
        }
        let changed = formatDescription != nil
        formatDescription = format
        activeParameterSets = parameterSets
        if changed {
            // A resolution or profile switch must start again from a keyframe.
            renderer.flush()
            waitingForKeyframe = true
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        logger.info("camera format \(codec.rawValue, privacy: .public) \(dims.width)x\(dims.height)")
    }

    // MARK: - CoreMedia helpers

    private static func nalUnits(of data: Data, lengthSize: Int) -> [Data]? {
        if let units = VideoNALUnits.split(data, lengthSize: lengthSize) {
            return units
        }
        if let converted = VideoNALUnits.annexBToLengthPrefixed(data) {
            return VideoNALUnits.split(converted, lengthSize: 4)
        }
        return nil
    }

    static func isParameterSet(_ unit: Data, codec: FMP4VideoCodec) -> Bool {
        let type = VideoNALUnits.nalType(unit, codec: codec)
        switch codec {
        case .h264: return type == 7 || type == 8
        case .hevc: return (32...34).contains(type)
        }
    }

    static func makeFormatDescription(parameterSets: [Data], codec: FMP4VideoCodec) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }
        let copies: [UnsafeMutablePointer<UInt8>] = parameterSets.map { set in
            let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: ptr, count: set.count)
            return ptr
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = parameterSets.map(\.count)

        var format: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &format
            )
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &format
            )
        }
        return status == noErr ? format : nil
    }

    static func makeSampleBuffer(
        units: [Data],
        format: CMVideoFormatDescription,
        sample: FMP4Sample,
        timescale: UInt32,
        isKeyframe: Bool,
        displayImmediately: Bool = false
    ) -> CMSampleBuffer? {
        var payload = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            let len = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: len) { payload.append(contentsOf: $0) }
            payload.append(unit)
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copyStatus = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        let scale = CMTimeScale(clamping: timescale == 0 ? 90_000 : timescale)
        let dts = CMTime(value: CMTimeValue(clamping: sample.decodeTime), timescale: scale)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(sample.duration), timescale: scale),
            presentationTimeStamp: CMTimeAdd(dts, CMTime(value: CMTimeValue(sample.compositionOffset), timescale: scale)),
            decodeTimeStamp: dts
        )
        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        if displayImmediately || !isKeyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = Unmanaged<CFMutableDictionary>.fromOpaque(
                CFArrayGetValueAtIndex(attachments, 0)
            ).takeUnretainedValue()
            if displayImmediately {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
            if !isKeyframe {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        return sampleBuffer
    }
}

// MARK: - SwiftUI surface

/// Hosts the player's display layer; the layer outlives SwiftUI view re-creation.
struct CameraLiveVideoSurface: NSViewRepresentable {
    let player: CameraLiveVideoPlayer

    func makeNSView(context: Context) -> CameraLiveVideoHostView {
        let view = CameraLiveVideoHostView()
        view.attach(player.displayLayer)
        return view
    }

    func updateNSView(_ nsView: CameraLiveVideoHostView, context: Context) {
        nsView.attach(player.displayLayer)
    }

    static func dismantleNSView(_ nsView: CameraLiveVideoHostView, coordinator: ()) {
        nsView.detach()
    }
}

final class CameraLiveVideoHostView: NSView {
    private weak var videoLayer: CALayer?
    /// Set while Picture in Picture owns the layer. Resetting `frame` here would pin it to the
    /// hidden panel and paint a black rectangle over the system window.
    var suspendsGeometryUpdates = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ newLayer: CALayer) {
        guard videoLayer !== newLayer else { return }
        videoLayer?.removeFromSuperlayer()
        newLayer.removeFromSuperlayer()
        layer?.addSublayer(newLayer)
        videoLayer = newLayer
        needsLayout = true
    }

    func detach() {
        videoLayer?.removeFromSuperlayer()
        videoLayer = nil
    }

    /// Clicks fall through to the window drag area underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard !suspendsGeometryUpdates, let videoLayer, videoLayer.superlayer === layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Native Picture in Picture

private final class CameraPlaybackPause: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var restoreRequested = false

    func isPaused() -> Bool { lock.withLock { paused } }
    func setPaused(_ value: Bool) { lock.withLock { paused = value } }
    func setRestoreRequested(_ value: Bool) { lock.withLock { restoreRequested = value } }
    func isRestoreRequested() -> Bool { lock.withLock { restoreRequested } }
    func consumeRestoreRequested() -> Bool {
        lock.withLock {
            let value = restoreRequested
            restoreRequested = false
            return value
        }
    }
}

/// Moves the live display layer into the system Picture-in-Picture window (#97).
@MainActor
final class CameraPictureInPicture: NSObject {
    private let displayLayer: AVSampleBufferDisplayLayer
    private nonisolated let playbackPause = CameraPlaybackPause()
    private(set) var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private weak var observedPiPContentView: NSView?
    private var pipFrameObserver: NSObjectProtocol?
    private var pipSyncTask: Task<Void, Never>?
    private var wantsStart = false

    private(set) var isPossible = false
    private(set) var isActive = false

    /// Fires whenever `isPossible` or `isActive` changes.
    var onStateChange: (() -> Void)?
    /// The user pressed the PiP "back to app" button; show the floating window again.
    var onRestore: (() -> Void)?
    /// PiP ended without a restore request (the user closed it).
    var onClosed: (() -> Void)?
    var onPlaybackPaused: ((Bool) -> Void)?

    nonisolated static func livePlaybackTimeRange() -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init()
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.requiresLinearPlayback = true
        controller = pip
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            Task { @MainActor in
                guard let self else { return }
                let changed = self.isPossible != possible
                self.isPossible = possible
                if changed { self.onStateChange?() }
                if possible, self.wantsStart, let controller = self.controller, !controller.isPictureInPictureActive {
                    self.wantsStart = false
                    self.setHostSuspended(true)
                    controller.startPictureInPicture()
                }
            }
        }
    }

    func start() {
        wantsStart = true
        playbackPause.setRestoreRequested(false)
        guard let controller, controller.isPictureInPicturePossible, !controller.isPictureInPictureActive else { return }
        wantsStart = false
        setHostSuspended(true)
        controller.startPictureInPicture()
    }

    /// Programmatic stop means "bring the floating window back", never "close the camera".
    func stop() {
        guard controller?.isPictureInPictureActive == true else { return }
        wantsStart = false
        playbackPause.setRestoreRequested(true)
        controller?.stopPictureInPicture()
    }

    func invalidate() {
        wantsStart = false
        pipSyncTask?.cancel()
        pipSyncTask = nil
        stopObservingPiPWindow()
        setHostSuspended(false)
        possibleObservation?.invalidate()
        possibleObservation = nil
        if controller?.isPictureInPictureActive == true {
            let clearRestore = PictureInPictureCloseDecision.clearRestoreOnInvalidate(
                restoreAlreadyRequested: playbackPause.isRestoreRequested()
            )
            if clearRestore {
                playbackPause.setRestoreRequested(false)
            }
            controller?.stopPictureInPicture()
        }
        controller?.delegate = nil
        controller = nil
        if playbackPause.isPaused() {
            playbackPause.setPaused(false)
            onPlaybackPaused?(false)
        }
    }

    private func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        onStateChange?()
    }

    /// AVKit mirrors this display layer into PIPPanel through a `CALayerHost` and scales the video
    /// with its own `sublayerTransform`, assuming the mirrored container is the PiP window's size.
    /// So the display layer follows the PiP window, the host view stops pinning it back to the
    /// hidden panel, and AVKit's own content view is made to follow the window too. AVKit's layers
    /// and transforms are never changed: resetting them cropped the picture to one corner (#97).
    fileprivate func syncPictureInPictureLayerBounds() {
        guard isActive,
              let pipWindow = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("PIP") }),
              let contentView = pipWindow.contentView,
              contentView.bounds.width > 1,
              contentView.bounds.height > 1 else { return }

        if observedPiPContentView !== contentView {
            stopObservingPiPWindow()
            observedPiPContentView = contentView
            contentView.postsFrameChangedNotifications = true
            pipFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.syncPictureInPictureLayerBounds()
                }
            }
        }

        let target = contentView.bounds
        setHostSuspended(true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill(displayLayer, in: target)
        displayLayer.backgroundColor = nil
        CATransaction.commit()
        Self.trackWindowSize(in: contentView)
    }

    /// AVKit sizes its PiP content view once, at the starting window size, and leaves it there.
    /// Only the view's frame is changed; AVKit still lays out and scales everything inside it.
    static func trackWindowSize(in contentView: NSView) {
        for view in contentView.subviews
        where String(describing: type(of: view)).hasPrefix("AVPictureInPicture") {
            view.autoresizingMask = [.width, .height]
            if view.frame != contentView.bounds {
                view.frame = contentView.bounds
                view.needsLayout = true
            }
            keepParkedHostViewsOffscreen(in: view)
        }
    }

    /// AVKit parks an opaque black `AVPictureInPictureCALayerHostView` 10 pt past the top of the
    /// starting window and never moves it, so it slides into view once the window grows. Keep a
    /// parked one (origin above zero) just past the current top edge; one AVKit shows at zero is
    /// left alone.
    static func keepParkedHostViewsOffscreen(in root: NSView) {
        for view in root.subviews {
            if String(describing: type(of: view)) == "AVPictureInPictureCALayerHostView",
               view.frame.minY > 0 {
                let parkedY = root.bounds.height + 10
                if view.frame.minY != parkedY {
                    view.setFrameOrigin(NSPoint(x: view.frame.minX, y: parkedY))
                }
            }
            keepParkedHostViewsOffscreen(in: view)
        }
    }

    fileprivate func restoreHostLayerBounds() {
        pipSyncTask?.cancel()
        pipSyncTask = nil
        stopObservingPiPWindow()
        setHostSuspended(false)
        displayLayer.backgroundColor = NSColor.black.cgColor
        guard let superlayer = displayLayer.superlayer,
              superlayer.bounds.width > 1,
              superlayer.bounds.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.sublayerTransform = CATransform3DIdentity
        displayLayer.frame = superlayer.bounds
        CATransaction.commit()
    }

    private func setHostSuspended(_ suspended: Bool) {
        (displayLayer.superlayer?.delegate as? CameraLiveVideoHostView)?.suspendsGeometryUpdates = suspended
    }

    private func fill(_ layer: CALayer, in bounds: CGRect) {
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.bounds = bounds
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private nonisolated func onMain(_ work: @MainActor @escaping () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated(work)
            }
        }
    }

    private func stopObservingPiPWindow() {
        if let pipFrameObserver {
            NotificationCenter.default.removeObserver(pipFrameObserver)
            self.pipFrameObserver = nil
        }
        observedPiPContentView = nil
    }
}

extension CameraPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onMain { [weak self] in
            guard let self else { return }
            self.wantsStart = false
            self.setActive(true)
            self.syncPictureInPictureLayerBounds()
            self.pipSyncTask?.cancel()
            self.pipSyncTask = Task { @MainActor [weak self] in
                for delayMs in [60, 220, 500] {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    guard !Task.isCancelled, let self, self.isActive else { return }
                    self.syncPictureInPictureLayerBounds()
                }
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        onMain {
            self.wantsStart = false
            self.setActive(false)
            self.restoreHostLayerBounds()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        playbackPause.setRestoreRequested(true)
        onMain {
            self.onRestore?()
        }
        completionHandler(true)
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let restore = playbackPause.consumeRestoreRequested()
        onMain {
            if self.playbackPause.isPaused() {
                self.playbackPause.setPaused(false)
                self.onPlaybackPaused?(false)
            }
            self.setActive(false)
            self.restoreHostLayerBounds()
            if PictureInPictureCloseDecision.shouldClosePanel(restoreRequested: restore) {
                self.onClosed?()
            } else {
                self.onRestore?()
            }
        }
    }
}

extension CameraPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        let paused = !playing
        playbackPause.setPaused(paused)
        onMain {
            self.onPlaybackPaused?(paused)
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        Self.livePlaybackTimeRange()
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        playbackPause.isPaused()
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        Task { @MainActor [weak self] in
            self?.syncPictureInPictureLayerBounds()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

// MARK: - Window dragging

/// Lets a borderless panel be dragged from SwiftUI regions. `NSHostingView` swallows mouse-down,
/// so `isMovableByWindowBackground` alone never moves the camera window.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> WindowDragView {
        let view = WindowDragView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: WindowDragView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

final class WindowDragView: NSView {
    var onDoubleClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
            return
        }
        window?.performDrag(with: event)
    }
}
