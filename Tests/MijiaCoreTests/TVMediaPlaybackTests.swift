import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

struct TVMediaPlaybackTests {
    private static let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    private static func parse(_ state: String, _ attributes: [String: JSONValue]) -> MediaPlaybackState? {
        MediaPlaybackState.fromHomeAssistant(state: state, attributes: attributes, parseDate: HAHomeSnapshot.parseLastChanged)
    }

    @Test("HA media_player attributes become Now Playing with supported_features bits")
    func parsesNowPlaying() throws {
        let playback = try #require(Self.parse("playing", [
            "media_title": .string("沙丘 2"),
            "media_series_title": .string("Dune"),
            "app_name": .string("Netflix"),
            "entity_picture": .string("/api/media_player_proxy/media_player.tv?token=abc&cache=1"),
            "media_duration": .number(9960),
            "media_position": .number(120.5),
            "media_position_updated_at": .string("2027-01-15T08:00:00.000000+00:00"),
            "supported_features": .number(Double(1 | 2 | 16 | 32 | 16384)),
        ]))
        #expect(playback.state == .playing)
        #expect(playback.title == "沙丘 2")
        #expect(playback.subtitle == "Dune")
        #expect(playback.appName == "Netflix")
        #expect(playback.artworkURL?.hasPrefix("/api/media_player_proxy/") == true)
        #expect(playback.durationSec == 9960)
        #expect(playback.positionSec == 120.5)
        #expect(playback.positionUpdatedAt != nil)
        #expect(playback.playbackRate == 1.0)
        #expect(playback.canPlayPause && playback.canSeek && playback.canSkipTrack)
        #expect(playback.progressStyle == .seekable)

        let readOnly = try #require(Self.parse("paused", [
            "media_title": .string("Song"), "media_artist": .string("Artist"),
            "media_duration": .number(200), "media_position": .number(10),
            "supported_features": .number(16384),
        ]))
        #expect(readOnly.playbackRate == 0)
        #expect(readOnly.canPlayPause && !readOnly.canSeek && !readOnly.canSkipTrack)
        #expect(readOnly.progressStyle == .readOnly)

        let appOnly = try #require(Self.parse("idle", ["app_name": .string("YouTube")]))
        #expect(appOnly.progressStyle == .hidden)

        #expect(Self.parse("on", ["supported_features": .number(0)]) == nil)
        #expect(Self.parse("off", ["media_title": .string("Stale")]) == nil)
    }

    @Test("Progress extrapolates only while playing and stays inside the duration")
    func extrapolatesPosition() {
        let playing = MediaPlaybackState(state: .playing, durationSec: 100, positionSec: 40, positionUpdatedAt: Self.anchor)
        #expect(playing.extrapolatedPosition(at: Self.anchor.addingTimeInterval(5)) == 45)
        #expect(playing.extrapolatedPosition(at: Self.anchor.addingTimeInterval(500)) == 100)
        #expect(playing.extrapolatedPosition(at: Self.anchor.addingTimeInterval(-5)) == 40)

        let paused = MediaPlaybackState(state: .paused, durationSec: 100, positionSec: 40, positionUpdatedAt: Self.anchor)
        #expect(paused.extrapolatedPosition(at: Self.anchor.addingTimeInterval(30)) == 40)
        #expect(MediaPlaybackState(state: .playing).extrapolatedPosition(at: Self.anchor) == nil)
    }

    @Test("Dragging previews locally, releases one seek, and holds 2 s against snap-back")
    func seekGuardStateMachine() {
        var seek = MediaSeekGuard()
        #expect(seek.displayedPosition(remote: 10, at: Self.anchor) == 10)
        #expect(seek.endDrag(now: Self.anchor) == nil)

        seek.beginDrag(at: 30)
        seek.updateDrag(to: 55)
        #expect(seek.displayedPosition(remote: 12, at: Self.anchor) == 55)

        #expect(seek.endDrag(now: Self.anchor) == 55)
        #expect(seek.endDrag(now: Self.anchor) == nil, "One release sends exactly one seek")
        #expect(seek.displayedPosition(remote: 12, at: Self.anchor.addingTimeInterval(1.9)) == 55)
        #expect(seek.displayedPosition(remote: 56, at: Self.anchor.addingTimeInterval(2.0)) == 56)
    }

    @Test("HA TV claims its remote.* entity and keeps an idle TV without Now Playing")
    func synthesizesHATVWithRemote() throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [HAAreaEntry(area_id: "living", name: "客厅")],
            devices: [
                HADeviceEntry(id: "tv", area_id: "living", name: "客厅电视", model: "sony.tv.x90"),
                HADeviceEntry(id: "tv-plain", area_id: "living", name: "卧室电视", model: "sony.tv.x80"),
            ],
            entities: [
                HAEntityEntry(entity_id: "media_player.living_tv", device_id: "tv"),
                HAEntityEntry(entity_id: "remote.living_tv", device_id: "tv"),
                HAEntityEntry(entity_id: "media_player.bedroom_tv", device_id: "tv-plain"),
            ],
            states: [
                "media_player.living_tv": HAEntityState(entityId: "media_player.living_tv", state: "playing", attributes: [
                    "device_class": .string("tv"), "media_title": .string("News"), "supported_features": .number(1),
                ]),
                "remote.living_tv": HAEntityState(entityId: "remote.living_tv", state: "on"),
                "media_player.bedroom_tv": HAEntityState(entityId: "media_player.bedroom_tv", state: "on", attributes: [
                    "device_class": .string("tv"), "supported_features": .number(0),
                ]),
            ]
        )
        let byId = Dictionary(uniqueKeysWithValues: home.devices.map { ($0.id, $0) })
        guard case .tv(let tv) = try #require(byId["tv"]).kind,
              case .tv(let plain) = try #require(byId["tv-plain"]).kind else {
            Issue.record("expected two TVs"); return
        }
        #expect(tv.remoteEntityId == "remote.living_tv")
        #expect(tv.supportsRemotePad)
        #expect(tv.playback?.title == "News")
        #expect(byId["tv"]?.referencedEntityIds.contains("remote.living_tv") == true)
        #expect(!home.devices.contains { $0.id != "tv" && $0.referencedEntityIds.contains("remote.living_tv") })

        #expect(plain.playback == nil)
        #expect(plain.remoteEntityId == nil)
        #expect(!plain.supportsRemotePad)
    }

    @Test("Artwork cache key is a digest that never carries the entity token")
    func artworkCacheKeyIsRedacted() {
        let path = "/api/media_player_proxy/media_player.tv?token=secret-entity-token&cache=1"
        let key = MediaArtworkLoader.cacheKey(artworkPath: path, serverBaseURL: "http://ha.local:8123")
        #expect(key.count == 64)
        #expect(!key.contains("secret-entity-token") && !key.contains("token"))
        #expect(key == MediaArtworkLoader.cacheKey(artworkPath: path, serverBaseURL: "http://ha.local:8123/"))
        #expect(key != MediaArtworkLoader.cacheKey(artworkPath: path + "2", serverBaseURL: "http://ha.local:8123"))
    }

    @Test("HA service mapping for transport, seek and remote keys")
    func mapsHomeAssistantServices() {
        let seek = HAWebSocketProvider.mapCommandToService(.mediaSeek(entityId: "media_player.tv", positionSec: 61.5))
        #expect(seek.domain == "media_player" && seek.service == "media_seek")
        #expect(seek.payload["seek_position"] as? Double == 61.5)
        #expect(HAWebSocketProvider.mapCommandToService(.mediaPlayPause(entityId: "media_player.tv")).service == "media_play_pause")
        #expect(HAWebSocketProvider.mapCommandToService(.mediaNextTrack(entityId: "media_player.tv")).service == "media_next_track")
        #expect(HAWebSocketProvider.mapCommandToService(.mediaPreviousTrack(entityId: "media_player.tv")).service == "media_previous_track")
        let key = HAWebSocketProvider.mapCommandToService(.remoteSendKey(entityId: "remote.tv", key: .select))
        #expect(key.domain == "remote" && key.service == "send_command")
        #expect(key.payload["command"] as? String == "ENTER")
    }

    @Test("Xiaomi TV remote-control actions become the pad and map only to matching keys")
    func miotRemoteControl() throws {
        func action(_ iid: Int, _ name: String, inputs: [Int] = []) -> MiotAction {
            MiotAction(iid: iid, type: "urn:miot-spec-v2:action:\(name):00002800:xiaomi-tv:1", inputProperties: inputs)
        }
        let tv = MiotService(
            iid: 2, type: "urn:miot-spec-v2:service:television:00007817:xiaomi-tv:1",
            properties: [MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:xiaomi-tv:1", format: "bool", access: ["read", "write"])]
        )
        let remote = MiotService(
            iid: 5, type: "urn:miot-spec-v2:service:remote-control:00007880:xiaomi-tv:1",
            actions: [action(1, "up"), action(2, "down"), action(3, "ok"), action(4, "back"), action(5, "home"), action(6, "left", inputs: [9])]
        )
        let spec = MiotDeviceSpec(type: "urn:miot-spec-v2:device:television:0000A010:xiaomi-tv:1", services: [tv, remote])
        let device = MiDeviceRecord(did: "tv9", name: "小米电视", model: "xiaomi.tv.v1", isOnline: true)
        let home = MiotSynthesizer.synthesize(devices: [device], rooms: [], specs: [device.model: spec], values: [:])
        guard case .tv(let built) = try #require(home.devices.first).kind else {
            Issue.record("expected TV"); return
        }
        #expect(built.supportsRemotePad)
        #expect(built.miotRemoteActions["up"] == "miot-action:tv9:5:1")
        #expect(built.miotRemoteActions["select"] == "miot-action:tv9:5:3")
        #expect(built.miotRemoteActions["left"] == nil, "Actions with inputs are not pad keys")

        let select = try #require(built.miotRemoteActions["select"])
        #expect(try MiotCommandMapper.map(.remoteSendKey(entityId: select, key: .select), spec: spec)
            == .action(.init(did: "tv9", siid: 5, aiid: 3)))
        #expect(throws: MiotCommandError.self) {
            try MiotCommandMapper.map(.remoteSendKey(entityId: select, key: .home), spec: spec)
        }
        #expect(throws: MiotCommandError.self) {
            try MiotCommandMapper.map(.mediaSeek(entityId: built.mediaEntityId, positionSec: 5), spec: spec)
        }
    }

    @Test("Pad, transport and seek writes go through the store gates; the screen lock blocks them")
    @MainActor
    func storeRoutesThroughGates() async throws {
        let tv = SmartDevice(
            id: "tv", name: "客厅电视", roomId: "living", roomName: "客厅", model: "sony.tv", isOnline: true,
            kind: .tv(TVSpec(
                mediaEntityId: "media_player.tv", state: "playing", volumePercent: 20,
                playback: MediaPlaybackState(state: .playing, title: "News", durationSec: 600, positionSec: 10,
                                             canPlayPause: true, canSeek: true, canSkipTrack: true),
                remoteEntityId: "remote.tv", supportsRemotePad: true
            ))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [tv], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.tvmedia.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()

        store.setScreenLocked(true)
        store.sendTVRemoteKey("tv", key: .up)
        store.seekMedia("tv", toSeconds: 30)
        store.sendMediaTransport("tv", .playPause)
        store.setScreenLocked(false)
        store.blockControlWhileLocked = false

        store.sendTVRemoteKey("tv", key: .up)
        store.seekMedia("tv", toSeconds: 9_999)
        store.sendMediaTransport("tv", .next)
        let expected: [DeviceCommand] = [
            .remoteSendKey(entityId: "remote.tv", key: .up),
            .mediaSeek(entityId: "media_player.tv", positionSec: 600),
            .mediaNextTrack(entityId: "media_player.tv"),
        ]
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await mock.executedCommands.count < expected.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let executed = await mock.executedCommands
        #expect(Set(executed.map { "\($0)" }) == Set(expected.map { "\($0)" }))
        #expect(executed.count == expected.count, "Locked presses never reach the provider")
    }
}
