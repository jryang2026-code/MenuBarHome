import Foundation

// MARK: - Out-of-process adapter rows (ADR-0026)
//
// An optional adapter (the TV bridge) reports `adapter:<adapterId>:<nativeId>` rows. They are appended
// after the built-in rows and never take one over (ADR-0024 §5.3): a Home Assistant or Xiaomi row with
// the same id or the same normalized name keeps the card and its write route.

extension HomeStore {
    public static let adapterDevicePrefix = "adapter:"

    public static func isAdapterDeviceId(_ id: String) -> Bool {
        id.hasPrefix(adapterDevicePrefix)
    }

    /// True for rows whose writes never need the Xiaomi Home session (the LG LAN client, adapters).
    func servedWithoutMiSession(_ device: SmartDevice) -> Bool {
        lgClientServes(device) || Self.isAdapterDeviceId(device.id)
    }

    /// Replaces every adapter row. An empty list removes them, so turning an adapter off clears the panel.
    /// `hardwareIds` maps a row id to the MACs the adapter reported for it.
    public func setAdapterDevices(_ incoming: [SmartDevice], hardwareIds: [String: [String]] = [:]) {
        let next = incoming.filter { Self.isAdapterDeviceId($0.id) }
        guard next != adapterDevices || hardwareIds != adapterHardwareIds else { return }
        adapterDevices = next
        adapterHardwareIds = hardwareIds
        refreshGenericCameraCards()
    }

    /// The adapter rows to show next to `native`, minus any a built-in row already covers.
    func adapterCards(excluding native: [SmartDevice]) -> [SmartDevice] {
        guard !adapterDevices.isEmpty, homeBackend != .demo, !isIdentityUncertain,
              capabilitySelection.enabledCategories.contains(.tv) else { return [] }
        return Self.nonHijackingAdapterRows(
            adapterDevices, builtIn: native, adapterMACs: adapterHardwareIds, builtInMACs: builtInHardwareIds
        ).map { row in
            var row = row
            if let room = rooms.first(where: { $0.name == row.roomName }) { row.roomId = room.id }
            return row
        }
    }

    /// ADR-0024 §5.3: the built-in source always wins a duplicate. A row is a duplicate when a built-in
    /// row has its id, the same normalized TV name, or the same MAC: in `builtInMACs` (pairing
    /// evidence) or inside the built-in id itself (`…_aabbccddeeff`).
    public static func nonHijackingAdapterRows(
        _ adapter: [SmartDevice], builtIn: [SmartDevice],
        adapterMACs: [String: [String]] = [:], builtInMACs: [String: [String]] = [:]
    ) -> [SmartDevice] {
        let builtInRows = builtIn.filter { !isAdapterDeviceId($0.id) }
        let ids = Set(builtInRows.map(\.id))
        let tvNames = Set(builtInRows.compactMap { device -> String? in
            guard case .tv = device.kind else { return nil }
            return DeviceIdentityNormalizer.normalizedToken(device.name)
        })
        let knownMACs = Set(builtInRows.flatMap { builtInMACs[$0.id] ?? [] }.compactMap(DeviceIdentityNormalizer.macAddress(from:)))
        let hexIds = builtInRows.map { $0.id.lowercased().filter(\.isHexDigit) }
        return adapter.filter { row in
            guard !ids.contains(row.id), !tvNames.contains(DeviceIdentityNormalizer.normalizedToken(row.name)) else { return false }
            let macs = (adapterMACs[row.id] ?? []).compactMap(DeviceIdentityNormalizer.macAddress(from:))
            return !macs.contains { mac in knownMACs.contains(mac) || hexIds.contains { $0.contains(mac) } }
        }
    }
}
