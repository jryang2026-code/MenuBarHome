import AppKit
import SwiftUI
import MijiaCore

/// Settings → 通用 → 自动化与外部控制 (#57, #59).
///
/// Rules are stored in `UserDefaults` and start empty. `AutomationEngine` reads the same store on
/// every system event, so toggling a rule takes effect immediately without restarting the app.
struct AutomationSettingsSection: View {
    let store: HomeStore

    @Environment(\.settingsSearchFocus) private var searchFocus
    @AppStorage(RaycastSnapshotExporter.integrationEnabledKey) private var raycastEnabled = false
    /// Loaded in `onAppear`; a `@State` initializer would re-decode `UserDefaults` on every render.
    @State private var rules: [AutomationRule] = []
    /// Mirrors the Location authorization so the conditions editor can explain a silent rule.
    @State private var locationAuthorized = MacHardwareProbe.isWiFiAuthorized

    @State private var newTrigger: AutomationTrigger = .away
    @State private var newActionKind: AutomationActionKind = .quickAction
    @State private var newQuickAction: QuickAction = .lightsOff
    @State private var newSceneId: String?
    @State private var newDeviceIds: Set<String> = []
    @State private var newDeviceTurnOn = false

    // #174: per-trigger parameters. They stay at safe defaults unless the selected trigger uses
    // them, and are copied into the rule when it is added.
    @State private var newBatteryThreshold = 20
    @State private var newWiFiSSID = ""
    @State private var newLateNightStart = 23
    @State private var newLateNightEnd = 6
    @State private var newCalendarLeadMinutes = 1

    // Conditions. Kept separate from the trigger parameters above: they apply to every trigger,
    // not just the Wi-Fi one.
    @State private var newWiFiMode: WiFiConditionMode = .any
    @State private var newWiFiSSIDList = ""

    // Time window. Hour granularity is what the editor offers today; the model stores minutes so a
    // finer control can be added later without migrating stored rules.
    @State private var newTimeWindowEnabled = false
    @State private var newTimeStartHour = 22
    @State private var newTimeEndHour = 7

