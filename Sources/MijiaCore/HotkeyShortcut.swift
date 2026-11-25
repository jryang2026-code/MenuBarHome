import Foundation

// MARK: - Customizable Global Hotkey (#43)

/// Modifier keys of a global shortcut, stored as a plain bit mask in `UserDefaults`.
///
/// MijiaCore stays Foundation-only (the core test suite also runs on Linux), so this mirrors the
/// Carbon flags instead of importing `Carbon`.
public struct HotkeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let control = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)

    /// Masks away bits this build does not know about (e.g. caps lock / fn left in storage).
    public static let supported: HotkeyModifiers = [.command, .option, .control, .shift]

    /// Display order matches macOS (`⌃⌥⇧⌘`).
    public var symbolString: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// A recorded global shortcut: a macOS virtual key code plus the modifier bits.
public struct HotkeyShortcut: Equatable, Hashable, Sendable, Codable {
    public var keyCode: UInt16
    /// Layout-respecting label captured at record time (e.g. "M", "F5", "←").
    public var keyLabel: String
    public var modifiers: HotkeyModifiers

    /// `kVK_ANSI_M` (Carbon). The default stays ⌥M for existing users.
    public static let defaultKeyCode: UInt16 = 46
    public static let defaultShortcut = HotkeyShortcut(keyCode: defaultKeyCode, keyLabel: "M", modifiers: .option)

    /// F1–F20 key codes; these work without a modifier on macOS.
    static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107,
        113, 106, 64, 79, 80, 90,
    ]

    public init(keyCode: UInt16, keyLabel: String, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.modifiers = modifiers
    }

    /// A shortcut must be printable and either carry a modifier or be a function key; otherwise the
    /// global registration would swallow an ordinary letter system-wide.
    public var isValid: Bool {
        let label = keyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return false }
        return !modifiers.isEmpty || Self.functionKeyCodes.contains(keyCode)
    }

    /// e.g. "⌃⌥M".
    public var displayString: String {
        modifiers.symbolString + keyLabel
    }

    public var isDefault: Bool {
        keyCode == Self.defaultKeyCode && modifiers == .option
    }
}

/// Persistence for the global shortcut (#43). Keys are part of the public contract so a reinstall
/// and the settings UI agree on where the choice lives.
public enum HotkeyPreferences {
    public static let keyCodeKey = "menubar_hotkey_key_code"
    public static let modifiersKey = "menubar_hotkey_modifiers"
    public static let keyLabelKey = "menubar_hotkey_key_label"

    /// Falls back to ⌥M when nothing (or something unusable) was stored.
    public static func load(from defaults: UserDefaults = .standard) -> HotkeyShortcut {
        guard defaults.object(forKey: keyCodeKey) != nil else { return .defaultShortcut }
        let stored = HotkeyShortcut(
            keyCode: UInt16(clamping: defaults.integer(forKey: keyCodeKey)),
            keyLabel: defaults.string(forKey: keyLabelKey) ?? "",
            modifiers: HotkeyModifiers(rawValue: defaults.integer(forKey: modifiersKey))
                .intersection(.supported)
        )
        return stored.isValid ? stored : .defaultShortcut
    }

    public static func save(_ shortcut: HotkeyShortcut, to defaults: UserDefaults = .standard) {
        guard shortcut.isValid else { return }
        defaults.set(Int(shortcut.keyCode), forKey: keyCodeKey)
        defaults.set(shortcut.modifiers.rawValue, forKey: modifiersKey)
        defaults.set(shortcut.keyLabel, forKey: keyLabelKey)
    }

    public static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: keyCodeKey)
        defaults.removeObject(forKey: modifiersKey)
        defaults.removeObject(forKey: keyLabelKey)
    }
}

// MARK: - Per-Device / Per-Scene Global Hotkey Bindings (P1-6)

public enum HotkeyBindingTarget: Equatable, Hashable, Sendable, Codable {
    case devicePower(deviceId: String)
    case scene(sceneId: String)
    case mood(moodId: String)
    case quickAction(QuickAction)

