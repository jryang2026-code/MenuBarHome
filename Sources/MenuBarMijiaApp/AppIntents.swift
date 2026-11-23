import AppIntents
import Foundation
import MijiaCore

// MARK: - App Intents (#57)
//
// Every intent executes through the same HomeStore entry points as the panel, so optimistic
// updates, optimistic locking, habit recording, and undo stay consistent with manually clicking a
// tile. Parameter lists come from the live store, which means Shortcuts/Siri only offer devices,
// scenes, and rooms that exist in the connected home.
//
// MARK: - Entities

struct DeviceEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "设备"
    static let defaultQuery = DeviceEntityQuery()

    let id: String
    let name: String
    let roomName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(L10n.displayRoomName(roomName))"
        )
    }

    init(device: SmartDevice) {
        self.id = device.id
        self.name = device.name
        self.roomName = device.roomName
    }
}

struct DeviceEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        let wanted = Set(identifiers)
        return await MainActor.run {
            HomeStore.shared.controllableDevices
                .filter { wanted.contains($0.id) }
                .map { DeviceEntity(device: $0) }
        }
    }

    func suggestedEntities() async throws -> [DeviceEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        return await MainActor.run {
            HomeStore.shared.controllableDevices.map { DeviceEntity(device: $0) }
        }
    }

    func entities(matching string: String) async throws -> [DeviceEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return try await suggestedEntities() }
        return await MainActor.run {
            HomeStore.shared.controllableDevices
                .filter {
                    $0.name.lowercased().contains(needle)
                        || $0.roomName.lowercased().contains(needle)
                }
                .map { DeviceEntity(device: $0) }
        }
    }
}

struct SceneEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "场景"
    static let defaultQuery = SceneEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(scene: HomeScene) {
        self.id = scene.id
        self.name = scene.name
    }
}

struct SceneEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SceneEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        let wanted = Set(identifiers)
        return await MainActor.run {
            HomeStore.shared.visibleScenes
                .filter { wanted.contains($0.id) }
                .map { SceneEntity(scene: $0) }
        }
    }

    func suggestedEntities() async throws -> [SceneEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        return await MainActor.run {
            HomeStore.shared.visibleScenes.map { SceneEntity(scene: $0) }
        }
    }

    func entities(matching string: String) async throws -> [SceneEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        let needle = IntentValidator.normalizedSceneName(string).lowercased()
        guard !needle.isEmpty else { return try await suggestedEntities() }
        return await MainActor.run {
            HomeStore.shared.visibleScenes
                .filter { IntentValidator.normalizedSceneName($0.name).lowercased().contains(needle) }
                .map { SceneEntity(scene: $0) }
        }
    }
}

struct RoomEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "房间"
    static let defaultQuery = RoomEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(L10n.displayRoomName(name))")
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct RoomEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [RoomEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        let wanted = Set(identifiers)
        return await MainActor.run {
            Self.allRooms(in: HomeStore.shared).filter { wanted.contains($0.id) }
        }
    }

    func suggestedEntities() async throws -> [RoomEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        return await MainActor.run {
            Self.allRooms(in: HomeStore.shared)
        }
    }

    func entities(matching string: String) async throws -> [RoomEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return try await suggestedEntities() }
        return await MainActor.run {
            Self.allRooms(in: HomeStore.shared)
                .filter {
                    $0.name.lowercased().contains(needle)
                        || L10n.displayRoomName($0.name).lowercased().contains(needle)
                }
        }
    }

    /// Areas from the registry plus any room that only exists as an environment reading.
    @MainActor
    private static func allRooms(in store: HomeStore) -> [RoomEntity] {
        var rooms = store.rooms.map { RoomEntity(id: $0.id, name: $0.name) }
        let knownNames = Set(rooms.map(\.name))
        for reading in store.environmentReadings
        where !reading.roomName.isEmpty && !knownNames.contains(reading.roomName) {
            if !rooms.contains(where: { $0.id == "reading:\(reading.roomName)" }) {
                rooms.append(RoomEntity(id: "reading:\(reading.roomName)", name: reading.roomName))
            }
        }
        return rooms
    }
}

// MARK: - Quick Actions (#575)

