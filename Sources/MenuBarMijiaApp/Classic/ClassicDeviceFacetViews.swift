import AppKit
import Foundation
import MijiaCore
import SwiftUI

// MARK: - Shared Detail Controls (#5)

/// A reading value in the drawer's right column. Shared by the cover battery and generic facets.
struct ClassicDetailValueText: View {
    let text: String
    var color: Color = .secondary
    var size: CGFloat = DesignTokens.TypeSize.caption
    var weight: Font.Weight = .medium

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
    }
}

/// A pill button in a detail drawer. `tint` nil keeps the shared accent colour.
struct ClassicDetailPillButton: View {
    let title: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(ClassicPillActionButtonStyle(tintColor: tint ?? .accentColor))
    }
}

/// The glass slider shared by the cover position row and generic sliders.
struct ClassicDetailSliderControl: View {
    let value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let iconName: String
    var iconColor: Color = .secondary
    var trackColors: [Color]
    let formattedValue: String
    let onChange: (Double) -> Void

    var body: some View {
        ClassicLiquidGlassSlider(
            value: Binding(get: { value }, set: onChange),
            in: range,
            step: step,
            iconName: iconName,
            iconColor: iconColor,
            trackFill: LinearGradient(
                colors: trackColors,
                startPoint: .leading,
                endPoint: .trailing
            ),
            formattedValue: formattedValue
        )
    }
}

// MARK: - Generic fallback drawer (#6)

/// The drawer above 更多设置 for a card with no dedicated type. A read-only device says so in
/// words instead of showing controls it cannot offer; a writable one explains why the main switch
/// is missing when no low-risk `on` exists.
struct ClassicGenericDetailDrawer: View {
    var device: SmartDevice? = nil
    var store: HomeStore? = nil
    let spec: GenericSpec
    let statusColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(spec.alerts, id: \.self) { alert in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(alert)
                        .fixedSize(horizontal: false, vertical: true)
                    if let controlID = lockedControlID(for: alert) {
                        Spacer(minLength: 8)
                        Button(L10n.tr("去处理", "Show")) {
                            guard let device else { return }
                            FacetRowFocus.shared.reveal(deviceID: device.id, controlID: controlID)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: DesignTokens.TypeSize.control, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    }
                }
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous)
                        .fill(Color.red.opacity(0.10))
                )
            }
            if spec.isReadOnly {
                explanation(
                    L10n.tr(
                        "该设备只向云端开放读数，不能从这里控制。",
                        "This device only exposes readings and cannot be controlled here."
                    ),
                    systemImage: "lock.fill"
                )
            } else if spec.powerControl == nil, showsAdvancedViewOnlyCopy {
                explanation(
                    L10n.tr(
                        "为安全起见，这类设备默认只能查看。需要调整时，在下方「更多设置」里开启。",
                        "For safety, this kind of device is view-only. Turn changes on under More Settings below when you need to adjust it."
                    ),
                    systemImage: "lock.shield"
                )
            }
        }
    }

    private func explanation(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
            .foregroundStyle(statusColor)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsAdvancedViewOnlyCopy: Bool {
        guard let device, let store else { return false }
        return MiotFacetText.showsAdvancedViewOnlyCopy(
            controls: store.deviceFacets[device.id] ?? [],
            allowsAdvancedWrites: store.allowAdvancedFacetWrites
        )
    }

    private func lockedControlID(for alert: String) -> String? {
        guard let device, let store else { return nil }
        return MiotFacetText.lockedControlID(
            forAlert: alert,
            controls: store.deviceFacets[device.id] ?? [],
            allowsAdvancedWrites: store.allowAdvancedFacetWrites
        )
    }
}

// MARK: - 更多设置

/// Generic drawer rows synthesized from the MIoT spec (#5). The section starts folded, keeps the
/// busiest rows behind a second fold, and shows one notice when advanced writes stay locked.
struct ClassicDeviceFacetSection: View {
    let device: SmartDevice
    let store: HomeStore
    let accent: Color
    let statusColor: Color

    @State private var isExpanded: Bool
    @State private var showsRest: Bool
    /// Portion picked per feeding action; the spec's minimum until the user changes it (#7).
    @State private var portionSelections: [String: Int] = [:]

