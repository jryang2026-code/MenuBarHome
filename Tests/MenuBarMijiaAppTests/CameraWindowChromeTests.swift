import AppKit
import SwiftUI
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

@Suite("Camera window chrome")
struct CameraWindowChromeTests {
    @Test("Sleep state renders the power toggle unselected")
    func sleepRendersPowerUnselected() {
        L10n.$overrideLanguage.withValue(.zhHans) {
        let asleep = CameraSpec(entityId: "cam", isOn: false, powerWritable: true)
        let off = CameraControlBar(spec: asleep, showsQuality: false, currentQuality: .sd)
        #expect(off.power?.isSelected == false)
        #expect(off.power?.title == "镜头 关")

        let awake = CameraSpec(entityId: "cam", isOn: true, powerWritable: true)
        let on = CameraControlBar(spec: awake, showsQuality: false, currentQuality: .sd)
        #expect(on.power?.isSelected == true)
        #expect(on.power?.title == "镜头 开")
        }
    }

    @Test("Quality shows the current value, and motion is a checkmark rather than a state sentence")
    func qualityAndMoreAreGrouped() {
        L10n.$overrideLanguage.withValue(.zhHans) {
        let spec = CameraSpec(
            entityId: "cam",
            isOn: true,
            nightShot: "Auto",
            availableNightShots: ["Off", "On", "Auto"],
            motionDetectionEntityId: "switch.motion",
            isMotionDetectionOn: true
        )
        let bar = CameraControlBar(spec: spec, showsQuality: true, currentQuality: .hd)
        #expect(bar.qualityMenuTitle == "高清 ▾")
        #expect(bar.qualityItems.filter(\.isSelected).map(\.title) == ["高清"])
        #expect(bar.moreItems.map(\.title) == ["移动侦测", "夜视关", "夜视开", "自动夜视"])
        #expect(bar.moreItems.filter(\.isSelected).map(\.id) == ["motion", "night.Auto"])
        #expect(bar.moreItems.allSatisfy { !$0.title.contains("：") })
        }
    }

    @Test("Dual-lens cameras expose a lens menu instead of a flat row")
    func lensMenuExposesBothLenses() {
        L10n.$overrideLanguage.withValue(.zhHans) {
        let spec = CameraSpec(
            entityId: "cam",
            isOn: true,
            lenses: [
                CameraLens(role: .main, channel: 0),
                CameraLens(role: .secondary, channel: 1),
            ]
        )
        let bar = CameraControlBar(spec: spec, showsQuality: false, currentQuality: .sd)
        #expect(bar.lensMenuTitle == "主镜头 ▾")
        #expect(bar.lensItems.map(\.title) == ["主镜头", "第二镜头"])
        #expect(bar.lensItems.filter(\.isSelected).map(\.id) == ["lens.main"])
        }
    }

    @Test("The camera name keeps at least half the toolbar")
    func titleKeepsHalfTheToolbar() {
        let crowded = CameraTitleBarSplit.split(barWidth: 360, trailingIdeal: 500, spacing: 6)
        #expect(crowded.leadingWidth == 177)
        #expect(crowded.trailingWidth == 177)

        let roomy = CameraTitleBarSplit.split(barWidth: 360, trailingIdeal: 120, spacing: 6)
        #expect(roomy.trailingWidth == 120)
        #expect(roomy.leadingWidth == 234)
    }

    @MainActor
    @Test("The trailing toolbar fits the half reserved at the 360 pt compact width in both languages")
    func trailingToolbarFitsCompactWidth() {
        let reserved = CameraTitleBarSplit.split(barWidth: 360, trailingIdeal: 500, spacing: 6).trailingWidth
        #expect(reserved == 177)

        for language in [AppLanguage.zhHans, AppLanguage.en] {
            L10n.$overrideLanguage.withValue(language) {
            // Same order and spacing as CameraLivePanelView.toolbarTrailing: audio badge, pin,
            // rotate, maximize, overflow menu, close.
            let bar = HStack(spacing: 4) {
                CameraLiveAudioStatusView(status: .videoOnly, isCompact: true, onToggleMute: {})
                CameraHUDGlyph(symbol: "pin.slash")
                CameraHUDGlyph(symbol: "rotate.right")
                CameraHUDGlyph(symbol: "arrow.up.left.and.arrow.down.right")
                Menu {
                    Button("Reconnect") {}
                } label: {
                    CameraHUDGlyph(symbol: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                CameraHUDGlyph(symbol: "xmark")
            }
            .padding(.trailing, 12)
            let width = NSHostingView(rootView: bar).fittingSize.width
            #expect(
                width <= reserved,
                "\(language.rawValue) trailing toolbar is \(width) pt, reserved \(reserved) pt"
            )
            }
        }
    }
}