/// A built-in quick action as a Shortcut parameter. The `id` is `BuiltInURLScene`'s raw value, so a
/// saved shortcut keeps working even if the display title is re-translated.
struct QuickActionEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "快捷动作"
    static let defaultQuery = QuickActionEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(scene: BuiltInURLScene) {
        self.id = scene.rawValue
        self.name = scene.displayTitle
    }

    /// For a shortcut saved by an earlier build whose raw value no longer exists: resolving it
    /// reports "unsupported" instead of failing to decode the shortcut.
    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct QuickActionEntityQuery: EntityStringQuery {
    /// `undo` is deliberately absent: "undo the last action" is only meaningful right after an
    /// action, so offering it in Shortcuts would mostly report "nothing to undo".
    static let catalog: [BuiltInURLScene] = [.lightsOff, .softNightLight, .climateSleepOff, .allOff]

    func entities(for identifiers: [String]) async throws -> [QuickActionEntity] {
        // A shortcut saved by an earlier build can name an action this one no longer ships. Resolving
        // it to a placeholder keeps the shortcut runnable so `RunQuickActionIntent` can say
        // "unsupported" instead of Shortcuts failing entity resolution with no explanation.
        identifiers.map { identifier in
            Self.catalog.first { $0.rawValue == identifier }.map { QuickActionEntity(scene: $0) }
                ?? QuickActionEntity(id: identifier, name: identifier)
        }
    }

    func suggestedEntities() async throws -> [QuickActionEntity] {
        Self.catalog.map { QuickActionEntity(scene: $0) }
    }

    func entities(matching string: String) async throws -> [QuickActionEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return try await suggestedEntities() }
        return Self.catalog
            .filter { $0.displayTitle.lowercased().contains(needle) || $0.rawValue.lowercased().contains(needle) }
            .map { QuickActionEntity(scene: $0) }
    }
}

// MARK: - Intents

struct ToggleDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "切换设备"
    static let description: IntentDescription? = IntentDescription(
        "打开或关闭一台可控设备，与菜单栏面板共用开关、失败提示和撤销逻辑。"
    )

    @Parameter(title: "设备")
    var device: DeviceEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await execute(in: HomeStore.shared)
        await notifyExternalAction(message)
        return .result(dialog: intentDialog(message))
    }

    @MainActor
    func execute(in store: HomeStore) async throws -> String {
        try await store.waitForInitialSnapshot()
        if store.isControlBlockedByScreenLock { return store.screenLockBlockedMessage }
        if let rejection = store.capabilityControlRejectionMessage(forDeviceId: device.id) {
            return rejection
        }
        guard let current = store.controllableDevices.first(where: { $0.id == device.id }) else {
            return L10n.format(
                "找不到可控设备「%@」",
                "Controllable device \"%@\" was not found",
                device.name
            )
        }
        let isMomentary = current.isMomentaryButton
        let task = store.togglePrimary(current, offersSwitchLightMark: false)
        guard await task?.value == true else {
            return isMomentary
                ? L10n.format("%@ 触发失败", "Failed to trigger %@", current.name)
                : L10n.format("%@ 响应失败", "%@ failed to respond", current.name)
        }
        if isMomentary {
            return L10n.format("已触发 %@", "Triggered %@", current.name)
        }
        let isOn = store.devices.first(where: { $0.id == device.id })?.isActiveOn ?? false
        return isOn
            ? L10n.format("已打开 %@", "Turned on %@", current.name)
            : L10n.format("已关闭 %@", "Turned off %@", current.name)
    }
}

struct RunSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "执行场景"
    static let description: IntentDescription? = IntentDescription(
        "触发 Home Assistant 中已有的场景或脚本。"
    )

    @Parameter(title: "场景")
    var scene: SceneEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await execute(in: HomeStore.shared)
        await notifyExternalAction(message)
        return .result(dialog: intentDialog(message))
    }

    @MainActor
    func execute(in store: HomeStore) async throws -> String {
        try await store.waitForInitialSnapshot()
        if store.isControlBlockedByScreenLock { return store.screenLockBlockedMessage }
        if let rejection = store.capabilitySceneControlRejectionMessage(forSceneIdOrName: scene.id)
            ?? store.capabilitySceneControlRejectionMessage(forSceneIdOrName: scene.name) {
            return rejection
        }
        guard let current = store.visibleScenes.first(where: { $0.id == scene.id }) else {
            return L10n.format(
                "找不到场景「%@」",
                "Scene \"%@\" was not found",
                scene.name
            )
        }
        guard await store.triggerScene(current).value else {
            return L10n.format("场景「%@」执行失败", "Scene \"%@\" failed", current.name)
        }
        return L10n.format("已触发场景：%@", "Activated scene: %@", current.name)
    }
}