    init(
        device: SmartDevice,
        store: HomeStore,
        accent: Color,
        statusColor: Color,
        initiallyExpanded: Bool = false,
        initiallyShowsRest: Bool = false
    ) {
        self.device = device
        self.store = store
        self.accent = accent
        self.statusColor = statusColor
        _isExpanded = State(initialValue: initiallyExpanded)
        _showsRest = State(initialValue: initiallyShowsRest)
    }

    private var controls: [FacetControl] {
        store.deviceFacets[device.id] ?? []
    }

    /// High-value facets first, then the rest in spec order. `sorted` is not stable.
    private var ordered: [FacetControl] {
        let all = controls
        return all.filter(\.isHighValue) + all.filter { !$0.isHighValue }
    }

    private var visibleLimit: Int {
        max(1, DeviceProfiles.current.facets.maxVisible)
    }

    private var visible: [FacetControl] {
        Array(ordered.prefix(visibleLimit))
    }

    private var folded: [FacetControl] {
        Array(ordered.dropFirst(visibleLimit))
    }

    private var duplicateTitles: Set<String> {
        var seen: Set<String> = []
        var repeated: Set<String> = []
        for control in ordered {
            let title = FacetLabel.title(control)
            if !seen.insert(title).inserted { repeated.insert(title) }
        }
        return repeated
    }

