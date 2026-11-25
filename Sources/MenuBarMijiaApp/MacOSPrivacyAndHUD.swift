import AppKit
import SwiftUI

struct HotkeyHUDState: Equatable, Sendable {
    enum Result: Equatable, Sendable { case on, off, failed }
    var title: String
    var result: Result
    var generation: UInt64
}

func hotkeyHUDScreenIndex(mouseLocation: CGPoint, screenFrames: [CGRect]) -> Int? {
    screenFrames.firstIndex { $0.contains(mouseLocation) }
}

enum HotkeyHUDTiming { static let displayDuration: Duration = .milliseconds(1_200) }

@MainActor
final class ScreenSharingPrivacy {
    static let storageKey = "hide_from_screen_sharing"
    static let shared = ScreenSharingPrivacy()

    private let defaults: UserDefaults
    private let windows = NSHashTable<NSWindow>.weakObjects()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func register(_ window: NSWindow) {
        windows.add(window)
        window.sharingType = defaults.bool(forKey: Self.storageKey) ? .none : .readOnly
    }

    func setHidden(_ hidden: Bool) {
        defaults.set(hidden, forKey: Self.storageKey)
        for window in windows.allObjects {
            window.sharingType = hidden ? .none : .readOnly
        }
    }
}

@MainActor
final class HotkeyHUDController {
    static let shared = HotkeyHUDController()
    private(set) var state: HotkeyHUDState?
    private(set) var window: NSPanel?
    private(set) var dismissTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private let sleep: @MainActor (Duration) async throws -> Void
    private let sharingPrivacy: ScreenSharingPrivacy

    init(
        sharingPrivacy: ScreenSharingPrivacy = .shared,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sharingPrivacy = sharingPrivacy
        self.sleep = sleep
    }

    func show(title: String, result: HotkeyHUDState.Result, screen: NSScreen? = nil) {
        generation &+= 1
        let currentGeneration = generation
        let state = HotkeyHUDState(title: title, result: result, generation: currentGeneration)
        self.state = state
        let panel = window ?? makeWindow()
        window = panel
        panel.contentView = NSHostingView(rootView: HotkeyHUDView(state: state))
        panel.setFrame(frame(for: screen), display: true)
        panel.orderFrontRegardless()
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self, sleep] in
            try? await sleep(HotkeyHUDTiming.displayDuration)
            guard !Task.isCancelled, self?.generation == currentGeneration else { return }
            self?.window?.orderOut(nil)
            self?.state = nil
        }
    }

    func makeWindow() -> NSPanel {
        let panel = HotkeyHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 42), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        sharingPrivacy.register(panel)
        return panel
    }

    private func frame(for screen: NSScreen?) -> NSRect {
        let visible = (screen ?? preferredScreen())?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: visible.maxX - 236, y: visible.maxY - 56, width: 220, height: 42)
    }

    private func preferredScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let index = hotkeyHUDScreenIndex(mouseLocation: NSEvent.mouseLocation, screenFrames: screens.map(\.frame)) {
            return screens[index]
        }
        return NSScreen.main ?? screens.first
    }
}

private final class HotkeyHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