struct AskAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "一句话控制"
    static let description: IntentDescription? = IntentDescription(
        "用一句自然语言控制设备；与 AI 栏共用本地解析、云端回退和撤销。"
    )

    @Parameter(title: "指令")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else {
            return .result(dialog: intentDialog(L10n.tr(
                "请先说一句要执行的家居指令",
                "Say a smart-home command first"
            )))
        }

        let message = try await execute(in: HomeStore.shared)
        await notifyExternalAction(message)
        return .result(dialog: intentDialog(message))
    }

    /// Shortcuts and Siri have no suggestion chips, so an ambiguous command only ever reports back.
    @MainActor
    func execute(in store: HomeStore) async throws -> String {
        let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else {
            return L10n.tr("请先说一句要执行的家居指令", "Say a smart-home command first")
        }
        try await store.waitForInitialSnapshot()
        if store.isControlBlockedByScreenLock { return store.screenLockBlockedMessage }
        return await askAssistant(utterance, in: store)
    }
}

struct GetRoomClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "查询房间温湿度"
    static let description: IntentDescription? = IntentDescription(
        "返回某个房间最新的温度与湿度，可用于快捷指令中的条件判断。"
    )

    @Parameter(title: "房间")
    var room: RoomEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try await HomeStore.shared.waitForInitialSnapshot()
        let roomName = room.name
        let summary: (value: String, dialog: String) = await MainActor.run {
            let displayName = L10n.displayRoomName(roomName)
            let readings = HomeStore.shared.environmentReadings.filter { $0.roomName == roomName }
            guard let reading = readings.first(where: { $0.temperature != nil }) ?? readings.first else {
                return ("", missingClimateText(roomName: displayName))
            }

            var parts: [String] = []
            if let temperature = reading.temperature {
                // Spoken/returned value follows the display unit; the core stays Celsius (#52).
                parts.append(L10n.temperature(temperature, fractionDigits: 1))
            }
            if let humidity = reading.humidity {
                parts.append(String(format: "%.0f%%", humidity))
            }
            guard !parts.isEmpty else {
                return ("", missingClimateText(roomName: displayName))
            }
            let value = parts.joined(separator: " · ")
            // Whole sentence, not concatenation: zh-Hant/other tables can reorder it (#52).
            return (value, L10n.format("%@：%@", "%@: %@", displayName, value))
        }
        return .result(value: summary.value, dialog: intentDialog(summary.dialog))
    }
}

// MARK: - Parameterized Control (#575)

/// Bounds shared by the parameterized intents and their tests.
///
/// The `inclusiveRange` on each `@Parameter` already stops Shortcuts from sending 250 %, but Siri and
/// a hand-built shortcut can still deliver a stale or hand-typed value; `perform()` therefore
/// re-checks the number and reports a sentence instead of forwarding it to a device.
enum IntentParameterBounds {
    static let brightness = AppURLParser.brightnessRange
    static let colorTemperature = AppURLParser.colorTempRange

    static func brightnessPercent(_ raw: Int) -> Int? {
        brightness.contains(raw) ? raw : nil
    }

    static func colorTemperatureKelvin(_ raw: Int) -> Int? {
        colorTemperature.contains(raw) ? raw : nil
    }
}

struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "调亮度"
    static let description: IntentDescription? = IntentDescription(
        "把一台灯具调到指定亮度；与面板、URL 链接共用同一个写入门、锁屏拦截和高风险确认。"
    )

    @Parameter(title: "设备")
    var device: DeviceEntity

    @Parameter(title: "亮度（%）", inclusiveRange: (0, 100))
    var percent: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await execute(in: HomeStore.shared)
        await notifyExternalAction(message)
        return .result(dialog: intentDialog(message))
    }

    @MainActor
    func execute(in store: HomeStore) async throws -> String {
        try await store.waitForInitialSnapshot()
        guard let percent = IntentParameterBounds.brightnessPercent(percent) else {
            return L10n.tr("亮度需要在 0–100 之间", "Brightness must be between 0 and 100")
        }
        // `executeRaycastBrightness` is the exact path `menumijia://brightness` takes: capability
        // write gate, screen-lock block, hazard confirmation and optimistic write all live there.
        let outcome = await store.executeRaycastBrightness(deviceId: device.id, percent: percent)
        return outcome.message
    }
}

