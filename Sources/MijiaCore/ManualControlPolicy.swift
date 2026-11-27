import Foundation

/// The «this is a light» entry a wall-switch confirmation offers (#104). Choosing it marks the
/// device (persisted per device id) and executes the action in the same tap.
public struct ManualControlConfirmationMark: Equatable, Sendable {
    public let deviceId: String
    public let title: String

    public init(deviceId: String, title: String) {
        self.deviceId = deviceId
        self.title = title
    }
}

/// A second-confirmation prompt for a manual control action on a high-risk device (#143).
public struct ManualControlConfirmation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let confirmTitle: String
    public let cancelTitle: String
    /// Extra guidance under the decision text. Nil unless this prompt is the wall-switch case (#104).
    public let hint: String?
    /// #104: offered only when the device is the wall-switch shape the hint describes and the user
    /// has not marked it yet. Nil everywhere else.
    public let markAsLight: ManualControlConfirmationMark?

    public init(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String,
        hint: String? = nil,
        markAsLight: ManualControlConfirmationMark? = nil
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.hint = hint
        self.markAsLight = markAsLight
    }
}

/// #104: the user's per-device «这其实是灯» marks. Stored like every other per-device view
/// preference under a canonical device id, so a dual-source merge keeps them, and read by the
/// manual confirmation policy at its single decision point (`ManualControlPolicy`), never by a
/// UI layer deciding to skip the gate.
public enum SwitchLightMarks {
    public static let storageKey = ViewPreferenceKeys.switchesMarkedAsLights

    public static func load(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    public static func save(_ ids: Set<String>, defaults: UserDefaults) {
        defaults.set(ids.sorted(), forKey: storageKey)
    }

    public static func isMarked(_ deviceId: String, defaults: UserDefaults = .standard) -> Bool {
        load(defaults: defaults).contains(deviceId)
    }
}

/// Which hazard confirmation a facet write requires, or nil when the write is direct.
///
/// Kept more specific than a Bool so a continuous slider drag can reuse only an approval that
/// actually covers the tick or the re-evaluated pre-send command: cooling never covers warming,
/// and a known-start warming answer does not cover a missing reported start.
enum FacetDragApproval: Sendable, Equatable, Hashable {
    case write
    case power(Bool)
    case nonOffMode
    case warmer
    case unknownStartTemperature
}

package enum PanelConfirmationLevel: Hashable {
    case hold
    case slide
}

/// Safety rules for controls the user triggers directly (card tap, detail drawer, URL, App Intent,
/// assistant). The hazard table itself stays in `ModelActionPolicy`, so manual and AI actions cannot
/// drift apart (#143).
public enum ManualControlPolicy {
    /// True when a manual operation needs a second confirmation. De-escalating actions (turning a
    /// plug, heater, or water heater off, stopping a vacuum) stay direct: making a home safer must
    /// never require fighting a dialog. A wall switch the user marked as an ordinary light (#104)
    /// follows the mark here — the single decision point — so no caller can bypass the check.
    public static func requiresConfirmation(
        _ intent: DeviceIntent,
        devices: [SmartDevice],
        markedLightIds: Set<String>? = nil
    ) -> Bool {
        guard let device = devices.first(where: { $0.id == intent.targetId }) else { return false }
        return requiresConfirmation(intent.operation, for: device, markedLightIds: markedLightIds)
    }

    public static func requiresConfirmation(
        _ operation: IntentOperation,
        for device: SmartDevice,
        markedLightIds: Set<String>? = nil
    ) -> Bool {
        // Closing a cover is not automatically de-escalating: a garage door closing is itself
        // hazardous, so every cover operation goes through the subtype hazard table.
        if operation.deescalatesHazard, !device.kind.isCover { return false }
        if case .power = operation,
           isMarkedSwitchLight(device, markedLightIds: markedLightIds ?? SwitchLightMarks.load()) {
            return false
        }
        return ModelActionPolicy.needsConfirmation(
            DeviceIntent(targetId: device.id, operation: operation),
            devices: [device]
        )
    }

    package static func panelConfirmationLevel(
        _ operation: IntentOperation,
        for device: SmartDevice,
        markedLightIds: Set<String>? = nil
    ) -> PanelConfirmationLevel? {
        guard requiresConfirmation(operation, for: device, markedLightIds: markedLightIds) else { return nil }
        return panelConfirmationLevel(for: device)
    }

