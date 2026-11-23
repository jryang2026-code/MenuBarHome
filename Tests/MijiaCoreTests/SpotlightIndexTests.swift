import Foundation
import Testing
@testable import MijiaCore

/// The Spotlight plan is a pure mapping, so these tests pin exactly what an upgrade writes into the
/// system index — including everything that must *not* be there (#575).
struct SpotlightIndexTests {
    private static let lamp = SmartDevice(
        id: "ha:light.living_ceiling", name: "客厅顶灯", roomId: "living", roomName: "客厅",
        model: "test.light", isOnline: true,
        kind: .light(LightSpec(entityId: "light.living_ceiling", isOn: true, brightnessPercent: 40))
    )
    private static let plug = SmartDevice(
        id: "did_1234567890", name: "书房插座", roomId: "study", roomName: "书房",
        model: "cuco.plug.v3", isOnline: true,
        kind: .plug(PlugSpec(switchEntityId: "switch.study_plug", isOn: false))
    )
    private static let rooms = [
        RoomArea(id: "living", name: "客厅", sortOrder: 1),
        RoomArea(id: "study", name: "书房", sortOrder: 2),
    ]
    private static let scenes = [HomeScene(id: "sc_movie", name: "电影模式", entityId: "scene.movie")]

    private static func entries(
        devices: [SmartDevice] = [lamp, plug],
        rooms: [RoomArea] = rooms,
        scenes: [HomeScene] = scenes,
        hiddenIds: Set<String> = [],
        backend: @escaping (String) -> HomeBackend = { $0.hasPrefix("ha:") ? .homeAssistant : .xiaomiCloud }
    ) -> [SpotlightIndexEntry] {
        SpotlightIndexPlan.entries(
            devices: devices,
            rooms: rooms,
            scenes: scenes,
            hiddenIds: hiddenIds,
            homeDomain: SpotlightIndexPlan.domain(for: .homeAssistant),
            backend: backend
        )
    }

    @Test("Devices, rooms and scenes are indexed once each with the display title and room")
    func mapsEveryEntity() throws {
        let entries = Self.entries()
        #expect(entries.count == 5)

        let lamp = try #require(entries.first { $0.kind == .device && $0.entityId == Self.lamp.id })
        #expect(lamp.title == "客厅顶灯")
        #expect(lamp.roomName == "客厅")

        let room = try #require(entries.first { $0.kind == .room && $0.entityId == "study" })
        #expect(room.title == "书房")
        #expect(room.roomName.isEmpty)

        let scene = try #require(entries.first { $0.kind == .scene })
        #expect(scene.title == "电影模式")
    }

    @Test("A hidden device stays out of the index")
    func hiddenDevicesAreNotIndexed() {
        let entries = Self.entries(hiddenIds: [Self.plug.id])
        #expect(!entries.contains { $0.entityId == Self.plug.id })
        #expect(entries.contains { $0.entityId == Self.lamp.id })
    }

