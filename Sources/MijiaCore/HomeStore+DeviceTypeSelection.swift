import Foundation

/// The three ways to pick device types (P4b-M), shared in meaning with Windows
/// `deviceCategorySelectionMode`: a preset when the set matches it exactly, otherwise the user's list.
public enum DeviceTypeSelectionMode: String, CaseIterable, Sendable {
    case allSupportedTypes, lightAndSwitch, custom

    public var title: String {
        switch self {
        case .allSupportedTypes: L10n.tr("全部已支持类型", "All Supported Types")
        case .lightAndSwitch: L10n.tr("只用灯和开关", "Only Lights & Switches")
        case .custom: L10n.tr("自己选", "Choose Myself")
        }
    }

    public static func mode(for categories: Set<DeviceCategoryID>) -> DeviceTypeSelectionMode {
        let delivered = Set(HomeStore.deliveredDeviceCategories)
        let picked = categories.intersection(delivered)
        if picked == delivered { return .allSupportedTypes }
        if picked == DeviceCategoryPreset.lightAndSwitch.categorySet.intersection(delivered) { return .lightAndSwitch }
        return .custom
    }
}

extension DeviceCategoryID {
    /// Picker label; the same wording as Windows `DEVICE_CATEGORY_LABELS`.
    public var selectionTitle: String {
        switch self {
        case .light: L10n.tr("灯", "Lights")
        case .plug: L10n.tr("插座与开关", "Plugs & Switches")
        case .climate: L10n.tr("空调与温控", "Climate")
        case .fan: L10n.tr("风扇、净化与加湿", "Fans, Purifiers & Humidifiers")
        case .cover: L10n.tr("窗帘与门", "Covers & Doors")
        case .appliance: L10n.tr("家电", "Appliances")
        case .fridge: L10n.tr("冰箱", "Fridges")
        case .vacuum: L10n.tr("扫地机", "Robot Vacuums")
        case .speaker: L10n.tr("音箱", "Speakers")
        case .tv: L10n.tr("电视", "TVs")
        case .camera: L10n.tr("摄像机", "Cameras")
        case .sensor: L10n.tr("传感器", "Sensors")
        case .valve: L10n.tr("阀门", "Valves")
        case .generic: L10n.tr("其他设备", "Other Devices")
        }
    }
}

extension SafetySignalKind {
    /// Which alert keeps reading a hidden device; the same wording as Windows `SAFETY_SIGNAL_LABELS`.
    public var selectionTitle: String {
        switch self {
        case .leak: L10n.tr("漏水", "Leak")
        case .smoke: L10n.tr("烟雾", "Smoke")
        case .gas: L10n.tr("燃气", "Gas")
        case .contact: L10n.tr("门窗", "Door/Window")
        case .motion: L10n.tr("人体移动", "Motion")
        case .vibration: L10n.tr("震动", "Vibration")
        case .lock: L10n.tr("门锁", "Locks")
        case .doorbell: L10n.tr("门铃", "Doorbell")
        case .lowBattery: L10n.tr("低电量", "Low Battery")
        case .longRunningPlug: L10n.tr("插座长开", "Plug Left On")
        case .longRunningClimate: L10n.tr("空调长开", "Climate Left On")
        case .highPower: L10n.tr("高功率", "High Power")
        case .starredOffline: L10n.tr("星标离线", "Starred Offline")
        }
    }
}

/// What a device-type change would do, shown before anything is saved (architecture.md §B, §D).
public struct DeviceTypeSelectionImpact: Equatable, Sendable {
    public struct RetainedSafetyDevice: Equatable, Sendable {
        public let id: String, name: String, signals: [SafetySignalKind]
    }

    public let target: Set<DeviceCategoryID>
    public let removedCategories: [DeviceCategoryID]
    /// Cards on the panel now that the change hides.
    public let hiddenCardNames: [String]
    /// Hidden devices the enabled alerts still read, with the alerts that need them.
    public let retainedSafetyDevices: [RetainedSafetyDevice]
    public let verdict: CapabilityDeactivationVerdict

    public var itemsToPause: [AffectedReferenceItem] { verdict.itemsToPause }
    public var pauseItemKeys: Set<String> { Set(verdict.itemsToPause.map(\.pauseKey)) }
    public var showsManualSceneNotice: Bool {
        verdict.softNotices.contains { $0.kind == .manualScenesMayControlHiddenDevices }
    }
}

public enum DeviceTypeSelectionOutcome: Equatable, Sendable {
    case applied, unchanged
    /// Timers, rules or quick actions point at a closing type; ask before pausing them.
    case needsConfirmation(DeviceTypeSelectionImpact)
    case blocked(DeviceTypeSelectionImpact)
    /// Nothing changed: identity reads failed closed, the list was empty, or the save was refused.
    case refused(String)
}

extension HomeStore {
    /// Types the picker offers: delivered on macOS per the capability manifest.
    nonisolated public static var deliveredDeviceCategories: [DeviceCategoryID] {
        DeviceCategoryID.allCases.filter {
            CapabilityManifest.shared.entry(for: .deviceCategory($0)).platforms.status(for: .macos) != .unsupported
        }
    }