    static func panelConfirmationLevel(for device: SmartDevice) -> PanelConfirmationLevel {
        if IntentDeviceCategory(device) == .valve { return .slide }
        if case .cover(let spec) = device.kind, spec.subtype == .garageDoor { return .slide }
        return .hold
    }

    /// #104: the mark never widens. It only silences primary power on a device the existing
    /// wall-switch rule already considers light-like (the rename-hint shape); a stale id on a plug,
    /// cover, lock, valve, heater or UV lamp keeps its confirmation.
    static func isMarkedSwitchLight(_ device: SmartDevice, markedLightIds: Set<String>) -> Bool {
        markedLightIds.contains(device.id) && wallSwitchMayControlLight(device)
    }

    /// The prompt text for a hazardous manual operation, or nil when the action is low risk.
    /// `offersMarkAsLight` is enabled only by card primary-power confirmations (#104).
    public static func confirmation(
        _ intent: DeviceIntent,
        devices: [SmartDevice],
        markedLightIds: Set<String>? = nil,
        offersMarkAsLight: Bool = false
    ) -> ManualControlConfirmation? {
        guard let device = devices.first(where: { $0.id == intent.targetId }),
              requiresConfirmation(intent.operation, for: device, markedLightIds: markedLightIds) else { return nil }
        return buildConfirmation(
            intent.operation,
            for: device,
            markedLightIds: markedLightIds,
            offersMarkAsLight: offersMarkAsLight
        )
    }

    /// Builds the confirmation prompt for an operation even when the default hazard table would
    /// treat it as direct (e.g. external `cover-position` 0% on a window opener).
    static func forcedConfirmation(
        _ operation: IntentOperation,
        for device: SmartDevice,
        markedLightIds: Set<String>? = nil,
        offersMarkAsLight: Bool = false
    ) -> ManualControlConfirmation {
        buildConfirmation(
            operation,
            for: device,
            markedLightIds: markedLightIds,
            offersMarkAsLight: offersMarkAsLight
        )
    }

    private static func buildConfirmation(
        _ operation: IntentOperation,
        for device: SmartDevice,
        markedLightIds: Set<String>?,
        offersMarkAsLight: Bool
    ) -> ManualControlConfirmation {
        let marks = markedLightIds ?? SwitchLightMarks.load()
        let isPrimaryPower: Bool
        if case .power = operation { isPrimaryPower = true } else { isPrimaryPower = false }
        let markOption = (offersMarkAsLight && isPrimaryPower)
            ? switchLightMarkOption(for: device, marks: marks)
            : nil
        let hint = markOption != nil
            ? wallSwitchMarkPromptHint(for: device)
            : wallSwitchLightHint(for: device)
        return ManualControlConfirmation(
            title: L10n.tr("确认操作高风险设备？", "Control a high-risk device?"),
            message: L10n.format(
                "「%@」属于高风险设备，执行「%@」需要再次确认。",
                "\"%@\" is a high-risk device. Confirm \"%@\".",
                device.name,
                actionLabel(operation)
            ),
            confirmTitle: L10n.tr("确认执行", "Confirm"),
            cancelTitle: L10n.tr("取消", "Cancel"),
            hint: hint,
            markAsLight: markOption
        )
    }

    /// #104: the in-prompt «this is a light» entry, offered only while it would change something:
    /// the device is the rename-hint wall-switch shape and the id is not marked yet.
    private static func switchLightMarkOption(
        for device: SmartDevice,
        marks: Set<String>
    ) -> ManualControlConfirmationMark? {
        guard wallSwitchMayControlLight(device), !marks.contains(device.id) else { return nil }
        return ManualControlConfirmationMark(
            deviceId: device.id,
            title: L10n.tr("这是灯，以后不再询问", "This is a light, don't ask again")
        )
    }

    /// #104: the wall-switch shape the rename hint and the light mark both key on: a writable
    /// `.plug` card on a switch model whose name is the only thing keeping it out of
    /// `isSwitchedLight` (appending 「灯」 would make it a light).
    public static func wallSwitchMayControlLight(_ device: SmartDevice) -> Bool {
        guard case .plug(let spec) = device.kind,
              spec.powerWritable,
              !spec.switchEntityId.hasPrefix("button.") else { return false }
        let model = device.model.lowercased()
        guard model.contains(".switch."), !model.contains(".plug.") else { return false }
        guard IntentDeviceCategory(device) == .plug else { return false }
        var renamed = device
        renamed.name = device.name + "灯"
        return renamed.isSwitchedLight
    }

