import MijiaCore
import SwiftUI

/// Position, open/stop/close, battery and fault for a cover (window opener, curtain or airer). An
/// airer reads as height with raise/stop/lower (#299). Kept out of `DeviceCardView` so that file
/// stays under the line-count gate (#184). Its slider and buttons render through the shared detail
/// controls, the same ones 更多设置 uses (#5).
struct CoverDetailDrawer: View {
    let device: SmartDevice
    let spec: CoverSpec
    let store: HomeStore
    let accent: Color
    let statusColor: Color
    var theme: PanelTheme = .liquidGlass

    var body: some View {
        let position = Double(spec.positionPercent ?? 0)
        VStack(alignment: .leading, spacing: 8) {
            if let motion = spec.motion.localizedLabel(for: spec.subtype) {
                Text(motion)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            if let fault = spec.faultText, !fault.isEmpty {
                Text(fault)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if spec.positionWritable {
                CoverPositionPanelSlider(
                    device: device, store: store, value: position, accent: accent,
                    statusColor: statusColor, theme: theme,
                    iconName: spec.subtype == .clothesAirer ? "hanger" : "window.vertical.open",
                    label: L10n.tr("开合位置", "Position")
                )
                .disabled(!device.isOnline)
            }
            if spec.canMove || spec.batteryPercent != nil {
                HStack(spacing: 8) {
                    if let open = spec.openDescription {
                        motorButton(open)
                    }
                    if let pause = spec.pauseDescription {
                        motorButton(pause)
                    }
                    if let close = spec.closeDescription {
                        motorButton(close)
                    }
                    if let battery = spec.batteryPercent {
                        Spacer(minLength: 0)
                        DetailValueText(
                            text: L10n.tr("电量 \(battery)%", "Battery \(battery)%"),
                            color: statusColor
                        )
                    }
                }
            }
        }
    }

    private func motorButton(_ description: String) -> some View {
        DetailPillButton(title: Self.actionTitle(description, subtype: spec.subtype), theme: theme) {
            store.setCoverMotor(device.id, description: description)
        }
        .panelControlGesture(.coverMotor(description), for: device, store: store,
                             slideAlignment: .trailing, slideWidth: 64, reserveSlideSpace: true,
                             label: Self.actionTitle(description, subtype: spec.subtype))
        .disabled(!device.isOnline)
    }

    static func actionTitle(_ description: String, subtype: CoverSubtype) -> String {
        let airer = subtype == .clothesAirer
        switch description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "open", "打开": return L10n.tr("打开", "Open")
        case "close", "关闭": return L10n.tr("关闭", "Close")
        case "up", "raise": return airer ? L10n.tr("升", "Raise") : L10n.tr("升起", "Up")
        case "down", "lower": return airer ? L10n.tr("降", "Lower") : L10n.tr("降下", "Down")
        case "pause", "stop", "暂停": return airer ? L10n.tr("停", "Stop") : L10n.tr("暂停", "Pause")
        default: return description
        }
    }
}

private struct CoverPositionPanelSlider: View {
    let device: SmartDevice
    let store: HomeStore
    let value: Double
    let accent: Color
    let statusColor: Color
    var theme: PanelTheme = .liquidGlass
    let iconName: String
    let label: String

    @State private var draft: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let shown = draft.map(Double.init) ?? value
            DetailSliderControl(
                value: shown, range: 0...100, step: 1, iconName: iconName,
                iconColor: statusColor, trackColors: [accent.opacity(0.55), accent.opacity(0.92)],
                formattedValue: "\(Int(shown))%", theme: theme
            ) { next in
                let target = Int(next.rounded())
                if store.panelConfirmationLevel(for: device, action: .coverPosition(target)) != nil {
                    draft = target
                } else {
                    draft = nil
                    store.setCoverPosition(device.id, percent: target)
                }
            }
            .accessibilityLabel(Text(label))

            if let draft {
                let title = L10n.format("移至 %@", "Move to %@", "\(draft)%")
                HStack(spacing: 6) {
                    DetailPillButton(title: title, theme: theme) {
                        self.draft = nil
                        store.setCoverPosition(device.id, percent: draft)
                    }
                    .panelControlGesture(.coverPosition(draft), for: device, store: store,
                                         slideAlignment: .trailing, slideWidth: 64, reserveSlideSpace: true,
                                         label: title, onSubmitted: { self.draft = nil })
                    Button {
                        self.draft = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.tr("取消", "Cancel")))
                }
            }
        }
        .onChange(of: device.kind) { _, _ in draft = nil }
        .onChange(of: store.isControlBlockedByScreenLock) { _, blocked in
            if blocked { draft = nil }
        }
    }
}

/// The slider a full-row card shows without opening a drawer: brightness, fan speed, cover
/// position, target humidity or volume. Kept beside the cover drawer so `DeviceCardView` stays
/// under the line-count gate (#184).
struct InlinePrimaryControl {
    enum Target {
        case lightBrightness, fanSpeed, coverPosition, humidity, volume
    }

    let target: Target
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let iconName: String
    let label: String

