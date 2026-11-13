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
}
