import Foundation

extension HomeStore {
    public nonisolated static let defaultDoorbellPopupSeconds = 60
    public static let doorbellPopupSecondsRange = 15...300
    static let recentDoorbellRingLimit = 20
    private nonisolated static let cameraPipPinnedSwitchesKey = "camera_pip_pinned_switches_v1"

    static func loadCameraPipPinnedSwitchIds(from defaults: UserDefaults) -> [String: [String]] {
        guard let data = defaults.data(forKey: cameraPipPinnedSwitchesKey),
              let raw = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return raw.reduce(into: [:]) { acc, pair in
            let sanitized = CameraPipWatchPolicy.sanitizePinnedSwitchIDs(pair.value)
            if !sanitized.isEmpty { acc[pair.key] = sanitized }
        }
    }

    func saveCameraPipPinnedSwitchIds() {
        let cleaned = cameraPipPinnedSwitchIds.reduce(into: [String: [String]]()) { acc, pair in
            let sanitized = CameraPipWatchPolicy.sanitizePinnedSwitchIDs(pair.value)
            if !sanitized.isEmpty { acc[pair.key] = sanitized }
        }
        if cleaned.isEmpty {
            userDefaults.removeObject(forKey: Self.cameraPipPinnedSwitchesKey)
        } else if let data = try? JSONEncoder().encode(cleaned) {
            userDefaults.set(data, forKey: Self.cameraPipPinnedSwitchesKey)
        }
    }

    public func isCameraPipAutoOpenEnabled(for cameraId: String) -> Bool {
        cameraPipAutoOpenDeviceIds.contains(cameraId)
    }

    public func setCameraPipAutoOpen(_ enabled: Bool, for cameraId: String) {
        if enabled {
            cameraPipAutoOpenDeviceIds.insert(cameraId)
        } else {
            cameraPipAutoOpenDeviceIds.remove(cameraId)
        }
    }

    public func pinnedSwitchDevices(forCamera cameraId: String) -> [SmartDevice] {
        let ids = CameraPipWatchPolicy.sanitizePinnedSwitchIDs(cameraPipPinnedSwitchIds[cameraId] ?? [])
        return ids.compactMap { id in
            devices.first(where: { $0.id == id && CameraPipWatchPolicy.isPinnableSwitch($0) })
        }
    }

    public func pinnableSwitchDevices(excludingCamera cameraId: String) -> [SmartDevice] {
        devices.filter { $0.id != cameraId && CameraPipWatchPolicy.isPinnableSwitch($0) }
    }

    public func toggleCameraPipPinnedSwitch(_ switchId: String, forCamera cameraId: String) {
        var current = CameraPipWatchPolicy.sanitizePinnedSwitchIDs(cameraPipPinnedSwitchIds[cameraId] ?? [])
        if let idx = current.firstIndex(of: switchId) {
            current.remove(at: idx)
        } else if current.count < CameraPipWatchPolicy.maxPinnedSwitches {
            current.append(switchId)
        } else {
            current.removeFirst()
            current.append(switchId)
        }
        if current.isEmpty {
            cameraPipPinnedSwitchIds.removeValue(forKey: cameraId)
        } else {
            cameraPipPinnedSwitchIds[cameraId] = current
        }
    }

    /// A press also posts a system notification once the user asked for doorbell reminders at all
    /// (#10). Both switches default off, so the default stays exactly as before: a home that never
    /// turned on the chime or the popup is not notified about rings either.
    public var wantsDoorbellNotification: Bool {
        doorbellChime || doorbellAutoPopup || !cameraPipAutoOpenDeviceIds.isEmpty
    }

    /// Evaluates a doorbell or alarm/detection camera event against per-camera opt-in,
    /// screen-lock, and Focus/DND policy (#475) and triggers top-right auto-open when permitted.
    @discardableResult
    public func handleCameraAutoOpenEvent(
        cameraId: String,
        kind: CameraEvent.Kind,
        isFocusActive: Bool = false,
        focusFilter: FocusFilterProfile = .inactive
    ) -> Bool {
        if kind != .doorbell {
            _ = cameraEventStore.record(cameraID: cameraId, kind: kind, timestamp: Date())
            cameraEventRevision &+= 1
        }
        guard CameraPipWatchPolicy.shouldAutoOpen(
            eventKind: kind,
            cameraOptIn: isCameraPipAutoOpenEnabled(for: cameraId),
            globalDoorbellAutoPopup: doorbellAutoPopup,
            isScreenLocked: isControlBlockedByScreenLock,
            isFocusActive: isFocusActive,
            focusFilter: focusFilter
        ) else {
            return false
        }
        guard let device = devices.first(where: { $0.id == cameraId }),
              device.isOnline, case .camera = device.kind else {
            return false
        }
        let seconds = doorbellPopupSeconds.clamped(to: Self.doorbellPopupSecondsRange)
        onDoorbellRing?(DoorbellResponse(
            cameraDeviceId: device.id,
            playsChime: kind == .doorbell && doorbellChime,
            dismissAfter: .seconds(seconds)
        ))
        return true
    }

    /// Records every press once. The chime and the camera window are separate choices: the chime
    /// plays whenever it is on; the camera opens only when that is on, the screen-lock rule allows
    /// it, and the ringing device has an online camera card (#308).
    func handleDoorbellRing(_ ring: DoorbellRing) {
        guard !recentDoorbellRings.contains(where: { $0.key == ring.key }) else { return }
        let event = cameraEventStore.record(
            cameraID: ring.deviceId,
            kind: .doorbell,
            timestamp: ring.firedAtDate ?? Date()
        )
        cameraEventRevision &+= 1
        if let capture = onDoorbellSnapshot {
            Task { @MainActor [weak self] in
                guard let self, let data = await capture(ring.deviceId) else { return }
                if self.cameraEventStore.attachSnapshot(data, to: event) != nil {
                    self.cameraEventRevision &+= 1
                }
            }
        }
        recentDoorbellRings.insert(ring, at: 0)
        if recentDoorbellRings.count > Self.recentDoorbellRingLimit {
            recentDoorbellRings.removeLast(recentDoorbellRings.count - Self.recentDoorbellRingLimit)
        }
        if wantsDoorbellNotification {
            // Offline cameras and a locked screen still get the banner: it is not a control, and
            // the visitor is at the door either way.
            onDoorbellNotification?(DoorbellNotification(
                ring: ring,
                deviceName: devices.first(where: { $0.id == ring.deviceId })?.name
            ))
        }
        var cameraId: String?
        if CameraPipWatchPolicy.shouldAutoOpen(
            eventKind: .doorbell,
            cameraOptIn: isCameraPipAutoOpenEnabled(for: ring.deviceId),
            globalDoorbellAutoPopup: doorbellAutoPopup,
            isScreenLocked: isControlBlockedByScreenLock,
            isFocusActive: false
        ),
           let device = devices.first(where: { $0.id == ring.deviceId }),
           device.isOnline, case .camera = device.kind {
            cameraId = device.id
        }
        guard cameraId != nil || doorbellChime else { return }
        let seconds = doorbellPopupSeconds.clamped(to: Self.doorbellPopupSecondsRange)
        onDoorbellRing?(DoorbellResponse(cameraDeviceId: cameraId, playsChime: doorbellChime, dismissAfter: .seconds(seconds)))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