    init?(device: SmartDevice) {
        switch device.kind {
        case .light(let spec) where spec.brightnessWritable:
            target = .lightBrightness
            value = Double(spec.brightnessPercent ?? (spec.isOn ? 80 : 0))
            range = 1...100
            step = 1
            iconName = "sun.max.fill"
            label = L10n.tr("亮度", "Brightness")
        case .fan(let spec) where spec.speedWritable:
            guard let percent = spec.percentage else { return nil }
            target = .fanSpeed
            value = Double(max(1, min(100, percent)))
            range = 1...100
            step = 1
            iconName = "wind"
            label = L10n.tr("风速", "Fan speed")
        case .cover(let spec) where spec.positionWritable:
            target = .coverPosition
            value = Double(spec.positionPercent ?? 0)
            range = 0...100
            step = 1
            iconName = spec.subtype == .clothesAirer ? "hanger" : "window.vertical.open"
            label = L10n.tr("开合位置", "Position")
        case .humidifier(let spec) where spec.humidityWritable:
            guard let targetHumidity = spec.targetHumidity else { return nil }
            target = .humidity
            value = Double(targetHumidity)
            range = Double(spec.minHumidity)...Double(max(spec.minHumidity + 1, spec.maxHumidity))
            step = Double(max(spec.step, 1))
            iconName = "humidity.fill"
            label = L10n.tr("目标湿度", "Target humidity")
        case .speaker(let spec):
            guard device.isActiveOn else { return nil }
            target = .volume
            value = Double(spec.volumePercent)
            range = 0...100
            step = 1
            iconName = "speaker.wave.2.fill"
            label = L10n.tr("音量", "Volume")
        case .tv(let spec):
            guard device.isActiveOn, spec.volumeWritable, spec.volumePresent else { return nil }
            target = .volume
            value = Double(spec.volumePercent)
            range = 0...100
            step = 1
            iconName = "speaker.wave.2.fill"
            label = L10n.tr("音量", "Volume")
        default:
            return nil
        }
    }

    var formattedValue: String { "\(Int(value.rounded()))%" }

    @MainActor
    func apply(_ newValue: Double, device: SmartDevice, store: HomeStore) {
        let percent = Int(newValue.rounded())
        switch target {
        case .lightBrightness: store.setLightBrightness(device.id, percent: percent)
        case .fanSpeed: store.setFanPercentage(device.id, percent: percent)
        case .coverPosition: store.setCoverPosition(device.id, percent: percent)
        case .humidity: store.setHumidifierHumidity(device.id, percent: percent)
        case .volume: store.setSpeakerVolume(device.id, percent: percent)
        }
    }
}

/// The control-center style inline slider itself: one full-width glass track under the header.
struct DeviceInlineSlider: View {
    let control: InlinePrimaryControl
    let device: SmartDevice
    let store: HomeStore
    let accent: Color
    let statusColor: Color

    var body: some View {
        if case .coverPosition = control.target {
            CoverPositionPanelSlider(
                device: device, store: store, value: control.value, accent: accent,
                statusColor: statusColor, iconName: control.iconName, label: control.label
            )
        } else {
            slider
        }
    }

    private var slider: some View {
        LiquidGlassSlider(
            value: Binding(
                get: { control.value },
                set: { control.apply($0, device: device, store: store) }
            ),
            in: control.range,
            step: control.step,
            iconName: control.iconName,
            iconColor: statusColor,
            trackFill: LinearGradient(
                colors: [accent.opacity(0.55), accent.opacity(0.92)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            formattedValue: control.formattedValue
        )
        .accessibilityLabel(Text(control.label))
    }
}

/// Target humidity, modes and the live reading for a humidifier. Split from `DeviceCardView` for
/// the line-count gate (#184), like the cover controls above.
struct HumidifierDetailDrawer: View {
    let device: SmartDevice
    let spec: HumidifierSpec
    let store: HomeStore
    let accent: Color
    let statusColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if spec.humidityWritable, let target = spec.targetHumidity {
                LiquidGlassSlider(
                    value: Binding(
                        get: { Double(target) },
                        set: { store.setHumidifierHumidity(device.id, percent: Int($0.rounded())) }
                    ),
                    in: Double(spec.minHumidity)...Double(max(spec.minHumidity + 1, spec.maxHumidity)),
                    step: Double(spec.step),
                    iconName: "humidity.fill",
                    iconColor: statusColor,
                    trackFill: LinearGradient(
                        colors: [accent.opacity(0.55), accent.opacity(0.92)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    formattedValue: "\(target)%"
                )
                .disabled(!device.isOnline)
                .accessibilityLabel(Text(L10n.tr("目标湿度", "Target humidity")))
            }

            if !spec.availableModes.isEmpty, spec.modeWritable {
                ScrollView(.horizontal, showsIndicators: false) {
                    AdaptiveGlassContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(spec.availableModes, id: \.self) { mode in
                                Button(SmartDevice.localizeApplianceMode(mode)) {
                                    store.setHumidifierMode(device.id, mode: mode)
                                }
                                .buttonStyle(PillActionButtonStyle(
                                    isSelected: spec.currentMode == mode,
                                    tintColor: accent
                                ))
                                .disabled(!device.isOnline)
                            }
                        }
                    }
                    .padding(6)
                }
                .padding(-6)
            }

            if let current = spec.currentHumidity.flatMap(DeviceSynthesizer.roundedInt) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.tr("当前湿度", "Current humidity"))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    DetailValueText(text: "\(current)%", color: statusColor)
                }
                .padding(.horizontal, 8)
            }
        }
    }
}
