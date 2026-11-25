import Foundation
import Testing
@testable import MijiaCore

struct CanonicalDeviceRegistryTests {
    @Test("tombstones restore and expire")
    func tombstonesRestoreAndExpire() {
        var registry = CanonicalDeviceRegistry(assignments: ["did:lamp": "mi:lamp"])
        let now = Date(timeIntervalSince1970: 1_000)
        registry.reconcile(presentIDs: [], at: now)
        #expect(registry.canonicalID(forKeys: ["did:lamp"]) == "mi:lamp")
        registry.purgeExpired(at: now.addingTimeInterval(30 * 24 * 60 * 60))
        #expect(registry.canonicalID(forKeys: ["did:lamp"]) == nil)
    }

    @Test("explicit delete blocks resurrection")
    func explicitDeleteBlocksResurrection() {
        var registry = CanonicalDeviceRegistry(assignments: ["did:lamp": "mi:lamp"])
        registry.forget("mi:lamp")
        registry.assign("mi:lamp", toKeys: ["did:lamp"])
        #expect(registry.canonicalID(forKeys: ["did:lamp"]) == nil)
    }

    @Test("legacy flat registry remains decodable")
    func legacyFlatRegistryRemainsDecodable() throws {
        let data = try JSONEncoder().encode(["did:lamp": "mi:lamp"])
        let registry = try JSONDecoder().decode(CanonicalDeviceRegistry.self, from: data)
        #expect(registry.canonicalID(forKeys: ["did:lamp"]) == "mi:lamp")
    }

    @Test("a returning HA unique ID uses the earlier card ID and its saved preferences")
    func returningIdentity() {
        func home(id: String, scope: String = "ha:https://ha.example") -> SynthesizedHome {
            let device = SmartDevice(
                id: id, name: "Lamp", roomId: "room", roomName: "Room",
                model: "lamp", isOnline: true,
                kind: .light(LightSpec(entityId: "light.lamp", isOn: false))
            )
            var home = SynthesizedHome(devices: [device])
            home.homeAssistantScope = scope
            home.deviceIdentities[id] = DeviceSourceIdentity(dids: ["lamp-unique"], uniqueIds: ["lamp-unique"], kindTag: .light)
            return home
        }
        let now = Date(timeIntervalSince1970: 1_000)
        let preferences = ["old-card": ["favorite", "room", "alias", "hidden", "hotkey"]]
        let original = DeviceDeduplicator.merge(homeAssistant: home(id: "old-card"), xiaomiCloud: nil, registryNow: now)
        let absent = DeviceDeduplicator.merge(homeAssistant: nil, xiaomiCloud: nil, canonical: original.canonical, registryNow: now)
        let returning = DeviceDeduplicator.merge(
            homeAssistant: home(id: "new-card"), xiaomiCloud: nil, canonical: absent.canonical,
            registryNow: now.addingTimeInterval(24 * 60 * 60)
        )
        #expect(returning.home.devices.compactMap { preferences[$0.id] } == [["favorite", "room", "alias", "hidden", "hotkey"]])
        let differentInstance = DeviceDeduplicator.merge(
            homeAssistant: home(id: "foreign-card", scope: "ha:https://other.example"), xiaomiCloud: nil,
            canonical: returning.canonical, registryNow: now
        )
        #expect(differentInstance.home.devices.map(\.id) == ["foreign-card"])
        let expired = DeviceDeduplicator.merge(
            homeAssistant: home(id: "new-card"), xiaomiCloud: nil, canonical: absent.canonical,
            registryNow: now.addingTimeInterval(CanonicalDeviceRegistry.orphanRetention)
        )
        #expect(expired.home.devices.map(\.id) == ["new-card"])
    }

    @Test("registry falls back to the newest valid file and bounds backup count")
    func rollingBackups() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("canonical-devices.json")
        let file = CanonicalDeviceRegistryFile(url: url)
        let (legacy, save) = file.open(legacy: ["did:lamp": "old"])
        #expect(legacy.assignments == ["did:lamp": "old"])
        for generation in 1...5 {
            save(CanonicalDeviceRegistry(assignments: ["did:lamp": String(generation)]))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.filter { $0.hasSuffix(".bak") }.count == 2)
        try Data("{\"assignments\":42}".utf8).write(to: url)
        #expect(file.open(legacy: [:]).0.assignments == ["did:lamp": "4"])
        try Data("truncated".utf8).write(to: url.appendingPathExtension("1.bak"))
        #expect(file.open(legacy: [:]).0.assignments == ["did:lamp": "3"])
    }
}
