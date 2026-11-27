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
            actions: [
                action(1, "up"), action(2, "down"), action(3, "ok"), action(4, "back"), action(5, "home"),
                action(6, "left", inputs: [9]), action(7, "press-volume-up"), action(8, "press-volume-down"),
                action(9, "press-settings"), action(10, "press-menu"),
            ]
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
        #expect(built.miotRemoteActions["volumeUp"] == "miot-action:tv9:5:7")
        #expect(built.miotRemoteActions["volumeDown"] == "miot-action:tv9:5:8")
        #expect(built.miotRemoteActions["menu"] == "miot-action:tv9:5:10", "press-menu wins over press-settings")

        let select = try #require(built.miotRemoteActions["select"])
        #expect(try MiotCommandMapper.map(.remoteSendKey(entityId: select, key: .select), spec: spec)
            == .action(.init(did: "tv9", siid: 5, aiid: 3)))
        #expect(try MiotCommandMapper.map(.remoteSendKey(entityId: "miot-action:tv9:5:7", key: .volumeUp), spec: spec)
            == .action(.init(did: "tv9", siid: 5, aiid: 7)))
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

    @Test("HA TV mute routes #mute to volume_mute and never calls turn_on/off")
    @MainActor
    func haTVMuteUsesVolumeMuteNeverPower() async throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [HAAreaEntry(area_id: "living", name: "客厅")],
            devices: [HADeviceEntry(id: "tv-mute", area_id: "living", name: "客厅电视", model: "tv"), HADeviceEntry(id: "tv-nomute", area_id: "living", name: "卧室电视", model: "tv")],
            entities: [HAEntityEntry(entity_id: "media_player.living_tv", device_id: "tv-mute"), HAEntityEntry(entity_id: "media_player.plain_tv", device_id: "tv-nomute")],
            states: [
                "media_player.living_tv": HAEntityState(entityId: "media_player.living_tv", state: "on", attributes: ["device_class": .string("tv"), "is_volume_muted": .bool(true), "supported_features": .number(8)]),
                "media_player.plain_tv": HAEntityState(entityId: "media_player.plain_tv", state: "on", attributes: ["device_class": .string("tv"), "supported_features": .number(0)]),
            ]
        )
        let byId = Dictionary(uniqueKeysWithValues: home.devices.map { ($0.id, $0) })
        guard case .tv(let tvMute) = try #require(byId["tv-mute"]).kind,
              case .tv(let tvNoMute) = try #require(byId["tv-nomute"]).kind else { Issue.record("expected two TVs"); return }
        #expect(tvMute.isMuted && tvMute.muteSwitchEntityId == "media_player.living_tv#mute" && tvNoMute.muteSwitchEntityId == nil)
        let call = HAWebSocketProvider.mapCommandToService(.setSwitch(entityId: "media_player.living_tv#mute", isOn: false))
        #expect(call.domain == "media_player" && call.service == "volume_mute" && call.payload["entity_id"] as? String == "media_player.living_tv" && call.payload["is_volume_muted"] as? Bool == false)
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.hatvmute.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.blockControlWhileLocked = false
        store.toggleTVMute("tv-nomute")
        store.toggleTVMute("tv-mute")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await mock.executedCommands.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await mock.executedCommands == [.setSwitch(entityId: "media_player.living_tv#mute", isOn: false)])
    }

    @Test("HA TV primary tap & external power send media_player switch; non-power TV only expands drawer")
    @MainActor
    func haTVPrimaryToggleAndExternalPower() async throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [HAAreaEntry(area_id: "living", name: "客厅")],
            devices: [HADeviceEntry(id: "tv-pwr", area_id: "living", name: "客厅电视", model: "tv"), HADeviceEntry(id: "tv-nopwr", area_id: "living", name: "副屏电视", model: "tv")],
            entities: [HAEntityEntry(entity_id: "media_player.pwr_tv", device_id: "tv-pwr"), HAEntityEntry(entity_id: "media_player.nopwr_tv", device_id: "tv-nopwr")],
            states: [
                "media_player.pwr_tv": HAEntityState(entityId: "media_player.pwr_tv", state: "on", attributes: ["device_class": .string("tv"), "supported_features": .number(Double(128 | 256))]),
                "media_player.nopwr_tv": HAEntityState(entityId: "media_player.nopwr_tv", state: "on", attributes: ["device_class": .string("tv"), "media_title": .string("News"), "supported_features": .number(0)]),
            ]
        )
        let byId = Dictionary(uniqueKeysWithValues: home.devices.map { ($0.id, $0) })
        let pwrDev = try #require(byId["tv-pwr"]), noPwrDev = try #require(byId["tv-nopwr"])
        #expect(pwrDev.isPrimaryToggleable && !noPwrDev.isPrimaryToggleable)
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.hatvpwr.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.blockControlWhileLocked = false
        #expect(store.togglePrimary(noPwrDev) == nil && store.expandedDeviceId == "tv-nopwr")
        let offTask = try #require(store.togglePrimary(pwrDev))
        #expect(await offTask.value)
        let raycast = await store.executeRaycastPower(deviceId: "tv-pwr", isOn: true)
        #expect(raycast.handled && !raycast.isError)
        #expect(await mock.executedCommands == [.setSwitch(entityId: "media_player.pwr_tv", isOn: false), .setSwitch(entityId: "media_player.pwr_tv", isOn: true)])
    }

    @Test("HA remote.send_command adapts key names per ecosystem (golden parity)")
    func haRemoteProfilesMatchGoldenFixture() throws {
        struct Golden: Decodable {
            struct Case: Decodable { let name: String; let platform, manufacturer, model, entityId, friendlyName: String?; let identifiers: [[String]]?; let expectedProfile: HARemoteProfile }
            let inferenceCases: [Case]; let commandTable: [String: [String: String]]
        }
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: GoldenCorpusTests.locateGoldenFixture("Tests/Fixtures/ha_remote_commands_golden.json")))
        for c in golden.inferenceCases {
            #expect(HARemoteProfile.infer(platform: c.platform, manufacturer: c.manufacturer, model: c.model, identifiers: c.identifiers, entityId: c.entityId, friendlyName: c.friendlyName) == c.expectedProfile, "\(c.name)")
        }
        for (rawProfile, commands) in golden.commandTable {
            let profile = try #require(HARemoteProfile(rawValue: rawProfile))
            for (rawKey, expected) in commands {
                let key = try #require(TVRemoteKey(rawValue: rawKey))
                #expect(key.homeAssistantCommand(for: profile) == expected)
                #expect(HAWebSocketProvider.mapCommandToService(.remoteSendKey(entityId: "remote.tv", key: key), remoteProfile: profile).payload["command"] as? String == expected)
            }
        }
        var snap = HAHomeSnapshot()
        _ = try snap.receive(["type": .string("result"), "id": .number(2), "success": .bool(true), "result": .array([.object(["id": .string("dev-atv"), "manufacturer": .string("Apple"), "model": .string("Apple TV 4K")])])])
        _ = try snap.receive(["type": .string("result"), "id": .number(3), "success": .bool(true), "result": .array([.object(["entity_id": .string("remote.living"), "device_id": .string("dev-atv"), "platform": .string("apple_tv")])])])
        #expect(snap.remoteProfile(for: "remote.living") == .appleTV)
    }

    @Test("HA SpeakerSpec gains Now Playing parity and transport/seek routing (#564)")
    @MainActor
    func speakerNowPlayingParity() async throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [HAAreaEntry(area_id: "study", name: "书房")],
            devices: [HADeviceEntry(id: "sp1", area_id: "study", name: "Sonos 书房", model: "Sonos Era 100")],
            entities: [HAEntityEntry(entity_id: "media_player.sonos_study", device_id: "sp1")],
            states: ["media_player.sonos_study": HAEntityState(entityId: "media_player.sonos_study", state: "playing", attributes: ["media_title": .string("Kind of Blue"), "media_artist": .string("Miles Davis"), "media_duration": .number(300), "media_position": .number(45), "supported_features": .number(Double(1 | 2 | 8 | 16 | 32 | 16384))])]
        )
        guard case .speaker(let sp) = try #require(home.devices.first(where: { $0.id == "sp1" })).kind else { Issue.record("expected speaker"); return }
        #expect(sp.playback?.title == "Kind of Blue" && sp.playback?.progressStyle == .seekable && sp.muteSwitchEntityId == "media_player.sonos_study#mute")

        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.speaker.np.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.blockControlWhileLocked = false
        store.sendMediaTransport("sp1", .playPause)
        store.seekMedia("sp1", toSeconds: 90)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await mock.executedCommands.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let executed = await mock.executedCommands
        #expect(Set(executed.map { "\($0)" }) == Set([DeviceCommand.mediaPlayPause(entityId: "media_player.sonos_study"), DeviceCommand.mediaSeek(entityId: "media_player.sonos_study", positionSec: 90)].map { "\($0)" }))
    }
}
