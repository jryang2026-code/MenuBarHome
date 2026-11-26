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

    /// Replaces every adapter row. An empty list removes them, so turning an adapter off clears the panel.
    public func setAdapterDevices(_ incoming: [SmartDevice]) {
        let next = incoming.filter { Self.isAdapterDeviceId($0.id) }
        guard next != adapterDevices else { return }
        adapterDevices = next
        refreshGenericCameraCards()
    }

    /// The adapter rows to show next to `native`, minus any a built-in row already covers.
    func adapterCards(excluding native: [SmartDevice]) -> [SmartDevice] {
        guard !adapterDevices.isEmpty, homeBackend != .demo, !isIdentityUncertain,
              capabilitySelection.enabledCategories.contains(.tv) else { return [] }
        return Self.nonHijackingAdapterRows(adapterDevices, builtIn: native).map { row in
            var row = row
            if let room = rooms.first(where: { $0.name == row.roomName }) { row.roomId = room.id }
            return row
        }
    }

    /// ADR-0024 §5.3: the built-in source always wins a duplicate.
    public static func nonHijackingAdapterRows(_ adapter: [SmartDevice], builtIn: [SmartDevice]) -> [SmartDevice] {
        let builtInRows = builtIn.filter { !isAdapterDeviceId($0.id) }
        let ids = Set(builtInRows.map(\.id))
        let tvNames = Set(builtInRows.compactMap { device -> String? in
            guard case .tv = device.kind else { return nil }
            return DeviceIdentityNormalizer.normalizedToken(device.name)
        })
        return adapter.filter { row in
            !ids.contains(row.id) && !tvNames.contains(DeviceIdentityNormalizer.normalizedToken(row.name))
        }
    }
}