    /// Rename guidance for confirmations that do not offer the in-prompt mark button (#104).
    /// Appending 「灯」 reuses `isSwitchedLight`, so the sentence is shown only when that rename
    /// would actually stop the dialog.
    public static func wallSwitchLightHint(for device: SmartDevice) -> String? {
        guard wallSwitchMayControlLight(device) else { return nil }
        return L10n.tr(
            "如果这个开关实际控制的是普通照明灯，可在米家改名或在这里设置别名，名称里加上「灯」，以后就不会再弹出这个确认。",
            "If this switch actually controls an ordinary light, rename it in Xiaomi Home or set an alias here and include “light”. This confirmation will stop appearing."
        )
    }

    /// In-prompt guidance shown only when the confirmation actually carries the mark button (#104).
    public static func wallSwitchMarkPromptHint(for device: SmartDevice) -> String? {
        guard wallSwitchMayControlLight(device) else { return nil }
        return L10n.tr(
            "如果这个开关实际控制的是普通照明灯，点「这是灯，以后不再询问」，以后就不会再弹出这个确认。",
            "If this switch actually controls an ordinary light, tap “This is a light, don't ask again” and this confirmation will stop appearing."
        )
    }

    public static func speakerDirectiveConfirmation(
        text: String,
        for device: SmartDevice
    ) -> ManualControlConfirmation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ManualControlConfirmation(
            title: L10n.tr("确认向\(device.name)发送控制指令？", "Send directive to \(device.name)?"),
            message: L10n.tr(
                "「\(trimmed)」将作为小爱远程指令执行，可能触发全屋或高风险设备动作。请确认指令内容安全无误。",
                "“\(trimmed)” will execute as a remote XiaoAi directive and may trigger home-wide or high-risk device actions."
            ),
            confirmTitle: L10n.tr("确认执行", "Execute Directive"),
            cancelTitle: L10n.tr("取消", "Cancel")
        )
    }

    /// The whitelist controls availability; confirmation follows the operation's meaning. A feeding
    /// action reports its portion and the portions already dispensed today (#7).
    public static func confirmation(
        facet: FacetControl,
        value: JSONValue?,
        portion: Int? = nil,
        for device: SmartDevice
    ) -> ManualControlConfirmation? {
        guard facetRequiresConfirmation(facet, value: value, for: device) else { return nil }
        if facet.portionArgumentIndex != nil {
            return feedingConfirmation(facet, portion: portion, for: device)
        }
        let title = facet.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.flatMap { $0.isEmpty ? nil : $0 } ?? facet.name
        return ManualControlConfirmation(
            title: L10n.tr("确认修改更多设置？", "Change this additional setting?"),
            message: L10n.format(
                "执行「%@」的「%@」可能改变设备运行，请再次确认。",
                "Confirm changing an additional setting on %@: %@. It may affect device operation.",
                device.name,
                label
            ),
            confirmTitle: L10n.tr("确认执行", "Confirm"),
            cancelTitle: L10n.tr("取消", "Cancel")
        )
    }

    /// Dispensing food has a physical consequence and no undo, so the prompt names the portions.
    private static func feedingConfirmation(
        _ facet: FacetControl,
        portion: Int?,
        for device: SmartDevice
    ) -> ManualControlConfirmation {
        let count = portionLabel(facet, portion: portion)
        let message: String
        if let fedToday = facet.fedToday {
            message = L10n.format(
                "「%@」将投喂 %@，今日已投喂 %@。投喂后无法撤销，请确认。",
                "\"%@\" will dispense %@. Fed today: %@. This cannot be undone.",
                device.name,
                count,
                fedToday
            )
        } else {
            // Some feeders (`binuo.feeder.y1`, `xiaomi.feeder.iv2002`) report no daily total;
            // saying so keeps the prompt from looking like it silently dropped a fact.
            message = L10n.format(
                "「%@」将投喂 %@。该设备未上报今日已投喂份数；投喂后无法撤销，请确认。",
                "\"%@\" will dispense %@. This device does not report today's fed portions; this cannot be undone.",
                device.name,
                count
            )
        }
        return ManualControlConfirmation(
            title: L10n.tr("确认投喂？", "Dispense food?"),
            message: message,
            confirmTitle: L10n.tr("确认投喂", "Dispense"),
            cancelTitle: L10n.tr("取消", "Cancel")
        )
    }

