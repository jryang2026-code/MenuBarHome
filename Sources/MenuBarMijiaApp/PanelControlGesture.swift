import AppKit
import MijiaCore
import SwiftUI

struct PanelControlGestureAttempt {
    static let holdDuration: Duration = .milliseconds(650)
    /// The ring's linear sweep runs exactly as long as the hold it measures.
    static var holdSeconds: Double {
        let parts = holdDuration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
    static let slideThreshold: CGFloat = 0.92

    let startedAt: ContinuousClock.Instant
    private(set) var finished = false

    init(startedAt: ContinuousClock.Instant) {
        self.startedAt = startedAt
    }

    mutating func cancel() {
        finished = true
    }

    mutating func completeHold(at now: ContinuousClock.Instant) -> Bool {
        guard !finished, now - startedAt >= Self.holdDuration else { return false }
        finished = true
        return true
    }

    mutating func completeSlide(progress: CGFloat) -> Bool {
        guard !finished, progress >= Self.slideThreshold else { return false }
        finished = true
        return true
    }
}

extension View {
    func panelControlGesture(
        _ action: PanelControlAction = .primary,
        for device: SmartDevice,
        store: HomeStore,
        when enabled: Bool = true,
        ringAlignment: Alignment = .center,
        ringDiameter: CGFloat? = nil,
        slideAlignment: Alignment = .center,
        slideWidth: CGFloat? = nil,
        reserveSlideSpace: Bool = false,
        opensCameraLive: Bool = false,
        label: String? = nil,
        onSubmitted: (() -> Void)? = nil
    ) -> some View {
        modifier(PanelControlGesture(
            action: action, device: device, store: store, enabled: enabled, ringAlignment: ringAlignment,
            ringDiameter: ringDiameter, slideAlignment: slideAlignment, slideWidth: slideWidth, reserveSlideSpace: reserveSlideSpace,
            opensCameraLive: opensCameraLive, label: label, onSubmitted: onSubmitted
        ))
    }
}

private struct PanelControlGesture: ViewModifier {
    let action: PanelControlAction
    let device: SmartDevice
    let store: HomeStore
    let enabled: Bool
    let ringAlignment: Alignment
    let ringDiameter: CGFloat?
    let slideAlignment: Alignment
    let slideWidth: CGFloat?
    let reserveSlideSpace: Bool
    let opensCameraLive: Bool
    let label: String?
    let onSubmitted: (() -> Void)?

    func body(content: Content) -> some View {
        if enabled, let level = store.panelConfirmationLevel(for: device, action: action) {
            content
                .padding(.trailing, level == .slide && reserveSlideSpace ? (slideWidth ?? 72) + 4 : 0)
                .frame(minWidth: level == .slide ? (slideWidth ?? 72) : nil)
                .overlay {
                    PanelControlPointerSurface(
                        device: device, store: store, action: action, level: level,
                        ringAlignment: ringAlignment, ringDiameter: ringDiameter,
                        slideAlignment: slideAlignment, slideWidth: slideWidth, opensCameraLive: opensCameraLive,
                        onSubmitted: onSubmitted
                    )
                    .id(level)
                    // Keyboard and VoiceOver activate the underlying button, which still asks explicitly.
                    .accessibilityHidden(true)
                }
                .accessibilityHint(Text(L10n.tr("打开确认对话框", "Opens a confirmation dialog")))
                .panelHelp([label, instruction(level)].compactMap { $0 }.joined(separator: " · "))
        } else {
            content
        }
    }

