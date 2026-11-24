import Foundation
import Testing
@testable import MijiaCore

struct XiaomiCameraStreamQualityTests {
    @Test("Bridge query uses the requested Xiaomi subtype instead of forcing SD (~480p)")
    func xiaomiStreamQueryHonorsRequestedQuality() {
        let ultra = XiaomiCameraBridge.xiaomiStreamQuery(
            clientPublic: "aa",
            clientPrivate: "bb",
            devicePublic: "cc",
            sign: "dd",
            vendor: "cs2",
            model: "chuangmi.camera.81ac1",
            quality: .max,
            uid: "TICK",
            channel: 0,
            subdid: nil
        )
        #expect(ultra.contains("subtype=3"))
        #expect(!ultra.contains("subtype=sd"))
        #expect(ultra.contains("uid=TICK"))

        let high = XiaomiCameraBridge.xiaomiStreamQuery(
            clientPublic: "aa",
            clientPrivate: "bb",
            devicePublic: "cc",
            sign: "dd",
            vendor: "cs2",
            model: "chuangmi.camera.81ac1",
            quality: .hd,
            uid: nil,
            channel: 0,
            subdid: nil
        )
        #expect(high.contains("subtype=hd"))
        #expect(!high.contains("subtype=sd"))

        let smooth = XiaomiCameraBridge.xiaomiStreamQuery(
            clientPublic: "aa",
            clientPrivate: "bb",
            devicePublic: "cc",
            sign: "dd",
            vendor: "cs2",
            model: "chuangmi.camera.81ac1",
            quality: .sd,
            uid: nil,
            channel: 0,
            subdid: nil
        )
        #expect(smooth.contains("subtype=sd"))
        #expect(XiaomiCameraStreamQuality.storageDefault == .sd)
    }

    @Test("Bridge query adds a channel only for a second lens")
    func xiaomiStreamQueryAddsSecondLensChannel() {
        let main = XiaomiCameraBridge.xiaomiStreamQuery(
            clientPublic: "aa",
            clientPrivate: "bb",
            devicePublic: "cc",
            sign: "dd",
            vendor: "cs2",
            model: "isa.camera.500dh",
            quality: .hd,
            uid: nil,
            channel: 0,
            subdid: nil
        )
        #expect(!main.contains("channel="))

        let second = XiaomiCameraBridge.xiaomiStreamQuery(
            clientPublic: "aa",
            clientPrivate: "bb",
            devicePublic: "cc",
            sign: "dd",
            vendor: "cs2",
            model: "isa.camera.500dh",
            quality: .hd,
            uid: nil,
            channel: 1,
            subdid: nil
        )
        #expect(second.contains("channel=1"))
    }

    @Test("Stopping a camera removes streams from every lens channel")
    func bridgeStreamNamesCoverEveryLensChannel() {
        let names = XiaomiCameraBridge.allStreamNames(cleanDid: "camera123")
        #expect(names.contains("cam_raw_camera123"))
        #expect(names.contains("cam_raw_camera123_c1"))
        #expect(names.contains("cam_mjpeg_camera123_c1"))
        #expect(names.contains("cam_h264_camera123_c2"))
        #expect(XiaomiCameraBridge.rawStreamName(cleanDid: "camera123", channel: 0) == "cam_raw_camera123")
        #expect(XiaomiCameraBridge.rawStreamName(cleanDid: "camera123", channel: 1) == "cam_raw_camera123_c1")
    }

    @Test("Bridge query carries the hub subdid and the stream name stays unique")
    func bridgeQueryCarriesHubSubdid() {
        let query = XiaomiCameraBridge.xiaomiStreamQuery(
            clientPublic: "aa",
            clientPrivate: "bb",
            devicePublic: "cc",
            sign: "dd",
            vendor: "cs2",
            model: "mxiang.camera.mwc10",
            quality: .hd,
            uid: nil,
            channel: 0,
            subdid: "camera-123"
        )
        #expect(query.contains("subdid=camera-123"))

        let streamKey = XiaomiCameraBridge.streamKey(cleanDid: "hub123", subdid: "camera-123")
        #expect(streamKey == "hub123_sub_camera123")
    }

