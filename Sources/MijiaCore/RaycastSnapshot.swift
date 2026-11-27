import Foundation

// MARK: - Raycast Companion Snapshot Contract (ADR-0013, ADR-0004)

/// Execution result written back to `raycast-snapshot.json` after a `menumijia://` command finishes.
public struct RaycastCommandFeedback: Codable, Equatable, Sendable {
    public var requestId: String?
    public var command: String
    public var message: String
    public var isError: Bool
    public var completedAt: String

    public init(
        requestId: String? = nil,
        command: String,
        message: String,
        isError: Bool = false,
        completedAt: String
    ) {
        self.requestId = requestId
        self.command = command
        self.message = message
        self.isError = isError
        self.completedAt = completedAt
    }
}

/// Fine-grained device capabilities exported so Raycast can offer category-accurate preset actions.
public struct RaycastDeviceCapabilities: Codable, Equatable, Sendable {
    public var canTogglePower: Bool
    public var brightnessWritable: Bool
    public var brightnessPercent: Int?
    public var colorWritable: Bool
    public var colorTempKelvin: Int?
    public var minKelvin: Int?
    public var maxKelvin: Int?
    public var supportsMoonlight: Bool
    public var availableEffects: [String]
    public var temperatureWritable: Bool
    public var targetTemperature: Double?
    public var currentTemperature: Double?
    public var minTemp: Double?
    public var maxTemp: Double?
    public var step: Double?
    public var hvacMode: String?
    public var availableModes: [String]
    public var fanSpeedWritable: Bool
    public var fanPercentage: Int?
    public var availablePresetModes: [String]
    public var coverSubtype: String?
    public var positionWritable: Bool
    public var positionPercent: Int?
    public var canMoveCover: Bool
    public var volumeWritable, muteWritable, isMuted, canPlayPause: Bool?
    public var volumePercent: Int?
    public var isHighRisk: Bool

    public init(
        canTogglePower: Bool = false,
        brightnessWritable: Bool = false,
        brightnessPercent: Int? = nil,
        colorWritable: Bool = false,
        colorTempKelvin: Int? = nil,
        minKelvin: Int? = nil,
        maxKelvin: Int? = nil,
        supportsMoonlight: Bool = false,
        availableEffects: [String] = [],
        temperatureWritable: Bool = false,
        targetTemperature: Double? = nil,
        currentTemperature: Double? = nil,
        minTemp: Double? = nil,
        maxTemp: Double? = nil,
        step: Double? = nil,
        hvacMode: String? = nil,
        availableModes: [String] = [],
        fanSpeedWritable: Bool = false,
        fanPercentage: Int? = nil,
        availablePresetModes: [String] = [],
        coverSubtype: String? = nil,
        positionWritable: Bool = false,
        positionPercent: Int? = nil,
        canMoveCover: Bool = false,
        volumeWritable: Bool? = nil, volumePercent: Int? = nil, muteWritable: Bool? = nil, isMuted: Bool? = nil, canPlayPause: Bool? = nil,
        isHighRisk: Bool = false
    ) {
        self.canTogglePower = canTogglePower
        self.brightnessWritable = brightnessWritable
        self.brightnessPercent = brightnessPercent
        self.colorWritable = colorWritable
        self.colorTempKelvin = colorTempKelvin
        self.minKelvin = minKelvin
        self.maxKelvin = maxKelvin
        self.supportsMoonlight = supportsMoonlight
        self.availableEffects = availableEffects
        self.temperatureWritable = temperatureWritable
        self.targetTemperature = targetTemperature
        self.currentTemperature = currentTemperature
        self.minTemp = minTemp
        self.maxTemp = maxTemp
        self.step = step
        self.hvacMode = hvacMode
        self.availableModes = availableModes
        self.fanSpeedWritable = fanSpeedWritable
        self.fanPercentage = fanPercentage
        self.availablePresetModes = availablePresetModes
        self.coverSubtype = coverSubtype
        self.positionWritable = positionWritable
        self.positionPercent = positionPercent
        self.canMoveCover = canMoveCover
        self.volumeWritable = volumeWritable; self.volumePercent = volumePercent
        self.muteWritable = muteWritable; self.isMuted = isMuted; self.canPlayPause = canPlayPause
        self.isHighRisk = isHighRisk
    }
}

/// A visible device exported to `raycast-snapshot.json`.
public struct RaycastDeviceItem: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var roomId: String
    public var roomName: String
    public var roomSortOrder: Int
    public var category: String
    public var categoryTitle: String
    public var model: String
    public var stateText: String
    public var isOnline: Bool
    public var isActiveOn: Bool
    public var isPrimaryToggleable: Bool
    public var isFavorite: Bool
    public var favoriteRank: Int?
    public var pinyinInitials: String
    public var pinyinFull: String
    public var roomPinyinInitials: String
    public var capabilities: RaycastDeviceCapabilities

    public init(
        id: String,
        name: String,
        roomId: String,
        roomName: String,
        roomSortOrder: Int,
        category: String,
        categoryTitle: String,
        model: String,
        stateText: String,
        isOnline: Bool,
        isActiveOn: Bool,
        isPrimaryToggleable: Bool,
        isFavorite: Bool,
        favoriteRank: Int?,
        pinyinInitials: String,
        pinyinFull: String,
        roomPinyinInitials: String,
        capabilities: RaycastDeviceCapabilities
    ) {
        self.id = id
        self.name = name
        self.roomId = roomId
        self.roomName = roomName
        self.roomSortOrder = roomSortOrder
        self.category = category
        self.categoryTitle = categoryTitle
        self.model = model
        self.stateText = stateText
        self.isOnline = isOnline
        self.isActiveOn = isActiveOn
        self.isPrimaryToggleable = isPrimaryToggleable
        self.isFavorite = isFavorite
        self.favoriteRank = favoriteRank
        self.pinyinInitials = pinyinInitials
        self.pinyinFull = pinyinFull
        self.roomPinyinInitials = roomPinyinInitials
        self.capabilities = capabilities
    }
}

/// Built-in quick action (`QuickAction`, `allOff`, `undo`) exported to `raycast-snapshot.json`.
public struct RaycastQuickActionItem: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var icon: String
    public var isEnabled: Bool
    public var affectedCount: Int
    public var pinyinInitials: String

    public init(
        id: String,
        name: String,
        subtitle: String,
        icon: String,
        isEnabled: Bool,
        affectedCount: Int,
        pinyinInitials: String
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.icon = icon
        self.isEnabled = isEnabled
        self.affectedCount = affectedCount
        self.pinyinInitials = pinyinInitials
    }
}