    private enum CodingKeys: String, CodingKey {
        case kind, id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let id = try c.decode(String.self, forKey: .id)
        switch kind {
        case "devicePower":
            self = .devicePower(deviceId: id)
        case "scene":
            self = .scene(sceneId: id)
        case "mood":
            self = .mood(moodId: id)
        case "quickAction":
            guard let action = QuickAction(rawValue: id) else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Unknown QuickAction: \(id)")
            }
            self = .quickAction(action)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown HotkeyBindingTarget kind: \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .devicePower(let deviceId):
            try c.encode("devicePower", forKey: .kind)
            try c.encode(deviceId, forKey: .id)
        case .scene(let sceneId):
            try c.encode("scene", forKey: .kind)
            try c.encode(sceneId, forKey: .id)
        case .mood(let moodId):
            try c.encode("mood", forKey: .kind)
            try c.encode(moodId, forKey: .id)
        case .quickAction(let action):
            try c.encode("quickAction", forKey: .kind)
            try c.encode(action.rawValue, forKey: .id)
        }
    }
}

public struct HotkeyBinding: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public var target: HotkeyBindingTarget
    /// Cached display name from bind time so missing targets still render readably.
    public var targetLabel: String
    public var shortcut: HotkeyShortcut

    public init(
        id: String = UUID().uuidString,
        target: HotkeyBindingTarget,
        targetLabel: String,
        shortcut: HotkeyShortcut
    ) {
        self.id = id
        self.target = target
        self.targetLabel = targetLabel
        self.shortcut = shortcut
    }

    public func isTargetAvailable(devices: [SmartDevice], scenes: [HomeScene], moods: [MoodSnapshot] = []) -> Bool {
        switch target {
        case .devicePower(let deviceId):
            return devices.first(where: { $0.id == deviceId })?.isPrimaryToggleable == true
        case .scene(let sceneId):
            return scenes.contains(where: { $0.id == sceneId })
        case .mood(let moodId):
            return moods.contains { $0.id == moodId }
        case .quickAction:
            return !devices.isEmpty
        }
    }

    public func resolvedDisplayName(devices: [SmartDevice], scenes: [HomeScene], moods: [MoodSnapshot] = []) -> String {
        switch target {
        case .devicePower(let deviceId):
            return devices.first(where: { $0.id == deviceId })?.name ?? targetLabel
        case .scene(let sceneId):
            return scenes.first(where: { $0.id == sceneId })?.name ?? targetLabel
        case .mood(let moodId):
            return moods.first(where: { $0.id == moodId })?.name ?? targetLabel
        case .quickAction(let action):
            return action.title
        }
    }
}

public enum HotkeyConflictKind: Equatable, Sendable {
    case invalidShortcut
    case panelHotkey
    case existingBinding(targetLabel: String)
    case systemShortcut(label: String)
    case maxBindingsReached(limit: Int)

    public var userMessage: String {
        switch self {
        case .invalidShortcut:
            return L10n.tr(
                "需要至少一个 ⌘ / ⌥ / ⌃ / ⇧，或单按 F1–F20。",
                "Use at least one of ⌘ / ⌥ / ⌃ / ⇧, or a single F1–F20 key."
            )
        case .panelHotkey:
            return L10n.tr(
                "与呼出面板的全局快捷键冲突，换一个组合。",
                "Conflicts with the dashboard toggle shortcut. Choose another combination."
            )
        case .existingBinding(let label):
            return L10n.format(
                "已被「%@」占用，换一个组合。",
                "Already assigned to \"%@\". Choose another combination.",
                label
            )
        case .systemShortcut(let label):
            return L10n.format(
                "与系统快捷键（%@）冲突，换一个组合。",
                "Conflicts with a macOS system shortcut (%@). Choose another combination.",
                label
            )
        case .maxBindingsReached(let limit):
            return L10n.tr(
                "最多可绑定 \(limit) 组设备/场景热键。",
                "Up to \(limit) device/scene hotkeys are supported."
            )
        }
    }
}

public enum HotkeyBindingsPreferences {
    public static let storageKey = "menubar_custom_hotkey_bindings_v1"
    public static let maxBindings = 8