    @Test("go2rtc and Xiaomi stream URL builders set audio=0 when muted and request audio only for listen-only")
    func go2rtcAndXiaomiURLBuildersHonorAudioFlag() throws {
        let mutedXiaomi = XiaomiCameraBridge.xiaomiStreamQuery(
            clientPublic: "aa",
            clientPrivate: "bb",
            devicePublic: "cc",
            sign: "dd",
            vendor: "cs2",
            model: "isa.camera.hlc7",
            quality: .hd,
            uid: nil,
            channel: 0,
            subdid: nil
        )
        #expect(mutedXiaomi.contains("audio=0"))
        #expect(!mutedXiaomi.contains("audio=1"))

        let listenOnlyXiaomi = XiaomiCameraBridge.xiaomiStreamQuery(
            clientPublic: "aa",
            clientPrivate: "bb",
            devicePublic: "cc",
            sign: "dd",
            vendor: "cs2",
            model: "isa.camera.hlc7",
            quality: .hd,
            uid: nil,
            channel: 0,
            subdid: nil,
            audioEnabled: true
        )
        #expect(listenOnlyXiaomi.contains("audio=1"))
        #expect(!listenOnlyXiaomi.contains("audio=0"))

        let base = try #require(URL(string: "http://127.0.0.1:43123"))
        let mutedMP4 = try #require(XiaomiCameraBridge.go2rtcStreamURL(
            baseURL: base,
            path: "/api/stream.mp4",
            streamName: "cam_raw_1",
            audioEnabled: false
        ))
        #expect(mutedMP4.absoluteString == "http://127.0.0.1:43123/api/stream.mp4?src=cam_raw_1&mp4&audio=0")
        #expect(XiaomiCameraBridge.isMutedPreviewURL(mutedMP4))

        let listenOnlyMP4 = try #require(XiaomiCameraBridge.go2rtcStreamURL(
            baseURL: base,
            path: "/api/stream.mp4",
            streamName: "cam_raw_1",
            audioEnabled: true
        ))
        #expect(listenOnlyMP4.absoluteString == "http://127.0.0.1:43123/api/stream.mp4?src=cam_raw_1&mp4=all")
        #expect(!XiaomiCameraBridge.isMutedPreviewURL(listenOnlyMP4))

        let mutedHLS = try #require(XiaomiCameraBridge.go2rtcStreamURL(
            baseURL: base,
            path: "/api/stream.m3u8",
            streamName: "cam_raw_1",
            audioEnabled: false
        ))
        #expect(mutedHLS.absoluteString == "http://127.0.0.1:43123/api/stream.m3u8?src=cam_raw_1&video=all&audio=0")
        #expect(XiaomiCameraBridge.isMutedPreviewURL(mutedHLS))

        let listenOnlyHLS = try #require(XiaomiCameraBridge.go2rtcStreamURL(
            baseURL: base,
            path: "/api/stream.m3u8",
            streamName: "cam_raw_1",
            audioEnabled: true
        ))
        #expect(listenOnlyHLS.absoluteString == "http://127.0.0.1:43123/api/stream.m3u8?src=cam_raw_1")
        #expect(!XiaomiCameraBridge.isMutedPreviewURL(listenOnlyHLS))
    }

    @MainActor
    @Test("HomeStore saves the chosen camera quality and passes it when resolving the stream")
    func homeStorePassesSavedQuality() async throws {
        let suite = "camera-quality-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let mock = MockHomeProvider(snapshot: DemoHomeProvider.defaultHome())
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        let camera = try #require(store.devices.first(where: { if case .camera = $0.kind { return true }; return false }))
        #expect(store.cameraStreamQuality(for: camera.id) == .sd)
        store.setCameraStreamQuality(.max, for: camera.id)
        let reloaded = HomeStore(provider: mock, defaultsSuiteName: suite)
        try await reloaded.waitForTestSnapshot()
        #expect(reloaded.cameraStreamQuality(for: camera.id) == .max)
        _ = try await reloaded.resolveCameraStream(for: camera.id)
        #expect(await mock.requestedCameraQualities == [.max])
    }
}