/// Remote scene (`HomeScene`) exported to `raycast-snapshot.json`.
public struct RaycastSceneItem: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var entityId: String
    public var roomName: String?
    public var icon: String
    public var visualCategory: String
    public var pinyinInitials: String
    public var pinyinFull: String

    public init(
        id: String,
        name: String,
        entityId: String,
        roomName: String? = nil,
        icon: String,
        visualCategory: String,
        pinyinInitials: String,
        pinyinFull: String
    ) {
        self.id = id
        self.name = name
        self.entityId = entityId
        self.roomName = roomName
        self.icon = icon
        self.visualCategory = visualCategory
        self.pinyinInitials = pinyinInitials
        self.pinyinFull = pinyinFull
    }
}

/// Sensor environment reading exported to `raycast-snapshot.json`.
public struct RaycastClimateItem: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var roomName: String
    public var temperature: Double?
    public var humidity: Double?
    public var battery: Int?
    public var updatedAt: String
    public var pinyinInitials: String

    public init(
        id: String,
        label: String,
        roomName: String,
        temperature: Double?,
        humidity: Double?,
        battery: Int?,
        updatedAt: String,
        pinyinInitials: String
    ) {
        self.id = id
        self.label = label
        self.roomName = roomName
        self.temperature = temperature
        self.humidity = humidity
        self.battery = battery
        self.updatedAt = updatedAt
        self.pinyinInitials = pinyinInitials
    }
}

/// Sanitized automation run record (controlled enums only; no calendar titles, window names, SSIDs, or credentials).
public struct RaycastAutomationRunItem: Codable, Equatable, Sendable {
    public var ruleId, trigger, result, at: String
    public var skipReason: String?
    public init(ruleId: String, trigger: String, result: String, skipReason: String? = nil, at: String) {
        self.ruleId = ruleId; self.trigger = trigger; self.result = result; self.skipReason = skipReason; self.at = at
    }
}

/// Sanitized automation health and run/skip summary exported to `raycast-snapshot.json`.
public struct RaycastAutomationStatus: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var ruleCount, enabledRuleCount, executedCount, skippedCount: Int
    public var recentRuns: [RaycastAutomationRunItem]
    public init(enabled: Bool, ruleCount: Int, enabledRuleCount: Int, executedCount: Int, skippedCount: Int, recentRuns: [RaycastAutomationRunItem] = []) {
        self.enabled = enabled; self.ruleCount = ruleCount; self.enabledRuleCount = enabledRuleCount
        self.executedCount = executedCount; self.skippedCount = skippedCount; self.recentRuns = recentRuns
    }
}

/// Versioned snapshot written by `MenuBarHome` for `raycast-mijia` to read without touching credentials.
public struct RaycastSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var updatedAt: String
    public var bridgeToken: String
    public var connectionSummary: String
    public var isStale: Bool
    public var devices: [RaycastDeviceItem]
    public var quickActions: [RaycastQuickActionItem]
    public var scenes: [RaycastSceneItem]
    public var climate: [RaycastClimateItem]
    public var environmentReadings: [RaycastClimateItem]
    public var lastCommandFeedback: RaycastCommandFeedback?
    public var automationStatus: RaycastAutomationStatus?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        updatedAt: String,
        bridgeToken: String,
        connectionSummary: String,
        isStale: Bool,
        devices: [RaycastDeviceItem],
        quickActions: [RaycastQuickActionItem],
        scenes: [RaycastSceneItem],
        climate: [RaycastClimateItem],
        environmentReadings: [RaycastClimateItem],
        lastCommandFeedback: RaycastCommandFeedback? = nil,
        automationStatus: RaycastAutomationStatus? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.bridgeToken = bridgeToken
        self.connectionSummary = connectionSummary
        self.isStale = isStale
        self.devices = devices
        self.quickActions = quickActions
        self.scenes = scenes
        self.climate = climate
        self.environmentReadings = environmentReadings
        self.lastCommandFeedback = lastCommandFeedback
        self.automationStatus = automationStatus
    }

    func hasSameExportedContent(as other: RaycastSnapshot) -> Bool {
        var lhs = self
        lhs.updatedAt = other.updatedAt
        for index in lhs.climate.indices {
            lhs.climate[index].updatedAt = other.updatedAt
        }
        for index in lhs.environmentReadings.indices {
            lhs.environmentReadings[index].updatedAt = other.updatedAt
        }
        var rhs = other
        for index in rhs.climate.indices {
            rhs.climate[index].updatedAt = other.updatedAt
        }
        for index in rhs.environmentReadings.indices {
            rhs.environmentReadings[index].updatedAt = other.updatedAt
        }
        return lhs == rhs
    }
}

/// Read-only status of the local companion integration (Raycast, local CLI, MCP).
public enum CompanionCheckStatus: String, Equatable, Sendable { case disabled, ready, needsAttention }

/// Result of a read-only companion integration check; never mutates external app configs.
public struct CompanionCheckReport: Equatable, Sendable {
    public let status: CompanionCheckStatus
    public let summary: String
    public let snapshotPath: String
    public let snapshotPresent, tokenMatches, permissionsOwnerOnly: Bool
    public let exportedDeviceCount, exportedSceneCount: Int

    public init(
        status: CompanionCheckStatus, summary: String, snapshotPath: String,
        snapshotPresent: Bool = false, tokenMatches: Bool = false,
        permissionsOwnerOnly: Bool = false, exportedDeviceCount: Int = 0, exportedSceneCount: Int = 0
    ) {
        self.status = status; self.summary = summary; self.snapshotPath = snapshotPath
        self.snapshotPresent = snapshotPresent; self.tokenMatches = tokenMatches
        self.permissionsOwnerOnly = permissionsOwnerOnly
        self.exportedDeviceCount = exportedDeviceCount; self.exportedSceneCount = exportedSceneCount
    }
}

/// Builds copyable configuration snippets for local companions without editing external files
/// or exposing `bridgeToken` / home credentials (ADR-0013, P6a-M).
public enum CompanionIntegrationConfig {
    public static let defaultMCPCommandFallback = "mijia-mcp"

