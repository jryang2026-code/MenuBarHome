import AppKit
import SwiftUI

struct HotkeyHUDState: Equatable, Sendable {
    enum Result: Equatable, Sendable { case on, off, failed }
    var title: String
    var result: Result
    var generation: UInt64
}

enum HotkeyHUDTiming { static let displayDuration: TimeInterval = 1.2 }

enum PanelInputMode {
    static func acceptsHover(isKeyboardNavigating: Bool, mouseMovedSinceNavigation: Bool) -> Bool {
        !isKeyboardNavigating || mouseMovedSinceNavigation
    }
}

enum ScreenSharingPrivacy {
    static let storageKey = "hide_from_screen_sharing"
    static let didChange = Notification.Name("MenuBarMijia.hideFromScreenSharingChanged")

    static func sharingType(hidden: Bool) -> NSWindow.SharingType { hidden ? .none : .readOnly }
    static func apply(hidden: Bool, to windows: [NSWindow]) {
        windows.forEach { $0.sharingType = sharingType(hidden: hidden) }
    }
    static func applyToAppWindows(hidden: Bool, excluding excluded: NSWindow? = nil) {
        apply(hidden: hidden, to: NSApp.windows.filter { $0 !== excluded })
    }
}

@MainActor
final class HotkeyHUDController {
    static let shared = HotkeyHUDController()
    private(set) var state: HotkeyHUDState?
    private var window: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    func show(title: String, result: HotkeyHUDState.Result, screen: NSScreen? = nil) {
        generation &+= 1
        let currentGeneration = generation
        state = HotkeyHUDState(title: title, result: result, generation: currentGeneration)
        let panel = window ?? makeWindow()
        window = panel
        panel.contentView = NSHostingView(rootView: HotkeyHUDView(state: state!))
        panel.setFrame(frame(for: screen ?? NSScreen.main), display: true)
        panel.orderFrontRegardless()
        panel.sharingType = UserDefaults.standard.bool(forKey: ScreenSharingPrivacy.storageKey) ? .none : .readOnly
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(HotkeyHUDTiming.displayDuration))
            guard !Task.isCancelled, self?.generation == currentGeneration else { return }
            self?.window?.orderOut(nil)
            self?.state = nil
        }
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 42), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func frame(for screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: visible.maxX - 236, y: visible.maxY - 56, width: 220, height: 42)
    }
}

private struct HotkeyHUDView: View {
    let state: HotkeyHUDState
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(state.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 14).frame(height: 42)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
    }
    private var symbol: String {
        switch state.result { case .on: "checkmark.circle.fill"; case .off: "power"; case .failed: "exclamationmark.triangle.fill" }
    }
    private var color: Color {
        switch state.result { case .on: .green; case .off: .secondary; case .failed: .orange }
    }
}
