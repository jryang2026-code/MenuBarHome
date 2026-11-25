import AppKit
import SwiftUI
import MijiaCore

/// Localized copy for the companion integration block (Raycast / CLI / MCP, P6a-M).
enum CompanionSettingsCopy {
    static var toggleTitle: String { L10n.tr("Raycast / CLI / MCP 集成", "Raycast / CLI / MCP integration") }
    static var statusEnabled: String { L10n.tr("仅本机可读，不共享账号凭据", "Readable on this Mac only; account sign-ins are never shared") }
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
    @State private var showsCompanion = false
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
    @State private var newFrontmostAppBundleID = AutomationRuleTemplate.FrontmostAppPreset.iina.bundleID
    @State private var newRestoreWhenContextEnds = false

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
                "关闭后暂停执行，过期不补发",
                "Off pauses timers; overdue ones never run late"
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

            if rules.isEmpty {
                Text(L10n.tr(
                    "暂无自动化规则",
                    "No automation rules yet"
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
            quickTemplatesBar

            Divider().overlay(Color.primary.opacity(0.06))
            newRuleBuilder

            Divider().overlay(Color.primary.opacity(0.06))

            DisclosureGroup(isExpanded: $showsCompanion) {
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
                if store.companionIntegrationEnabled {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isCompanionPaused ? Color.orange : (store.companionIntegrationEnabled ? Color.green : DesignTokens.secondaryText.opacity(0.45)))
                        .frame(width: 7, height: 7)
                    Text(isCompanionPaused
                         ? HomeStore.companionIdentityUnavailableMessage
                         : CompanionSettingsCopy.statusEnabled)
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                }

                HStack(spacing: 8) {
                    // Copy and Disconnect only mean something while the integration is on; Check stays to explain why it is off.
                    if store.companionIntegrationEnabled {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.companionMCPConfigurationJSON(), forType: .string)
                        store.showToast(CompanionSettingsCopy.copiedToast)
                    } label: { Label(CompanionSettingsCopy.copyConfigButton, systemImage: "doc.on.doc").font(.system(size: DesignTokens.TypeSize.caption, weight: .medium)) }
                        .buttonStyle(PillActionButtonStyle()).help(CompanionSettingsCopy.copyConfigHelp)
                    }

                    Button { companionCheckReport = store.checkCompanionIntegrationStatus() } label: {
                        Label(CompanionSettingsCopy.checkButton, systemImage: "checkmark.shield").font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    }
                    .buttonStyle(PillActionButtonStyle()).help(CompanionSettingsCopy.checkHelp)

                    if store.companionIntegrationEnabled {
                    Button {
                        store.disconnectCompanionIntegration()
                        companionCheckReport = store.checkCompanionIntegrationStatus()
                    } label: { Label(CompanionSettingsCopy.disconnectButton, systemImage: "link.badge.minus").font(.system(size: DesignTokens.TypeSize.caption, weight: .medium)) }
                        .buttonStyle(PillActionButtonStyle())
                        .help(CompanionSettingsCopy.disconnectHelp)
                    }
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
            .padding(.top, 6)
            } label: {
                Text(L10n.tr("高级", "Advanced"))
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .medium))
            }
            .settingsRow(anchor: .raycast)
        }
        .onAppear {
            if searchFocus?.highlight == .raycast { showsCompanion = true }
            rules = store.automationRuleStore.load()
            refreshPausedQuickActions()
            locationAuthorized = MacHardwareProbe.isWiFiAuthorized
        }
        .onChange(of: searchFocus?.highlight) { _, highlight in
            if highlight == .raycast { showsCompanion = true }
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
                if case .devices = rule.action, let exitTrigger = rule.trigger.pairedContextTrigger {
                    Toggle(
                        L10n.tr("情境结束后还原", "Restore when the context ends"),
                        isOn: Binding(
                            get: { rules.first(where: { $0.id == rule.id })?.restoreWhenContextEnds ?? false },
                            set: { enabled in
                                guard var current = store.automationRuleStore.load().first(where: { $0.id == rule.id }) else { return }
                                current.restoreWhenContextEnds = enabled
                                current.restoreTrigger = enabled ? exitTrigger : nil
                                // Restoring a turn-off rule turns devices back on, so it asks the same
                                // high-risk question as the editor's copy of this switch.
                                if current.isEnabled, enabled,
                                   let confirmation = current.highRiskConfirmation(devices: store.devices),
                                   !current.highRiskApproved {
                                    guard confirmHighRiskRule(confirmation) else { return }
                                    current.highRiskApproved = true
                                }
                                update(current)
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(.system(size: DesignTokens.TypeSize.caption))
                }
                if store.pausedRuleRequiresManualResume(rule) {
                    Text(L10n.tr(
                        "已暂停，打开开关恢复",
                        "Paused; turn the switch on to resume"
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !rule.canEnable && !rule.isEnabled {
                    Text(L10n.tr(
                        "请先编辑并选择设备",
                        "Edit the rule and pick devices first"
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(L10n.tr("编辑规则", "Edit rule")) {
                    if rule.trigger == .frontmostAppBecame || rule.trigger == .frontmostAppLeft {
                        frontmostAppEditor(Binding(
                            get: { rule.triggerOptions.frontmostAppBundleID ?? "" },
                            set: { bundleID in
                                guard var current = store.automationRuleStore.load().first(where: { $0.id == rule.id }) else { return }
                                let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                                current.triggerOptions.frontmostAppBundleID = trimmed.isEmpty ? nil : trimmed
                                if !current.canEnable { current.isEnabled = false }
                                update(current)
                            }
                        ))
                    }
                    if case .devices(let ids, let isOn) = rule.action {
                        ruleDevicesEditor(rule: rule, selectedIDs: Set(ids), isOn: isOn)
                    }
                    // The row above already shows this switch when the trigger has a paired exit.
                    if rule.trigger.pairedContextTrigger == nil,
                       let defaultRestore = rule.trigger.defaultRestoreTrigger,
                       case .devices = rule.action {
                        Toggle(L10n.tr("情境结束后还原", "Restore when the context ends"), isOn: Binding(
                            get: { rule.restoreWhenContextEnds },
                            set: { enabled in
                                guard var current = store.automationRuleStore.load().first(where: { $0.id == rule.id }) else { return }
                                current.restoreWhenContextEnds = enabled
                                current.restoreTrigger = enabled ? defaultRestore : nil
                                if current.isEnabled, enabled,
                                   let confirmation = current.highRiskConfirmation(devices: store.devices),
                                   !current.highRiskApproved {
                                    guard confirmHighRiskRule(confirmation) else { return }
                                    current.highRiskApproved = true
                                }
                                update(current)
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
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
                }
                .font(.system(size: DesignTokens.TypeSize.caption))
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
                .disabled(!rule.canEnable && !rule.isEnabled)

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

    private var quickTemplatesBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("开箱模板", "Quick Templates"))
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(DesignTokens.secondaryText)

            HStack(spacing: 8) {
                ForEach(AutomationRuleTemplate.allCases) { template in
                    Button {
                        addTemplate(template)
                    } label: {
                        Label(template.title, systemImage: template.symbolName)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    }
                    .buttonStyle(PillActionButtonStyle())
                    .help(template.detail)
                }
            }
        }
    }

    private func addTemplate(_ template: AutomationRuleTemplate) {
        var stored = store.automationRuleStore.load()
        stored.append(contentsOf: template.makeRules())
        store.automationRuleStore.save(stored)
        rules = stored
        store.onAutomationRulesChanged?()
    }

    @ViewBuilder
    private func frontmostAppEditor(_ bundleID: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Menu(L10n.tr("常用播放器", "Player presets")) {
                    ForEach(AutomationRuleTemplate.FrontmostAppPreset.mediaPlayers) { preset in
                        Button("\(preset.name) (\(preset.bundleID))") {
                            bundleID.wrappedValue = preset.bundleID
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()

                TextField(
                    L10n.tr("应用 Bundle ID（如 com.colliderli.iina）", "App Bundle ID (e.g. com.colliderli.iina)"),
                    text: bundleID
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .controlSize(.regular)
            }
        }
    }

    @ViewBuilder
    private func ruleDevicesEditor(rule: AutomationRule, selectedIDs: Set<String>, isOn: Bool) -> some View {
        let selectable = store.controllableDevices
        if selectable.isEmpty {
            Text(L10n.tr(
                "当前没有可控设备，连接数据源后再选择。",
                "No controllable devices available. Connect a data source first."
            ))
            .foregroundStyle(DesignTokens.secondaryText)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(selectable) { device in
                        Toggle(isOn: Binding(
                            get: { selectedIDs.contains(device.id) },
                            set: { checked in
                                guard var current = store.automationRuleStore.load().first(where: { $0.id == rule.id }),
                                      case .devices(let existing, let turnOn) = current.action else { return }
                                var next = Set(existing)
                                if checked { next.insert(device.id) } else { next.remove(device.id) }
                                current.action = .devices(ids: next.sorted(), isOn: turnOn)
                                current.highRiskApproved = false
                                if !current.canEnable {
                                    current.isEnabled = false
                                } else if current.isEnabled,
                                          let confirmation = current.highRiskConfirmation(devices: store.devices) {
                                    guard confirmHighRiskRule(confirmation) else { return }
                                    current.highRiskApproved = true
                                }
                                update(current)
                            }
                        )) {
                            Text("\(device.name) · \(L10n.displayRoomName(device.roomName))")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)

            Picker("", selection: Binding(
                get: { isOn },
                set: { turnOn in
                    guard var current = store.automationRuleStore.load().first(where: { $0.id == rule.id }),
                          case .devices(let existing, _) = current.action else { return }
                    current.action = .devices(ids: existing, isOn: turnOn)
                    current.highRiskApproved = false
                    if current.isEnabled,
                       let confirmation = current.highRiskConfirmation(devices: store.devices) {
                        guard confirmHighRiskRule(confirmation) else { return }
                        current.highRiskApproved = true
                    }
                    update(current)
                }
            )) {
                Text(L10n.tr("打开", "Turn on")).tag(true)
                Text(L10n.tr("关闭", "Turn off")).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
        }
    }

    private func enabledBinding(for rule: AutomationRule) -> Binding<Bool> {
        Binding(
            get: { rules.first(where: { $0.id == rule.id })?.isEnabled ?? rule.isEnabled },
            set: { enabled in
                guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
                var updated = rules[index]
                if enabled, !updated.canEnable { return }
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

    /// One line under the action summary: the trigger's own parameter, restore flag, then conditions.
    private func triggerDetail(_ rule: AutomationRule) -> String? {
        var parts: [String] = []
        if let triggerPart = triggerParameterDetail(rule) {
            parts.append(triggerPart)
        }
        if rule.restoreWhenContextEnds {
            parts.append(L10n.tr("结束时还原", "Restore when ended"))
        }
        if let conditionPart = rule.conditions.summary() {
            parts.append(conditionPart)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        case .frontmostAppBecame, .frontmostAppLeft:
            if let bundleID = options.frontmostAppBundleID {
                return AutomationRuleTemplate.FrontmostAppPreset.displayLabel(for: bundleID)
            }
            return L10n.tr("未选择应用", "No app selected")
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
                    ForEach(AutomationTrigger.macOSSupportedTriggers) { trigger in
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

            if newActionKind == .devices, let exitTrigger = newTrigger.pairedContextTrigger {
                Toggle(
                    isOn: $newRestoreWhenContextEnds,
                    label: {
                        Text(L10n.tr("情境结束后还原", "Restore when the context ends"))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(DesignTokens.secondaryText)
                    }
                )
                .toggleStyle(.checkbox)
                Text(L10n.format(
                    "结束触发：%@",
                    "End trigger: %@",
                    exitTrigger.title
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
            }

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

            // A menu-bar-only app (LSUIElement) has no window at launch, so macOS often suppresses
            // the Location prompt entirely. Ask once, then tell the user exactly where to grant it
            // instead of leaving them with a rule that silently never fires.
            if !locationAuthorized {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.tr(
                        "需要定位权限才能识别 Wi-Fi",
                        "Location permission is needed to read Wi-Fi"
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
        case .frontmostAppBecame, .frontmostAppLeft:
            frontmostAppEditor($newFrontmostAppBundleID)
        default:
            EmptyView()
        }

        if newTrigger.defaultRestoreTrigger != nil && newActionKind == .devices {
            Toggle(L10n.tr("情境结束后还原", "Restore when the context ends"), isOn: $newRestoreWhenContextEnds)
                .toggleStyle(.checkbox)
                .font(.system(size: DesignTokens.TypeSize.caption))
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
                "读取 Wi-Fi 需定位权限",
                "Reading Wi-Fi needs Location permission"
            )
        case .focus:
            return L10n.tr(
                "需系统专注状态权限",
                "Needs Focus status permission"
            )
        case .calendar:
            return L10n.tr(
                "需日历完整访问权限，仅读取事件",
                "Needs full Calendar access; only reads events"
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
                    "暂无可控设备",
                    "No controllable devices"
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
        if (newTrigger == .frontmostAppBecame || newTrigger == .frontmostAppLeft),
           newFrontmostAppBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
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
        let isFrontmostApp = newTrigger == .frontmostAppBecame || newTrigger == .frontmostAppLeft
        let options = AutomationTriggerOptions(
            batteryThresholdPercent: newBatteryThreshold,
            wifiSSID: newWiFiSSID,
            lateNightStartHour: newLateNightStart,
            lateNightEndHour: newLateNightEnd,
            calendarLeadMinutes: newCalendarLeadMinutes,
            scheduledTime: newTrigger == .scheduledTime ? newSchedule : nil,
            frontmostAppBundleID: isFrontmostApp ? newFrontmostAppBundleID : nil
        )
        let wifi: AutomationWiFiCondition
        switch newWiFiMode {
        case .any: wifi = .any
        case .only: wifi = .inAny(parsedSSIDs)
        case .exclude: wifi = .notIn(parsedSSIDs)
        }
        let restoreTrigger = newRestoreWhenContextEnds && newActionKind == .devices
            ? newTrigger.defaultRestoreTrigger
            : nil
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
            ),
            restoreWhenContextEnds: restoreTrigger != nil,
            restoreTrigger: restoreTrigger
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
        newRestoreWhenContextEnds = false
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