    private enum WiFiConditionMode: String, CaseIterable, Identifiable {
        case any, only, exclude

        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: return L10n.tr("不限", "Any")
            case .only: return L10n.tr("只在以下 Wi-Fi", "Only on")
            case .exclude: return L10n.tr("不在以下 Wi-Fi", "Not on")
            }
        }
    }

    private enum AutomationActionKind: String, CaseIterable, Identifiable {
        case quickAction, scene, devices

        var id: String { rawValue }

        var title: String {
            switch self {
            case .quickAction: return L10n.tr("快捷动作", "Quick action")
            case .scene: return L10n.tr("场景", "Scene")
            case .devices: return L10n.tr("指定设备", "Devices")
            }
        }
    }

    var body: some View {
        let _ = store.effectiveLanguage
        SettingsSection(title: L10n.tr("自动化与外部控制", "Automation & External Control"), anchor: .automationRules) {
            Toggle(L10n.tr("运行自动化规则", "Run automation rules"), isOn: Binding(
                get: { store.eventAutomationEnabled },
                set: { enabled in
                    if store.setEventAutomationEnabled(enabled) {
                        rules = store.automationRuleStore.load()
                    }
                }
            ))
            .toggleStyle(.switch)
            .disabled(store.identityMigrationDiagnostic != nil)

            Text(L10n.tr(
                "规则默认没有任何内容。锁屏、合盖、睡眠会合并成一个「离开」触发；解锁与唤醒合并成「回来」。同一触发一分钟内只执行一次。摄像头 / 麦克风、电源与电量、Wi-Fi、专注状态、日历和深夜使用等 Mac 专属触发默认关闭，按需逐条添加；Wi-Fi 名称、专注状态和日历需要系统权限，未授权时对应规则不会触发。",
                "No rules exist by default. Lock, lid close and sleep are grouped as Away; unlock and wake as Back. The same trigger runs at most once per minute. Mac-only signals (camera/microphone, power and battery, Wi-Fi, Focus, Calendar, late-night use) are off until you add a rule. Wi-Fi name, Focus status and Calendar need system permission; without it their rules do not fire."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            Text(L10n.tr(
                "需要区分时改用三个精确触发：锁屏（未休眠）、合盖休眠、休眠（未合盖）。合盖会先锁屏再休眠，所以「锁屏」要晚约 2 秒判定，免得把合盖错认成单纯锁屏；休眠本身不等待，否则指令会赶不上机器挂起。条件是「且」的关系，例如「合盖休眠 + 只在公司 Wi-Fi」。",
                "For finer control use the three precise triggers: Screen locked (not asleep), Sleep after lid close, and Sleep (lid open). A lid close locks before it sleeps, so “Screen locked” is decided about 2 s late to avoid mistaking a lid close for a plain lock; sleep itself is never delayed, otherwise the command would miss the suspend. Conditions are ANDed with the trigger, for example “Sleep after lid close + only on office Wi-Fi”."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if rules.isEmpty {
                Text(L10n.tr(
                    "还没有规则。下面新建一条，例如「离开 → 关闭书房灯」。",
                    "No rules yet. Create one below, for example “Away → turn off the study light”."
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .padding(.vertical, 4)
            } else {
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
            }

            Divider().overlay(Color.primary.opacity(0.06))
            newRuleBuilder

            Divider().overlay(Color.primary.opacity(0.06))

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("外部链接直控权限", "External Link Direct Control"))
                        .font(.system(size: DesignTokens.TypeSize.body))
                    Text(L10n.tr(
                        "外部链接（menumijia://）跳过确认的高风险开关已归入「安全与提醒 › 高级控制权限」统一管理。",
                        "The high-risk switch allowing menumijia:// links to skip confirmation is managed under Safety & Alerts › High-Risk Control Permissions."
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button {
                    searchFocus?.jump(to: .allowURLControl)
                } label: {
                    HStack(spacing: 3) {
                        Text(L10n.tr("前往设置", "Go to Settings"))
                        Image(systemName: "chevron.right")
                            .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold))
                    }
                }
                .buttonStyle(PillActionButtonStyle())
            }

            Divider().overlay(Color.primary.opacity(0.06))

            SettingsToggleRow(
                title: L10n.tr("Raycast 集成", "Raycast integration"),
                isOn: $raycastEnabled
            )
            .onChange(of: raycastEnabled) { _, enabled in
                store.setRaycastIntegration(enabled: enabled)
            }
            .settingsRow(anchor: .raycast)
            Text(L10n.tr(
                "开启后把设备与场景列表写到本机一个只有你能读的文件，供 Raycast 扩展搜索；扩展发来的链接带本机令牌，不再弹确认，高风险设备仍会确认。关闭即删除该文件并作废令牌。",
                "Writes your device and scene list to a file only you can read, for the Raycast extension to search. Links from the extension carry a local token and skip confirmation; high-risk devices still ask. Turning this off deletes the file and revokes the token."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            rules = store.automationRuleStore.load()
            locationAuthorized = MacHardwareProbe.isWiFiAuthorized
        }
        // Coming back from System Settings is the moment the state actually changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            locationAuthorized = MacHardwareProbe.isWiFiAuthorized
        }
    }

    // MARK: - Existing Rules

    private func ruleRow(_ rule: AutomationRule) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: rule.trigger.symbolName)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(DesignTokens.secondaryText)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.trigger.title)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                Text(rule.action.summary(devices: store.devices, scenes: store.scenes))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .lineLimit(2)
                if let detail = triggerDetail(rule) {
                    Text(detail)
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Toggle("", isOn: enabledBinding(for: rule))
                .labelsHidden()
                .glassLabelHidden()
                .toggleStyle(.glass)
                .controlSize(.regular)

            Button {
                delete(rule)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: DesignTokens.TypeSize.caption))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DesignTokens.secondaryText)
            .help(L10n.tr("删除这条规则", "Delete this rule"))
        }
        .padding(.vertical, 2)
    }

    private func enabledBinding(for rule: AutomationRule) -> Binding<Bool> {
        Binding(
            get: { rules.first(where: { $0.id == rule.id })?.isEnabled ?? rule.isEnabled },
            set: { enabled in
                guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
                var updated = rules[index]
                if enabled, !updated.isEnabled,
                   let confirmation = updated.highRiskConfirmation(devices: store.devices) {
                    guard confirmHighRiskRule(confirmation) else { return }
                    updated.highRiskApproved = true
                }
                updated.isEnabled = enabled
                // A manual switch overrides the pause bookkeeping: turning a paused rule on runs it
                // now, and turning one off keeps it off even if the lost scope comes back (M5).
                updated.pausedCapabilities = []
                updated.pausedScopes = []
                update(updated)
            }
        )
    }

    private func delete(_ rule: AutomationRule) {
        rules.removeAll { $0.id == rule.id }
        var stored = store.automationRuleStore.load()
        stored.removeAll { $0.id == rule.id }
        store.automationRuleStore.save(stored)
        rules = stored
        store.onAutomationRulesChanged?()
    }

    /// Writes one rule against the current store instead of the array read on appear, so a background
    /// revalidation that paused or resumed another rule is not overwritten with stale rows (M5).
    private func update(_ rule: AutomationRule) {
        var stored = store.automationRuleStore.load()
        if let index = stored.firstIndex(where: { $0.id == rule.id }) {
            stored[index] = rule
        } else {
            stored.append(rule)
        }
        store.automationRuleStore.save(stored)
        rules = stored
        store.onAutomationRulesChanged?()
    }

    /// One line under the action summary: the trigger's own parameter, then the conditions.
    private func triggerDetail(_ rule: AutomationRule) -> String? {
        let triggerPart = triggerParameterDetail(rule)
        guard let conditionPart = rule.conditions.summary() else { return triggerPart }
        guard let triggerPart else { return conditionPart }
        return triggerPart + " · " + conditionPart
    }

    private func triggerParameterDetail(_ rule: AutomationRule) -> String? {
        let options = rule.triggerOptions
        switch rule.trigger {
        case .batteryBelowThreshold:
            return L10n.format(
                "电量低于 %@%",
                "Battery below %@%",
                String(options.batteryThresholdPercent)
            )
        case .wifiNetworkJoined, .wifiNetworkLeft:
            if let ssid = options.wifiSSID {
                return L10n.format("Wi-Fi：%@", "Wi-Fi: %@", ssid)
            }
            return L10n.tr("任意 Wi-Fi 网络", "Any Wi-Fi network")
        case .lateNightUsage:
            return L10n.format(
                "%@–%@",
                "%@–%@",
                String(format: "%02d:00", options.lateNightWindow.startHour),
                String(format: "%02d:00", options.lateNightWindow.endHour)
            )
        case .calendarMeetingStartingSoon:
            return L10n.format(
                "提前 %@ 分钟",
                "%@ min before",
                String(options.calendarLeadMinutes)
            )
        default:
            return nil
        }
    }

    // MARK: - New Rule

    private var newRuleBuilder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("新建规则", "New Rule"))
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(DesignTokens.secondaryText)

            HStack(spacing: 6) {
                Text(L10n.tr("触发", "When"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                Picker(L10n.tr("触发", "When"), selection: $newTrigger) {
                    ForEach(AutomationTrigger.allCases) { trigger in
                        Text(trigger.title).tag(trigger)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 185)
                .controlSize(.regular)

                Text(L10n.tr("动作", "Then"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                Picker(L10n.tr("动作", "Then"), selection: $newActionKind) {
                    ForEach(AutomationActionKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 130)
                .controlSize(.regular)
            }

            conditionsEditor

            triggerOptionsEditor

            actionEditor

            HStack {
                Spacer()
                Button {
                    addRule()
                } label: {
                    Label(L10n.tr("添加规则", "Add Rule"), systemImage: "plus")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                }
                .buttonStyle(PillActionButtonStyle(isSelected: canAdd))
                .disabled(!canAdd)
            }
        }
    }

    // MARK: - Conditions

    /// AND-ed with the trigger, so it is offered for every trigger rather than only for the
    /// "joined/left Wi-Fi" ones.
    @ViewBuilder
    private var conditionsEditor: some View {
        HStack(spacing: 6) {
            Text(L10n.tr("条件", "If"))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
            Text("Wi-Fi")
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
            Picker("", selection: $newWiFiMode) {
                ForEach(WiFiConditionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 170)
            .controlSize(.regular)
        }

        HStack(spacing: 6) {
            Toggle(isOn: $newTimeWindowEnabled) {
                Text(L10n.tr("限定时段", "Only between"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)

            if newTimeWindowEnabled {
                hourPicker($newTimeStartHour)

                Text("–")
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)

                hourPicker($newTimeEndHour)

                if newTimeStartHour == newTimeEndHour {
                    Text(L10n.tr("起止不能相同", "Start and end must differ"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                } else if newTimeStartHour > newTimeEndHour {
                    Text(L10n.tr("跨夜", "Overnight"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }

        if newWiFiMode != .any {
            HStack(spacing: 6) {
                TextField(
                    L10n.tr("网络名称，多个用逗号分隔", "Network names, comma separated"),
                    text: $newWiFiSSIDList
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 230)
                .controlSize(.regular)

                Button {
                    if let current = MacHardwareProbe.currentWiFi().ssid {
                        appendSSID(current)
                    }
                } label: {
                    Text(L10n.tr("填入当前网络", "Use current"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                }
                .buttonStyle(.borderless)
            }

            if parsedSSIDs.isEmpty {
                Text(L10n.tr(
                    "至少填写一个网络名称，否则这条规则不会触发。",
                    "Enter at least one network; otherwise this rule never fires."
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(L10n.tr(
                "精确匹配网络名称。未连接任何 Wi-Fi 时，上面两种条件都不满足，规则不会触发；未授予「定位」权限时同样不会触发。",
                "Names are matched exactly. When no Wi-Fi is connected neither mode is satisfied and the rule stays quiet; the same applies without Location permission."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            // A menu-bar-only app (LSUIElement) has no window at launch, so macOS often suppresses
            // the Location prompt entirely. Ask once, then tell the user exactly where to grant it
            // instead of leaving them with a rule that silently never fires.
            if !locationAuthorized {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.tr(
                        "还没有「定位」权限，带 Wi-Fi 条件的规则不会触发。菜单栏应用可能不弹授权框，请手动允许。",
                        "Location permission is missing, so rules with a Wi-Fi condition never fire. A menu-bar app often shows no prompt; grant it manually."
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                    Button {
                        openLocationPrivacySettings()
                    } label: {
                        Label(
                            L10n.tr("打开定位设置", "Open Location Settings"),
                            systemImage: "gearshape"
                        )
                        .font(.system(size: DesignTokens.TypeSize.caption))
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func openLocationPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Comma, full-width comma, enumeration comma or newline. Normalised by the core so the stored
    /// rule and the text the user sees cannot drift apart.
    private var parsedSSIDs: [String] {
        AutomationWiFiCondition.normalize(
            newWiFiSSIDList.components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
        )
    }

    private func appendSSID(_ ssid: String) {
        guard !parsedSSIDs.contains(ssid) else { return }
        let existing = parsedSSIDs + [ssid]
        newWiFiSSIDList = existing.joined(separator: L10n.tr("、", ", "))
    }

    // MARK: - Trigger Parameters (#174)

    @ViewBuilder
    private var triggerOptionsEditor: some View {
        switch newTrigger {
        case .batteryBelowThreshold:
            HStack(spacing: 6) {
                Text(L10n.tr("电量低于", "Battery below"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                Stepper(value: $newBatteryThreshold, in: 1...100) {
                    Text("\(newBatteryThreshold)%")
                        .font(.system(size: DesignTokens.TypeSize.caption))
                }
                .fixedSize()
            }
        case .wifiNetworkJoined, .wifiNetworkLeft:
            TextField(
                L10n.tr("Wi-Fi 名称（留空表示任意网络）", "Wi-Fi name (empty = any network)"),
                text: $newWiFiSSID
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 280)
            .controlSize(.regular)
        case .lateNightUsage:
            HStack(spacing: 6) {
                Text(L10n.tr("从", "From"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                hourPicker($newLateNightStart)
                Text(L10n.tr("到", "to"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                hourPicker($newLateNightEnd)
            }
        case .calendarMeetingStartingSoon:
            HStack(spacing: 6) {
                Text(L10n.tr("提前", "Lead"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                Stepper(value: $newCalendarLeadMinutes, in: 1...60) {
                    Text(L10n.format("%@ 分钟", "%@ min", String(newCalendarLeadMinutes)))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                }
                .fixedSize()
            }
        default:
            EmptyView()
        }

        if let permission = newTrigger.requiredPermission {
            Text(permissionHint(permission))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hourPicker(_ hour: Binding<Int>) -> some View {
        Picker("", selection: hour) {
            ForEach(0..<24, id: \.self) { value in
                Text(String(format: "%02d:00", value)).tag(value)
            }
        }
        .labelsHidden()
        .frame(width: 76)
        .controlSize(.regular)
    }

    private func permissionHint(_ permission: AutomationPermission) -> String {
        switch permission {
        case .location:
            return L10n.tr(
                "读取 Wi-Fi 名称需要「定位」权限。未授权时 Wi-Fi 规则不会触发，其他规则不受影响。",
                "Reading the Wi-Fi name requires Location permission. Wi-Fi rules stay inactive without it; other rules are unaffected."
            )
        case .focus:
            return L10n.tr(
                "专注状态需要系统权限。公开 API 只提供「是否处于专注」，无法读取具体专注模式名称。",
                "Focus status requires system permission. The public API only reports whether some Focus is active, not which Focus mode."
            )
        case .calendar:
            return L10n.tr(
                "日历规则需要完整的日历访问权限，只读取开始时间，不修改事件。",
                "Calendar rules need full calendar access. Only event start times are read; events are never modified."
            )
        }
    }

    @ViewBuilder
    private var actionEditor: some View {
        switch newActionKind {
        case .quickAction:
            Picker("", selection: $newQuickAction) {
                ForEach(QuickAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240, alignment: .leading)
            .controlSize(.regular)

        case .scene:
            if store.scenes.isEmpty {
                Text(L10n.tr(
                    "当前没有可用的场景。连接 Home Assistant 并同步场景后再试。",
                    "No scenes available. Connect Home Assistant and sync scenes first."
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
            } else {
                Picker("", selection: sceneSelection) {
                    ForEach(store.scenes) { scene in
                        Text(scene.name).tag(Optional(scene.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240, alignment: .leading)
                .controlSize(.regular)
            }

        case .devices:
            // Same set App Intents offer: visible, online, and closable/openable with one click, so
            // a rule cannot be created for a hidden or offline device (#57 共用).
            let selectable = store.controllableDevices
            if selectable.isEmpty {
                Text(L10n.tr(
                    "当前没有可控设备（隐藏、离线或只能展开详情的设备不会列出）。连接数据源或取消隐藏后再试。",
                    "No controllable devices (hidden, offline, or detail-only devices are not listed). Connect a data source or unhide a device first."
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(selectable) { device in
                            Toggle(isOn: deviceSelectionBinding(device.id)) {
                                Text("\(device.name) · \(L10n.displayRoomName(device.roomName))")
                                    .font(.system(size: DesignTokens.TypeSize.caption))
                            }
                            .toggleStyle(.checkbox)
                            .controlSize(.regular)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)

                Picker("", selection: $newDeviceTurnOn) {
                    Text(L10n.tr("打开", "Turn on")).tag(true)
                    Text(L10n.tr("关闭", "Turn off")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .controlSize(.regular)
            }
        }
    }

    private var sceneSelection: Binding<String?> {
        Binding(
            get: { newSceneId ?? store.scenes.first?.id },
            set: { newSceneId = $0 }
        )
    }

    private func deviceSelectionBinding(_ deviceId: String) -> Binding<Bool> {
        Binding(
            get: { newDeviceIds.contains(deviceId) },
            set: { selected in
                if selected {
                    newDeviceIds.insert(deviceId)
                } else {
                    newDeviceIds.remove(deviceId)
                }
            }
        )
    }

    private var canAdd: Bool {
        // A network condition with no network would never fire; refuse it instead of storing a
        // dead rule the user cannot debug.
        if newWiFiMode != .any, parsedSSIDs.isEmpty { return false }
        // Equal ends mean "all day" in the model but "never" for the late-night trigger; refuse the
        // ambiguous window rather than store a rule the user reads the other way.
        if newTimeWindowEnabled, newTimeStartHour == newTimeEndHour { return false }
        switch newActionKind {
        case .quickAction:
            return true
        case .scene:
            return !store.scenes.isEmpty
        case .devices:
            return !newDeviceIds.isEmpty
        }
    }

    private func addRule() {
        let action: AutomationAction
        switch newActionKind {
        case .quickAction:
            action = .quickAction(newQuickAction)
        case .scene:
            guard let sceneId = newSceneId ?? store.scenes.first?.id else { return }
            action = .scene(sceneId: sceneId)
        case .devices:
            guard !newDeviceIds.isEmpty else { return }
            action = .devices(ids: newDeviceIds.sorted(), isOn: newDeviceTurnOn)
        }
        let options = AutomationTriggerOptions(
            batteryThresholdPercent: newBatteryThreshold,
            wifiSSID: newWiFiSSID,
            lateNightStartHour: newLateNightStart,
            lateNightEndHour: newLateNightEnd,
            calendarLeadMinutes: newCalendarLeadMinutes
        )
        let wifi: AutomationWiFiCondition
        switch newWiFiMode {
        case .any: wifi = .any
        case .only: wifi = .inAny(parsedSSIDs)
        case .exclude: wifi = .notIn(parsedSSIDs)
        }
        var rule = AutomationRule(
            trigger: newTrigger,
            action: action,
            triggerOptions: options,
            conditions: AutomationConditions(
                wifi: wifi,
                timeWindow: AutomationTimeWindow(
                    isEnabled: newTimeWindowEnabled,
                    startMinute: newTimeStartHour * 60,
                    endMinute: newTimeEndHour * 60
                )
            )
        )
        if let confirmation = rule.highRiskConfirmation(devices: store.devices) {
            guard confirmHighRiskRule(confirmation) else { return }
            rule.highRiskApproved = true
        }
        var stored = store.automationRuleStore.load()
        stored.append(rule)
        store.automationRuleStore.save(stored)
        rules = stored
        newDeviceIds = []
        store.onAutomationRulesChanged?()
    }

    private func confirmHighRiskRule(_ confirmation: ManualControlConfirmation) -> Bool {
        let approved = store.manualControlConfirmationHandler?(confirmation)
            ?? ManualControlConfirmationPresenter.present(confirmation)
        if !approved {
            store.showToast(L10n.tr("已取消高风险操作", "High-risk action cancelled."), isError: true)
        }
        return approved
    }

    /// #174: a newly enabled Wi-Fi/Focus/calendar rule asks for its permission now, not at the next
    /// app launch. Every write above calls `store.onAutomationRulesChanged?()` after saving.
}
