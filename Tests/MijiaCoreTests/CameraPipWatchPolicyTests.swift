import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

@Suite("CameraPipWatchPolicy & HomeStore PiP watch preferences (P1-2 PR B)")
struct CameraPipWatchPolicyTests {
    @Test("Auto-open is OFF by default for doorbell and alarm events")
    func autoOpenOffByDefault() {
        for kind in CameraEvent.Kind.allCases {
            #expect(!CameraPipWatchPolicy.shouldAutoOpen(
                eventKind: kind,
                cameraOptIn: false,
                globalDoorbellAutoPopup: false,
                isScreenLocked: false,
                isFocusActive: false
            ))
        }
    }

    @Test("Per-camera opt-in respects Focus/DND (#475): doorbell never suppressed, alarm suppressed when Focus quiets non-safety")
    func focusAndDndPolicy() {
        let quietFocus = FocusFilterProfile(
            isEnabled: true,
            suppressNonSafetyNotifications: true,
            focusModeName: "睡眠"
        )

        // Doorbell is NEVER suppressed even under a quiet Focus filter.
        #expect(CameraPipWatchPolicy.shouldAutoOpen(
            eventKind: .doorbell,
            cameraOptIn: true,
            isScreenLocked: false,
            isFocusActive: true,
            focusFilter: quietFocus
        ))

        // Motion/person/package alarm events ARE suppressed when Focus quiets non-safety notifications.
        for kind in [CameraEvent.Kind.motion, .person, .package] {
            #expect(!CameraPipWatchPolicy.shouldAutoOpen(
                eventKind: kind,
                cameraOptIn: true,
                isScreenLocked: false,
                isFocusActive: true,
                focusFilter: quietFocus
            ))
            // Allowed when Focus is inactive.
            #expect(CameraPipWatchPolicy.shouldAutoOpen(
                eventKind: kind,
                cameraOptIn: true,
                isScreenLocked: false,
                isFocusActive: false,
                focusFilter: quietFocus
            ))
        }

        // Screen lock always blocks auto-open.
        #expect(!CameraPipWatchPolicy.shouldAutoOpen(
            eventKind: .doorbell,
            cameraOptIn: true,
            isScreenLocked: true,
            isFocusActive: false
        ))
    }

    @Test("Pinned switches sanitize to at most 2 unique IDs")
    func pinnedSwitchesSanitization() {
        #expect(CameraPipWatchPolicy.sanitizePinnedSwitchIDs(["a", "b", "c", "a"]) == ["a", "b"])
        #expect(CameraPipWatchPolicy.sanitizePinnedSwitchIDs([" ", "sw.1", "sw.1", "sw.2"]) == ["sw.1", "sw.2"])
    }

    @Test("Portrait doorbell model detection matches doorbell and cateye models")
    func portraitDoorbellDetection() {
        #expect(CameraPipWatchPolicy.isPortraitDoorbell(model: "xiaomi.doorbell.3s", name: "Front"))
        #expect(CameraPipWatchPolicy.isPortraitDoorbell(model: "madv.cateye.mjj2", name: "Entry"))
        #expect(CameraPipWatchPolicy.isPortraitDoorbell(model: "generic.cam", name: "入户门铃"))
        #expect(!CameraPipWatchPolicy.isPortraitDoorbell(model: "isa.camera.hlc7", name: "Living Room"))
    }

    @MainActor
    @Test("HomeStore persists per-camera auto-open opt-in and max 2 pinned switches, and routes auto-open events")
    func homeStorePerCameraOptInAndPinnedSwitches() {
        let ud = InMemoryUserDefaults()

        let store = HomeStore(provider: DemoHomeProvider(), defaults: ud)
        let cam = SmartDevice(
            id: "cam.front",
            name: "Front Doorbell",
            roomId: "entry",
            roomName: "Entry",
            model: "xiaomi.doorbell.3s",
            isOnline: true,
            kind: .camera(CameraSpec(
                entityId: "camera.front",
                isOn: true,
                nightShot: nil,
                availableNightShots: [],
                motionDetectionEntityId: nil,
                isMotionDetectionOn: nil,
                streamEntityId: nil
            ))
        )
        let light1 = SmartDevice(
            id: "light.entry",
            name: "Entry Light",
            roomId: "entry",
            roomName: "Entry",
            model: "yeelink.light.color",
            isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.entry",
                isOn: false,
                brightnessPercent: 50,
                colorTempKelvin: nil,
                minKelvin: 2700,
                maxKelvin: 6500,
                currentEffect: nil,
                availableEffects: []
            ))
        )
        let plug1 = SmartDevice(
            id: "plug.porch",
            name: "Porch Plug",
            roomId: "entry",
            roomName: "Entry",
            model: "cuco.plug.cp1",
            isOnline: true,
            kind: .plug(PlugSpec(
                switchEntityId: "switch.porch",
                isOn: false,
                powerWatts: nil,
                childLockEntityId: nil,
                isChildLocked: false
            ))
        )
        let light2 = SmartDevice(
            id: "light.hall",
            name: "Hall Light",
            roomId: "entry",
            roomName: "Entry",
            model: "yeelink.light.color",
            isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.hall",
                isOn: true,
                brightnessPercent: 80,
                colorTempKelvin: nil,
                minKelvin: 2700,
                maxKelvin: 6500,
                currentEffect: nil,
                availableEffects: []
            ))
        )
        store.devices = [cam, light1, plug1, light2]

        // Default is OFF.
        #expect(!store.isCameraPipAutoOpenEnabled(for: cam.id))
        var openedIds: [String] = []
        store.onDoorbellRing = { resp in
            if let id = resp.cameraDeviceId { openedIds.append(id) }
        }
        #expect(!store.handleCameraAutoOpenEvent(cameraId: cam.id, kind: .motion))
        #expect(openedIds.isEmpty)

        // Opt in for cam.front -> motion opens when Focus is off, suppressed when Focus quiets non-safety.
        store.setCameraPipAutoOpen(true, for: cam.id)
        #expect(store.isCameraPipAutoOpenEnabled(for: cam.id))
        let quietFocus = FocusFilterProfile(isEnabled: true, suppressNonSafetyNotifications: true, focusModeName: "睡眠")
        #expect(!store.handleCameraAutoOpenEvent(cameraId: cam.id, kind: .motion, isFocusActive: true, focusFilter: quietFocus))
        #expect(store.handleCameraAutoOpenEvent(cameraId: cam.id, kind: .doorbell, isFocusActive: true, focusFilter: quietFocus))
        #expect(openedIds == [cam.id])

        // Pinning switches caps at 2 (FIFO replacement on 3rd).
        store.toggleCameraPipPinnedSwitch(light1.id, forCamera: cam.id)
        store.toggleCameraPipPinnedSwitch(plug1.id, forCamera: cam.id)
        store.toggleCameraPipPinnedSwitch(light2.id, forCamera: cam.id)
        #expect(store.pinnedSwitchDevices(forCamera: cam.id).map(\.id) == [plug1.id, light2.id])

        // Re-load from same UserDefaults verifies persistence.
        let reloaded = HomeStore(provider: DemoHomeProvider(), defaults: ud)
        #expect(reloaded.isCameraPipAutoOpenEnabled(for: cam.id))
        #expect(reloaded.cameraPipPinnedSwitchIds[cam.id] == [plug1.id, light2.id])
    }
}
