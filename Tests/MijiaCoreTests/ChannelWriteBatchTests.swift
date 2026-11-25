import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChannelWriteBatchTests {
    @Test(arguments: [false, true])
    func fourOutletBatchRechecksScreenLock(lockWhilePending: Bool) async throws {
        let did = "101"
        let model = "test.switch.strip"
        let channelIDs = Array(2...5)
        let services = channelIDs.map { siid in
            MiotService(iid: siid, type: "urn:miot-spec-v2:service:outlet:00007805:test:1", properties: [
                MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:test:1",
                             format: "bool", access: ["read", "write"])
            ])
        }
        let spec = MiotDeviceSpec(type: "urn:miot-spec-v2:device:outlet:0000A002:test:1", services: services)
        let parent = MiDeviceRecord(did: did, name: "Strip", model: model, isOnline: true)
        let channels = channelIDs.map { siid in
            MiDeviceRecord(did: "\(did).s\(siid)", name: "Outlet \(siid)", model: model, isOnline: true,
                           splitParentDid: did, splitSiid: siid)
        }
        let properties = Dictionary(uniqueKeysWithValues: channelIDs.map {
            (MiotPropKey(did: did, siid: $0, piid: 1), JSONValue.bool(true))
        })
        let api = HybridMockCloudAPI(devices: [parent] + channels, rooms: [], props: properties)
        let session = MiSession(userId: "test", cUserId: "test", ssecurity: "test", serviceToken: "test", region: "cn")
        let provider = MiCloudProvider(
            sessionLoader: { session }, apiFactory: { _ in api },
            specSource: HybridMockSpecSource(specs: [model: spec]), localClient: nil,
            pollInterval: .seconds(3600), closedPollInterval: .seconds(3600), selectedHomeLoader: { nil }
        )
        let sleepGate = ScheduledCommandTestSupport.SleepGate()
        await provider.setChannelWriteSleepForTesting { delay in
            #expect(delay == .milliseconds(100))
            await sleepGate.sleep()
        }
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()
        store.blockControlWhileLocked = true
        for channel in channels { store.setJoinsAllOff(true, deviceId: channel.did) }
        #expect(store.allOffTargets.count == 4)
        let allOff = try #require(store.turnAllOff())
        await waitUntil { await provider.pendingChannelWriteCountForTesting(did: did) == 4 && sleepGate.waiting == 1 }
        #expect(await api.setPropsCalls.isEmpty)
        if lockWhilePending { store.setScreenLocked(true) }
        sleepGate.release()

        if lockWhilePending {
            #expect(await allOff.value == .partial)
            #expect(await api.setPropsCalls.isEmpty)
            await provider.shutdown()
            return
        }
        #expect(await allOff.value == .completed)
        let requests = await api.setPropsCalls
        let propertiesWritten = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(propertiesWritten.sorted { $0.siid < $1.siid } == channelIDs.map {
            MiotPropWrite(did: did, siid: $0, piid: 1, value: .bool(false))
        })
        await provider.shutdown()
    }

    @Test
    func acknowledgementMustIdentifyTheChannel() {
        let writes = [2, 3, 4].map { MiotPropWrite(did: "101", siid: $0, piid: 1, value: .bool(false)) }
        let result: JSONValue = .array([
            .object(["did": .string("101"), "siid": .number(3), "piid": .number(1), "code": .number(-1)]),
            .object(["did": .string("101"), "siid": .number(2), "piid": .number(1), "code": .number(0)]),
            .object(["did": .string("102"), "siid": .number(4), "piid": .number(1), "code": .number(0)]),
        ])
        let verdicts = MiCloudClient.propertyVerdicts(result, for: writes)
        #expect(throws: Never.self) { try verdicts[0].get() }
        guard case .failure(.deviceError(let code, _)) = verdicts[1],
              case .failure(.badResponse) = verdicts[2] else {
            Issue.record("Expected one explicit refusal and one missing acknowledgement")
            return
        }
        #expect(code == -1)
    }
}
