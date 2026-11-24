import Foundation

extension HomeStore {
    public nonisolated static let defaultDoorbellPopupSeconds = 60
    public static let doorbellPopupSecondsRange = 15...300
    static let recentDoorbellRingLimit = 20

    /// A press also posts a system notification once the user asked for doorbell reminders at all
    /// (#10). Both switches default off, so the default stays exactly as before: a home that never
    /// turned on the chime or the popup is not notified about rings either.
    public var wantsDoorbellNotification: Bool { doorbellChime || doorbellAutoPopup }

    /// Records every press once. The chime and the camera window are separate choices: the chime
    /// plays whenever it is on; the camera opens only when that is on, the screen-lock rule allows
    /// it, and the ringing device has an online camera card (#308).
    func handleDoorbellRing(_ ring: DoorbellRing) {
        guard !recentDoorbellRings.contains(where: { $0.key == ring.key }) else { return }
        cameraEventStore.record(
            cameraID: ring.deviceId,
            kind: .doorbell,
            timestamp: ring.firedAtDate ?? Date()
        )
        cameraEventRevision &+= 1
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
        if doorbellAutoPopup, !isControlBlockedByScreenLock,
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