    @Test("One domain per source, so turning a connection off can delete only its items")
    func domainFollowsTheServingBackend() throws {
        let entries = Self.entries()
        let lamp = try #require(entries.first { $0.entityId == Self.lamp.id })
        let plug = try #require(entries.first { $0.entityId == Self.plug.id })
        #expect(lamp.domainIdentifier == "menubarmijia.homeAssistant")
        #expect(plug.domainIdentifier == "menubarmijia.xiaomiCloud")
        // Rooms and scenes are not per-device, so they inherit the active home's domain.
        #expect(entries.filter { $0.kind != .device }.allSatisfy {
            $0.domainIdentifier == "menubarmijia.homeAssistant"
        })
    }

    @Test("Titles, rooms and keywords never contain an id, host, token or address")
    func neverExposesIdentifiers() {
        // Every free-text field the system could show or store, checked against the identifiers a
        // Xiaomi DID, a Home Assistant entity id or a token would put there.
        let forbidden = [
            Self.lamp.id, Self.plug.id,
            "light.living_ceiling", "switch.study_plug", "1234567890",
            "192.168.", "http://", "https://", "token", "Bearer", "ssecret",
        ]
        for entry in Self.entries() {
            let visible = ([entry.title, entry.roomName] + entry.keywords).joined(separator: " | ")
            for needle in forbidden {
                #expect(!visible.localizedCaseInsensitiveContains(needle), "\(entry.kind) leaked \(needle)")
            }
        }
    }

    @Test("Keywords carry the pinyin and initials the panel search already understands")
    func keywordsIncludePinyin() throws {
        let lamp = try #require(Self.entries().first { $0.entityId == Self.lamp.id })
        #expect(lamp.keywords.contains("客厅顶灯"))
        #expect(lamp.keywords.contains("ketingdingdeng"))
        #expect(lamp.keywords.contains("ktdd"))
        #expect(lamp.keywords.contains("客厅"))
    }

    @Test("A device result navigates; a scene result runs through the existing scene route")
    func routesUseTheURLContract() throws {
        let entries = Self.entries()
        let lamp = try #require(entries.first { $0.entityId == Self.lamp.id })
        let room = try #require(entries.first { $0.kind == .room && $0.entityId == "study" })
        let scene = try #require(entries.first { $0.kind == .scene })

        let lampURL = try #require(lamp.routeURL)
        #expect(AppURLParser.parse(lampURL) == .focus(deviceId: Self.lamp.id))
        #expect(AppURLParser.parse(lampURL)?.controlsDevice == false)

        let roomURL = try #require(room.routeURL)
        #expect(AppURLParser.parse(roomURL) == .focusRoom(roomId: "study"))
        #expect(AppURLParser.parse(roomURL)?.controlsDevice == false)

        let sceneURL = try #require(scene.routeURL)
        #expect(AppURLParser.parse(sceneURL) == .scene(name: "sc_movie"))
    }

    @Test("An entity id with its own dots survives the item-identifier round trip")
    func itemIdentifierRoundTrip() throws {
        let lamp = try #require(Self.entries().first { $0.entityId == Self.lamp.id })
        #expect(lamp.itemIdentifier == "menubarmijia.spotlight.device.ha:light.living_ceiling")

        let identity = try #require(SpotlightIndexPlan.identity(forItemIdentifier: lamp.itemIdentifier))
        #expect(identity.kind == .device)
        #expect(identity.entityId == Self.lamp.id)

        let url = try #require(SpotlightIndexPlan.route(forItemIdentifier: lamp.itemIdentifier))
        #expect(AppURLParser.parse(url) == .focus(deviceId: Self.lamp.id))
        #expect(SpotlightIndexPlan.route(forItemIdentifier: "com.other.app.item") == nil)
    }

    @Test("A reordered home with the same names produces the same signature")
    func signatureIgnoresOrderAndReadings() {
        let forward = Self.entries()
        let reversed = Self.entries(devices: [Self.plug, Self.lamp])
        #expect(SpotlightIndexPlan.contentSignature(of: forward) == SpotlightIndexPlan.contentSignature(of: reversed))

        let renamed = Self.entries(devices: [
            SmartDevice(
                id: Self.lamp.id, name: "客厅吊灯", roomId: "living", roomName: "客厅",
                model: "test.light", isOnline: true,
                kind: .light(LightSpec(entityId: "light.living_ceiling", isOn: false))
            ),
            Self.plug,
        ])
        #expect(SpotlightIndexPlan.contentSignature(of: forward) != SpotlightIndexPlan.contentSignature(of: renamed))
    }

    @Test("Removals are the identifiers that left the home, never the new ones")
    func removalsOnlyDeleteWhatLeft() {
        let previous = Set(Self.entries().map(\.itemIdentifier))
        let reduced = Self.entries(scenes: [])
        let removals = SpotlightIndexPlan.removals(previous: previous, current: reduced)
        #expect(removals == ["menubarmijia.spotlight.scene.sc_movie"])
    }

    @Test("An empty home plans an empty index")
    func emptyHomeIsEmptyPlan() {
        #expect(Self.entries(devices: [], rooms: [], scenes: []).isEmpty)
    }
}