    public var deviceTypeSelectionMode: DeviceTypeSelectionMode {
        DeviceTypeSelectionMode.mode(for: capabilitySelection.enabledCategories)
    }

    /// Undelivered types keep their stored value, so the picker can never toggle what it does not list.
    private func deviceCategoryTarget(_ picked: Set<DeviceCategoryID>) -> Set<DeviceCategoryID> {
        let delivered = Set(Self.deliveredDeviceCategories)
        return picked.intersection(delivered).union(capabilitySelection.enabledCategories.subtracting(delivered))
    }

    private func proposedSelection(categories target: Set<DeviceCategoryID>) -> CapabilitySelection {
        var next = capabilitySelection
        // 摄像机实况 only cascades off with the camera type; reopening the type brings it back.
        if target.contains(.camera), !next.enabledCategories.contains(.camera) {
            next.enabledFeatures.insert(.cameraLive)
        }
        next.enabledCategories = target
        return next.normalized(with: .shared)
    }

    public func previewDeviceCategorySelection(_ picked: Set<DeviceCategoryID>) -> DeviceTypeSelectionImpact {
        let target = deviceCategoryTarget(picked)
        let removed = capabilitySelection.enabledCategories.subtracting(target)
        let verdict = evaluateCapabilityDeactivation(proposed: proposedSelection(categories: target), expectedGeneration: nil)
        let policy = effectiveSafetyRetentionPolicy()
        let indexed = Dictionary(currentIndexedDevicesList().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let retained = verdict.partition.hiddenSafetyRetainedDeviceIds.compactMap { id -> DeviceTypeSelectionImpact.RetainedSafetyDevice? in
            guard let device = indexed[id] else { return nil }
            // Same test as `partitionDevices`: 星标离线 only keeps a device the user starred.
            let signals = SafetySignalKind.allCases.filter { signal in
                device.safetySignals.contains(signal) && policy.enabledSignals.contains(signal)
                    && (signal != .starredOffline || policy.starredDeviceIds.contains(id))
            }
            return .init(id: id, name: device.name, signals: signals)
        }
        return DeviceTypeSelectionImpact(
            target: target,
            removedCategories: DeviceCategoryID.allCases.filter(removed.contains),
            hiddenCardNames: devices.filter { removed.contains($0.capabilityCategoryID) }.map(\.name),
            retainedSafetyDevices: retained,
            verdict: verdict
        )
    }

    /// Saves the picked types. Closing a referenced type returns `.needsConfirmation` until the user
    /// confirms that exact list; a refused save restores the previous selection and changes nothing.
    @discardableResult
    public func applyDeviceCategorySelection(
        _ picked: Set<DeviceCategoryID>,
        pauseConfirmed: Bool = false,
        expectedPauseItemKeys: Set<String>? = nil
    ) -> DeviceTypeSelectionOutcome {
        let target = deviceCategoryTarget(picked)
        guard target != capabilitySelection.enabledCategories else { return .unchanged }
        guard !isIdentityUncertain else {
            return .refused(L10n.tr(
                "仍无法读取历史配置或凭据，请检查钥匙串授权后重试",
                "Still unable to read settings or credentials; check Keychain access and try again"
            ))
        }
        guard !target.intersection(Self.deliveredDeviceCategories).isEmpty else {
            return .refused(L10n.tr("至少保留一种设备类型", "Keep at least one device type"))
        }
        let impact = previewDeviceCategorySelection(target)
        if impact.verdict.disposition == .blocked { return .blocked(impact) }
        let saveFailed = L10n.tr("无法保存设备类型选择，已恢复原来的选择，请重试", "Could not save the device types; the previous choice is restored. Try again")
        guard canPersistCapabilitySelection() else { return .refused(saveFailed) }
        if pauseConfirmed {
            // A timer or rule that appeared since the preview re-previews instead of being paused unseen.
            if let expectedPauseItemKeys, !impact.pauseItemKeys.isEmpty, expectedPauseItemKeys != impact.pauseItemKeys {
                return .needsConfirmation(impact)
            }
        } else if impact.verdict.requiresPauseConfirmation {
            return .needsConfirmation(impact)
        }

        let previous = capabilitySelection
        let added = target.subtracting(previous.enabledCategories)
        // Index the live cards first so every write entry answers 「该设备类型已关闭」 for the newly hidden ones.
        if !devices.isEmpty { syncIndexedDevices(from: devices) }
        capabilitySelection = proposedSelection(categories: target)
        capabilityGeneration &+= 1
        guard persistCapabilitySelection() else {
            capabilitySelection = previous
            capabilityGeneration &+= 1
            syncMiotTypePrunePolicy()
            return .refused(saveFailed)
        }
        if !impact.itemsToPause.isEmpty {
            pauseAffectedReferences(impact.itemsToPause, fallbackCapabilities: impact.removedCategories.map(CapabilityID.deviceCategory))
        }
        if !added.isEmpty { revalidatePausedItems() }
        // The Mi and HA read plans pick the new types up on the next round; ask for it now.
        refreshNow()
        return .applied
    }
}