    /// The portion the action will send, clamped to the spec's range.
    public static func portionCount(_ facet: FacetControl, portion: Int?) -> Int {
        facet.clampedPortion(portion)
    }

    private static func portionLabel(_ facet: FacetControl, portion: Int?) -> String {
        L10n.format("%@ 份", "%@ portion(s)", "\(portionCount(facet, portion: portion))")
    }

    /// The confirmation table from `deviceProfiles.json`, decoded once (#26). The same document
    /// Windows reads, with `ManualControlRules.defaults` as the only fallback.
    static let currentRules: DeviceProfiles.ManualControlRules =
        DeviceProfiles.current.manualControlPolicy ?? .defaults

    static func facetRequiresConfirmation(
        _ facet: FacetControl,
        value: JSONValue?,
        for device: SmartDevice,
        rules: DeviceProfiles.ManualControlRules = currentRules
    ) -> Bool {
        facetConfirmationKind(facet, value: value, for: device, rules: rules) != nil
    }

    static func facetConfirmationKind(
        _ facet: FacetControl,
        value: JSONValue?,
        for device: SmartDevice,
        rules: DeviceProfiles.ManualControlRules = currentRules
    ) -> FacetDragApproval? {
        if facet.kind == .button { return .write }
        if facet.target?.isAction == true { return .write }
        let service = facet.serviceName.lowercased()
        let name = facet.name.lowercased()
        let tokens = Set(name.split(separator: "-").map(String.init))
        let isMode = name == "mode" || name.hasSuffix("-mode")
        let isTargetTemperature = name == "target-temperature" || name.hasSuffix("-target-temperature")
        let isPower = ["on", "power", "power-switch"].contains(name) || name.hasSuffix("-power")
        let coverServices = ["curtain", "window-opener", "airer", "clothes-airer", "garage-door"]
        if isMode, device.kind.isCover || coverServices.contains(service) { return .write }

        let deviceType = genericDeviceType(device)
        // Locks, valves, security, routers, disposers and sterilizers keep every write behind a
        // confirmation even after advanced writes are enabled (#6 review).
        if strictlyHighRisk(deviceType: deviceType, service: service, rules: rules) { return .write }

        // Indicator, sound and child-lock controls never move the appliance's main function.
        let lowRiskServices = Set(rules.lowRiskServices)
        let lowRiskTokens = Set(rules.lowRiskTokens)
        let lowRiskHA = !tokens.isDisjoint(with: lowRiskTokens)
            || name.contains("night-light")
            || name.contains("child-lock")
            || name.contains("physical-controls-locked")
            || name.contains("auto-off")
        if lowRiskServices.contains(service) || lowRiskHA { return nil }

        // A Home Assistant auxiliary switch uses the `switch` domain with a device-specific object
        // id (`bath-heater-ptc`, `dual-plug-socket-2`), so it follows the power hazard table rather
        // than a MIoT property short name. This also keeps a heater switch's off direction direct.
        // #104: wall-switch light marks apply only to primary power, never to auxiliary switches.
        if service == "switch", let isOn = value?.miotBool {
            return requiresConfirmation(.power(isOn), for: device, markedLightIds: []) ? .power(isOn) : nil
        }

        let category = IntentDeviceCategory(device)
        let selectedMode = (value?.intValue).flatMap { selected in
            facet.options.first { $0.value == selected }?.label
        } ?? value?.stringValue

        if category == .heater {
            if isPower, let isOn = value?.miotBool { return isOn ? .power(true) : nil }
            if isMode {
                return selectedMode?.caseInsensitiveCompare("off") != .orderedSame ? .nonOffMode : nil
            }
            return .write
        }

        let heatingService = rules.heatingService.contains(service)
        if isPower, let isOn = value?.miotBool {
            if heatingService { return isOn ? .power(true) : nil }
            if !device.kind.isGenericDevice {
                return requiresConfirmation(.power(isOn), for: device, markedLightIds: []) ? .power(isOn) : nil
            }
        }

        let waterHeater: Bool
        switch device.kind {
        case .appliance(let spec): waterHeater = spec.heats
        case .climate: waterHeater = device.name.contains("热水器")
        default: waterHeater = false
        }
        if isTargetTemperature, let requested = value?.doubleValue,
           heatingService || waterHeater {
            if let current = facet.value?.doubleValue {
                return requested > current ? .warmer : nil
            }
            if heatingService { return .unknownStartTemperature }
            if case .appliance(let spec) = device.kind, spec.targetTemperature == nil {
                return .unknownStartTemperature
            }
            guard requiresConfirmation(.targetTemperature(requested), for: device) else { return nil }
            return .warmer
        }
        if isMode, heatingService || waterHeater {
            return selectedMode?.caseInsensitiveCompare("off") != .orderedSame ? .nonOffMode : nil
        }

        // Data-driven high-risk types and services (#6). Generic facets outside the low-risk
        // whitelist belong here too: enabling advanced writes is not itself the confirmation.
        // Heating target/mode rules above keep their off and cool-down directions direct.
        let profiles = DeviceProfiles.current
        let highRisk = MiotFacetEngine.matches(deviceType, anyOf: profiles.facets.highRiskTypes)
            || MiotFacetEngine.matches(service, anyOf: profiles.facets.highRiskServices)
            || (device.kind.isGenericDevice && !facet.writesByDefault)
        if highRisk {
            let isOff = (isPower && value?.miotBool == false)
                || (isMode && selectedMode?.caseInsensitiveCompare("off") == .orderedSame)
            guard !isOff else { return nil }
            if isPower { return .power(true) }
            if isMode { return .nonOffMode }
            return .write
        }
        return nil
    }