    /// Resolves `mijia-mcp`: bundled `.app/Contents/Resources/cli/mijia-mcp` -> dev `scripts/mijia-mcp` -> installed `.app` -> `PATH`.
    public static func resolveMCPCommandPath(
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        executableURL: URL? = Bundle.main.executableURL,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = bundleResourceURL.map { [$0.appendingPathComponent("cli/mijia-mcp").standardizedFileURL.path] } ?? []
        for seed in [executableURL?.deletingLastPathComponent(), currentDirectoryURL].compactMap({ $0 }) {
            var dir = seed.standardizedFileURL
            for _ in 0..<6 {
                candidates.append(dir.appendingPathComponent("scripts/mijia-mcp").path)
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        candidates.append("/Applications/MenuBarHome.app/Contents/Resources/cli/mijia-mcp")
        candidates.append(homeDirectoryURL.appendingPathComponent("Applications/MenuBarHome.app/Contents/Resources/cli/mijia-mcp").standardizedFileURL.path)
        candidates.append(contentsOf: (pathEnvironment ?? "").split(separator: ":").filter { !$0.isEmpty }.map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("mijia-mcp").standardizedFileURL.path })
        var seen: Set<String> = []
        return candidates.first { seen.insert($0).inserted && isExecutable($0) }
    }

    public static func mcpConfigJSON(
        snapshotURL: URL = RaycastSnapshotExporter.defaultSnapshotURL,
        mcpCommandPath: String? = nil
    ) -> String {
        let trimmed = mcpCommandPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = (trimmed?.isEmpty == false) ? trimmed! : (resolveMCPCommandPath() ?? defaultMCPCommandFallback)
        let payload: [String: Any] = [
            "mcpServers": ["menubarhome": ["command": command, "env": ["MENUBARMIJIA_SNAPSHOT_PATH": snapshotURL.path]]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Writes `RaycastSnapshot` atomically with `0600` owner-only permissions.
public enum RaycastSnapshotExporter {
    public static let bridgeTokenDefaultsKey = "raycast_bridge_token_v1"
    /// Legacy defaults mirror for companion integration. Authoritative state lives in
    /// `CapabilitySelectionStore` under `FeatureID.companionIntegration` (P6a-M).
    public static let integrationEnabledKey = "raycast_integration_enabled"

    public static let defaultSnapshotURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("MenuBarMijia", isDirectory: true)
            .appendingPathComponent("raycast-snapshot.json", isDirectory: false)
    }()

    static func loadBridgeToken(in defaults: UserDefaults) -> String? {
        guard let existing = defaults.string(forKey: bridgeTokenDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              existing.count >= URLDirectControl.minimumBridgeTokenLength else { return nil }
        return existing
    }

    public static func loadOrCreateBridgeToken(in defaults: UserDefaults = .standard) -> String {
        if let existing = loadBridgeToken(in: defaults) { return existing }
        let generated = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        defaults.set(generated, forKey: bridgeTokenDefaultsKey)
        return generated
    }

    /// Serial, so a slower older write can never land after a newer one.
    private static let writeQueue = DispatchQueue(label: "MenuBarMijia.RaycastSnapshotExporter", qos: .utility)
    private static let generationLock = NSLock()
    private nonisolated(unsafe) static var exportGenerations: [URL: UInt64] = [:]

    public static func currentExportGeneration(for fileURL: URL = defaultSnapshotURL) -> UInt64 {
        let key = fileURL.standardizedFileURL
        generationLock.lock()
        defer { generationLock.unlock() }
        return exportGenerations[key] ?? 0
    }

    /// Synchronously advances the generation for `fileURL`, so any queued `writeInBackground`
    /// carrying an older generation becomes a no-op before touching disk.
    @discardableResult
    public static func invalidateExports(for fileURL: URL = defaultSnapshotURL) -> UInt64 {
        let key = fileURL.standardizedFileURL
        generationLock.lock()
        defer { generationLock.unlock() }
        let next = (exportGenerations[key] ?? 0) &+ 1
        exportGenerations[key] = next
        return next
    }

    public static func writeInBackground(
        _ snapshot: RaycastSnapshot,
        to fileURL: URL = defaultSnapshotURL,
        generation: UInt64? = nil
    ) {
        let key = fileURL.standardizedFileURL
        let expectedGeneration = generation ?? currentExportGeneration(for: key)
        writeQueue.async {
            guard currentExportGeneration(for: key) == expectedGeneration else { return }
            try? write(snapshot, to: fileURL)
        }
    }

    static func isMissingSnapshotError(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }

    /// Invalidates queued exports and waits for any in-flight write before deleting its output.
    static func removeSnapshot(at fileURL: URL) throws {
        invalidateExports(for: fileURL)
        try writeQueue.sync {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch let error as NSError where isMissingSnapshotError(error) {
                // Already removed.
            }
        }
    }

    /// Waits for all queued background snapshot writes/removals to finish (test synchronization).
    public static func flushBackgroundQueue() {
        writeQueue.sync {}
    }

    public static func write(_ snapshot: RaycastSnapshot, to fileURL: URL = defaultSnapshotURL) throws {
        let fm = FileManager.default
        let dirURL = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dirURL.path) {
            try fm.createDirectory(
                at: dirURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } else {
            try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: dirURL.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
    }
}

// MARK: - HomeStore Companion Bridge Integration

extension HomeStore {
    private static let roomAliasesDefaultsKey = "room_aliases"
    private static let roomOrderDefaultsKey = "room_custom_order"

    public static var companionDisabledMessage: String {
        L10n.tr(
            "外部伴生集成已关闭，已拒绝伴生命令",
            "Companion integration is turned off; companion command rejected"
        )
    }

    public static var companionIdentityUnavailableMessage: String {
        L10n.tr(
            "暂时无法读取历史设置或凭据，伴生命令和快照导出已暂停。",
            "Companion commands and snapshot export are paused while settings or credentials are unavailable."
        )
    }

    public static var companionInvalidTokenMessage: String {
        L10n.tr(
            "伴生令牌已失效，请重新获取最新本地快照后重试",
            "Companion token is invalid or expired; refresh from the latest local snapshot and try again"
        )
    }

    /// Authoritative companion integration toggle (`FeatureID.companionIntegration`).
    /// Fresh installs default off; upgraded users preserve existing behavior (on).
    public var companionIntegrationEnabled: Bool {
        !companionRevokedForSession && capabilitySelection.enabledFeatures.contains(.companionIntegration)
    }
    public var raycastIntegrationEnabled: Bool { companionIntegrationEnabled }
    public func companionCanExecute(generation: UInt64) -> Bool {
        companionIntegrationEnabled && !isIdentityUncertain && companionGeneration == generation
    }
    public var companionSnapshotFileURL: URL { raycastSnapshotTestURL ?? RaycastSnapshotExporter.defaultSnapshotURL }

    /// Runs one companion request under the generation it started with, so every write it makes is
    /// refused once the companion was disconnected. The `@TaskLocal` inheritance is intentional:
    /// unstructured tasks this command starts, such as the undo window or a delayed follow-up, keep
    /// the same generation and stop writing with it instead of outliving the disconnect.
    public func withCompanionCommandGeneration<T>(_ generation: UInt64, body: @MainActor () async -> T) async -> T {
        await Self.$companionCommandContext.withValue((ObjectIdentifier(self), generation), operation: body)
    }

    /// Local random bridge token for `menumijia://...?token=...`; `nil` while integration is off.
    public var raycastBridgeToken: String? {
        guard companionIntegrationEnabled, !isIdentityUncertain else { return nil }
        return RaycastSnapshotExporter.loadOrCreateBridgeToken(in: userDefaults)
    }

    /// Turns companion integration on or off and persists atomically; rolls back on write failure (P6a-M).
    @discardableResult
    public func setCompanionIntegrationEnabled(_ enabled: Bool) -> Bool {
        if isIdentityUncertain {
            guard !enabled else {
                showToast(L10n.tr("仍无法读取历史配置或凭据，请检查钥匙串授权后重试", "Still unable to read settings or credentials; check Keychain access and try again"), isError: true)
                return false
            }
            companionRevokedForSession = true
            if applyCompanionIntegrationTransition(enabled: false) {
                showToast(L10n.tr(
                    "已在本次运行中关闭伴生集成并删除快照，开关状态仅本次生效",
                    "Companion integration was turned off for this session and the snapshot was removed. The switch state applies to this session only."
                ))
                return true
            }
            return false
        }
        let wasEnabled = companionIntegrationEnabled
        let wasSelected = capabilitySelection.enabledFeatures.contains(.companionIntegration)
        if enabled && wasEnabled {
            exportRaycastSnapshotIfNeeded()
            return true
        }
        if !enabled && !wasSelected {
            return revokeCompanionIntegration()
        }
        let previous = capabilitySelection
        var next = capabilitySelection
        if enabled { next.enabledFeatures.insert(.companionIntegration) } else { next.enabledFeatures.remove(.companionIntegration) }
        isPersistingCompanionToggle = true
        capabilitySelection = next.normalized(with: .shared)
        let saved = persistCapabilitySelection()
        if !saved {
            capabilitySelection = previous
            isPersistingCompanionToggle = false
            showToast(L10n.tr("无法保存伴生集成开关状态，请重试", "Could not save the companion integration switch; try again"), isError: true)
            return false
        }
        isPersistingCompanionToggle = false
        let isSelected = capabilitySelection.enabledFeatures.contains(.companionIntegration)
        if isSelected == enabled { companionRevokedForSession = false }
        let actualEnabled = companionIntegrationEnabled
        let transitioned = wasEnabled != actualEnabled || wasSelected != isSelected
        let applied = transitioned ? applyCompanionIntegrationTransition(enabled: actualEnabled) : true
        return applied && actualEnabled == enabled
    }

    @discardableResult
    func applyCompanionIntegrationTransition(enabled: Bool) -> Bool {
        if !isIdentityUncertain {
            userDefaults.set(enabled, forKey: RaycastSnapshotExporter.integrationEnabledKey)
        }
        companionGeneration &+= 1
        capabilityGeneration &+= 1
        raycastExportTask?.cancel()
        raycastExportTask = nil
        if enabled {
            lastRaycastCommandFeedback = nil
            _ = raycastBridgeToken
            exportRaycastSnapshotIfNeeded()
            onCompanionIntegrationChanged?(true)
            return true
        }
        return revokeCompanionIntegration()
    }

    private func revokeCompanionIntegration() -> Bool {
        lastExportedRaycastSnapshot = nil
        lastRaycastCommandFeedback = nil
        if pendingCloudConsent?.companionGeneration != nil {
            pendingCloudConsent = nil
        }
        userDefaults.removeObject(forKey: RaycastSnapshotExporter.bridgeTokenDefaultsKey)
        defer { onCompanionIntegrationChanged?(false) }
        guard raycastSnapshotTestURL != nil || !isTestEnvironment else { return true }
        do {
            try RaycastSnapshotExporter.removeSnapshot(at: companionSnapshotFileURL)
            return true
        } catch {
            showToast(L10n.tr(
                "伴生命令已停用，旧令牌已作废，但本地快照删除失败。请检查文件权限后重试断开。",
                "Companion commands are disabled and the old token is revoked, but the local snapshot could not be deleted. Check file permissions and try disconnecting again."
            ), isError: true)
            return false
        }
    }

    @discardableResult
    public func setRaycastIntegration(enabled: Bool) -> Bool { setCompanionIntegrationEnabled(enabled) }

    /// Revokes the local companion integration and reports whether its snapshot was removed.
    @discardableResult
    public func disconnectCompanionIntegration() -> Bool {
        guard setCompanionIntegrationEnabled(false) else { return false }
        if !isIdentityUncertain {
            showToast(L10n.tr(
                "已断开伴生集成，旧令牌已作废，本地快照已清除",
                "Disconnected companion integration. The old token is revoked and the local snapshot is cleared."
            ))
        }
        return true
    }

    public func companionMCPConfigurationJSON(mcpCommandPath: String? = nil) -> String {
        CompanionIntegrationConfig.mcpConfigJSON(snapshotURL: companionSnapshotFileURL, mcpCommandPath: mcpCommandPath)
    }

    /// Read-only diagnostic check of the local companion integration and snapshot file.
    public func checkCompanionIntegrationStatus() -> CompanionCheckReport {
        let fileURL = companionSnapshotFileURL, path = fileURL.path
        let fm = FileManager.default
        if companionIntegrationEnabled, isIdentityUncertain {
            return CompanionCheckReport(
                status: .needsAttention,
                summary: Self.companionIdentityUnavailableMessage,
                snapshotPath: path,
                snapshotPresent: (try? fm.attributesOfItem(atPath: path)) != nil
            )
        }
        guard companionIntegrationEnabled else {
            do {
                _ = try fm.attributesOfItem(atPath: path)
                return CompanionCheckReport(
                    status: .needsAttention,
                    summary: L10n.tr(
                        "伴生集成已关闭，但本地快照仍在。请点击「断开」清除残留文件。",
                        "Companion integration is off, but the local snapshot remains. Click Disconnect to remove it."
                    ),
                    snapshotPath: path, snapshotPresent: true
                )
            } catch let error as NSError where RaycastSnapshotExporter.isMissingSnapshotError(error) {
                // The snapshot is absent.
            } catch {
                return CompanionCheckReport(
                    status: .needsAttention,
                    summary: L10n.tr(
                        "无法确认本地快照是否已清除。请检查文件权限后重新检测。",
                        "The local snapshot could not be checked. Check file permissions and try again."
                    ),
                    snapshotPath: path
                )
            }
            return CompanionCheckReport(
                status: .disabled,
                summary: L10n.tr(
                    "伴生集成已关闭，当前不导出快照并拒绝伴生命令；普通外部链接仍按安全与提醒设置执行",
                    "Companion integration is off; snapshot export is stopped and companion commands are rejected. Ordinary external links still follow Safety & Alerts."
                ),
                snapshotPath: path
            )
        }
        let exists = fm.fileExists(atPath: path)
        guard exists, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(RaycastSnapshot.self, from: data),
              decoded.schemaVersion == RaycastSnapshot.currentSchemaVersion else {
            return CompanionCheckReport(
                status: .needsAttention,
                summary: L10n.tr("尚未检测到有效的本地快照文件，请等待设备同步完成或重新开启此功能", "No valid local snapshot file was found yet; wait for device sync or re-enable this feature"),
                snapshotPath: path, snapshotPresent: exists
            )
        }
        let tokenMatches = URLDirectControl.isValidBridgeToken(decoded.bridgeToken, expectedToken: RaycastSnapshotExporter.loadBridgeToken(in: userDefaults))
        let perms = ((try? fm.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)?.intValue ?? 0
        let ownerOnly = (perms & 0o777) == 0o600
        let devicesCount = decoded.devices.count, scenesCount = decoded.scenes.count
        let (status, summary): (CompanionCheckStatus, String)
        if !tokenMatches {
            (status, summary) = (.needsAttention, L10n.tr("本地快照中的令牌已过期，请重新开启或等待下一次快照刷新", "The token in the local snapshot is stale; re-enable or wait for the next snapshot refresh"))
        } else if !ownerOnly {
            (status, summary) = (.needsAttention, L10n.tr("本地快照权限不是仅本机用户可读（0600），建议断开后重新开启", "Local snapshot permissions are not owner-only (0600); disconnect and turn this feature back on"))
        } else {
            (status, summary) = (.ready, L10n.format("伴生集成正常 · 已导出 %@ 台设备与 %@ 个场景（仅本机 0600 权限）", "Companion ready · Exported %@ device(s) and %@ scene(s) (local 0600 only)", String(devicesCount), String(scenesCount)))
        }
        return CompanionCheckReport(
            status: status, summary: summary, snapshotPath: path, snapshotPresent: true,
            tokenMatches: tokenMatches, permissionsOwnerOnly: ownerOnly,
            exportedDeviceCount: devicesCount, exportedSceneCount: scenesCount
        )
    }

    /// All visible devices across all rooms (ignoring the panel's temporary `listCut` filter),
    /// respecting hidden devices, offline hiding, and light-group folding.
    public var raycastVisibleDevices: [SmartDevice] {
        let baseVisible = devices.filter { dev in
            if hiddenDeviceIds.contains(dev.id) { return false }
            if hideOfflineDevices && !dev.isOnline { return false }
            return showsDeviceCategory(dev)
        }
        guard hideGroupedLights, !lightGroupOwners.isEmpty else { return baseVisible }
        let listed = Dictionary(baseVisible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var folded: Set<String> = []
        for device in baseVisible {
            guard let groupDid = lightGroupOwners[device.id],
                  let group = listed[groupDid],
                  group.isOnline else { continue }
            folded.insert(device.id)
        }
        return baseVisible.filter { !folded.contains($0.id) }
    }

    /// Records the outcome of a `menumijia://` command and immediately updates `raycast-snapshot.json`.
    public func recordRaycastCommandFeedback(
        requestId: String?,
        command: String,
        message: String,
        isError: Bool = false,
        now: Date = Date(),
        expectedGeneration: UInt64? = nil
    ) {
        if let expectedGeneration, !companionCanExecute(generation: expectedGeneration) {
            return
        }
        let iso = Self.raycastISO8601String(from: now)
        lastRaycastCommandFeedback = RaycastCommandFeedback(
            requestId: requestId,
            command: command,
            message: message,
            isError: isError,
            completedAt: iso
        )
        exportRaycastSnapshotIfNeeded(now: now, expectedGeneration: expectedGeneration)
    }

    /// Executes a built-in quick action or undo scene requested via `menumijia://scene?name=...`.
    public func executeBuiltInURLScene(_ builtIn: BuiltInURLScene) async -> (message: String, isError: Bool) {
        let generation = activeCompanionCommandGeneration
        if let generation, !companionCanExecute(generation: generation) {
            return (Self.companionDisabledMessage, true)
        }
        switch builtIn {
        case .lightsOff, .softNightLight, .climateSleepOff:
            guard let action = builtIn.quickAction else {
                return (L10n.tr("不支持的快捷动作", "Unsupported quick action"), true)
            }
            guard let task = executeQuickAction(
                action, undoBannerDuration: nil, recordsHabits: true, respectScreenLock: true,
                automationGeneration: nil, companionGeneration: generation
            ) else {
                return (
                    L10n.tr("当前无需执行「\(action.title)」", "No devices need \"\(action.title)\""),
                    false
                )
            }
            let outcome = await task.value
            return outcome.externalResult(
                success: L10n.tr("已执行「\(action.title)」", "Executed \"\(action.title)\""),
                incomplete: L10n.tr("「\(action.title)」未完成", "\"\(action.title)\" incomplete")
            )

        case .allOff:
            let targetCount = allOffTargets.count
            guard let task = turnAllOff() else {
                // "Nothing to turn off" is a result, not a failure; only the batch's own verdict
                // decides whether the link reports an error.
                return (L10n.tr("当前没有开启的设备", "No active devices are currently on"), false)
            }
            let outcome = await task.value
            return outcome.externalResult(
                success: L10n.tr("已关闭 \(targetCount) 台设备", "Turned off \(targetCount) device(s)"),
                incomplete: L10n.tr("全关未完成", "Turn all off incomplete")
            )

        case .undo:
            if undoBanner != nil {
                guard let task = undoTurnAllOff() else {
                    let msg = toastNotice?.message ?? L10n.tr("设备状态已变化，无法撤销", "Device state changed; cannot undo")
                    return (msg, true)
                }
                await task.value
                let msg = toastNotice?.message ?? L10n.tr("已恢复关闭前的状态", "Restored previous device states")
                let isErr = toastNotice?.isError ?? false
                return (msg, isErr)
            }
            _ = await runAssistantCommand("撤销")
            switch assistantState {
            case .done(let reply), .awaitingChoice(let reply):
                return (reply, false)
            case .failed(let reason):
                return (reason, true)
            case .thinking, .idle:
                return (L10n.tr("没有可以撤销的操作", "Nothing to undo"), true)
            }
        }
    }

    /// Builds a complete `RaycastSnapshot` from the store's current synthesized state and preferences.
    public func buildRaycastSnapshot(now: Date = Date()) -> RaycastSnapshot {
        let isoNow = Self.raycastISO8601String(from: now)
        let roomAliases = loadRoomAliases()
        let roomRanks = computeRoomRanks()
        let visible = raycastVisibleDevices

        let favOrderMap = Dictionary(
            favoriteOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let sortedDevices = visible.enumerated().sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            let aFav = favoriteDeviceIds.contains(a.id)
            let bFav = favoriteDeviceIds.contains(b.id)
            if aFav != bFav { return aFav && !bFav }
            if aFav && bFav {
                let rankA = favOrderMap[a.id] ?? Int.max
                let rankB = favOrderMap[b.id] ?? Int.max
                if rankA != rankB { return rankA < rankB }
            }
            let roomRankA = roomRanks[a.roomId] ?? roomRanks[a.roomName] ?? 999
            let roomRankB = roomRanks[b.roomId] ?? roomRanks[b.roomName] ?? 999
            if roomRankA != roomRankB { return roomRankA < roomRankB }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let markedLightIds = SwitchLightMarks.load(defaults: userDefaults)
        var favCounter = 0
        let deviceItems: [RaycastDeviceItem] = sortedDevices.map { dev in
            let isFav = favoriteDeviceIds.contains(dev.id)
            let favRank: Int?
            if isFav {
                favRank = favCounter
                favCounter += 1
            } else {
                favRank = nil
            }
            let displayRoom = resolvedRoomDisplayName(roomId: dev.roomId, rawRoomName: dev.roomName, aliases: roomAliases)
            let roomOrder = roomRanks[dev.roomId] ?? roomRanks[dev.roomName] ?? 999
            let pinyinInitials = Self.pinyinInitials(of: dev.name)
            let pinyinFull = PanelSearch.Pinyin.syllables(dev.name)?.joined() ?? ""
            let roomPinyin = Self.pinyinInitials(of: displayRoom)
            let isWritable = capabilityWriteRejection(for: dev) == nil
            let capabilities = Self.buildCapabilities(for: dev, markedLightIds: markedLightIds, isWritable: isWritable)
            let snapshotTag: DeviceKindTag = dev.isSwitchedLight ? .light : dev.kind.tag

            return RaycastDeviceItem(
                id: dev.id,
                name: dev.name,
                roomId: dev.roomId,
                roomName: displayRoom,
                roomSortOrder: roomOrder,
                category: snapshotTag.rawValue,
                categoryTitle: snapshotTag.chipTitle,
                model: dev.model,
                stateText: dev.statusSubtitle,
                isOnline: dev.isOnline,
                isActiveOn: dev.isActiveOn,
                isPrimaryToggleable: isWritable && dev.isPrimaryToggleable,
                isFavorite: isFav,
                favoriteRank: favRank,
                pinyinInitials: pinyinInitials,
                pinyinFull: pinyinFull,
                roomPinyinInitials: roomPinyin,
                capabilities: capabilities
            )
        }

        let quickActions = buildQuickActionItems()

        let sceneItems: [RaycastSceneItem] = visibleScenes.map { scene in
            RaycastSceneItem(
                id: scene.id,
                name: scene.name,
                entityId: scene.entityId,
                roomName: nil,
                icon: scene.iconName,
                visualCategory: String(describing: scene.visualCategory),
                pinyinInitials: Self.pinyinInitials(of: scene.name),
                pinyinFull: PanelSearch.Pinyin.syllables(scene.name)?.joined() ?? ""
            )
        }

        let orderedReadings = environmentReadings.enumerated().sorted { lhs, rhs in
            let rankA = roomRanks[lhs.element.roomName] ?? 999
            let rankB = roomRanks[rhs.element.roomName] ?? 999
            if rankA != rankB { return rankA < rankB }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let climateItems: [RaycastClimateItem] = orderedReadings.map { reading in
            let matchedRoom = rooms.first(where: { $0.name == reading.roomName || $0.id == reading.roomName })
            let displayRoom = resolvedRoomDisplayName(
                roomId: matchedRoom?.id ?? reading.roomName,
                rawRoomName: reading.roomName,
                aliases: roomAliases
            )
            let combinedLabel = "\(displayRoom) \(reading.label)"
            return RaycastClimateItem(
                id: reading.id,
                label: reading.label,
                roomName: displayRoom,
                temperature: reading.temperature,
                humidity: reading.humidity,
                battery: reading.battery,
                updatedAt: isoNow,
                pinyinInitials: Self.pinyinInitials(of: combinedLabel)
            )
        }

        let automationRules = automationRuleStore.load()
        let automationStatus = RaycastAutomationStatus(
            enabled: eventAutomationEnabled, ruleCount: automationRules.count,
            enabledRuleCount: automationRules.filter(\.isEnabled).count,
            executedCount: automationRunHistory.filter { $0.result == .executed }.count,
            skippedCount: automationRunHistory.filter { $0.result == .skipped }.count,
            recentRuns: automationRunHistory.prefix(15).map {
                RaycastAutomationRunItem(ruleId: $0.ruleId.uuidString, trigger: $0.trigger.rawValue, result: $0.result.rawValue, skipReason: $0.reason?.rawValue, at: Self.raycastISO8601String(from: $0.time))
            }
        )

        return RaycastSnapshot(
            schemaVersion: RaycastSnapshot.currentSchemaVersion,
            updatedAt: isoNow,
            bridgeToken: raycastBridgeToken ?? "",
            connectionSummary: serverHostSummary,
            isStale: deviceValuesAreStale,
            devices: deviceItems,
            quickActions: quickActions,
            scenes: sceneItems,
            climate: climateItems,
            environmentReadings: climateItems,
            lastCommandFeedback: lastRaycastCommandFeedback,
            automationStatus: automationStatus
        )
    }

    /// Writes `raycast-snapshot.json` when in live app mode or when an explicit test output URL is configured.
    /// Coalesces bursts of state changes (provider snapshots, optimistic updates, layout edits) into
    /// one export 0.3 s after the last change, so the main actor does not encode and write the file
    /// on every `didSet`.
    public func scheduleRaycastSnapshotExport() {
        guard companionIntegrationEnabled, !isIdentityUncertain, !isApplyingProviderSnapshot else { return }
        raycastExportTask?.cancel()
        let generation = companionGeneration
        let sleep = raycastExportSleep
        raycastExportTask = Task { @MainActor [weak self] in
            try? await sleep(.milliseconds(300))
            guard !Task.isCancelled, let self, self.companionCanExecute(generation: generation) else { return }
            self.exportRaycastSnapshotIfNeeded(expectedGeneration: generation)
        }
    }

    /// Writes the snapshot now. Command feedback uses this directly because Raycast is waiting for it;
    /// everything else goes through `scheduleRaycastSnapshotExport()`.
    public func exportRaycastSnapshotIfNeeded(
        to customURL: URL? = nil,
        now: Date = Date(),
        expectedGeneration: UInt64? = nil
    ) {
        guard !isIdentityUncertain, companionIntegrationEnabled || customURL != nil,
              !isApplyingProviderSnapshot else { return }
        if let expectedGeneration, !companionCanExecute(generation: expectedGeneration) {
            return
        }
        let targetURL: URL
        if let customURL {
            targetURL = customURL
        } else if let testURL = raycastSnapshotTestURL {
            targetURL = testURL
        } else if isTestEnvironment {
            return
        } else {
            targetURL = RaycastSnapshotExporter.defaultSnapshotURL
        }
        guard hasReceivedInitialSnapshot
                || !devices.isEmpty
                || !scenes.isEmpty
                || !environmentReadings.isEmpty
                || lastRaycastCommandFeedback != nil
                || customURL != nil
                || raycastSnapshotTestURL != nil else {
            return
        }
        let snapshot = buildRaycastSnapshot(now: now)
        if customURL == nil, let previous = lastExportedRaycastSnapshot,
           previous.hasSameExportedContent(as: snapshot) {
            return
        }
        raycastExportTask?.cancel()
        lastExportedRaycastSnapshot = snapshot
        if customURL != nil || raycastSnapshotTestURL != nil {
            try? RaycastSnapshotExporter.write(snapshot, to: targetURL)
        } else {
            let exportGeneration = RaycastSnapshotExporter.currentExportGeneration(for: targetURL)
            RaycastSnapshotExporter.writeInBackground(snapshot, to: targetURL, generation: exportGeneration)
        }
    }

    // MARK: - Private Snapshot Helpers

    private static func pinyinInitials(of text: String) -> String {
        guard let syllables = PanelSearch.Pinyin.syllables(text) else { return "" }
        return PanelSearch.Pinyin.initials(of: syllables)
    }

    private func loadRoomAliases() -> [String: String] {
        guard let raw = userDefaults.string(forKey: Self.roomAliasesDefaultsKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func loadRoomCustomOrder() -> [String] {
        guard let raw = userDefaults.string(forKey: Self.roomOrderDefaultsKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    private func computeRoomRanks() -> [String: Int] {
        let customOrder = loadRoomCustomOrder()
        let baseOrderedRooms = rooms.enumerated()
            .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }
            .map(\.element)

        let orderedRooms: [RoomArea]
        if customOrder.isEmpty {
            orderedRooms = baseOrderedRooms
        } else {
            let customRank = Dictionary(
                customOrder.enumerated().map { ($1, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            orderedRooms = baseOrderedRooms.enumerated().sorted { lhs, rhs in
                let rA = customRank[lhs.element.id] ?? (customOrder.count + lhs.offset)
                let rB = customRank[rhs.element.id] ?? (customOrder.count + rhs.offset)
                return rA < rB
            }.map(\.element)
        }

        var ranks: [String: Int] = [:]
        for (idx, room) in orderedRooms.enumerated() {
            if ranks[room.id] == nil { ranks[room.id] = idx }
            if ranks[room.name] == nil { ranks[room.name] = idx }
        }
        return ranks
    }

    private func resolvedRoomDisplayName(
        roomId: String,
        rawRoomName: String,
        aliases: [String: String]
    ) -> String {
        if let alias = aliases[roomId]?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return alias
        }
        return L10n.displayRoomName(rawRoomName)
    }

    private func buildQuickActionItems() -> [RaycastQuickActionItem] {
        let activeLightsCount = devices.filter { dev in
            guard dev.isOnline, capabilityWriteRejection(for: dev) == nil, case .light(let s) = dev.kind else { return false }
            return s.isOn && s.powerWritable
        }.count

        let nightLightCandidatesCount = devices.filter { dev in
            guard dev.isOnline, capabilityWriteRejection(for: dev) == nil, case .light(let s) = dev.kind else { return false }
            return s.brightnessWritable && s.colorWritable
        }.count

        let activeClimateFanCount = devices.filter { dev in
            guard dev.isOnline, capabilityWriteRejection(for: dev) == nil else { return false }
            switch dev.kind {
            case .climate(let s): return s.isOn && s.hvacMode != "off" && s.powerWritable
            case .fan(let s): return s.isOn && s.powerWritable
            default: return false
            }
        }.count

        let allOffCount = allOffTargets.count

        let hasBannerUndo = undoBanner != nil
        let hasAssistantUndo: Bool = {
            guard let last = lastAssistantUndo else { return false }
            return Date().timeIntervalSince(last.at) <= Self.voiceUndoWindow
        }()
        let canUndo = hasBannerUndo || hasAssistantUndo
        let undoSubtitle: String
        if let banner = undoBanner {
            undoSubtitle = L10n.tr("可撤销：\(banner.title)", "Undo: \(banner.title)")
        } else if let last = lastAssistantUndo, hasAssistantUndo {
            undoSubtitle = L10n.tr("可撤销：\(last.reply)", "Undo: \(last.reply)")
        } else {
            undoSubtitle = L10n.tr("当前没有可撤销的操作", "Nothing to undo right now")
        }

        return [
            RaycastQuickActionItem(
                id: BuiltInURLScene.lightsOff.rawValue,
                name: QuickAction.lightsOff.title,
                subtitle: activeLightsCount > 0
                    ? L10n.tr("当前有 \(activeLightsCount) 盏灯开启", "\(activeLightsCount) light(s) currently on")
                    : L10n.tr("全部灯具已关闭", "All lights are already off"),
                icon: QuickAction.lightsOff.sfSymbolName,
                isEnabled: activeLightsCount > 0,
                affectedCount: activeLightsCount,
                pinyinInitials: Self.pinyinInitials(of: QuickAction.lightsOff.title)
            ),
            RaycastQuickActionItem(
                id: BuiltInURLScene.softNightLight.rawValue,
                name: QuickAction.softNightLight.title,
                subtitle: nightLightCandidatesCount > 0
                    ? L10n.tr("调至 15% 亮度与 2700K 暖光", "Dim to 15% at 2700K warm light")
                    : L10n.tr("无支持调光调色温的在线灯具", "No dimmable warm-white lights online"),
                icon: QuickAction.softNightLight.sfSymbolName,
                isEnabled: nightLightCandidatesCount > 0,
                affectedCount: min(max(nightLightCandidatesCount, 0), 1),
                pinyinInitials: Self.pinyinInitials(of: QuickAction.softNightLight.title)
            ),
            RaycastQuickActionItem(
                id: BuiltInURLScene.climateSleepOff.rawValue,
                name: QuickAction.climateSleepOff.title,
                subtitle: activeClimateFanCount > 0
                    ? L10n.tr("当前有 \(activeClimateFanCount) 台温控/风扇开启", "\(activeClimateFanCount) climate/fan device(s) on")
                    : L10n.tr("空调与风扇均已关闭", "All climate & fan devices are off"),
                icon: QuickAction.climateSleepOff.sfSymbolName,
                isEnabled: activeClimateFanCount > 0,
                affectedCount: activeClimateFanCount,
                pinyinInitials: Self.pinyinInitials(of: QuickAction.climateSleepOff.title)
            ),
            RaycastQuickActionItem(
                id: BuiltInURLScene.allOff.rawValue,
                name: BuiltInURLScene.allOff.displayTitle,
                subtitle: allOffCount > 0
                    ? L10n.tr("关闭当前开启的 \(allOffCount) 台设备（支持撤销）", "Turn off \(allOffCount) active device(s) (with undo)")
                    : L10n.tr("当前没有开启的设备", "No active devices are currently on"),
                icon: "power",
                isEnabled: allOffCount > 0,
                affectedCount: allOffCount,
                pinyinInitials: Self.pinyinInitials(of: BuiltInURLScene.allOff.displayTitle)
            ),
            RaycastQuickActionItem(
                id: BuiltInURLScene.undo.rawValue,
                name: BuiltInURLScene.undo.displayTitle,
                subtitle: undoSubtitle,
                icon: "arrow.uturn.backward",
                isEnabled: canUndo,
                affectedCount: undoBanner?.restoreCommands.count ?? lastAssistantUndo?.restore.count ?? 0,
                pinyinInitials: Self.pinyinInitials(of: BuiltInURLScene.undo.displayTitle)
            ),
        ]
    }

    private static func buildCapabilities(
        for device: SmartDevice,
        markedLightIds: Set<String> = [],
        isWritable: Bool = true
    ) -> RaycastDeviceCapabilities {
        let isHighRisk = ManualControlPolicy.requiresConfirmation(.power(true), for: device, markedLightIds: markedLightIds)
            || ManualControlPolicy.requiresConfirmation(.power(false), for: device, markedLightIds: markedLightIds)
        switch device.kind {
        case .light(let s):
            return RaycastDeviceCapabilities(
                canTogglePower: isWritable && s.powerWritable,
                brightnessWritable: isWritable && s.brightnessWritable,
                brightnessPercent: s.brightnessPercent,
                colorWritable: isWritable && s.colorWritable,
                colorTempKelvin: s.colorTempKelvin,
                minKelvin: s.minKelvin,
                maxKelvin: s.maxKelvin,
                supportsMoonlight: isWritable && (s.brightnessWritable || s.colorWritable || !s.availableEffects.isEmpty),
                availableEffects: isWritable ? s.availableEffects : [],
                isHighRisk: isHighRisk
            )
        case .climate(let s):
            return RaycastDeviceCapabilities(
                canTogglePower: isWritable && s.powerWritable,
                temperatureWritable: isWritable && s.temperatureWritable,
                targetTemperature: s.targetTemperature,
                currentTemperature: s.currentTemperature,
                minTemp: s.minTemp,
                maxTemp: s.maxTemp,
                step: s.step,
                hvacMode: s.hvacMode,
                availableModes: isWritable ? s.availableModes : [],
                isHighRisk: isHighRisk
            )
        case .fan(let s):
            return RaycastDeviceCapabilities(
                canTogglePower: isWritable && s.powerWritable,
                fanSpeedWritable: isWritable && s.speedWritable,
                fanPercentage: s.percentage,
                availablePresetModes: isWritable ? s.availablePresetModes : [],
                isHighRisk: isHighRisk
            )
        case .cover(let s):
            return RaycastDeviceCapabilities(
                canTogglePower: isWritable && device.kind.canTogglePower,
                coverSubtype: s.subtype.rawValue,
                positionWritable: isWritable && s.positionWritable,
                positionPercent: s.positionPercent,
                canMoveCover: isWritable && s.canMove,
                isHighRisk: isHighRisk || s.subtype == .garageDoor || s.subtype == .windowOpener
            )
        case .speaker(let s):
            return RaycastDeviceCapabilities(canTogglePower: isWritable && device.kind.canTogglePower, volumeWritable: isWritable && s.volumeWritable, volumePercent: s.volumePresent ? s.volumePercent : nil, muteWritable: isWritable && s.muteSwitchEntityId != nil, isMuted: s.isMuted, canPlayPause: isWritable && s.playback?.canPlayPause == true, isHighRisk: isHighRisk)
        case .tv(let s):
            return RaycastDeviceCapabilities(canTogglePower: isWritable && device.kind.canTogglePower, volumeWritable: isWritable && s.volumeWritable, volumePercent: s.volumePresent ? s.volumePercent : nil, muteWritable: isWritable && (LGWebOSProtocol.isLGEntity(s.mediaEntityId) || s.muteSwitchEntityId != nil), isMuted: s.isMuted, canPlayPause: isWritable && s.playback?.canPlayPause == true, isHighRisk: isHighRisk)
        default:
            return RaycastDeviceCapabilities(
                canTogglePower: isWritable && device.kind.canTogglePower,
                isHighRisk: isHighRisk
            )
        }
    }

    private static func raycastISO8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
