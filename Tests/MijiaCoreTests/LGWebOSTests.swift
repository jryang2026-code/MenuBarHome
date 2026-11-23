import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

struct LGWebOSTests {
    @Test("LGWebOSProtocol builds valid SSAP registration and Wake-on-LAN packets")
    func protocolPacketsAndParsing() throws {
        let regJSON = LGWebOSProtocol.registrationPacket(id: "register_0", clientKey: "test-client-key-123")
        let regObj = try #require(JSONSerialization.jsonObject(with: Data(regJSON.utf8)) as? [String: Any])
        #expect(regObj["type"] as? String == "register")
        #expect(regObj["id"] as? String == "register_0")
        let payload = try #require(regObj["payload"] as? [String: Any])
        #expect(payload["client-key"] as? String == "test-client-key-123")
        #expect(payload["pairingType"] as? String == "PROMPT")

        let promptOutcome = LGWebOSProtocol.parseRegistrationOutcome(
            #"{"type":"response","id":"register_0","payload":{"pairingType":"PROMPT","returnValue":true}}"#
        )
        #expect(promptOutcome == .promptPending)

        let registeredOutcome = LGWebOSProtocol.parseRegistrationOutcome(
            #"{"type":"registered","id":"register_0","payload":{"client-key":"lg-c2-secret-key"}}"#
        )
        #expect(registeredOutcome == .registered(clientKey: "lg-c2-secret-key"))

        let wol = try #require(LGWebOSProtocol.wakeOnLanMagicPacket(macAddress: "aa:bb:cc:dd:ee:ff"))
        #expect(wol.count == 102)
        #expect(Array(wol.prefix(6)) == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(Array(wol[6..<12]) == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        #expect(LGWebOSProtocol.wakeOnLanMagicPacket(macAddress: "invalid") == nil)

        let upnpXML = """
        <root><device>
        <friendlyName>[LG] webOS TV OLED42C2PCA</friendlyName>
        <modelName>OLED42C2PCA</modelName>
        <UDN>uuid:fe42fad6-8f3a-0211-c3b5-363fad426a96</UDN>
        </device></root>
        """
        let discovered = LGWebOSProtocol.parseUPnPDescription(xml: upnpXML, host: "192.168.1.50")
        #expect(discovered.friendlyName == "LG C2 电视")
        #expect(discovered.modelName == "OLED42C2PCA")
        #expect(discovered.uuid == "fe42fad6-8f3a-0211-c3b5-363fad426a96")
    }

    @Test("HomeStore TV controls and voice assistant commands work with LG C2 TV")
    @MainActor
    func storeTVControlsAndAssistant() async throws {
        let lgTV = SmartDevice(
            id: LGWebOSProtocol.deviceId,
            name: "LG C2 电视",
            roomId: "ke_ting",
            roomName: "客厅",
            model: "lg.webos.oled42c2pca",
            isOnline: true,
            kind: .tv(TVSpec(
                mediaEntityId: LGWebOSProtocol.mediaEntityId,
                state: "standby",
                volumePercent: 18,
                isMuted: false,
                isScreenOff: false,
                currentSource: "HDMI 1",
                availableSources: ["HDMI 1", "HDMI 2", "YouTube", "Netflix"]
            ))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [lgTV], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.lg.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()

        // 1. Voice command "打开电视"
        let generationBeforePowerOn = store.snapshotGeneration
        let onPlan = try #require(await store.runAssistantCommand("打开电视"))
        #expect(onPlan.source == .local)
        #expect(onPlan.reply == "已打开LG C2 电视")
        // Wait for command delivery and the provider snapshot to converge rather than asserting
        // a transient optimistic lock immediately after `runAssistantCommand` returns (#304).
        let powerDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (await !mock.executedCommands.contains(.setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: true))
               || store.snapshotGeneration == generationBeforePowerOn),
              ContinuousClock.now < powerDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.devices.first?.isActiveOn == true)