    var body: some View {
        let focusToken = FacetRowFocus.shared.token
        if controls.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header
                if isExpanded {
                    if showsWriteLockNotice {
                        writeLockNotice
                    }
                    ForEach(visible) { control in
                        row(control)
                    }
                    if !folded.isEmpty {
                        restToggle
                        if showsRest {
                            ForEach(folded) { control in
                                row(control)
                            }
                        }
                    }
                }
            }
            .onChange(of: focusToken) { _, _ in
                revealFocusedRow()
            }
        }
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(L10n.tr("更多设置", "More Settings"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                Text("\(controls.count)")
                    .font(.system(size: DesignTokens.TypeSize.control, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: DesignTokens.TypeSize.control, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.tr("更多设置", "More Settings")))
        .accessibilityValue(Text(isExpanded
            ? L10n.tr("已展开", "Expanded")
            : L10n.tr("已收起", "Collapsed")))
        .panelHelp(L10n.tr("显示辅助控件", "Show auxiliary controls"))
    }

    private var restToggle: some View {
        Button {
            showsRest.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(L10n.tr(
                    "还有 \(folded.count) 项次要设置",
                    "\(folded.count) more settings"
                ))
                .font(.system(size: DesignTokens.TypeSize.control, weight: .medium))
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showsRest ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(_ control: FacetControl) -> some View {
        let title = displayTitle(control)
        let enabled = isEnabled(control)
        let locked = isWriteLocked(control)
        let anchor = FacetRowFocus.anchorID(deviceID: device.id, controlID: control.id)
        rowBody(control, title: title, enabled: enabled, locked: locked)
            .background(alignment: .leading) {
                ClassicFacetRowAnchor(identifier: anchor)
                    .frame(width: 1, height: 1)
            }
    }

    @ViewBuilder
    private func rowBody(
        _ control: FacetControl,
        title: String,
        enabled: Bool,
        locked: Bool
    ) -> some View {
        switch control.kind {
        case .toggle:
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                Spacer(minLength: 8)
                lockedControl(locked) {
                    Toggle("", isOn: Binding(
                        get: { control.isOn ?? false },
                        set: { store.setFacetValue(device.id, controlId: control.id, value: .bool($0)) }
                    ))
                    .labelsHidden()
                    .glassLabelHidden()
                    .accessibilityLabel(Text(title))
                    .toggleStyle(.glass)
                    .controlSize(.mini)
                    .disabled(!enabled)
                }
            }

        case .select:
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                Spacer(minLength: 8)
                lockedControl(locked) {
                    Picker("", selection: Binding(
                        get: { control.value?.intValue ?? control.options.first?.value ?? 0 },
                        set: { store.setFacetValue(device.id, controlId: control.id, value: .number(Double($0))) }
                    )) {
                        ForEach(control.options, id: \.value) { option in
                            Text(MiotValueText.display(option.label)).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text(title))
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(!enabled)
                }
            }

        case .slider:
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                // The range is cloud data: `min...max` traps when it is inverted or not finite,
                // and `max - min` can overflow to `+infinity` on extreme finite bounds.
                if let range = control.range,
                   range.min.isFinite,
                   range.max.isFinite,
                   range.min < range.max,
                   (range.max - range.min).isFinite {
                    lockedControl(locked) {
                        ClassicDetailSliderControl(
                            value: control.numberValue ?? range.min,
                            range: range.min...range.max,
                            step: range.step > 0 ? range.step : nil,
                            iconName: FacetLabel.icon(control.name),
                            iconColor: statusColor,
                            trackColors: [accent.opacity(0.55), accent.opacity(0.92)],
                            formattedValue: FacetLabel.value(control)
                        ) { newValue in
                            store.setFacetValue(device.id, controlId: control.id, value: .number(newValue))
                        }
                        .disabled(!enabled)
                        .accessibilityLabel(Text(title))
                        .frame(maxWidth: .infinity)
                    }
                }
            }

        case .reading:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ClassicDetailValueText(text: FacetLabel.value(control), color: .secondary)
            }

        case .button:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if locked {
                        lockedButton(title)
                    } else {
                        ClassicDetailPillButton(title: title, tint: accent) {
                            store.runFacetAction(
                                device.id,
                                controlId: control.id,
                                portion: portion(for: control)
                            )
                        }
                        .disabled(!enabled)
                    }
                    if let values = portionValues(control) {
                        Picker("", selection: Binding(
                            get: { portion(for: control) },
                            set: { portionSelections[control.id] = $0 }
                        )) {
                            ForEach(values, id: \.self) { value in
                                Text(L10n.format("%@ 份", "%@ portion(s)", "\(value)")).tag(value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .disabled(!enabled)
                        .accessibilityLabel(Text(L10n.tr("投喂份数", "Portions")))
                    }
                    Spacer(minLength: 0)
                }
                if let fedToday = control.fedToday {
                    Text(L10n.format("今日已投喂 %@", "Fed today %@", fedToday))
                        .font(.system(size: DesignTokens.TypeSize.micro, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var showsWriteLockNotice: Bool {
        ordered.contains(where: isWriteLocked)
    }

    private var writeLockNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.tr(
                "部分高级项默认只读，防止误操作",
                "Some advanced controls stay view-only to prevent mistakes."
            ))
            .font(.system(size: DesignTokens.TypeSize.control, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.tr("允许修改…", "Allow changes…")) {
                SettingsWindowOpener.shared.show(tab: .general)
            }
            .buttonStyle(.plain)
            .font(.system(size: DesignTokens.TypeSize.control, weight: .semibold))
            .foregroundStyle(accent)
        }
    }

    /// Dims the control itself. The lock stays at full opacity so the row still explains why.
    @ViewBuilder
    private func lockedControl<Content: View>(_ locked: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
                .opacity(locked ? 0.4 : 1)
            if locked {
                lockGlyph
            }
        }
    }

    /// A flat label. The glass pill reads as tappable even when the button is disabled.
    private func lockedButton(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .opacity(0.4)
            lockGlyph
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(L10n.tr("默认只读", "View only")))
    }

    private var lockGlyph: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func revealFocusedRow() {
        guard FacetRowFocus.shared.deviceID == device.id,
              let controlID = FacetRowFocus.shared.controlID,
              ordered.contains(where: { $0.id == controlID }) else { return }
        isExpanded = true
        if folded.contains(where: { $0.id == controlID }) {
            showsRest = true
        }
    }

    /// The portions the spec's feeding input allows, or nil for an ordinary button.
    private func portionValues(_ control: FacetControl) -> [Int]? {
        let values = control.portionOptions
        return values.isEmpty ? nil : values
    }

    private func portion(for control: FacetControl) -> Int {
        if let chosen = portionSelections[control.id] { return chosen }
        return portionValues(control)?.first ?? 1
    }

    private func displayTitle(_ control: FacetControl) -> String {
        let title = FacetLabel.title(control)
        guard duplicateTitles.contains(title) else { return title }
        return "\(title) · \(FacetLabel.service(control.serviceName))"
    }

    private func isEnabled(_ control: FacetControl) -> Bool {
        guard control.isWritable else { return false }
        return device.isOnline
            && (control.writesByDefault || control.isConfirmedWrite || store.allowAdvancedFacetWrites)
    }

    private func isWriteLocked(_ control: FacetControl) -> Bool {
        MiotFacetText.isAdvancedWriteLocked(control, allowsAdvancedWrites: store.allowAdvancedFacetWrites)
    }
}

private struct ClassicFacetRowAnchor: NSViewRepresentable {
    var identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.setAccessibilityIdentifier(identifier)
    }
}

