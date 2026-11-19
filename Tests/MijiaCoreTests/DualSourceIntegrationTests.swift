import Foundation
import Testing
@testable import MijiaCore

@Suite(.serialized)
struct DualSourceIntegrationTests {
    private let did = "1234567890"
    private let haID = "ha-registry-1"

    private func light(
        id: String,
        name: String,
        roomID: String,
        roomName: String,
        entityId: String,
        online: Bool = true
    ) -> SmartDevice {
        SmartDevice(
            id: id,
            name: name,
            roomId: roomID,
            roomName: roomName,
            model: "yeelink.light.ceiling22",
            isOnline: online,
            kind: .light(LightSpec(entityId: entityId, isOn: false, brightnessPercent: 80))
        )
    }

    private func home(
        _ devices: [SmartDevice],
        identities: [String: DeviceSourceIdentity]
    ) -> SynthesizedHome {
        var home = SynthesizedHome(devices: devices)
        home.deviceIdentities = identities
        return home
    }

    @MainActor
    @Test("HA disconnect hands the paired card to Mi Cloud with its favorite and alias intact")
    func haDisconnectKeepsPreferences() async throws {
        let suite = "test.dual.fallback.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let suiteDefaults = try #require(UserDefaults(suiteName: suite))
        suiteDefaults.set([String](), forKey: ViewPreferenceKeys.favoriteDeviceIds)
        suiteDefaults.set([String](), forKey: ViewPreferenceKeys.favoriteOrder)

        let haDevice = light(
            id: haID,
            name: "客厅吸顶灯",
            roomID: "ha-living",
            roomName: "客厅",
            entityId: "light.living_ceiling"
        )
        let miDevice = light(
            id: did,
            name: "吸顶灯",
            roomID: "mi-living",
            roomName: "客厅",
            entityId: "miot:\(did):2"
        )
        let haHome = home(
            [haDevice],
            identities: [
                haID: DeviceSourceIdentity(
                    dids: [did],
                    model: "yeelink.light.ceiling22",
                    name: "客厅吸顶灯",
                    roomName: "客厅",
                    kindTag: .light
                )
            ]
        )
        let miHome = home(
            [miDevice],
            identities: [
                did: DeviceSourceIdentity(
                    dids: [did],
                    model: "yeelink.light.ceiling22",
                    name: "吸顶灯",
                    roomName: "客厅",
                    kindTag: .light
                )
            ]
        )

        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: miHome)
        let store = HomeStore(
            dualSource: (homeAssistant: haMock, xiaomiCloud: miMock),
            defaultsSuiteName: suite
        )

        await waitUntil {
            store.connectedBackends == Set([.homeAssistant, .xiaomiCloud])
                && store.devices.count == 1
                && store.deviceBackend(for: haID) == .homeAssistant
        }
        let canonical = try #require(store.devices.first?.id)
        #expect(canonical == haID)
        #expect(store.connectedBackends == Set([.homeAssistant, .xiaomiCloud]))
        let persisted = suiteDefaults.dictionary(forKey: ViewPreferenceKeys.canonicalDeviceIds) as? [String: String]
        #expect(persisted?.values.contains(canonical) == true)

        store.favoriteDeviceIds = []
        store.favoriteOrder = []
        store.toggleFavorite(canonical)
        store.applyDeviceAliases([canonical: "客厅主灯"])
        #expect(store.favoriteDeviceIds.contains(canonical))

        let haDeviceForCommand = try #require(store.devices.first)
        _ = await store.togglePrimary(haDeviceForCommand)?.value
        let haCommands = await haMock.executedCommands
        #expect(haCommands.contains { $0.targetEntityId == "light.living_ceiling" })

        await haMock.sendStatus(.disconnected("LAN unreachable"))
        // The fallback grace (#25) holds the HA route through a brief blip; the outage that
        // outlasts the window adopts the Mi Cloud handoff. The drop must be observed before the
        // seam rewinds it, or the seam races the still-in-flight status event.
        await waitUntil {
            if case .disconnected = store.sourceStatuses[.homeAssistant] ?? .connecting { return true }
            return false
        }
        await (store.provider as? DualSourceHomeProvider)?.expireFallbackGraceForTesting()
        await waitUntil {
            store.devices.count == 1 && store.deviceBackend(for: canonical) == .xiaomiCloud
        }
        #expect(store.devices.first?.id == canonical)
        #expect(store.devices.first?.name == "客厅主灯")
        #expect(store.favoriteDeviceIds.contains(canonical))
        #expect(store.connectedBackends == Set([.xiaomiCloud]))

        let miDeviceForCommand = try #require(store.devices.first)
        if case .light(let spec) = miDeviceForCommand.kind {
            #expect(spec.entityId == "miot:\(did):2")
        } else {
            Issue.record("handoff lost the light card")
        }
        _ = await store.togglePrimary(miDeviceForCommand)?.value
        await store.executeQuickAction(.lightsOff)?.value
        await store.undoTurnAllOff()?.value
        let miCommands = await miMock.executedCommands
        #expect(miCommands.filter { $0.targetEntityId == "miot:\(did):2" }.count >= 2)
        #expect((await haMock.executedCommands).count == haCommands.count)