struct SetColorTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "调色温"
    static let description: IntentDescription? = IntentDescription(
        "把一台灯具调到指定色温（开尔文）；与面板、URL 链接共用同一个写入门和确认流程。"
    )

    @Parameter(title: "设备")
    var device: DeviceEntity

    @Parameter(title: "色温（K）", inclusiveRange: (1_000, 20_000))
    var kelvin: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await execute(in: HomeStore.shared)
        await notifyExternalAction(message)
        return .result(dialog: intentDialog(message))
    }

    @MainActor
    func execute(in store: HomeStore) async throws -> String {
        try await store.waitForInitialSnapshot()
        guard let kelvin = IntentParameterBounds.colorTemperatureKelvin(kelvin) else {
            return L10n.tr("色温需要在 1000–20000 K 之间", "Colour temperature must be between 1000 and 20000 K")
        }
        let outcome = await store.executeRaycastColorTemp(deviceId: device.id, kelvin: kelvin)
        return outcome.message
    }
}

struct RunQuickActionIntent: AppIntent {
    static let title: LocalizedStringResource = "执行快捷动作"
    static let description: IntentDescription? = IntentDescription(
        "执行全屋关灯、柔和夜灯、关温控风扇或一键全关，与面板快捷动作共用同一条控制路径。"
    )

    @Parameter(title: "快捷动作")
    var action: QuickActionEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await execute(in: HomeStore.shared)
        await notifyExternalAction(message)
        return .result(dialog: intentDialog(message))
    }

    @MainActor
    func execute(in store: HomeStore) async throws -> String {
        try await store.waitForInitialSnapshot()
        guard let builtIn = BuiltInURLScene(rawValue: action.id) else {
            return L10n.tr("不支持的快捷动作", "Unsupported quick action")
        }
        let outcome = await store.executeBuiltInURLScene(builtIn)
        return outcome.message
    }
}

// MARK: - Focus Filter (#575)

/// Lets a Focus mode (System Settings → 专注模式 → 添加过滤条件 → MenuBarHome) quieten ordinary
/// notifications and optionally run a quick action when it starts.
///
/// Safety alerts and the doorbell are never suppressed: `NotificationDeliveryPolicy` decides that
/// per category and refuses to honour any profile for them, so a misconfigured filter cannot hide a
/// leak, smoke or gas alert or a ringing doorbell.
struct MenuBarHomeFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "MenuBarHome 专注模式"
    static let description: IntentDescription? = IntentDescription(
        "在这个专注模式下不推送非安全通知，可在开始时执行一个快捷动作。安全告警与门铃绝不会被静音。"
    )

    @Parameter(title: "静音非安全通知", default: true)
    var suppressNonSafetyNotifications: Bool

    @Parameter(title: "开始时执行的快捷动作")
    var quickAction: QuickActionEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(Self.title)")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("静音非安全通知 \(\.$suppressNonSafetyNotifications)")
    }

    func perform() async throws -> some IntentResult {
        Self.applyProfile(suppressNonSafetyNotifications: suppressNonSafetyNotifications)
        if let quickAction {
            // The system does not wait for a scene to finish, and neither does the user: the Focus
            // is already on. The action runs in the background and keeps every write gate.
            Task { @MainActor in
                _ = await Self.runStartAction(quickAction, in: HomeStore.shared)
            }
        }
        return .result()
    }

    /// Records what this Focus mode asked for. Split from `perform()` so the parameter-to-profile
    /// mapping can be asserted against a throwaway suite instead of the real defaults.
    @discardableResult
    static func applyProfile(
        suppressNonSafetyNotifications: Bool,
        defaults: UserDefaults = .standard
    ) -> FocusFilterProfile {
        let profile = FocusFilterProfile(
            isEnabled: true,
            suppressNonSafetyNotifications: suppressNonSafetyNotifications
        )
        FocusFilterStorage.save(profile, defaults: defaults)
        return profile
    }

    /// Runs the configured quick action for a Focus that just started.
    ///
    /// A Focus can start before the first snapshot arrives (cold launch from a login item), so this
    /// waits a bounded five seconds instead of failing, then goes through `executeBuiltInURLScene`,
    /// which owns the screen-lock block, the capability gate and the high-risk confirmation.
    @MainActor
    static func runStartAction(_ action: QuickActionEntity, in store: HomeStore) async -> String? {
        try? await store.waitForInitialSnapshot(timeout: .seconds(5))
        guard let builtIn = BuiltInURLScene(rawValue: action.id) else { return nil }
        return await store.executeBuiltInURLScene(builtIn).message
    }
}