    private func instruction(_ level: PanelConfirmationLevel) -> String {
        switch level {
        case .hold: L10n.tr("按住 0.65 秒确认", "Hold for 0.65 seconds to confirm")
        case .slide: L10n.tr("向右滑动确认", "Slide right to confirm")
        }
    }
}

private struct PanelControlPointerSurface: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isEditingLayout) private var isEditingLayout
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var attempt: PanelControlGestureAttempt?
    @State private var confirmation: PanelControlConfirmation?
    @State private var holdTask: Task<Void, Never>?
    @State private var session: UUID?
    @State private var ringProgress: CGFloat = 0
    @State private var slideProgress: CGFloat = 0
    @GestureState private var pointerDown = false

    let device: SmartDevice
    let store: HomeStore
    let action: PanelControlAction
    let level: PanelConfirmationLevel
    let ringAlignment: Alignment
    let ringDiameter: CGFloat?
    let slideAlignment: Alignment
    let slideWidth: CGFloat?
    let opensCameraLive: Bool
    let onSubmitted: (() -> Void)?

    private let thumbSize: CGFloat = 22
    private let trackHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            if level == .slide {
                let width = min(geometry.size.width, slideWidth ?? geometry.size.width)
                ZStack(alignment: slideAlignment) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in })
                    track(width: width)
                }
            } else {
                let size = max(3, ringDiameter ?? min(geometry.size.width, geometry.size.height))
                Color.clear
                    .overlay(alignment: ringAlignment) {
                        Circle()
                            .trim(from: 0, to: ringProgress)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: size - 3, height: size - 3)
                            .frame(width: size, height: size)
                            .opacity(confirmation != nil ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($pointerDown) { _, down, _ in down = true }
                            .onChanged(updateHold)
                            .onEnded { _ in reset() }
                    )
            }
        }
        .onChange(of: pointerDown) { _, down in
            if !down { reset() }
        }
        .onChange(of: device.id) { _, _ in cancel() }
        .onChange(of: action) { _, _ in cancel() }
        .onChange(of: store.isControlBlockedByScreenLock) { _, blocked in
            if blocked { cancel() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { cancel() }
        }
        .onChange(of: isEditingLayout) { _, editing in
            if editing { cancel() }
        }
        .onDisappear { reset() }
        // The ring's sweep is the hold's progress readout, so it keeps running under Reduce Motion.
        .transaction { if reduceMotion { $0.disablesAnimations = false } }
    }

    private func track(width: CGFloat) -> some View {
        let travel = max(1, width - trackHeight)
        return ZStack(alignment: .leading) {
            Capsule().fill(.background)
            Capsule().strokeBorder(Color.secondary.opacity(0.4))
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 8)
            Circle()
                .fill(Color.accentColor)
                .overlay {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: thumbSize, height: thumbSize)
                .padding(.leading, 3)
                .offset(x: travel * slideProgress)
        }
        .frame(width: width, height: trackHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pointerDown) { _, down, _ in down = true }
                .onChanged { value in
                    if attempt == nil {
                        begin()
                        if value.startLocation.x > trackHeight { cancel() }
                    }
                    guard confirmation != nil else { return }
                    guard (-12...(trackHeight + 12)).contains(value.location.y) else {
                        cancel()
                        return
                    }
                    slideProgress = min(1, max(0, value.translation.width / travel))
                    if attempt?.completeSlide(progress: slideProgress) == true { confirm() }
                }
                .onEnded { _ in reset() }
        )
    }

    private func begin() {
        let now = ContinuousClock.now
        attempt = PanelControlGestureAttempt(startedAt: now)
        guard isEnabled, !isEditingLayout else { return }
        confirmation = store.beginPanelConfirmation(for: device, action: action, level: level)
        guard confirmation != nil else { return }
        session = PanelTransientUIState.shared.beginDeviceControlGesture(onCancel: cancel)
        guard level == .hold else { return }
        withAnimation(.linear(duration: PanelControlGestureAttempt.holdSeconds)) { ringProgress = 1 }
        holdTask = Task { @MainActor in
            try? await ContinuousClock().sleep(until: now + PanelControlGestureAttempt.holdDuration)
            guard !Task.isCancelled, NSEvent.pressedMouseButtons & 1 != 0,
                  attempt?.completeHold(at: .now) == true else { return }
            confirm()
        }
    }

    private func updateHold(_ value: DragGesture.Value) {
        if attempt == nil { begin() }
        if abs(value.translation.width) > 15 || abs(value.translation.height) > 15 { cancel() }
    }

    private func confirm() {
        guard let confirmation else { return }
        cancel()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        let task = store.performPanelConfirmation(confirmation)
        if opensCameraLive, task != nil, case .camera = device.kind {
            store.openCameraLiveView(device.id)
        }
        onSubmitted?()
    }

    private func cancel() {
        PanelTransientUIState.shared.endDeviceControlGesture(session)
        session = nil
        attempt?.cancel()
        holdTask?.cancel()
        holdTask = nil
        // A released slide springs back to the start and the ring fades out, instead of vanishing.
        withAnimation(AppleMotion.resolve(.control, reduceMotion: reduceMotion)) {
            confirmation = nil
            ringProgress = 0
            slideProgress = 0
        }
    }

    private func reset() {
        cancel()
        attempt = nil
    }
}
