import Foundation

extension HomeStore {
    static let genericCameraSourcesKey = "generic_camera_sources_v1"
    private static let genericCameraConsentKey = "generic_camera_plaintext_consent_v1"

    public func genericCamera(for deviceID: String) -> GenericCameraSource? {
        genericCameras.first { $0.deviceID == deviceID }
    }

    var genericCameraCards: [SmartDevice] {
        guard hasCompletedOnboarding, homeBackend != .demo, !isIdentityUncertain,
              capabilitySelection.enabledCategories.contains(.camera) else { return [] }
        return genericCameras.filter(\.isValid).map(\.device)
    }

    func refreshGenericCameraCards() {
        let native = devices.filter { !$0.id.hasPrefix(GenericCameraSource.devicePrefix) }
        guard !genericCameras.isEmpty || native.count != devices.count else { return }
        let next = devicesWithAliases(native + genericCameraCards)
        if devices != next { devices = next }
    }

    public func genericCameraCredentials(_ camera: GenericCameraSource) -> GenericCameraSource.Credentials? {
        camera.credentials(vault: credentialVault ?? .shared)
    }

    public func hasGenericCameraConsent(_ camera: GenericCameraSource) -> Bool {
        userDefaults.dictionary(forKey: Self.genericCameraConsentKey)?[camera.deviceID] as? String == camera.endpointKey
    }

    public func saveGenericCamera(
        _ camera: GenericCameraSource, credentials: GenericCameraSource.Credentials, confirmedPlaintext: Bool
    ) -> Bool {
        guard camera.isValid, camera.kind != .tapo || !credentials.password.isEmpty,
              !camera.requiresPlaintextConsent || confirmedPlaintext || hasGenericCameraConsent(camera) else { return false }
        var next = genericCameras
        if let index = next.firstIndex(where: { $0.id == camera.id }) {
            next[index] = camera
        } else {
            next.append(camera)
        }
        guard let data = try? JSONEncoder().encode(next),
              camera.storeCredentials(credentials, vault: credentialVault ?? .shared) else { return false }
        persistGenericCameras(next, data: data, camera: camera, approved: camera.requiresPlaintextConsent)
        return true
    }

    public func removeGenericCamera(_ camera: GenericCameraSource) -> Bool {
        let next = genericCameras.filter { $0.id != camera.id }
        guard let data = try? JSONEncoder().encode(next),
              camera.storeCredentials(nil, vault: credentialVault ?? .shared) else { return false }
        persistGenericCameras(next, data: data, camera: camera, approved: false)
        return true
    }

    private func persistGenericCameras(
        _ next: [GenericCameraSource], data: Data, camera: GenericCameraSource, approved: Bool
    ) {
        if genericCamera(for: camera.deviceID) != nil {
            onGenericCameraChanged?(camera.deviceID)
            rawDeviceNames.removeValue(forKey: camera.deviceID)
        }
        var consent = userDefaults.dictionary(forKey: Self.genericCameraConsentKey) ?? [:]
        consent[camera.deviceID] = approved ? camera.endpointKey : nil
        userDefaults.set(consent, forKey: Self.genericCameraConsentKey)
        userDefaults.set(data, forKey: Self.genericCameraSourcesKey)
        genericCameraRevision &+= 1
        genericCameras = next
        refreshGenericCameraCards()
    }

    public func previewGenericCamera(
        _ camera: GenericCameraSource, onFrame: @escaping @MainActor @Sendable (Data) -> Void
    ) async throws {
        guard genericCameraCards.contains(where: { $0.id == camera.deviceID }),
              let credentials = genericCameraCredentials(camera) else { throw GenericCameraError.invalidConnection }
        _ = try await testGenericCamera(camera, credentials: credentials, confirmedPlaintext: false, onFrame: onFrame)
    }

    /// Uses a separate registration so a Settings test cannot replace an open live window.
    public func testGenericCamera(
        _ camera: GenericCameraSource, credentials: GenericCameraSource.Credentials, confirmedPlaintext: Bool,
        onFrame: (@MainActor @Sendable (Data) -> Void)? = nil
    ) async throws -> Data {
        guard !rejectControlWhileLocked(), homeBackend != .demo else { throw GenericCameraError.invalidConnection }
        let allowPublic = confirmedPlaintext || hasGenericCameraConsent(camera)
        var preview = camera
        preview.id = UUID()
        return try await XiaomiCameraBridge.shared.genericCameraFrame(
            preview, credentials: credentials, allowPublic: allowPublic, onFrame: onFrame
        )
    }
}

private extension GenericCameraSource {
    var device: SmartDevice {
        SmartDevice(
            id: deviceID, name: name, roomId: "", roomName: "", model: kind.title, isOnline: true,
            kind: .camera(CameraSpec(entityId: deviceID, isOn: true, powerWritable: false))
        )
    }
}