// MARK: - App Shortcuts

struct MenuBarMijiaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: ToggleDeviceIntent(),
                phrases: [
                    "用 \(.applicationName) 切换设备",
                    "用 \(.applicationName) 打开或关闭设备"
                ],
                shortTitle: "切换设备",
                systemImageName: "lightbulb"
            ),
            AppShortcut(
                intent: RunSceneIntent(),
                phrases: ["用 \(.applicationName) 执行场景"],
                shortTitle: "执行场景",
                systemImageName: "sparkles"
            ),
            AppShortcut(
                intent: AskAssistantIntent(),
                phrases: ["用 \(.applicationName) 执行家居指令"],
                shortTitle: "一句话控制",
                systemImageName: "text.bubble"
            ),
            AppShortcut(
                intent: GetRoomClimateIntent(),
                phrases: ["用 \(.applicationName) 查询房间温湿度"],
                shortTitle: "房间温湿度",
                systemImageName: "thermometer"
            ),
            AppShortcut(
                intent: SetBrightnessIntent(),
                phrases: ["用 \(.applicationName) 调亮度"],
                shortTitle: "调亮度",
                systemImageName: "sun.max"
            ),
            AppShortcut(
                intent: SetColorTemperatureIntent(),
                phrases: ["用 \(.applicationName) 调色温"],
                shortTitle: "调色温",
                systemImageName: "thermometer.sun"
            ),
            AppShortcut(
                intent: RunQuickActionIntent(),
                phrases: ["用 \(.applicationName) 执行快捷动作"],
                shortTitle: "快捷动作",
                systemImageName: "bolt.fill"
            )
        ]
    }
}

// MARK: - Helpers

/// Runs a natural-language command through the AI bar's entry point on the main actor and reduces
/// the store state to one line, so Shortcuts/Siri can show it as the intent result.
@MainActor
private func askAssistant(_ utterance: String, in store: HomeStore) async -> String {
    let plan = await store.runAssistantCommand(utterance)

    if store.pendingCloudConsent != nil {
        // The consent card lives in the assistant bar; open it so the user can allow this request.
        store.presentAssistantBar()
        HotkeyAndNotificationManager.shared.ensureMenuBarExtraWindowVisible()
        return L10n.tr(
            "这条指令需要云端 AI。请在 MenuBarHome 面板里确认后重试。",
            "This command needs cloud AI. Confirm it in the MenuBarHome panel and try again."
        )
    }
    if let plan, !plan.reply.isEmpty {
        return plan.reply
    }
    switch store.assistantState {
    case .done(let reply), .failed(let reply), .awaitingChoice(let reply):
        return reply
    case .thinking:
        return L10n.tr("正在执行…", "Working…")
    case .idle:
        return L10n.tr("没有找到可执行的设备操作", "No matching device actions")
    }
}

/// Runtime text (device names, assistant replies) is not a compile-time localization key, but
/// `IntentDialog` only accepts `LocalizedStringResource`; a literal resource falls back to the text
/// when no catalog entry exists.
private func intentDialog(_ text: String) -> IntentDialog {
    IntentDialog(LocalizedStringResource(stringLiteral: text))
}

private func missingClimateText(roomName: String) -> String {
    L10n.format(
        "%@ 没有可用的温湿度读数",
        "No temperature or humidity reading for %@",
        roomName
    )
}

/// Shortcuts/Siri show the dialog as the response; a banner also tells a user who invoked the
/// intent from Spotlight or Shortcuts that something happened. The notification is a no-op when the
/// app is not bundled or notifications were never allowed (#55).
@MainActor
private func notifyExternalAction(_ message: String) {
    HotkeyAndNotificationManager.shared.deliverExternalActionNotification(
        title: "MenuBarHome",
        body: message
    )
}