    /// The MIoT device type of a generic card, or an empty string for a dedicated card.
    private static func genericDeviceType(_ device: SmartDevice) -> String {
        if case .generic(let spec) = device.kind { return spec.deviceType }
        return ""
    }

    /// Writes that never take the low-risk shortcut: locks, valves, security, routers, disposers
    /// and sterilizers. These ask even for an off direction (#6 review). The table lives in
    /// `deviceProfiles.json` (#26).
    private static func strictlyHighRisk(
        deviceType: String,
        service: String,
        rules: DeviceProfiles.ManualControlRules
    ) -> Bool {
        MiotFacetEngine.matches(deviceType, anyOf: rules.strictlyHighRisk)
            || MiotFacetEngine.matches(service, anyOf: rules.strictlyHighRisk)
    }

    /// The lock-screen preference guard: off by default would leave every external control path open
    /// after the Mac locks, so the app ships with it on and lets people opt out in Settings (#143).
    public static func isScreenLockBlocked(isLocked: Bool, blockWhileLocked: Bool) -> Bool {
        isLocked && blockWhileLocked
    }

    private static func actionLabel(_ operation: IntentOperation) -> String {
        switch operation {
        case .power(true):
            return L10n.tr("打开", "turn on")
        case .power(false):
            return L10n.tr("关闭", "turn off")
        case .hvacMode(let mode):
            return mode == "off"
                ? L10n.tr("关闭", "turn off")
                : L10n.format("切换到%@", "switch to %@", SmartDevice.localizeHVACMode(mode))
        case .targetTemperature(let celsius):
            return L10n.format("设为 %@", "set to %@", L10n.temperature(celsius))
        case .fanSpeed(let speed):
            return L10n.format("风速调为%@", "set fan speed to %@", IntentReply.fanSpeedLabel(speed))
        case .fanPercentage(let percent):
            return L10n.format("风速调为 %@%", "set fan speed to %@%", String(percent))
        case .coverPosition(let percent):
            if percent == 0 { return L10n.tr("关闭", "close") }
            if percent == 100 { return L10n.tr("打开", "open") }
            return L10n.format("开至 %@%", "set position to %@%", String(percent))
        case .oscillation(let isOn):
            return isOn ? L10n.tr("开启摇头", "enable oscillation") : L10n.tr("关闭摇头", "disable oscillation")
        default:
            return L10n.tr("执行操作", "perform this action")
        }
    }
}

extension IntentOperation {
    /// Operations that end a hazard instead of starting or intensifying one. Turning a hazardous
    /// plug/heater off, switching a water heater to off, or stopping a vacuum is always allowed.
    var deescalatesHazard: Bool {
        switch self {
        case .power(false):
            return true
        case .hvacMode(let mode):
            return mode.caseInsensitiveCompare("off") == .orderedSame
        default:
            return false
        }
    }
}