    public static func load(from defaults: UserDefaults = .standard) -> [HotkeyBinding] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data) else {
            return []
        }
        var seenIds = Set<String>()
        var seenChords = Set<HotkeyChordKey>()
        var out: [HotkeyBinding] = []
        for item in decoded {
            guard out.count < maxBindings,
                  !item.id.isEmpty,
                  seenIds.insert(item.id).inserted else { continue }
            var normalized = item
            normalized.shortcut.modifiers = item.shortcut.modifiers.intersection(.supported)
            guard normalized.shortcut.isValid else { continue }
            let chord = HotkeyChordKey(shortcut: normalized.shortcut)
            guard seenChords.insert(chord).inserted else { continue }
            out.append(normalized)
        }
        return out
    }

    public static func save(_ bindings: [HotkeyBinding], to defaults: UserDefaults = .standard) {
        let bounded = Array(bindings.prefix(maxBindings))
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: storageKey)
    }

    public static func validate(
        shortcut: HotkeyShortcut,
        excludingBindingId: String? = nil,
        panelShortcut: HotkeyShortcut,
        checkPanelConflict: Bool = true,
        existingBindings: [HotkeyBinding]
    ) -> HotkeyConflictKind? {
        let normalized = HotkeyShortcut(
            keyCode: shortcut.keyCode,
            keyLabel: shortcut.keyLabel,
            modifiers: shortcut.modifiers.intersection(.supported)
        )
        guard normalized.isValid else { return .invalidShortcut }

        if let systemName = knownSystemShortcutName(for: normalized) {
            return .systemShortcut(label: systemName)
        }

        let candidateChord = HotkeyChordKey(shortcut: normalized)
        if checkPanelConflict, HotkeyChordKey(shortcut: panelShortcut) == candidateChord {
            return .panelHotkey
        }

        if let duplicate = existingBindings.first(where: {
            $0.id != excludingBindingId && HotkeyChordKey(shortcut: $0.shortcut) == candidateChord
        }) {
            return .existingBinding(targetLabel: duplicate.targetLabel)
        }

        return nil
    }

    /// Well-known macOS system & standard app shortcuts that a global hotkey must not hijack.
    public static func knownSystemShortcutName(for shortcut: HotkeyShortcut) -> String? {
        let key = HotkeyChordKey(shortcut: shortcut)
        return knownSystemShortcuts[key]
    }

    private struct HotkeyChordKey: Hashable {
        let keyCode: UInt16
        let modifiers: Int

        init(shortcut: HotkeyShortcut) {
            self.keyCode = shortcut.keyCode
            self.modifiers = shortcut.modifiers.intersection(.supported).rawValue
        }

        init(keyCode: UInt16, modifiers: HotkeyModifiers) {
            self.keyCode = keyCode
            self.modifiers = modifiers.intersection(.supported).rawValue
        }
    }

    private static let knownSystemShortcuts: [HotkeyChordKey: String] = [
        HotkeyChordKey(keyCode: 49, modifiers: .command): "Spotlight (⌘Space)",
        HotkeyChordKey(keyCode: 49, modifiers: [.command, .option]): "Finder Search (⌥⌘Space)",
        HotkeyChordKey(keyCode: 48, modifiers: .command): "App Switcher (⌘Tab)",
        HotkeyChordKey(keyCode: 12, modifiers: .command): "Quit (⌘Q)",
        HotkeyChordKey(keyCode: 12, modifiers: [.control, .command]): "Lock Screen (⌃⌘Q)",
        HotkeyChordKey(keyCode: 13, modifiers: .command): "Close Window (⌘W)",
        HotkeyChordKey(keyCode: 4, modifiers: .command): "Hide App (⌘H)",
        HotkeyChordKey(keyCode: 46, modifiers: .command): "Minimize (⌘M)",
        HotkeyChordKey(keyCode: 43, modifiers: .command): "Settings (⌘,)",
        HotkeyChordKey(keyCode: 53, modifiers: [.command, .option]): "Force Quit (⌥⌘Esc)",
        HotkeyChordKey(keyCode: 8, modifiers: .command): "Copy (⌘C)",
        HotkeyChordKey(keyCode: 9, modifiers: .command): "Paste (⌘V)",
        HotkeyChordKey(keyCode: 7, modifiers: .command): "Cut (⌘X)",
        HotkeyChordKey(keyCode: 0, modifiers: .command): "Select All (⌘A)",
        HotkeyChordKey(keyCode: 6, modifiers: .command): "Undo (⌘Z)",
        HotkeyChordKey(keyCode: 20, modifiers: [.command, .shift]): "Screenshot (⇧⌘3)",
        HotkeyChordKey(keyCode: 21, modifiers: [.command, .shift]): "Screenshot Selection (⇧⌘4)",
        HotkeyChordKey(keyCode: 23, modifiers: [.command, .shift]): "Screenshot Menu (⇧⌘5)",
    ]
}
