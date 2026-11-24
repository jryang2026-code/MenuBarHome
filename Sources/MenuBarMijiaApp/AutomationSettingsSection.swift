import AppKit
import SwiftUI
import MijiaCore

/// Localized copy for the companion integration block (Raycast / CLI / MCP, P6a-M).
enum CompanionSettingsCopy {
    static var toggleTitle: String { L10n.tr("外部快捷工具与伴生集成（Raycast / CLI / MCP）", "External Tools & Companion Integration (Raycast / CLI / MCP)") }
    static var statusEnabled: String { L10n.tr("已开启 · 仅本机可访问（0600 本地快照，不共享家居连接凭据）", "Enabled · Local access only (0600 snapshot, no home connection credentials shared)") }
    static var statusDisabled: String { L10n.tr("已关闭 · 停止快照导出并拒绝伴生命令（普通外部链接仍按安全与提醒设置执行）", "Off · Snapshot export stopped and companion commands rejected (ordinary links still follow Safety & Alerts)") }
    static var scopeHint: String {
        L10n.tr(
            "开启后只在本机导出当前已启用连接与设备类型的快照文件，供 Raycast、本地 CLI 与 MCP 协作；高风险设备与锁屏保护仍在应用内执行。本功能不会自动修改任何外部应用配置。",
            "Exports a local snapshot of enabled connections and device types for Raycast, local CLI, and MCP. High-risk confirmations and screen-lock protection still run inside the app. External app configs are never modified automatically."
        )
    }
    static var copyConfigButton: String { L10n.tr("复制配置", "Copy Config") }
    static var checkButton: String { L10n.tr("检测", "Check") }
    static var disconnectButton: String { L10n.tr("断开", "Disconnect") }
    static var copyConfigHelp: String { L10n.tr("复制 MCP 与本地快照配置片段（不含令牌或家居凭据）", "Copy the MCP and local snapshot config snippet (contains no token or home credentials)") }
    static var checkHelp: String { L10n.tr("只读检查本地快照、令牌和权限状态", "Read-only check of local snapshot, token, and file permissions") }
    static var disconnectHelp: String { L10n.tr("立即关闭伴生集成、作废旧令牌并删除本地快照", "Turn off companion integration, revoke old tokens, and delete the local snapshot") }
    static var copiedToast: String {
        L10n.tr(
            "已复制配置。请将 command 中的占位路径换成本机 scripts/mijia-mcp 的绝对路径。",
            "Config copied. Replace the placeholder in command with the absolute path to scripts/mijia-mcp on this Mac."
        )
    }
    static func snapshotPathLine(_ path: String) -> String { L10n.format("快照路径：%@", "Snapshot path: %@", path) }
}

/// Settings → 通用 → 自动化与外部控制 (#57, #59).
///
/// Rules are stored in `UserDefaults` and start empty. `AutomationEngine` reads the same store on
/// every system event, so toggling a rule takes effect immediately without restarting the app.
struct AutomationSettingsSection: View {
    let store: HomeStore

    @Environment(\.settingsSearchFocus) private var searchFocus
    @State private var companionCheckReport: CompanionCheckReport?
    /// Loaded in `onAppear`; a `@State` initializer would re-decode `UserDefaults` on every render.
    @State private var rules: [AutomationRule] = []
    /// Paused groups and quick actions whose connection was removed: the fail-safe keeps them paused,
    /// so this list is the only place the user can release them by hand (`resumePausedQuickAction`).
    @State private var pausedQuickActions: [HomeStore.PausedQuickAction] = []
    @State private var timersToPause: [ScheduledCommand]?
    /// Mirrors the Location authorization so the conditions editor can explain a silent rule.
    @State private var locationAuthorized = MacHardwareProbe.isWiFiAuthorized

    init(store: HomeStore, initialCompanionCheckReport: CompanionCheckReport? = nil) {
        self.store = store
        self._companionCheckReport = State(initialValue: initialCompanionCheckReport)
    }

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
    @State private var newSchedule = ScheduledTime(hour: 8, minute: 0)