        // 2. Mute, OLED Screen Off, and HDMI Source Switch
        store.toggleTVMute(LGWebOSProtocol.deviceId)
        store.toggleTVScreenOff(LGWebOSProtocol.deviceId)
        store.selectTVSource(LGWebOSProtocol.deviceId, source: "HDMI 2")
        // These controls dispatch tasks; wait for delivery rather than assuming a scheduler delay.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await mock.executedCommands.count < 4, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let executed = await mock.executedCommands
        #expect(executed.contains(.setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: true)))
        #expect(executed.contains(.setSwitch(entityId: LGWebOSProtocol.muteEntityId, isOn: true)))
        #expect(executed.contains(.setSwitch(entityId: LGWebOSProtocol.screenOffEntityId, isOn: true)))
        #expect(executed.contains(.mediaSelectSource(entityId: LGWebOSProtocol.mediaEntityId, source: "HDMI 2")))
    }

    @Test("Disconnected LGWebOSClient throws on socket controls and keeps isConnected false on Wake-on-LAN")
    func disconnectedControlsThrowAndWakeStaysStandby() async throws {
        let emitted = LockedDevices()
        let client = LGWebOSClient(
            config: LGWebOSConfig(isEnabled: true, host: "192.168.1.50", macAddress: "AA:BB:CC:DD:EE:FF"),
            onDeviceUpdated: { emitted.append($0) },
            onClientKeyRegistered: { _ in },
            onSecurityFailure: { _ in }
        )

        let disconnectedCommands: [DeviceCommand] = [
            .setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: false),
            .setSwitch(entityId: LGWebOSProtocol.muteEntityId, isOn: true),
            .setSwitch(entityId: LGWebOSProtocol.screenOffEntityId, isOn: true),
            .mediaSetVolume(entityId: LGWebOSProtocol.mediaEntityId, volumeLevel: 0.35),
            .mediaSelectSource(entityId: LGWebOSProtocol.mediaEntityId, source: "HDMI 2"),
        ]

        for cmd in disconnectedCommands {
            await #expect(throws: HomeProviderError.self) {
                try await client.execute(cmd)
            }
        }
        #expect(emitted.items.isEmpty)

        try await client.execute(.setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: true))
        #expect(await client.isConnectedForTesting == false)
        await client.shutdown()
    }

    @Test("LGWebOSClient LAN discovery only probes private IPv4 and valid .local hosts")
    func lanDiscoveryRejectsNonLANHostHints() async throws {
        let upnpXML = """
        <root><device>
        <friendlyName>[LG] webOS TV OLED42C2PCA</friendlyName>
        <modelName>OLED42C2PCA</modelName>
        <UDN>uuid:fe42fad6-8f3a-0211-c3b5-363fad426a96</UDN>
        </device></root>
        """
        let probed = LockedStrings()
        let probe: @Sendable (String) async -> LGWebOSDiscoveredTV? = { host in
            probed.append(host)
            return LGWebOSProtocol.parseUPnPDescription(xml: upnpXML, host: host)
        }

        for rejected in [
            "8.8.8.8",
            "example.com",
            "localhost",
            "127.0.0.1",
            "192.0.2.10",
            "http://192.168.1.50:1869",
            "192.168.1.50/evil",
            "user@192.168.1.50",
        ] {
            let found = await LGWebOSClient.discoverOnLAN(
                hostHint: rejected,
                arpHostsProvider: { [] },
                probeHost: probe
            )
            #expect(found.isEmpty, "Expected \(rejected) to be rejected without probing")
        }
        #expect(probed.items.isEmpty)

        let allowed = await LGWebOSClient.discoverOnLAN(
            hostHint: " lg-tv.local. ",
            arpHostsProvider: { ["192.168.1.50", "8.8.8.8"] },
            probeHost: probe
        )
        #expect(allowed.map(\.host) == ["lg-tv.local", "192.168.1.50"])
        #expect(probed.items.sorted() == ["192.168.1.50", "lg-tv.local"])
        #expect(LGWebOSClient.discoveryFailureMessage(hostHint: "8.8.8.8").contains("8.8.8.8"))
        #expect(!LGWebOSClient.discoveryFailureMessage(hostHint: "192.168.1.50").contains("192.168.1.50"))
    }

    @Test("HomeStore LG discovery failure message explains rejected host hints including saved fallback")
    @MainActor
    func storeDiscoveryFailureMessageExplainsRejectedHost() async throws {
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [], scenes: [])),
            defaults: InMemoryUserDefaults()
        )
        try await store.waitForTestSnapshot()

        let explicitRejected = store.lgWebOSDiscoveryFailureMessage(hostHint: "8.8.8.8")
        #expect(explicitRejected.contains("8.8.8.8"))

        let allowedHint = store.lgWebOSDiscoveryFailureMessage(hostHint: "192.168.1.50")
        #expect(!allowedHint.contains("192.168.1.50"))

        store.updateLGWebOSConfig(LGWebOSConfig(isEnabled: true, host: "example.com"))
        let savedRejected = store.lgWebOSDiscoveryFailureMessage(hostHint: "   ")
        #expect(savedRejected.contains("example.com"))
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var items: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

private final class LockedDevices: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SmartDevice] = []
    var items: [SmartDevice] { lock.withLock { stored } }
    func append(_ device: SmartDevice) { lock.withLock { stored.append(device) } }
}
