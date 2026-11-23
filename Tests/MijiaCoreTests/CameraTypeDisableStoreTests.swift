import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

/// P3c-CM on the host: closing the camera type hands the live camera cards to the panel once, and a
/// hidden camera answers 「该设备类型已关闭」 without resolving a stream.
@Suite("Camera type disable store", .timeLimit(.minutes(1)))
@MainActor
struct CameraTypeDisableStoreTests {
    static let scope = "mi:region:acct"

    static let camera = SmartDevice(
        id: "cam-hidden", name: "门口摄像机", roomId: "door", roomName: "门口",
        model: "chuangmi.camera.061a01", isOnline: true,
        kind: .camera(CameraSpec(entityId: "miot:cam-hidden:2", isOn: true))
    )

    static let light = SmartDevice(
        id: "light-visible", name: "书房吸顶灯", roomId: "study", roomName: "书房",
        model: "090615.light.ailig1", isOnline: true,
        kind: .light(LightSpec(entityId: "miot:light-visible:2", isOn: true))
    )

    private func makeStore(defaults: UserDefaults = InMemoryUserDefaults()) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.camera, Self.light]))
        let store = HomeStore(provider: mock, defaults: defaults)
        try await store.waitForTestSnapshot()
        store.toastAutoDismissInterval = nil
        var selection = store.capabilitySelection
        selection.enabledConnections.insert(.xiaomiCloud)
        selection.enabledConnectionScopes.insert(Self.scope)
        store.capabilitySelection = selection
        return (store, mock)
    }

    @Test("Only a persisted camera type closure tears down the stream")
    func persistencePrecedesTeardown() async throws {
        let defaults = CameraCapabilityDefaults()
        let (store, provider) = try await makeStore(defaults: defaults)
        try #require(store.persistCapabilitySelection())
        let original = store.capabilitySelection
        let generation = store.capabilityGeneration
        let picked = original.enabledCategories.subtracting([.camera])
        var reported: [[String]] = []
        store.onCameraCategoryDisabled = { cameras in
            reported.append(cameras.map(\.id))
            let data = defaults.data(forKey: CapabilitySelectionStore.storageKey) ?? Data()
            let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            #expect((envelope?["enabledCategories"] as? [String])?.contains(DeviceCategoryID.camera.rawValue) == false)
        }

        _ = try await store.resolveCameraStream(for: Self.camera.id)
        defaults.failCapabilityReadAfterPreflight()
        guard case .refused = store.applyDeviceCategorySelection(picked) else {
            Issue.record("the corrupt envelope must refuse the save")
            return
        }
        #expect(store.capabilitySelection == original)
        #expect(store.capabilityGeneration == generation)
        #expect(store.lastCapabilityMergeDiagnostic == "corrupt_capability_selection")
        #expect(reported.isEmpty)
        #expect(await provider.stoppedCameraIDs.isEmpty)
        _ = try await store.resolveCameraStream(for: Self.camera.id)

        #expect(store.applyDeviceCategorySelection(picked) == .applied)
        #expect(reported == [[Self.camera.id]])
        #expect(store.capabilityGeneration == generation + 1)
        #expect(!store.capabilitySelection.enabledFeatures.contains(.cameraLive))
    }

    private func setCamera(_ enabled: Bool, in store: HomeStore) {
        var selection = store.capabilitySelection
        if enabled { selection.enabledCategories.insert(.camera) } else { selection.enabledCategories.remove(.camera) }
        store.capabilitySelection = selection
    }

    @Test("Closing the camera type reports the camera cards once; other type changes and reopening do not")
    func closingReportsCamerasOnce() async throws {
        let (store, _) = try await makeStore()
        var reports: [[String]] = []
        store.onCameraCategoryDisabled = { reports.append($0.map(\.id)) }

        var selection = store.capabilitySelection
        selection.enabledCategories.remove(.light)
        store.capabilitySelection = selection
        #expect(reports.isEmpty)

        setCamera(false, in: store)
        #expect(reports == [[Self.camera.id]])
        setCamera(false, in: store)
        setCamera(true, in: store)
        #expect(reports == [[Self.camera.id]])
    }

    @Test("A hidden camera answers 「该设备类型已关闭」 and never resolves a stream")
    func hiddenCameraRefusesToOpen() async throws {
        let (store, mock) = try await makeStore()
        setCamera(false, in: store)
        let hidden = CapabilityIndexedDevice(
            id: Self.camera.id, name: Self.camera.name, category: .camera,
            connection: .xiaomiCloud, sourceScope: Self.scope,
            isSourceAvailable: true, upstreamHiddenOrDisabled: false, participatesInAllOff: false,
            safetySignals: [], readKeys: [Self.camera.id], safetyReadKeys: []
        )
        store.applyMiotTypePruneReport(MiotTypePruneReport(
            scope: Self.scope, hiddenIndexedDevices: [hidden],
            hiddenDeviceIds: [Self.camera.id], safetyDevices: []
        ))
        store.devices.removeAll { $0.id == Self.camera.id }
        var opened = 0
        store.onOpenCameraLiveView = { _ in opened += 1 }
        let closed = ControlTargetRejectionReason.categoryDisabled(.camera).userMessage

        store.openCameraLiveView(Self.camera.id)
        #expect(opened == 0)
        #expect(store.toastNotice?.message == closed)

        do {
            _ = try await store.resolveCameraStream(for: Self.camera.id)
            Issue.record("a closed camera type must refuse the stream")
        } catch let error as CapabilityControlBlockedError {
            #expect(error.reason == .categoryDisabled(.camera))
        }
        #expect(await mock.requestedCameraQualities.isEmpty)
        #expect(await mock.executedCommands.isEmpty)
    }
}

private final class CameraCapabilityDefaults: UserDefaults, @unchecked Sendable {
    private let backing = InMemoryUserDefaults()
    private let lock = NSLock()
    private var readsUntilFailure: Int?

    func failCapabilityReadAfterPreflight() {
        lock.withLock { readsUntilFailure = 1 }
    }

    override func object(forKey defaultName: String) -> Any? { backing.object(forKey: defaultName) }
    override func set(_ value: Any?, forKey defaultName: String) { backing.set(value, forKey: defaultName) }
    override func removeObject(forKey defaultName: String) { backing.removeObject(forKey: defaultName) }

    override func data(forKey defaultName: String) -> Data? {
        if defaultName == CapabilitySelectionStore.storageKey {
            let shouldFail = lock.withLock {
                guard let remaining = readsUntilFailure else { return false }
                readsUntilFailure = remaining == 0 ? nil : remaining - 1
                return remaining == 0
            }
            if shouldFail { return Data("corrupt".utf8) }
        }
        return backing.data(forKey: defaultName)
    }
}