        await haMock.updateSnapshot(haHome)
        await waitUntil {
            store.connectedBackends == Set([.homeAssistant, .xiaomiCloud])
                && store.deviceBackend(for: canonical) == .homeAssistant
        }
        #expect(store.devices.first?.id == canonical)
        #expect(store.devices.first?.name == "客厅主灯")
        #expect(store.favoriteDeviceIds.contains(canonical))
    }

    @MainActor
    @Test("Mi-first preferences choose the Mi id as the canonical id while HA drives the card")
    func miPreferencesChooseMiCanonical() async throws {
        let suite = "test.dual.preferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([did], forKey: ViewPreferenceKeys.favoriteDeviceIds)

        let haDevice = light(
            id: haID,
            name: "客厅吸顶灯",
            roomID: "ha-living",
            roomName: "客厅",
            entityId: "light.living_ceiling"
        )
        let miDevice = light(
            id: did,
            name: "吸顶灯",
            roomID: "mi-living",
            roomName: "客厅",
            entityId: "miot:\(did):2"
        )
        let haHome = home(
            [haDevice],
            identities: [
                haID: DeviceSourceIdentity(
                    dids: [did],
                    model: "yeelink.light.ceiling22",
                    name: "客厅吸顶灯",
                    roomName: "客厅",
                    kindTag: .light
                )
            ]
        )
        let miHome = home(
            [miDevice],
            identities: [
                did: DeviceSourceIdentity(
                    dids: [did],
                    model: "yeelink.light.ceiling22",
                    name: "吸顶灯",
                    roomName: "客厅",
                    kindTag: .light
                )
            ]
        )

        let store = HomeStore(
            dualSource: (
                homeAssistant: MockHomeProvider(snapshot: haHome),
                xiaomiCloud: MockHomeProvider(snapshot: miHome)
            ),
            defaultsSuiteName: suite
        )
        await waitUntil {
            store.connectedBackends == Set([.homeAssistant, .xiaomiCloud]) && store.devices.count == 1
        }

        #expect(store.devices.first?.id == did)
        #expect(store.deviceBackend(for: did) == .homeAssistant)
        #expect(store.favoriteDeviceIds.contains(did))
    }

    @MainActor
    @Test("Auto-seeded favorites written before the second source arrives still pick the canonical id")
    func autoSeededFavoritesChooseCanonical() async throws {
        let suite = "test.dual.autoseed.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let haDevice = light(
            id: haID,
            name: "客厅吸顶灯",
            roomID: "ha-living",
            roomName: "客厅",
            entityId: "light.living_ceiling"
        )
        let miDevice = light(
            id: did,
            name: "吸顶灯",
            roomID: "mi-living",
            roomName: "客厅",
            entityId: "miot:\(did):2"
        )
        let haHome = home(
            [haDevice],
            identities: [
                haID: DeviceSourceIdentity(
                    dids: [did],
                    model: "yeelink.light.ceiling22",
                    name: "客厅吸顶灯",
                    roomName: "客厅",
                    kindTag: .light
                )
            ]
        )
        let miHome = home(
            [miDevice],
            identities: [
                did: DeviceSourceIdentity(
                    dids: [did],
                    model: "yeelink.light.ceiling22",
                    name: "吸顶灯",
                    roomName: "客厅",
                    kindTag: .light
                )
            ]
        )

        let haMock = MockHomeProvider(snapshot: SynthesizedHome())
        let miMock = MockHomeProvider(snapshot: miHome)
        let store = HomeStore(
            dualSource: (homeAssistant: haMock, xiaomiCloud: miMock),
            defaultsSuiteName: suite
        )

        await waitUntil {
            store.devices.count == 1 && store.favoriteDeviceIds.contains(did)
        }
        await haMock.updateSnapshot(haHome)
        await waitUntil {
            store.connectedBackends == Set([.homeAssistant, .xiaomiCloud])
                && store.devices.count == 1
                && store.deviceBackend(for: did) == .homeAssistant
        }
        #expect(store.devices.first?.id == did)
        #expect(store.favoriteDeviceIds.contains(did))
    }

    @Test("HA registry identifiers, connections and unique ids become pairing evidence")
    func haIdentityDecoding() throws {
        let json = """
        {
          "id": "ha-registry-1",
          "name": "吸顶灯",
          "model": "yeelink.light.ceiling22",
          "identifiers": [["xiaomi_home", "cn_1234567890"]],
          "connections": [["mac", "AA:BB:CC:DD:EE:FF"]],
          "serial_number": "sn-1"
        }
        """
        let entry = try JSONDecoder().decode(HADeviceEntry.self, from: Data(json.utf8))
        #expect(entry.identifiers == [["xiaomi_home", "cn_1234567890"]])
        #expect(entry.connections == [["mac", "AA:BB:CC:DD:EE:FF"]])
        #expect(entry.serial_number == "sn-1")

        let home = DeviceSynthesizer.synthesize(
            areas: [HAAreaEntry(area_id: "living", name: "客厅")],
            devices: [entry],
            entities: [
                HAEntityEntry(
                    entity_id: "light.living_ceiling",
                    device_id: "ha-registry-1",
                    area_id: "living",
                    unique_id: "1234567890_2_1"
                )
            ],
            states: [
                "light.living_ceiling": HAEntityState(entityId: "light.living_ceiling", state: "on")
            ]
        )
        let identity = try #require(home.deviceIdentities["ha-registry-1"])
        #expect(identity.dids.contains("1234567890"))
        #expect(identity.macAddresses.contains("aabbccddeeff"))
        #expect(identity.uniqueIds.contains("1234567890_2_1"))
    }

    @Test("Identity normalisation handles Xiaomi server prefixes and MAC punctuation")
    func identityNormalisation() {
        #expect(DeviceIdentityNormalizer.didCandidates(from: ["cn_1234567890"]).contains("1234567890"))
        #expect(DeviceIdentityNormalizer.didCandidates(from: ["1234567890_2_1"]).contains("1234567890"))
        #expect(DeviceIdentityNormalizer.macAddress(from: "AA-BB-CC-DD-EE-FF") == "aabbccddeeff")
        #expect(DeviceIdentityNormalizer.normalizedRoomName(" 客厅 ") == "客厅")
    }

    @Test("Preference index sees every view preference key that holds a device id")
    func preferenceIndexReadsViewPreferences() throws {
        let suite = "test.dual.prefindex.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["favorite-a"], forKey: ViewPreferenceKeys.favoriteDeviceIds)
        defaults.set(["order-a"], forKey: ViewPreferenceKeys.favoriteOrder)
        defaults.set(["hidden-a"], forKey: ViewPreferenceKeys.hiddenDeviceIds)
        defaults.set(["alloff-a": true], forKey: ViewPreferenceKeys.allOffOverrides)
        defaults.set(#"{"alias-a":"Alias"}"#, forKey: ViewPreferenceKeys.deviceAliases)
        defaults.set(#"{"all|tile-a":"full","tile-b":"half"}"#, forKey: ViewPreferenceKeys.tileSizes)
        defaults.set(#"["order-b"]"#, forKey: ViewPreferenceKeys.customOrder)
        defaults.set(#"{"group-a":"g1"}"#, forKey: ViewPreferenceKeys.groupMap)
        defaults.set(["camera-a": "http://example.test/stream"], forKey: ViewPreferenceKeys.cameraStreamURLs)
        defaults.set(["camera-b": "hd"], forKey: ViewPreferenceKeys.cameraStreamQuality)
        defaults.set("light-a", forKey: ViewPreferenceKeys.lastManualLightId)
        defaults.set("temp:sensor-a", forKey: ViewPreferenceKeys.menuBarTargetId)

        let ids = DevicePreferenceIndex.referencedIDs(defaults: defaults)
        for id in [
            "favorite-a", "order-a", "hidden-a", "alloff-a", "alias-a", "tile-a",
            "tile-b", "order-b", "group-a", "camera-a", "camera-b", "light-a", "sensor-a",
        ] {
            #expect(ids.contains(id), "missing \(id)")
        }
    }

    @Test("Mi Cloud records carry the did and MAC into pairing evidence")
    func miIdentityExtraction() throws {
        let record = MiDeviceRecord(
            did: did,
            name: "吸顶灯",
            model: "yeelink.light.ceiling22",
            isOnline: true,
            mac: "AA:BB:CC:DD:EE:FF"
        )
        let home = MiotSynthesizer.synthesize(
            devices: [record],
            rooms: [],
            specs: MiotFixtures.specs,
            values: [MiotFixtures.key(did, 2, 1): .bool(true)]
        )
        let identity = try #require(home.deviceIdentities[did])
        #expect(identity.dids == [did])
        #expect(identity.macAddresses == ["aabbccddeeff"])
        #expect(identity.kindTag == .light)
    }

    @MainActor
    @Test("Undo after source handoff retargets restore commands to the active source")
    func undoRetargetsAfterSourceSwitch() async throws {
        let suite = "test.dual.undo.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        var haDevice = light(
            id: haID,
            name: "客厅吸顶灯",
            roomID: "ha-living",
            roomName: "客厅",
            entityId: "light.living_ceiling"
        )
        haDevice.kind = .light(LightSpec(entityId: "light.living_ceiling", isOn: true, brightnessPercent: 80))

        var miDevice = light(
            id: did,
            name: "吸顶灯",
            roomID: "mi-living",
            roomName: "客厅",
            entityId: "miot:\(did):2"
        )
        miDevice.kind = .light(LightSpec(entityId: "miot:\(did):2", isOn: false, brightnessPercent: 80))

        let haHome = home(
            [haDevice],
            identities: [
                haID: DeviceSourceIdentity(
                    dids: [did],
                    model: "yeelink.light.ceiling22",
                    name: "客厅吸顶灯",
                    roomName: "客厅",
                    kindTag: .light
                )
            ]
        )
        let miHome = home(
            [miDevice],
            identities: [
                did: DeviceSourceIdentity(
                    dids: [did],
                    model: "yeelink.light.ceiling22",
                    name: "吸顶灯",
                    roomName: "客厅",
                    kindTag: .light
                )
            ]
        )

        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: miHome)
        let store = HomeStore(
            dualSource: (homeAssistant: haMock, xiaomiCloud: miMock),
            defaultsSuiteName: suite
        )

        await waitUntil {
            store.connectedBackends == Set([.homeAssistant, .xiaomiCloud])
                && store.devices.count == 1
        }
        let canonical = try #require(store.devices.first?.id)
        #expect(store.deviceBackend(for: canonical) == .homeAssistant)

        store.turnAllOff()
        await waitUntil { store.undoBanner != nil }
        store.pauseUndoBannerCountdown()
        for _ in 0..<100 where (await haMock.executedCommands.isEmpty) {
            try await Task.sleep(for: .milliseconds(10))
        }

        // HA disconnects before the user taps Undo; the card falls back to Mi Cloud (`miot:...`).
        await haMock.sendStatus(.disconnected("HA down"))
        await waitUntil {
            if case .disconnected = store.sourceStatuses[.homeAssistant] ?? .connecting { return true }
            return false
        }
        await (store.provider as? DualSourceHomeProvider)?.expireFallbackGraceForTesting()
        await waitUntil {
            store.deviceBackend(for: canonical) == .xiaomiCloud
        }

        let undoTask = store.undoTurnAllOff()
        await undoTask?.value

        let miCommands = await miMock.executedCommands
        #expect(miCommands.contains(.setLightPower(entityId: "miot:\(did):2", isOn: true)))
    }

    @MainActor
    @Test("Source handoff cancels in-flight debounced slider writes from the old source")
    func sourceHandoffCancelsStaleDebouncedWrite() async throws {
        let suite = "test.dual.debounce.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let haDevice = light(
            id: haID,
            name: "客厅吸顶灯",
            roomID: "ha-living",
            roomName: "客厅",
            entityId: "light.living_ceiling"
        )
        let miDevice = light(
            id: did,
            name: "吸顶灯",
            roomID: "mi-living",
            roomName: "客厅",
            entityId: "miot:\(did):2"
        )
        let haHome = home(
            [haDevice],
            identities: [
                haID: DeviceSourceIdentity(
                    dids: [did],
                    model: "yeelink.light.ceiling22",
                    name: "客厅吸顶灯",
                    roomName: "客厅",
                    kindTag: .light
                )
            ]
        )
        let miHome = home(
            [miDevice],
            identities: [
                did: DeviceSourceIdentity(
                    dids: [did],
                    model: "yeelink.light.ceiling22",
                    name: "吸顶灯",
                    roomName: "客厅",
                    kindTag: .light
                )
            ]
        )

        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: miHome)
        let store = HomeStore(
            dualSource: (homeAssistant: haMock, xiaomiCloud: miMock),
            defaultsSuiteName: suite
        )
        store.controlDebounceInterval = .milliseconds(120)

        await waitUntil {
            store.connectedBackends == Set([.homeAssistant, .xiaomiCloud])
                && store.devices.count == 1
        }
        let canonical = try #require(store.devices.first?.id)
        #expect(store.deviceBackend(for: canonical) == .homeAssistant)

        await haMock.setShouldFail(true)
        store.setLightBrightness(canonical, percent: 45)
        let debouncedTask = try #require(store.debounceTasks["\(canonical).brightness"])
        await haMock.sendStatus(.disconnected("HA down"))
        await waitUntil {
            if case .disconnected = store.sourceStatuses[.homeAssistant] ?? .connecting { return true }
            return false
        }
        await (store.provider as? DualSourceHomeProvider)?.expireFallbackGraceForTesting()
        await waitUntil {
            store.deviceBackend(for: canonical) == .xiaomiCloud
        }
        await debouncedTask.value
        #expect(debouncedTask.isCancelled)
        #expect(store.debounceTasks.isEmpty)
        guard case .light(let spec) = store.devices.first?.kind else {
            Issue.record("expected light device")
            return
        }
        #expect(spec.entityId == "miot:\(did):2")
    }

    @MainActor
    @Test("Per-source statuses update after both snapshots are dropped")
    func sourceStatusesSurviveBothOffline() async throws {
        let suite = "test.dual.statuses.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let haDevice = light(
            id: "ha-status-light",
            name: "客厅灯",
            roomID: "ha-living",
            roomName: "客厅",
            entityId: "light.living_ceiling"
        )
        let miDevice = light(
            id: "999888777",
            name: "吸顶灯",
            roomID: "mi-living",
            roomName: "客厅",
            entityId: "miot:999888777:2"
        )
        let haMock = MockHomeProvider(snapshot: home([haDevice], identities: [:]))
        let miMock = MockHomeProvider(snapshot: home([miDevice], identities: [:]))
        let store = HomeStore(
            dualSource: (homeAssistant: haMock, xiaomiCloud: miMock),
            defaultsSuiteName: suite
        )
        store.hasHASource = true
        store.miSessionMaskedUserId = "masked"

        await waitUntil {
            store.sourceStatuses[.homeAssistant] == .connected
                && store.sourceStatuses[.xiaomiCloud] == .connected
        }

        await haMock.sendStatus(.disconnected("HA down"))
        await miMock.sendStatus(.disconnected("Mi down"))
        await waitUntil {
            if case .disconnected = store.connectionStatus {
                return store.sourceStatuses[.homeAssistant] != .connected
                    && store.sourceStatuses[.xiaomiCloud] != .connected
            }
            return false
        }

        await haMock.sendStatus(.connecting)
        await waitUntil {
            store.sourceStatuses[.homeAssistant] == .connecting
                && store.sourceStatuses[.xiaomiCloud] != .connected
        }
        #expect(store.dualSourceStatusSummary == L10n.tr(
            "HA 连接中 · 米家云未连接",
            "HA connecting · Xiaomi Cloud offline"
        ))
    }

    @MainActor
    @Test("Source pin propagates in memory even when UserDefaults loses the persisted value")
    func pinPropagatesViaInMemoryBoxWhenDefaultsDropWrite() async throws {
        let suite = "test.dual.pinbox.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let haDevice = light(
            id: haID,
            name: "客厅吸顶灯",
            roomID: "ha-living",
            roomName: "客厅",
            entityId: "light.living_ceiling"
        )
        let miDevice = light(
            id: did,
            name: "吸顶灯",
            roomID: "mi-living",
            roomName: "客厅",
            entityId: "miot:\(did):2"
        )
        let haHome = home(
            [haDevice],
            identities: [
                haID: DeviceSourceIdentity(dids: [did], model: "yeelink.light.ceiling22", name: "客厅吸顶灯", roomName: "客厅", kindTag: .light)
            ]
        )
        let miHome = home(
            [miDevice],
            identities: [
                did: DeviceSourceIdentity(dids: [did], model: "yeelink.light.ceiling22", name: "吸顶灯", roomName: "客厅", kindTag: .light)
            ]
        )

        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: miHome)
        let store = HomeStore(
            dualSource: (homeAssistant: haMock, xiaomiCloud: miMock),
            defaultsSuiteName: suite
        )

        await waitUntil {
            store.connectedBackends == Set([.homeAssistant, .xiaomiCloud]) && store.devices.count == 1
        }
        let cardID = try #require(store.devices.first?.id)
        #expect(store.deviceBackend(for: cardID) == .homeAssistant)

        // Simulate UserDefaults dropping the write (e.g. cfprefsd FD exhaustion); remove the key
        // directly from defaults, then re-pin `.xiaomiCloud`.
        store.pinDeviceSource(cardID, to: .xiaomiCloud)
        defaults.removeObject(forKey: ViewPreferenceKeys.pinnedDeviceSources)
        (store.provider as? any DualSourceRecomputing)?.requestRecompute()

        await waitUntil {
            store.deviceBackend(for: cardID) == .xiaomiCloud
        }
        #expect(store.pinnedSource(for: cardID) == .xiaomiCloud)
        #expect(store.deviceBackend(for: cardID) == .xiaomiCloud)
        #expect(store.currentSourceMenuTitle(for: cardID) == L10n.format("当前来源：%@", "Current source: %@", HomeBackend.xiaomiCloud.shortTitle))

        // When pinned source goes offline while HA is online, menu title surfaces the fallback.
        let offlineMi = light(id: did, name: "吸顶灯", roomID: "mi-living", roomName: "客厅", entityId: "miot:\(did):2", online: false)
        await miMock.updateSnapshot(home([offlineMi], identities: miHome.deviceIdentities))
        await waitUntil {
            store.deviceBackend(for: cardID) == .homeAssistant
        }
        #expect(store.currentSourceMenuTitle(for: cardID) == L10n.format(
            "当前来源：%@（%@离线，临时兜底）",
            "Current source: %@ (%@ offline, fallback)",
            HomeBackend.homeAssistant.shortTitle,
            HomeBackend.xiaomiCloud.shortTitle
        ))
    }

    @MainActor
    @Test("disconnectHomeAssistant drops HA, switches live backend to Xiaomi Cloud, or clears when Mi is absent")
    func disconnectHomeAssistantTransitionsCleanly() async throws {
        let suite = "test.dual.disconnect_ha.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let session = MiSession(
            userId: "42", cUserId: "c", ssecurity: "s", serviceToken: "token",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        #expect(MiSessionStore.save(session, defaults: defaults))
        #expect(KeychainHelper.saveToken("ha-token", defaults: defaults))

        let storeWithMi = HomeStore(
            dualSource: (homeAssistant: MockHomeProvider(), xiaomiCloud: MockHomeProvider()),
            defaultsSuiteName: suite
        )
        defer { storeWithMi.logoutMiAccount() }
        storeWithMi.hasHASource = true
        #expect(storeWithMi.hasHASource)
        #expect(storeWithMi.hasMiSource)
        storeWithMi.haPlaintextPrompt = .asking("http://example.invalid:8123")

        #expect(storeWithMi.disconnectHomeAssistant())
        #expect(!storeWithMi.hasHASource)
        #expect(storeWithMi.haPlaintextPrompt == nil)
        #expect(storeWithMi.homeBackend == .xiaomiCloud)
        #expect(KeychainHelper.loadToken(defaults: defaults).isEmpty)

        // When no Mi account exists, disconnecting HA clears the stale HA devices/scenes.
        let suiteNoMi = "test.dual.disconnect_ha_only.\(UUID().uuidString)"
        let defaultsNoMi = try #require(UserDefaults(suiteName: suiteNoMi))
        defer { defaultsNoMi.removePersistentDomain(forName: suiteNoMi) }
        #expect(KeychainHelper.saveToken("ha-token", defaults: defaultsNoMi))
        let haMock = MockHomeProvider(snapshot: home([
            light(id: haID, name: "客厅灯", roomID: "ha-living", roomName: "客厅", entityId: "light.living")
        ], identities: [:]))
        let miMock = MockHomeProvider()
        let haOnlyStore = HomeStore(
            dualSource: (homeAssistant: haMock, xiaomiCloud: miMock),
            defaultsSuiteName: suiteNoMi
        )
        defer { haOnlyStore.switchBackend(.demo) }
        await waitUntil { !haOnlyStore.devices.isEmpty }
        haOnlyStore.hasHASource = true
        #expect(haOnlyStore.disconnectHomeAssistant())
        #expect(haOnlyStore.devices.isEmpty)
        #expect(haOnlyStore.rooms.isEmpty)
    }

    @MainActor
    @Test("Transient Xiaomi Cloud disconnect retains unpaired Mi-only cards as offline+stale with favorites and aliases intact, then recovers")
    func transientMiDisconnectRetainsUnpairedCardsAndRecovers() async throws {
        let suite = "test.dual.retain_unpaired.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let pairedHA = light(
            id: haID,
            name: "客厅吸顶灯",
            roomID: "ha-living",
            roomName: "客厅",
            entityId: "light.living_ceiling"
        )
        let pairedMi = light(
            id: did,
            name: "吸顶灯",
            roomID: "mi-living",
            roomName: "客厅",
            entityId: "miot:\(did):2"
        )
        let unpairedMiDid = "mi-only-kettle-888"
        let unpairedMi = SmartDevice(
            id: unpairedMiDid,
            name: "恒温电水壶",
            roomId: "mi-kitchen",
            roomName: "厨房",
            model: "yunmi.kettle.v1",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:\(unpairedMiDid):2", isOn: true))
        )

        let haHome = home(
            [pairedHA],
            identities: [
                haID: DeviceSourceIdentity(dids: [did], model: "yeelink.light.ceiling22", name: "客厅吸顶灯", roomName: "客厅", kindTag: .light)
            ]
        )
        let miHome = home(
            [pairedMi, unpairedMi],
            identities: [
                did: DeviceSourceIdentity(dids: [did], model: "yeelink.light.ceiling22", name: "吸顶灯", roomName: "客厅", kindTag: .light),
                unpairedMiDid: DeviceSourceIdentity(dids: [unpairedMiDid], model: "yunmi.kettle.v1", name: "恒温电水壶", roomName: "厨房", kindTag: .plug),
            ]
        )

        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: miHome)
        let store = HomeStore(
            dualSource: (homeAssistant: haMock, xiaomiCloud: miMock),
            defaultsSuiteName: suite
        )

        await waitUntil {
            store.connectedBackends == Set([.homeAssistant, .xiaomiCloud])
                && store.devices.count == 2
        }
        let pairedLightID = try #require(store.devices.first { $0.id != unpairedMiDid }?.id)
        #expect(pairedLightID == haID || pairedLightID == did)

        store.favoriteDeviceIds = []
        store.favoriteOrder = []
        store.toggleFavorite(unpairedMiDid)
        store.applyDeviceAliases([unpairedMiDid: "吧台水壶"])
        #expect(store.favoriteDeviceIds.contains(unpairedMiDid))

        await miMock.sendStatus(.disconnected("HTTP 429 Too Many Requests"))
        // Within the fallback grace (#25) the kettle keeps its last known fresh state; once the
        // drop outlasts the window it is retained as offline+stale rather than dropped.
        await waitUntil {
            if case .disconnected = store.sourceStatuses[.xiaomiCloud] ?? .connecting { return true }
            return false
        }
        await (store.provider as? DualSourceHomeProvider)?.expireFallbackGraceForTesting()
        await waitUntil {
            guard store.connectedBackends == Set([.homeAssistant]),
                  let kettle = store.devices.first(where: { $0.id == unpairedMiDid }) else { return false }
            return !kettle.isOnline && kettle.telemetryStale
        }

        #expect(store.devices.count == 2)
        let retainedKettle = try #require(store.devices.first { $0.id == unpairedMiDid })
        #expect(retainedKettle.isOnline == false)
        #expect(retainedKettle.telemetryStale == true)
        #expect(retainedKettle.name == "吧台水壶")
        #expect(store.favoriteDeviceIds.contains(unpairedMiDid))

        let onlineLight = try #require(store.devices.first { $0.id == pairedLightID })
        #expect(onlineLight.isOnline == true)
        #expect(onlineLight.telemetryStale == false)

        await miMock.updateSnapshot(miHome)
        await waitUntil {
            guard store.connectedBackends == Set([.homeAssistant, .xiaomiCloud]),
                  let kettle = store.devices.first(where: { $0.id == unpairedMiDid }) else { return false }
            return kettle.isOnline && !kettle.telemetryStale
        }
        #expect(store.devices.first(where: { $0.id == unpairedMiDid })?.name == "吧台水壶")
        #expect(store.favoriteDeviceIds.contains(unpairedMiDid))
        let recoveredLight = try #require(store.devices.first { $0.id == pairedLightID })
        #expect(recoveredLight.isOnline == true)
        #expect(recoveredLight.telemetryStale == false)
    }

    @MainActor
    @Test("Disconnecting 1 of 2 Xiaomi accounts fails over its paired cards to Home Assistant while aggregate Mi status stays connected")
    func multiAccountSingleDisconnectFailsOverPairedCardToHA() async throws {
        let suite = "test.dual.multi_acc_failover.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let suiteDefaults = try #require(UserDefaults(suiteName: suite))
        // Without an explicit list, a Mi snapshot arriving first seeds favorites with the Mi id and
        // makes it the paired card's canonical id.
        suiteDefaults.set([String](), forKey: ViewPreferenceKeys.favoriteDeviceIds)
        suiteDefaults.set([String](), forKey: ViewPreferenceKeys.favoriteOrder)

        let acc1Id = "cn:1001"
        let acc2Id = "de:2002"
        let sharedDid = "cam-did-1"
        let haCamId = "ha-cam-1"

        let haCamWithoutStream = SmartDevice(
            id: haCamId,
            name: "玄关摄像机",
            roomId: "ha-entry",
            roomName: "玄关",
            model: "chuangmi.camera.061a01",
            isOnline: true,
            kind: .camera(CameraSpec(entityId: "switch.entry_cam", isOn: true))
        )
        let miCamAcc1 = SmartDevice(
            id: sharedDid,
            name: "玄关摄像机",
            roomId: "\(acc1Id)/r1",
            roomName: "玄关",
            model: "chuangmi.camera.061a01",
            isOnline: true,
            kind: .camera(CameraSpec(entityId: "miot:\(sharedDid):2", isOn: true)),
            accountId: acc1Id,
            accountLabel: "10****01"
        )
        let miPlugAcc2 = SmartDevice(
            id: "de-plug-1",
            name: "书房插座",
            roomId: "\(acc2Id)/r2",
            roomName: "书房",
            model: "cuco.plug.v3",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:de-plug-1:2", isOn: true)),
            accountId: acc2Id,
            accountLabel: "20****02"
        )

        let haHome = home(
            [haCamWithoutStream],
            identities: [
                haCamId: DeviceSourceIdentity(dids: [sharedDid], model: "chuangmi.camera.061a01", name: "玄关摄像机", roomName: "玄关", kindTag: .camera)
            ]
        )
        var miHomeBothConnected = home(
            [miCamAcc1, miPlugAcc2],
            identities: [
                sharedDid: DeviceSourceIdentity(dids: [sharedDid], model: "chuangmi.camera.061a01", name: "玄关摄像机", roomName: "玄关", kindTag: .camera),
                "de-plug-1": DeviceSourceIdentity(dids: ["de-plug-1"], model: "cuco.plug.v3", name: "书房插座", roomName: "书房", kindTag: .plug),
            ]
        )
        miHomeBothConnected.accountStatuses = [
            acc1Id: .connected,
            acc2Id: .connected,
        ]

        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: miHomeBothConnected)
        let store = HomeStore(
            dualSource: (homeAssistant: haMock, xiaomiCloud: miMock),
            defaultsSuiteName: suite
        )

        await waitUntil {
            store.devices.count == 2 && store.deviceBackend(for: haCamId) == .xiaomiCloud
        }

        var miHomeAcc1Disconnected = miHomeBothConnected
        miHomeAcc1Disconnected.accountStatuses = [
            acc1Id: .disconnected("HTTP 502"),
            acc2Id: .connected,
        ]
        await miMock.updateSnapshot(miHomeAcc1Disconnected)
        await waitUntil {
            if case .disconnected = store.miAccountStatuses[acc1Id] ?? .connecting { return true }
            return false
        }
        #expect(store.deviceBackend(for: haCamId) == .xiaomiCloud)
        await (store.provider as? DualSourceHomeProvider)?.expireFallbackGraceForTesting()

        await waitUntil {
            store.deviceBackend(for: haCamId) == .homeAssistant
        }
        let camCard = try #require(store.devices.first { $0.id == haCamId })
        #expect(camCard.isOnline == true)
        #expect(camCard.telemetryStale == false)

        var miHomeAcc1Retrying = miHomeBothConnected
        miHomeAcc1Retrying.accountStatuses = [
            acc1Id: .connecting,
            acc2Id: .connected,
        ]
        await miMock.updateSnapshot(miHomeAcc1Retrying)
        #expect(store.deviceBackend(for: haCamId) == .homeAssistant)
        let camCardDuringRetry = try #require(store.devices.first { $0.id == haCamId })
        #expect(camCardDuringRetry.isOnline == true)
        #expect(camCardDuringRetry.telemetryStale == false)
    }

    @MainActor
    @Test("Dual-source remaps deviceTransportDiagnostics to canonicalID only for Xiaomi-driven cards and unmasks HA Local Network TCC block while Mi Cloud is connected")
    func dualSourceTransportDiagnosticsRemapAndHATCCUnmasking() async throws {
        let suite = "test.dual.tcc_and_diag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let session = MiSession(
            userId: "1001", cUserId: "c1", ssecurity: "s", serviceToken: "tok",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        #expect(MiSessionStore.save(session, defaults: defaults))
        #expect(KeychainHelper.saveToken("ha-token", defaults: defaults))

        let pairedHA = light(id: haID, name: "客厅灯", roomID: "ha-r1", roomName: "客厅", entityId: "light.living")
        let pairedMi = light(id: did, name: "客厅灯", roomID: "mi-r1", roomName: "客厅", entityId: "miot:\(did):2")
        let miOnlyDid = "mi-plug-99"
        let miOnlyPlug = SmartDevice(
            id: miOnlyDid, name: "书房插座", roomId: "mi-r2", roomName: "书房",
            model: "cuco.plug.v3", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:\(miOnlyDid):2", isOn: true))
        )

        let haHome = home(
            [pairedHA],
            identities: [haID: DeviceSourceIdentity(dids: [did], model: "yeelink.light.ceiling22", name: "客厅灯", roomName: "客厅", kindTag: .light)]
        )
        var miHome = home(
            [pairedMi, miOnlyPlug],
            identities: [
                did: DeviceSourceIdentity(dids: [did], model: "yeelink.light.ceiling22", name: "客厅灯", roomName: "客厅", kindTag: .light),
                miOnlyDid: DeviceSourceIdentity(dids: [miOnlyDid], model: "cuco.plug.v3", name: "书房插座", roomName: "书房", kindTag: .plug),
            ]
        )
        miHome.deviceTransportDiagnostics = [
            did: DeviceTransportDiagnostics(route: .lan, rttMs: 15, consecutiveFailures: 0, usedBroadcastRecovery: true),
            miOnlyDid: DeviceTransportDiagnostics(route: .lan, rttMs: 20, consecutiveFailures: 0, usedBroadcastRecovery: false),
        ]

        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: miHome)
        let store = HomeStore(dualSource: (homeAssistant: haMock, xiaomiCloud: miMock), defaultsSuiteName: suite)
        defer { store.stop() }
        store.hasHASource = true

        await waitUntil {
            store.connectedBackends == Set([.homeAssistant, .xiaomiCloud])
                && store.pairedDeviceIDs.count == 1
                && store.deviceTransportDiagnostics[miOnlyDid]?.route == .lan
        }

        let pairedCardId = try #require(store.pairedDeviceIDs.first)
        #expect(store.deviceBackend(for: pairedCardId) == .homeAssistant)
        #expect(store.deviceTransportDiagnostics[pairedCardId] == nil)
        #expect(store.deviceTransportDiagnostics[miOnlyDid]?.rttMs == 20)

        store.pinDeviceSource(pairedCardId, to: .xiaomiCloud)
        await waitUntil {
            store.deviceBackend(for: pairedCardId) == .xiaomiCloud
                && store.deviceTransportDiagnostics[pairedCardId]?.route == .lan
        }
        #expect(store.deviceTransportDiagnostics[pairedCardId]?.usedBroadcastRecovery == true)

        await haMock.sendLocalNetworkPermission([.homeAssistant])
        await waitUntil { store.effectiveLocalNetworkBlocks.contains(.homeAssistant) }
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(store.panelHealth == .degraded(reason: "Home Assistant 本地网络权限受阻，米家云端仍可用"))
        }

        // A Xiaomi status update while HA is still in the TCC-blocked window (before HA emits
        // `.disconnected`, or while merged snapshots are held/absent) emits `sourceStatusesChanged`
        // with `.homeAssistant: .connected` and must not clear `.homeAssistant` in `HomeStore`.
        let seenGen = store.snapshotGeneration
        await miMock.sendStatus(.connecting)
        await waitUntil { store.snapshotGeneration != seenGen }

        // Direct `sourceStatusesChanged` without a following snapshot (e.g. before initial snapshot
        // or when only statuses change) preserves `.homeAssistant` while HA has no active usable
        // route, and clears it once HA is genuinely on an active connected path.
        store.connectedBackends = [.xiaomiCloud]
        store.handleProviderEvent(.sourceStatusesChanged([
            .homeAssistant: .connected,
            .xiaomiCloud: .connected,
        ]))
        #expect(store.effectiveLocalNetworkBlocks.contains(.homeAssistant))
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(store.panelHealth == .degraded(reason: "Home Assistant 本地网络权限受阻，米家云端仍可用"))
        }

        store.connectedBackends = [.homeAssistant, .xiaomiCloud]
        store.handleProviderEvent(.sourceStatusesChanged([
            .homeAssistant: .connected,
            .xiaomiCloud: .connected,
        ]))
        #expect(!store.effectiveLocalNetworkBlocks.contains(.homeAssistant))

        await haMock.sendLocalNetworkPermission([.homeAssistant])
        await waitUntil { store.effectiveLocalNetworkBlocks.contains(.homeAssistant) }

        // When Home Assistant genuinely reconnects through `DualSourceHomeProvider`, its
        // `.connected` status clears the HA TCC block.
        await haMock.sendStatus(.connected)
        await waitUntil { !store.effectiveLocalNetworkBlocks.contains(.homeAssistant) }
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(store.panelHealth == .ok)
        }

        // Xiaomi LAN blocked while Xiaomi Cloud is still `.connecting` reports only HA available;
        // once Xiaomi Cloud reaches `.connected`, panelHealth reports cloud fallback; when Xiaomi
        // Cloud disconnects again, it reverts to reporting only HA available.
        await miMock.sendLocalNetworkPermission([.xiaomiLAN])
        await waitUntil { store.effectiveLocalNetworkBlocks.contains(.xiaomiLAN) }
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(store.panelHealth == .degraded(reason: "米家局域网直连权限受阻，当前仅 Home Assistant 可用"))
        }

        await miMock.sendStatus(.connected)
        await waitUntil { store.sourceStatuses[.xiaomiCloud] == .connected }
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(store.panelHealth == .degraded(reason: "米家局域网直连权限受阻，已回退云端"))
        }

        await miMock.sendStatus(.disconnected("HTTP 502"))
        await waitUntil { store.sourceStatuses[.xiaomiCloud] == .disconnected("HTTP 502") }
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(store.panelHealth == .degraded(reason: "米家局域网直连权限受阻，当前仅 Home Assistant 可用"))
        }
    }

    @MainActor
    @Test("HomeStore wires setNetworkSatisfiedForResume into HAWebSocketProvider so offline -1009 is not misclassified as Local Network TCC block")
    func homeStoreNetworkSatisfiedGatingInHAProvider() async throws {
        let suite = "test.ha.net_satisfied.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        defer { store.stop() }

        store.setNetworkSatisfiedForResume(false)
        let haProvider = store.makeHAProvider(baseURLString: "http://192.168.1.50:8123", token: "ha-tok")
        let offlineErr = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        await haProvider.setTestSeams(
            connectOverride: { .failedBeforeAuth(offlineErr) },
            reconnectSleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )

        let stream = haProvider.events()
        var iterator = stream.makeAsyncIterator()
        var sawLocalNetworkBlockedWhileOffline = false
        for _ in 0..<2 {
            guard let event = await iterator.next() else { break }
            if case .localNetworkPermissionChanged(let blocked) = event, blocked.contains(.homeAssistant) {
                sawLocalNetworkBlockedWhileOffline = true
            }
            if case .statusChanged(.disconnected) = event { break }
        }
        #expect(sawLocalNetworkBlockedWhileOffline == false)

        store.setNetworkSatisfiedForResume(true)
        await haProvider.refreshNow()
        var sawLocalNetworkBlockedWhenOnline = false
        for _ in 0..<4 {
            guard let event = await iterator.next() else { break }
            if case .localNetworkPermissionChanged(let blocked) = event, blocked.contains(.homeAssistant) {
                sawLocalNetworkBlockedWhenOnline = true
                break
            }
        }
        #expect(sawLocalNetworkBlockedWhenOnline == true)
        await haProvider.shutdown()
    }

    @MainActor
    @Test("Unknown network reachability does not classify Home Assistant LAN or .local -1009 failures as Local Network TCC block until reachability is confirmed")
    func unknownNetworkReachabilityDoesNotClassifyHAFailureAsLocalNetworkBlock() async throws {
        let suite = "test.ha.net_unknown.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        defer { store.stop() }

        // Notice: `store.setNetworkSatisfiedForResume(...)` has NEVER been called yet (reachability is unknown).
        let haProvider = store.makeHAProvider(baseURLString: "http://homeassistant.local:8123", token: "ha-tok")
        let offlineErr = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        await haProvider.setTestSeams(
            connectOverride: { .failedBeforeAuth(offlineErr) },
            reconnectSleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )

        let stream = haProvider.events()
        var iterator = stream.makeAsyncIterator()
        var sawBlockedWhileUnknown = false
        var unknownDisconnectMessage: String?
        for _ in 0..<4 {
            guard let event = await iterator.next() else { break }
            if case .localNetworkPermissionChanged(let blocked) = event, blocked.contains(.homeAssistant) {
                sawBlockedWhileUnknown = true
            }
            if case .statusChanged(.disconnected(let msg)) = event {
                unknownDisconnectMessage = msg
                break
            }
        }
        #expect(sawBlockedWhileUnknown == false)
        if let unknownDisconnectMessage {
            #expect(!unknownDisconnectMessage.contains("隐私与安全性") && !unknownDisconnectMessage.contains("Privacy & Security"))
        }

        // Once NWPathMonitor reports satisfied (even though isNetworkSatisfiedForResume defaulted to true),
        // HomeStore records known reachability = true and subsequent -1009 classifies as Local Network block.
        store.setNetworkSatisfiedForResume(true)
        await haProvider.refreshNow()
        var sawBlockedOnceKnownOnline = false
        for _ in 0..<4 {
            guard let event = await iterator.next() else { break }
            if case .localNetworkPermissionChanged(let blocked) = event, blocked.contains(.homeAssistant) {
                sawBlockedOnceKnownOnline = true
                break
            }
            if case .statusChanged(.disconnected) = event { break }
        }
        #expect(sawBlockedOnceKnownOnline == true)
        await haProvider.shutdown()

        // Direct HAWebSocketProvider without an injected reachability oracle also treats reachability as unknown.
        let standaloneProvider = HAWebSocketProvider(
            baseURLString: "http://192.168.1.50:8123",
            token: "ha-tok",
            allowsToken: { _ in true }
        )
        await standaloneProvider.setTestSeams(
            connectOverride: { .failedBeforeAuth(offlineErr) },
            reconnectSleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
        let standaloneStream = standaloneProvider.events()
        var standaloneIterator = standaloneStream.makeAsyncIterator()
        var standaloneSawBlocked = false
        for _ in 0..<4 {
            guard let event = await standaloneIterator.next() else { break }
            if case .localNetworkPermissionChanged(let blocked) = event, blocked.contains(.homeAssistant) {
                standaloneSawBlocked = true
            }
            if case .statusChanged(.disconnected) = event { break }
        }
        #expect(standaloneSawBlocked == false)
        await standaloneProvider.shutdown()
    }

    @MainActor
    @Test("Expired Xiaomi account immediately switches paired cards and commands to HA while healthy accounts stay on Mi Cloud")
    func expiredXiaomiAccountSwitchesPairedCardsAndCommandsToHA() async throws {
        let suite = "test.dual.expired_acc_handoff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let session1 = MiSession(
            userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-1", serviceToken: "tok-cn", region: "cn"
        )
        let session2 = MiSession(
            userId: "20020002", cUserId: "c-de", ssecurity: "ssec-2", serviceToken: "tok-de", region: "de"
        )
        let account1 = MiAccount(session: session1)
        let account2 = MiAccount(session: session2)
        let studyMiDID = "2234567890"
        let studyHAID = "ha-study-light"
        let hallMiDID = "3234567890"
        let hallHAID = "ha-hall-light"

        let api1 = StubMiCloudAPI(
            devices: [
                MiDeviceRecord(did: did, name: "客厅吸顶灯", model: "yeelink.light.ceiling22", isOnline: true),
                MiDeviceRecord(did: hallMiDID, name: "玄关灯", model: "yeelink.light.ceiling22", isOnline: true),
            ],
            rooms: [MiRoom(id: "r1", name: "客厅", dids: [did, hallMiDID], homeId: "h1", homeName: "家")],
            values: [
                MiotFixtures.key(did, 2, 1): .bool(false),
                MiotFixtures.key(hallMiDID, 2, 1): .bool(false),
            ]
        )
        let api2 = StubMiCloudAPI(
            devices: [
                MiDeviceRecord(did: studyMiDID, name: "书房吸顶灯", model: "yeelink.light.ceiling22", isOnline: true),
                MiDeviceRecord(did: "de-light-2", name: "客卧吸顶灯", model: "yeelink.light.ceiling22", isOnline: true),
            ],
            rooms: [MiRoom(id: "r2", name: "书房", dids: [studyMiDID, "de-light-2"], homeId: "h2", homeName: "Office")],
            values: [
                MiotFixtures.key(studyMiDID, 2, 1): .bool(false),
                MiotFixtures.key("de-light-2", 2, 1): .bool(false),
            ]
        )
        let miAccounts = MiAccountsProvider(
            accounts: [account1, account2],
            apiFactory: { session in session.userId == session1.userId ? api1 : api2 },
            specSource: StubSpecSource(),
            localClientFactory: { nil },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            followUpDelay: .zero,
            selectedHomeLoader: { nil },
            clearSelectedHome: {}
        )

        // `haID` starts offline on HA and pinned to Xiaomi Cloud so tie-breakers + pin would keep
        // Xiaomi winning if expired candidates were merely marked offline; `hallHAID` is online on HA
        // and pinned to Xiaomi Cloud so commands can be dispatched right after failover.
        let haLivingOffline = light(
            id: haID,
            name: "客厅吸顶灯",
            roomID: "ha-living",
            roomName: "客厅",
            entityId: "light.living_ceiling",
            online: false
        )
        let haHallOnline = light(
            id: hallHAID,
            name: "玄关灯",
            roomID: "ha-living",
            roomName: "客厅",
            entityId: "light.hall_ceiling",
            online: true
        )
        let haStudyOnline = light(
            id: studyHAID,
            name: "书房吸顶灯",
            roomID: "ha-study",
            roomName: "书房",
            entityId: "light.study_ceiling",
            online: true
        )
        let haHome = home(
            [haLivingOffline, haHallOnline, haStudyOnline],
            identities: [
                haID: DeviceSourceIdentity(
                    dids: [did],
                    model: "yeelink.light.ceiling22",
                    name: "客厅吸顶灯",
                    roomName: "客厅",
                    kindTag: .light
                ),
                hallHAID: DeviceSourceIdentity(
                    dids: [hallMiDID],
                    model: "yeelink.light.ceiling22",
                    name: "玄关灯",
                    roomName: "客厅",
                    kindTag: .light
                ),
                studyHAID: DeviceSourceIdentity(
                    dids: [studyMiDID],
                    model: "yeelink.light.ceiling22",
                    name: "书房吸顶灯",
                    roomName: "书房",
                    kindTag: .light
                ),
            ]
        )
        let haMock = MockHomeProvider(snapshot: haHome)
        let store = HomeStore(
            dualSource: (homeAssistant: haMock, xiaomiCloud: miAccounts),
            defaultsSuiteName: suite
        )
        defer { store.stop() }

        await waitUntil {
            store.connectedBackends == Set([.homeAssistant, .xiaomiCloud])
                && store.devices.count == 4
        }
        store.pinDeviceSource(haID, to: .xiaomiCloud)
        store.pinDeviceSource(hallHAID, to: .xiaomiCloud)
        store.pinDeviceSource(studyHAID, to: .xiaomiCloud)
        await waitUntil {
            store.deviceBackend(for: haID) == .xiaomiCloud
                && store.deviceBackend(for: hallHAID) == .xiaomiCloud
                && store.deviceBackend(for: studyHAID) == .xiaomiCloud
                && store.deviceBackend(for: "de-light-2") == .xiaomiCloud
        }

        // Trigger `.sessionExpired` on `account1` via a control write on `hallHAID`.
        await api1.setSetPropsFailure(.sessionExpired)
        let hallBefore = try #require(store.devices.first { $0.id == hallHAID })
        _ = await store.togglePrimary(hallBefore)?.value
        let api1CallsAfterRejection = await api1.setPropsCalls.count
        #expect(api1CallsAfterRejection == 1)

        // Both paired cards on `account1` must immediately route to HA without waiting for grace,
        // even `haID` whose HA copy is offline and pinned to `.xiaomiCloud`.
        await waitUntil(timeout: .seconds(2)) {
            store.deviceBackend(for: haID) == .homeAssistant
                && store.deviceBackend(for: hallHAID) == .homeAssistant
        }
        #expect(store.deviceBackend(for: studyHAID) == .xiaomiCloud)
        #expect(store.deviceBackend(for: "de-light-2") == .xiaomiCloud)

        // Subsequent command on `hallHAID` goes straight to HA (`light.hall_ceiling`), never `api1`.
        let hallAfter = try #require(store.devices.first { $0.id == hallHAID })
        _ = await store.togglePrimary(hallAfter)?.value
        let haCommands = await haMock.executedCommands
        #expect(haCommands.contains(.setLightPower(entityId: "light.hall_ceiling", isOn: true)))
        #expect(await api1.setPropsCalls.count == api1CallsAfterRejection)

        // Healthy `account2` paired and unpaired devices continue routing commands to `api2`.
        let studyCard = try #require(store.devices.first { $0.id == studyHAID })
        _ = await store.togglePrimary(studyCard)?.value
        let guestCard = try #require(store.devices.first { $0.id == "de-light-2" })
        _ = await store.togglePrimary(guestCard)?.value
        let api2Targets = await api2.setPropsCalls.flatMap { $0.map(\.did) }
        #expect(api2Targets.contains(studyMiDID))
        #expect(api2Targets.contains("de-light-2"))
    }
}