    // Conditions. Kept separate from the trigger parameters above: they apply to every trigger,
    // not just the Wi-Fi one.
    @State private var newWiFiMode: WiFiConditionMode = .any
    @State private var newWiFiSSIDList = ""

    // Time window. Hour granularity is what the editor offers today; the model stores minutes so a
    // finer control can be added later without migrating stored rules.
    @State private var newTimeWindowEnabled = false
    @State private var newTimeStartHour = 22
    @State private var newTimeEndHour = 7
    @State private var newLastingMinutes = 0

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

    private var scheduledCommandsToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L10n.tr("运行定时任务", "Run Scheduled Commands"), isOn: Binding(
                get: { store.scheduledCommandsEnabled },
                set: { enabled in
                    let affected = store.scheduledCommandsAffectedByDisable
                    if enabled || affected.isEmpty {
                        store.setScheduledCommandsEnabled(enabled)
                    } else {
                        timersToPause = affected
                    }
                }
            ))
            .toggleStyle(.switch)

            Text(L10n.tr(
                "关闭后停止到点执行和补发，已排定的定时暂停保留；重新开启时先复验目标，已过期的不补发，改为进入错过流程。",
                "Turning this off stops timers from firing and never catches up; pending timers stay paused with their plans. Turning it back on revalidates every target first, and timers that came due meanwhile go to the missed flow instead of running silently."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .settingsRow(anchor: .scheduledCommands)
        .confirmationDialog(
            L10n.tr("关闭定时任务？", "Turn off scheduled commands?"),
            isPresented: Binding(
                get: { timersToPause != nil },
                set: { if !$0 { timersToPause = nil } }
            ),
            titleVisibility: .visible,
            presenting: timersToPause
        ) { entries in
            Button(L10n.tr("暂停这些项并关闭", "Pause These & Turn Off")) {
                let current = store.scheduledCommandsAffectedByDisable
                if current != entries, !current.isEmpty {
                    Task { @MainActor in timersToPause = current }
                } else {
                    store.setScheduledCommandsEnabled(false, confirming: current)
                }
            }
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
        } message: { entries in
            Text(entries.map(\.reply).joined(separator: "\n"))
        }
    }

    var body: some View {
        let _ = store.effectiveLanguage
        SettingsSection(title: L10n.tr("自动化与外部控制", "Automation & External Control"), anchor: .automationRules) {
            scheduledCommandsToggle

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

            if !pausedQuickActions.isEmpty {
                pausedQuickActionsBlock
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

            VStack(alignment: .leading, spacing: 8) {
                SettingsToggleRow(
                    title: CompanionSettingsCopy.toggleTitle,
                    isOn: Binding(
                        get: { store.companionIntegrationEnabled },
                        set: {
                            store.setCompanionIntegrationEnabled($0)
                            companionCheckReport = nil
                        }
                    )
                )
                .disabled(store.identityMigrationDiagnostic != nil && !store.companionIntegrationEnabled)

                let isCompanionPaused = store.companionIntegrationEnabled && store.identityMigrationDiagnostic != nil
                HStack(spacing: 6) {
                    Circle()
                        .fill(isCompanionPaused ? Color.orange : (store.companionIntegrationEnabled ? Color.green : DesignTokens.secondaryText.opacity(0.45)))
                        .frame(width: 7, height: 7)
                    Text(isCompanionPaused
                         ? HomeStore.companionIdentityUnavailableMessage
                         : (store.companionIntegrationEnabled ? CompanionSettingsCopy.statusEnabled : CompanionSettingsCopy.statusDisabled))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .foregroundStyle(store.companionIntegrationEnabled ? Color.primary : DesignTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(CompanionSettingsCopy.scopeHint)
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.companionMCPConfigurationJSON(), forType: .string)
                        store.showToast(CompanionSettingsCopy.copiedToast)
                    } label: { Label(CompanionSettingsCopy.copyConfigButton, systemImage: "doc.on.doc").font(.system(size: DesignTokens.TypeSize.caption, weight: .medium)) }
                        .buttonStyle(PillActionButtonStyle()).help(CompanionSettingsCopy.copyConfigHelp)

                    Button { companionCheckReport = store.checkCompanionIntegrationStatus() } label: {
                        Label(CompanionSettingsCopy.checkButton, systemImage: "checkmark.shield").font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    }
                    .buttonStyle(PillActionButtonStyle()).help(CompanionSettingsCopy.checkHelp)

                    Button {
                        store.disconnectCompanionIntegration()
                        companionCheckReport = store.checkCompanionIntegrationStatus()
                    } label: { Label(CompanionSettingsCopy.disconnectButton, systemImage: "link.badge.minus").font(.system(size: DesignTokens.TypeSize.caption, weight: .medium)) }
                        .buttonStyle(PillActionButtonStyle())
                        .help(CompanionSettingsCopy.disconnectHelp)
                }

                if let report = companionCheckReport {
                    let (symbol, color): (String, Color) = switch report.status {
                    case .ready: ("checkmark.circle.fill", .green)
                    case .needsAttention: ("exclamationmark.triangle.fill", .orange)
                    case .disabled: ("minus.circle", DesignTokens.secondaryText)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: symbol).font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold)).foregroundStyle(color)
                            Text(report.summary).font(.system(size: DesignTokens.TypeSize.caption)).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(CompanionSettingsCopy.snapshotPathLine(report.snapshotPath))
                            .font(.system(size: DesignTokens.TypeSize.caption)).foregroundStyle(DesignTokens.secondaryText)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .settingsRow(anchor: .raycast)
        }
        .onAppear {
            rules = store.automationRuleStore.load()
            refreshPausedQuickActions()
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
                if store.pausedRuleRequiresManualResume(rule) {
                    Text(L10n.tr(
                        "已暂停且不会自动恢复，打开右侧开关即可恢复",
                        "Paused and it will not resume on its own; turn the switch on to resume it"
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if rule.trigger == .scheduledTime || rule.trigger.supportsLasting {
                    DisclosureGroup(L10n.tr("编辑触发设置", "Edit trigger settings")) {
                        if rule.trigger == .scheduledTime {
                            scheduleEditor(Binding(
                                get: { rule.triggerOptions.scheduledTime ?? ScheduledTime(hour: 8, minute: 0) },
                                set: { schedule in
                                    guard var current = store.automationRuleStore.load().first(where: { $0.id == rule.id }) else { return }
                                    current.triggerOptions.scheduledTime = schedule
                                    update(current)
                                }
                            ))
                        }
                        if rule.trigger.supportsLasting {
                            lastingEditor(Binding(
                                get: { rule.conditions.lastingMinutes ?? 0 },
                                set: { minutes in
                                    guard var current = store.automationRuleStore.load().first(where: { $0.id == rule.id }) else { return }
                                    current.conditions.lastingMinutes = minutes == 0 ? nil : minutes
                                    update(current)
                                }
                            ))
                        }
                    }
                    .font(.system(size: DesignTokens.TypeSize.caption))
                }
                Picker(L10n.tr("执行模式", "Execution mode"), selection: Binding(
                    get: { rule.mode },
                    set: { mode in
                        guard var current = store.automationRuleStore.load().first(where: { $0.id == rule.id }) else { return }
                        current.mode = mode
                        update(current)
                    }
                )) {
                    ForEach(AutomationExecutionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                DisclosureGroup(L10n.tr("最近运行", "Recent runs")) {
                    let entries = store.automationRunHistory.filter { $0.ruleId == rule.id }
                    if entries.isEmpty {
                        Text(L10n.tr("暂无运行记录", "No runs yet"))
                    }
                    ForEach(entries) { entry in
                        let result = entry.reason.map {
                            L10n.format("已跳过 · %@", "Skipped · %@", $0.title)
                        } ?? L10n.tr("已执行", "Executed")
                        VStack(alignment: .leading) {
                            Text(entry.time, format: .dateTime.month().day().hour().minute().second())
                            Text("\(entry.trigger.title) · \(result)")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .font(.system(size: DesignTokens.TypeSize.caption))
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

    /// Paused quick actions and groups the fail-safe never resumes on its own; each row is the manual
    /// path and still re-checks its targets before it clears the pause marker.
    private var pausedQuickActionsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pausedQuickActions) { item in
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "pause.circle")
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        Text(L10n.tr(
                            "已暂停，未记录原连接，不会自动恢复",
                            "Paused without the connection it lost; it will not resume on its own"
                        ))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Button(L10n.tr("手动恢复", "Resume Now")) {
                        if store.resumePausedQuickAction(id: item.id) { refreshPausedQuickActions() }
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func refreshPausedQuickActions() {
        pausedQuickActions = store.pausedQuickActionsRequiringManualResume
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
        case .scheduledTime:
            guard let schedule = options.scheduledTime else { return nil }
            let weekdays = schedule.weekdays ?? []
            let days = weekdays.isEmpty || Set(weekdays).count == 7
                ? L10n.tr("每天", "Every day")
                : weekdays.map { weekdayNames[$0] }.joined(separator: L10n.tr("、", ", "))
            let time = String(format: "%02d:%02d", schedule.hour, schedule.minute)
            return L10n.format("%@（%@）", "%@ (%@)", time, days)
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

        if newTrigger.supportsLasting {
            lastingEditor($newLastingMinutes)
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
        case .scheduledTime:
            scheduleEditor($newSchedule)
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

    private var weekdayNames: [String] {
        ["日", "一", "二", "三", "四", "五", "六"].enumerated().map { index, day in
            L10n.tr("周" + day, ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][index])
        }
    }

    private func scheduleEditor(_ schedule: Binding<ScheduledTime>) -> some View {
        let time = Binding<Date>(
            get: {
                let value = schedule.wrappedValue
                return Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: value.hour, minute: value.minute)) ?? Date()
            },
            set: { date in
                let time = Calendar.current.dateComponents([.hour, .minute], from: date)
                guard let hour = time.hour, let minute = time.minute else { return }
                schedule.wrappedValue = ScheduledTime(hour: hour, minute: minute, weekdays: schedule.wrappedValue.weekdays)
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            DatePicker(L10n.tr("时间", "Time"), selection: time, displayedComponents: .hourAndMinute)
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { day in
                    Toggle(weekdayNames[day], isOn: Binding(
                        get: { schedule.wrappedValue.weekdays?.contains(day) == true },
                        set: { selected in
                            let value = schedule.wrappedValue
                            var days = Set(value.weekdays ?? [])
                            if selected { days.insert(day) } else { days.remove(day) }
                            schedule.wrappedValue = ScheduledTime(
                                hour: value.hour, minute: value.minute, weekdays: days.isEmpty ? nil : days.sorted()
                            )
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            Text(L10n.tr("未选星期时每天触发", "Repeats every day if no days are selected"))
                .foregroundStyle(DesignTokens.secondaryText)
        }
        .font(.system(size: DesignTokens.TypeSize.caption))
    }

    private func lastingEditor(_ minutes: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Toggle(L10n.tr("持续", "For at least"), isOn: Binding(
                get: { minutes.wrappedValue > 0 },
                set: { minutes.wrappedValue = $0 ? 5 : 0 }
            ))
            .toggleStyle(.checkbox)
            if minutes.wrappedValue > 0 {
                Stepper(value: minutes, in: 1...1440) {
                    Text(L10n.format("%@ 分钟", "%@ min", String(minutes.wrappedValue)))
                }
                .fixedSize()
            }
        }
        .font(.system(size: DesignTokens.TypeSize.caption))
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
            calendarLeadMinutes: newCalendarLeadMinutes,
            scheduledTime: newTrigger == .scheduledTime ? newSchedule : nil
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
                ),
                lastingMinutes: newTrigger.supportsLasting && newLastingMinutes > 0 ? newLastingMinutes : nil
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
