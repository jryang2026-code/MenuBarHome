import Foundation

/// Deterministic, zero-network parser for short Chinese and English home commands.
/// Every recognized phrase is consumed from the utterance; any leftover text means the
/// command has parts this parser does not understand, so it returns nil and the model takes over.
public enum LocalIntentParser {
    private static let consumed: Character = "\u{1F}"

    private static let powerVerbs: [String: Bool] = [
        "打开": true, "开启": true, "开": true,
        "关闭": false, "关掉": false, "关上": false, "熄灭": false, "熄掉": false, "关": false
    ]

    private static let brightnessWords: [String: Int] = [
        "调暗": 20, "变暗": 20, "最暗": 10,
        "调亮": 100, "变亮": 100, "最亮": 100
    ]

    private static let colorTemperatureWords: [String: Int] = [
        "暖光": 2700, "暖色": 2700, "黄光": 2700,
        "自然光": 4000,
        "白光": 6500, "冷光": 6500
    ]

    private static let lightEffectWords: [String: String] = [
        "月光模式": "Night", "月光灯": "Night", "月光": "Night",
        "夜灯模式": "Night", "夜灯": "Night",
        "日光模式": "Day", "日光灯": "Day", "日光": "Day"
    ]

    /// Relative brightness ("暗一点"), resolved against the light's current level.
    private static let brightnessStepWords: [String: Int] = [
        "暗一点": -20, "暗一些": -20, "暗点": -20,
        "亮一点": 20, "亮一些": 20, "亮点": 20
    ]

    /// Relative temperature words without a number ("温度低一点"); numbered ones ("调高两度") are regex-parsed.
    private static let temperatureStepWords: [String: Double] = [
        "高一点": 1, "高一些": 1, "低一点": -1, "低一些": -1,
        "热一点": 1, "冷一点": -1, "凉快一点": -1
    ]

    private static let fanSpeedWords: [String: String] = [
        "高档": "high", "三档": "high", "高速": "high", "大风": "high", "最大风": "high", "强风": "high",
        "风速调高": "high", "风速调大": "high", "风速最大": "high",
        "中档": "medium", "二档": "medium", "中速": "medium", "风速调中": "medium",
        "低档": "low", "一档": "low", "低速": "low", "小风": "low", "微风": "low", "最小风": "low",
        "风速调低": "low", "风速调小": "low", "风速最小": "low",
        "自动风": "auto", "自动档": "auto", "风速自动": "auto",
        "睡眠模式": "sleep", "睡眠档": "sleep", "静音模式": "sleep", "静音档": "sleep",
        "最爱模式": "favorite", "最爱档": "favorite", "最爱": "favorite"
    ]

    /// Longer "stop" phrases are consumed first, so "关闭摇头" never reads as 关闭 + 摇头.
    private static let oscillationWords: [String: Bool] = [
        "摇头": true, "摆头": true, "摆风": true,
        "停止摇头": false, "关闭摇头": false, "关掉摇头": false, "不要摇头": false, "别摇头": false, "不摇头": false,
        "停止摆头": false, "关闭摆头": false, "关掉摆头": false, "不要摆头": false, "别摆头": false, "不摆头": false,
        "停止摆风": false, "关闭摆风": false, "关掉摆风": false, "不要摆风": false, "别摆风": false, "不摆风": false
    ]

    private static let hvacModeWords: [String: String] = [
        "制冷": "cool", "制热": "heat", "除湿": "dry", "送风": "fan_only", "自动": "auto"
    ]

    private static let scopeWords: Set<String> = [
        "所有设备", "全部设备", "全屋设备",
        "全部", "所有", "全屋", "全家", "家里", "整个家"
    ]

    private static let categoryWords: [String: IntentDeviceCategory] = [
        "灯": .light, "灯光": .light, "电灯": .light,
        "空调": .climate,
        "暖气": .heater, "电暖器": .heater, "电暖气": .heater, "取暖器": .heater, "暖风机": .heater,
        "风扇": .fan, "电风扇": .fan, "电扇": .fan,
        "空气净化器": .airPurifier, "净化器": .airPurifier, "空净": .airPurifier,
        "新风机": .airPurifier, "新风": .airPurifier, "加湿器": .airPurifier,
        "除湿机": .dehumidifier, "香氛机": .diffuser,
        "插座": .plug,
        "扫地机": .vacuum, "扫地机器人": .vacuum,
        "电视": .tv, "电视机": .tv,
        "摄像头": .camera, "摄像机": .camera, "监控": .camera,
        "阀门": .valve, "水阀": .valve, "气阀": .valve, "燃气阀": .valve, "总阀": .valve
    ]

    /// Generic room words users say, mapped to room names they may correspond to in HA.
    private static let roomAliases: [String: [String]] = [
        "卧室": ["卧室", "主卧"], "主卧": ["主卧", "卧室"],
        "次卧": ["次卧", "小卧室"], "小卧室": ["小卧室", "次卧"],
        "客厅": ["客厅"], "书房": ["书房"], "厨房": ["厨房"], "阳台": ["阳台"], "餐厅": ["餐厅"],
        "卫生间": ["卫生间", "浴室"], "浴室": ["浴室", "卫生间"]
    ]

    private static let fillers: Set<String> = [
        "请", "帮我", "帮忙", "麻烦", "给我", "把", "将", "给", "一下", "一点", "一些",
        "吧", "了", "的", "呢", "啊", "呀", "都", "里", "模式",
        "再", "稍微", "稍", "更", "温度", "风速", "亮度", "色温",
        "调到", "调成", "调为", "调至", "设为", "设成", "设置为", "设置成", "设置", "调节", "调", "到", "为",
        "切换为", "切换到", "切到", "切为", "切成", "切换", "切", "改成", "改为"
    ]

    private static let sceneVerbs: Set<String> = ["执行", "启动", "打开", "开启", "激活", "切换到", "切换", "进入", "运行"]
    private static let sceneSuffixes = ["场景", "模式"]

    private static let ignorable = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "，。！？、；：,!?;:~～\"'“”‘’"))

    private static let tradToSimpMap: [Character: Character] = {
        let trad = Array("開關啟啓閉滅調變設為換執動進運場燈電氣機風熱涼溫濕溼乾淨掃視攝頭監閥門總鎖簾紗捲葉車庫揚聲魚寵餵煙霧應傳臥廳書廚陽臺檯衛間裡裏內頂帶環點黃藍綠紅檔擋級強靜愛搖擺別製備個盞隻條請幫煩給將兩過時鐘鍾後銷剛暫還計")
        let simp = Array("开关启启闭灭调变设为换执动进运场灯电气机风热凉温湿湿干净扫视摄头监阀门总锁帘纱卷叶车库扬声鱼宠喂烟雾应传卧厅书厨阳台台卫间里里内顶带环点黄蓝绿红档档级强静爱摇摆别制备个盏只条请帮烦给将两过时钟钟后销刚暂还计")
        var map: [Character: Character] = [:]
        for (idx, ch) in trad.enumerated() where idx < simp.count {
            map[ch] = simp[idx]
        }
        return map
    }()

    public static func toSimplifiedChinese(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        let replaced = input.replacingOccurrences(of: "裝置", with: "设备")
        return String(replaced.map { tradToSimpMap[$0] ?? $0 })
    }

    // MARK: - Entry Point

    public static func parse(
        _ utterance: String,
        devices: [SmartDevice],
        scenes: [HomeScene],
        panelRoom: BareCategoryCommand.Room? = nil,
        usageOrder: [String] = []
    ) -> IntentPlan? {
        let normalizedUtterance = toSimplifiedChinese(utterance)
        let text = String(String.UnicodeScalarView(normalizedUtterance.unicodeScalars.filter { !ignorable.contains($0) }))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !text.isEmpty else { return nil }

        let rawSceneCore = strippedRawSceneText(utterance)
        let sceneCore = strippedSceneText(text)
        let rawExactScenes = scenes.filter { !$0.name.isEmpty && strippedRawSceneText($0.name) == rawSceneCore }
        if rawExactScenes.count == 1, let scene = rawExactScenes.first {
            return scenePlan(scene)
        }
        if rawExactScenes.isEmpty {
            let exactScenes = scenes.filter { !$0.name.isEmpty && strippedSceneText($0.name) == sceneCore }
            if exactScenes.count == 1, let scene = exactScenes.first {
                return scenePlan(scene)
            }
        }
        if let plan = parseDeviceCommand(
            text,
            rawUtterance: utterance,
            devices: devices,
            scenes: scenes,
            panelRoom: panelRoom,
            usageOrder: usageOrder
        ) {
            return plan
        }
        if sceneCore.count >= 2 {
            let rawContaining = scenes.filter { !$0.name.isEmpty && strippedRawSceneText($0.name).contains(rawSceneCore) }
            if rawContaining.count == 1, let scene = rawContaining.first {
                return scenePlan(scene)
            }
            if rawContaining.isEmpty {
                let containing = scenes.filter { !$0.name.isEmpty && strippedSceneText($0.name).contains(sceneCore) }
                if containing.count == 1, let scene = containing.first {
                    return scenePlan(scene)
                }
            }
        }
        if utterance.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) {
            return parseEnglishCommand(
                utterance,
                devices: devices,
                scenes: scenes,
                panelRoom: panelRoom,
                usageOrder: usageOrder
            )
        }
        return nil
    }

    private static func scenePlan(_ scene: HomeScene) -> IntentPlan {
        let intents = [DeviceIntent(targetId: scene.id, operation: .activateScene)]
        return IntentPlan(
            intents: intents,
            reply: IntentReply.describe(intents, devices: [], scenes: [scene]),
            source: .local
        )
    }

    private static func strippedRawSceneText(_ raw: String) -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !ignorable.contains($0) }))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var chars = Array(cleaned)
        var normChars = Array(toSimplifiedChinese(cleaned))
        let normJoined = String(normChars)
        for verb in sceneVerbs.sorted(by: { $0.count > $1.count }) where normJoined.hasPrefix(verb) {
            chars.removeFirst(verb.count)
            normChars.removeFirst(verb.count)
            break
        }
        let normAfterVerb = String(normChars)
        for suffix in sceneSuffixes where normAfterVerb.hasSuffix(suffix) && chars.count > suffix.count {
            chars.removeLast(suffix.count)
            break
        }
        return String(chars)
    }

    private static func strippedSceneText(_ raw: String) -> String {
        let normalized = toSimplifiedChinese(raw)
        var s = String(String.UnicodeScalarView(normalized.unicodeScalars.filter { !ignorable.contains($0) }))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        for verb in sceneVerbs.sorted(by: { $0.count > $1.count }) where s.hasPrefix(verb) {
            s.removeFirst(verb.count)
            break
        }
        for suffix in sceneSuffixes where s.hasSuffix(suffix) && s.count > suffix.count {
            s.removeLast(suffix.count)
        }
        return s
    }

    // MARK: - Device Commands

    private static func parseDeviceCommand(
        _ text: String,
        rawUtterance: String,
        devices: [SmartDevice],
        scenes: [HomeScene],
        panelRoom: BareCategoryCommand.Room?,
        usageOrder: [String]
    ) -> IntentPlan? {
        var rest = text
        var ops: [IntentOperation] = extractNumericOperations(&rest)

        // 1. Device names (full name such as 书房台灯, or name without room prefix such as 台灯)
        let deviceById = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var matchedEntries: [[DevicePhraseCandidate]] = []
        for (phrase, candidates) in devicePhrases(devices) where consume(phrase, from: &rest) {
            matchedEntries.append(candidates)
        }

        // 2. Rooms, scope, and category words
        let roomWords = Set(devices.map { toSimplifiedChinese($0.roomName) }).union(roomAliases.keys).filter { !$0.isEmpty }
        let matchedRooms = longestFirst(roomWords).filter { consume($0, from: &rest) }
        let hasScope = !longestFirst(scopeWords).filter { consume($0, from: &rest) }.isEmpty
        let categories = Set(longestFirst(Set(categoryWords.keys)).filter { consume($0, from: &rest) }.compactMap { categoryWords[$0] })

        // 3. Operation words (phrases that contain power verbs or 调高/调低 go first)
        for word in longestFirst(Set(oscillationWords.keys)) where consume(word, from: &rest) {
            ops.append(.oscillation(oscillationWords[word]!))
        }
        for word in longestFirst(Set(fanSpeedWords.keys)) where consume(word, from: &rest) {
            ops.append(.fanSpeed(fanSpeedWords[word]!))
        }
        for word in longestFirst(Set(brightnessStepWords.keys)) where consume(word, from: &rest) {
            ops.append(.brightnessStep(brightnessStepWords[word]!))
        }
        for word in longestFirst(Set(temperatureStepWords.keys)) where consume(word, from: &rest) {
            ops.append(.temperatureStep(temperatureStepWords[word]!))
        }
        for word in longestFirst(Set(lightEffectWords.keys)) where consume(word, from: &rest) {
            ops.append(.lightEffect(lightEffectWords[word]!))
        }
        for word in longestFirst(Set(brightnessWords.keys)) where consume(word, from: &rest) {
            ops.append(.brightness(brightnessWords[word]!))
        }
        for word in longestFirst(Set(colorTemperatureWords.keys)) where consume(word, from: &rest) {
            ops.append(.colorTemperature(colorTemperatureWords[word]!))
        }
        for word in longestFirst(Set(hvacModeWords.keys)) where consume(word, from: &rest) {
            ops.append(.hvacMode(hvacModeWords[word]!))
        }
        for word in longestFirst(Set(powerVerbs.keys)) where consume(word, from: &rest) {
            ops.append(.power(powerVerbs[word]!))
        }

        // 4. Fillers, then anything left over means we don't understand the utterance
        for word in longestFirst(fillers) {
            _ = consume(word, from: &rest)
        }
        guard rest.allSatisfy({ $0 == consumed }) else { return nil }

        guard let ops = reconcile(ops) else { return nil }

        var roomDeviceIds: Set<String> = []
        for word in matchedRooms {
            guard let ids = deviceIds(inRoom: word, devices: devices, panelRoom: panelRoom) else {
                return nil
            }
            roomDeviceIds.formUnion(ids)
        }
        let isTurningOff = ops == [.power(false)]
        var targetIds: [String] = []
        var mustAcceptAll: Set<String> = []

        if !matchedEntries.isEmpty {
            for candidates in matchedEntries {
                let preScript = disambiguateDeviceScriptCollision(candidates, rawUtterance: rawUtterance)
                let initialCandidates = preScript.isEmpty ? candidates : preScript
                let hasFullCandidate = initialCandidates.contains { $0.isFull }
                let narrowedCandidates: [DevicePhraseCandidate]
                if hasFullCandidate {
                    narrowedCandidates = (initialCandidates.count > 1 && !matchedRooms.isEmpty)
                        ? initialCandidates.filter { roomDeviceIds.contains($0.id) }
                        : initialCandidates
                } else {
                    narrowedCandidates = matchedRooms.isEmpty
                        ? initialCandidates
                        : initialCandidates.filter { roomDeviceIds.contains($0.id) }
                }
                guard !narrowedCandidates.isEmpty else { return nil }
                let roomResolvedIds = Set(disambiguateRoomDevices(
                    narrowedCandidates.compactMap { deviceById[$0.id] },
                    panelRoom: panelRoom
                ))
                let roomResolvedCandidates = narrowedCandidates.filter { roomResolvedIds.contains($0.id) }
                guard !roomResolvedCandidates.isEmpty else { return nil }
                let finalCandidates = disambiguateDeviceScriptCollision(roomResolvedCandidates, rawUtterance: rawUtterance)
                guard !finalCandidates.isEmpty else { return nil }
                let isFullMatch = finalCandidates.contains { $0.isFull }
                if !isFullMatch && finalCandidates.count != 1 && !hasScope { return nil }
                for c in finalCandidates {
                    if !targetIds.contains(c.id) { targetIds.append(c.id) }
                    if isFullMatch { mustAcceptAll.insert(c.id) }
                }
                if !isFullMatch, finalCandidates.count == 1, let only = finalCandidates.first {
                    mustAcceptAll.insert(only.id)
                }
            }
        } else {
            let implied = impliedCategories(for: ops)
            let wanted = categories.isEmpty ? implied : categories
            if wanted == nil && !isTurningOff { return nil }
            guard hasScope || !matchedRooms.isEmpty || wanted != nil else { return nil }

            if let bare = bareCategoryOutcome(
                ops: ops,
                wanted: wanted,
                hasScope: hasScope,
                hasRoomWord: !matchedRooms.isEmpty,
                devices: devices,
                scenes: scenes,
                panelRoom: panelRoom,
                usageOrder: usageOrder
            ) {
                switch bare {
                case .plan(let plan): return plan
                case .targets(let ids): targetIds = ids
                }
            } else {
                // "再暗一点" with no target means "the light that is on", never a dark one.
                let onlyActive = ops.allSatisfy(\.isRelative)
                let candidates = devices.filter { dev in
                    let category = IntentDeviceCategory(dev)
                    guard dev.isOnline, category.isAssistantControllable, dev.kind.acceptsControlWrites else { return false }
                    if category == .valve && !(wanted?.contains(.valve) ?? false) { return false }
                    if onlyActive && !dev.isActiveOn { return false }
                    if !matchedRooms.isEmpty && !roomDeviceIds.contains(dev.id) { return false }
                    if let wanted, !wanted.contains(category) { return false }
                    return true
                }
                // A bare category ("打开空调") is only unambiguous when the home has exactly one such device;
                // relative adjustments ("再暗一点") intentionally apply to all currently-on matching devices.
                if !onlyActive && !hasScope && matchedRooms.isEmpty && candidates.count != 1 { return nil }
                targetIds = candidates.map(\.id)
            }
        }

        var intents: [DeviceIntent] = []
        for id in targetIds {
            guard let device = deviceById[id] else { return nil }
            let normalized = ops.compactMap { IntentValidator.normalize($0, for: device) }
            guard normalized.count == ops.count else {
                if mustAcceptAll.contains(id) { return nil }
                continue
            }
            intents.append(contentsOf: normalized.map { DeviceIntent(targetId: id, operation: $0) })
        }
        guard !intents.isEmpty else { return nil }

        return IntentPlan(
            intents: intents,
            reply: IntentReply.describe(intents, devices: devices, scenes: scenes),
            source: .local
        )
    }

    // MARK: - Helpers

    private enum BareCategoryOutcome {
        case plan(IntentPlan)
        case targets([String])
    }

    /// GLOSSARY `BareCategoryCommand`: a command that names only a category. Closing looks at the
    /// devices that are on right now and opening at the ones that are off, so "关灯" never touches a
    /// lamp that is already off and "开灯" never offers one that is already lit. Nil means the
    /// utterance is not a bare-category command this rule can answer.
    private static func bareCategoryOutcome(
        ops: [IntentOperation],
        wanted: Set<IntentDeviceCategory>?,
        hasScope: Bool,
        hasRoomWord: Bool,
        devices: [SmartDevice],
        scenes: [HomeScene],
        panelRoom: BareCategoryCommand.Room?,
        usageOrder: [String]
    ) -> BareCategoryOutcome? {
        guard ops.count == 1,
              let operation = ops.first,
              !hasScope,
              !hasRoomWord,
              let wanted,
              wanted.count == 1,
              let category = wanted.first else { return nil }
        let direction: BareCategoryCommand.Direction
        switch operation {
        case .power(false): direction = .close
        case .power(true): direction = .open
        default: return nil
        }
        let allControllable = devices.filter { dev in
            let deviceCategory = IntentDeviceCategory(dev)
            return deviceCategory.isAssistantControllable && wanted.contains(deviceCategory)
        }
        let sameCategory = allControllable.filter(\.isOnline)
        if let panelRoom, !panelRoom.id.isEmpty {
            let roomControllable = allControllable.filter { $0.roomId == panelRoom.id }
            if !roomControllable.isEmpty, roomControllable.allSatisfy({ !$0.isOnline }) {
                return .plan(IntentPlan(
                    intents: [],
                    reply: offlineBareCategoryReply(category: category, room: panelRoom.name),
                    source: .local
                ))
            }
        }
        if !allControllable.isEmpty, sameCategory.isEmpty {
            return .plan(IntentPlan(
                intents: [],
                reply: offlineBareCategoryReply(category: category, room: nil),
                source: .local
            ))
        }
        // The open rule starts when the home has more than one device of the category: a single one
        // stays unambiguous and keeps the existing direct behavior.
        if direction == .open, sameCategory.count <= 1 { return nil }
        // What is on answers a close and what is off answers an open, even when the device cannot
        // perform the operation (#273 review).
        let affected = sameCategory.filter {
            direction == .close ? $0.isActiveDevice : !$0.isActiveDevice
        }
        let switchable = affected.filter { IntentValidator.normalize(operation, for: $0) != nil }
        if !affected.isEmpty, switchable.isEmpty {
            return .plan(IntentPlan(
                intents: [],
                reply: BareCategoryCommand.blockedReply(direction: direction, category: category),
                source: .local
            ))
        }
        switch BareCategoryCommand.resolve(candidates: switchable, panelRoom: panelRoom, usageOrder: usageOrder) {
        case .none(let room):
            return .plan(IntentPlan(
                intents: [],
                reply: BareCategoryCommand.answerReply(
                    direction: direction,
                    category: category,
                    room: room
                ),
                source: .local
            ))
        case .candidates(let candidates):
            return .plan(IntentPlan(
                intents: [],
                reply: BareCategoryCommand.choiceReply(direction: direction, candidates),
                source: .local,
                suggestions: BareCategoryCommand.suggestions(
                    direction: direction,
                    candidates: candidates,
                    devices: devices,
                    scenes: scenes
                )
            ))
        case .run(let targets):
            return .targets(targets.map(\.id))
        }
    }

    private static func offlineBareCategoryReply(category: IntentDeviceCategory, room: String?) -> String {
        let noun = category.spokenNoun
        guard let room, !room.isEmpty else {
            return L10n.format("%@当前离线", "The %@ are offline", noun)
        }
        return L10n.format(
            "%@的%@当前离线",
            "The %@ %@ are offline",
            L10n.displayRoomName(room),
            noun
        )
    }

    private struct DevicePhraseCandidate {
        let id: String
        let rawPhrase: String
        let isFull: Bool
    }

    private static func cleanRawText(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.filter { !ignorable.contains($0) }))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func devicePhrases(_ devices: [SmartDevice]) -> [(String, [DevicePhraseCandidate])] {
        var full: [String: [DevicePhraseCandidate]] = [:]
        var base: [String: [DevicePhraseCandidate]] = [:]
        for dev in devices where !dev.name.isEmpty {
            let rawName = cleanRawText(dev.name)
            let rawRoom = cleanRawText(dev.roomName)
            let devName = toSimplifiedChinese(rawName)
            let roomName = toSimplifiedChinese(rawRoom)
            guard !devName.isEmpty else { continue }
            full[devName, default: []].append(DevicePhraseCandidate(id: dev.id, rawPhrase: rawName, isFull: true))
            if !roomName.isEmpty, devName.hasPrefix(roomName) {
                let stripped = String(devName.dropFirst(roomName.count))
                let rawStripped = String(rawName.dropFirst(roomName.count))
                // 「关空调」 is a category command even when a device is literally named 客厅空调 (#273).
                if stripped.count >= 2, categoryWords[stripped] == nil {
                    base[stripped, default: []].append(DevicePhraseCandidate(id: dev.id, rawPhrase: rawStripped, isFull: false))
                }
            }
        }
        var phrases: [(String, [DevicePhraseCandidate])] = []
        for (phrase, fullCandidates) in full {
            let fullRawSet = Set(fullCandidates.map(\.rawPhrase))
            let extraBase = (base[phrase] ?? []).filter { !fullRawSet.contains($0.rawPhrase) }
            phrases.append((phrase, fullCandidates + extraBase))
        }
        for (phrase, baseCandidates) in base where full[phrase] == nil {
            phrases.append((phrase, baseCandidates))
        }
        return phrases.sorted { $0.0.count > $1.0.count }
    }

    private static func disambiguateDeviceScriptCollision(
        _ candidates: [DevicePhraseCandidate],
        rawUtterance: String
    ) -> [DevicePhraseCandidate] {
        let distinctRaw = Set(candidates.map(\.rawPhrase))
        guard distinctRaw.count > 1 else { return candidates }
        let rawCleaned = cleanRawText(rawUtterance)
        let rawMatched = candidates.filter { !$0.rawPhrase.isEmpty && rawCleaned.contains($0.rawPhrase) }
        let matchedRaw = Set(rawMatched.map(\.rawPhrase))
        guard matchedRaw.count == 1 else { return [] }
        return rawMatched
    }

    /// When two homes/accounts share a display room name (e.g. two 客厅 with distinct roomIds),
    /// narrow to the panel's selected roomId or refuse ambiguous cross-home execution (ADR-0010).
    private static func disambiguateRoomDevices(
        _ matched: [SmartDevice],
        panelRoom: BareCategoryCommand.Room?
    ) -> [String] {
        var roomIdsByName: [String: Set<String>] = [:]
        for dev in matched where !dev.roomName.isEmpty && !dev.roomId.isEmpty {
            roomIdsByName[toSimplifiedChinese(dev.roomName), default: []].insert(dev.roomId)
        }
        let hasCollision = roomIdsByName.values.contains { $0.count > 1 }
        guard hasCollision else { return matched.map(\.id) }
        if let panelRoom, !panelRoom.id.isEmpty,
           matched.contains(where: { $0.roomId == panelRoom.id }) {
            return matched.filter { $0.roomId == panelRoom.id }.map(\.id)
        }
        return []
    }

    /// Returns `nil` when `word` matched at least one device whose room name collides across
    /// distinct `roomId`s without a matching `panelRoom` (refuses partial cross-account execution).
    private static func deviceIds(
        inRoom word: String,
        devices: [SmartDevice],
        panelRoom: BareCategoryCommand.Room?
    ) -> [String]? {
        let normWord = toSimplifiedChinese(word)
        let exact = devices.filter { toSimplifiedChinese($0.roomName) == normWord }
        if !exact.isEmpty {
            let resolved = disambiguateRoomDevices(exact, panelRoom: panelRoom)
            return resolved.isEmpty ? nil : resolved
        }
        let aliases = roomAliases[normWord] ?? [normWord]
        let matched = devices.filter { dev in
            let room = toSimplifiedChinese(dev.roomName)
            return aliases.contains { room.contains($0) }
        }
        guard !matched.isEmpty else { return [] }
        let resolved = disambiguateRoomDevices(matched, panelRoom: panelRoom)
        return resolved.isEmpty ? nil : resolved
    }

    private static func impliedCategories(for ops: [IntentOperation]) -> Set<IntentDeviceCategory>? {
        for op in ops {
            switch op {
            case .brightness, .brightnessStep, .colorTemperature, .lightEffect: return [.light]
            case .hvacMode, .targetTemperature, .temperatureStep: return [.climate, .heater]
            case .fanSpeed: return [.fan, .airPurifier, .climate]
            case .oscillation: return [.fan]
            case .power, .activateScene: continue
            }
        }
        return nil
    }

    /// Orders operations for dispatch and rejects contradictory combinations.
    private static func reconcile(_ ops: [IntentOperation]) -> [IntentOperation]? {
        guard !ops.isEmpty else { return nil }
        var byRank: [Int: IntentOperation] = [:]
        for op in ops {
            let rank = dispatchRank(op)
            if let existing = byRank[rank], existing != op { return nil }
            byRank[rank] = op
        }
        if byRank[0] == .power(false), byRank.count > 1 { return nil }
        // HVAC mode, light effect, brightness, and color temperature already switch the device on.
        if byRank[0] == .power(true), byRank.keys.contains(where: { $0 == 1 || $0 == 3 || $0 == 4 || $0 == 5 }) {
            byRank[0] = nil
        }
        return byRank.keys.sorted().compactMap { byRank[$0] }
    }

    private static func dispatchRank(_ op: IntentOperation) -> Int {
        switch op {
        case .power: return 0
        case .hvacMode: return 1
        case .targetTemperature, .temperatureStep: return 2
        case .lightEffect: return 3
        case .brightness, .brightnessStep: return 4
        case .colorTemperature: return 5
        case .activateScene: return 6
        case .fanSpeed: return 7
        case .oscillation: return 8
        }
    }

    private static func spokenNumber(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let n = Int(trimmed) { return n }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let chars = Array(trimmed)
        if chars.count == 2, chars[0] == "零", let ones = digits[chars[1]] {
            return ones
        }
        if let tenIndex = chars.firstIndex(of: "十") {
            guard tenIndex <= 1, chars.count - tenIndex <= 2 else { return nil }
            let tens = tenIndex == 0 ? 1 : digits[chars[0]]
            let ones = tenIndex == chars.count - 1 ? 0 : digits[chars[tenIndex + 1]]
            guard let tens, tens > 0, let ones else { return nil }
            return tens * 10 + ones
        }
        guard chars.count == 1 else { return nil }
        return digits[chars[0]]
    }

    private static func longestFirst(_ words: Set<String>) -> [String] {
        words.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    /// Replaces every occurrence with a marker (not the empty string) so fragments on either side
    /// can't join into a phrase that was never said.
    private static func consume(_ phrase: String, from text: inout String) -> Bool {
        guard !phrase.isEmpty, text.contains(phrase) else { return false }
        text = text.replacingOccurrences(of: phrase, with: String(consumed))
        return true
    }

    private static func extractNumericOperations(_ text: inout String) -> [IntentOperation] {
        // Relative degrees first, otherwise "调高2度" would read as an absolute 2°C.
        let stepPattern = #"(调高|调低|升高|降低|升|降|高|低)(\d{1,2}|[零一二两三四五六七八九十]+)(?:度|℃|°C|°)"#
        var ops: [IntentOperation] = []
        if let regex = try? NSRegularExpression(pattern: stepPattern) {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            var stepMatched = false
            for match in matches {
                let direction = ns.substring(with: match.range(at: 1))
                guard let amount = spokenNumber(ns.substring(with: match.range(at: 2))),
                      amount > 0, amount <= 99 else { continue }
                let sign: Double = (direction.contains("高") || direction.contains("升")) ? 1 : -1
                ops.append(.temperatureStep(sign * Double(amount)))
                stepMatched = true
            }
            if stepMatched {
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(location: 0, length: ns.length), withTemplate: String(consumed)
                )
            }
        }
        let patterns: [(String, (Double) -> IntentOperation)] = [
            (#"(\d{4})[kK]"#, { .colorTemperature(Int($0)) }),
            (#"亮度(?:调到|调至|调为|设为|设置为|到|为)?(\d{1,3})(?:%|％)?"#, { .brightness(Int($0)) }),
            (#"(\d{1,3})(?:%|％)"#, { .brightness(Int($0)) }),
            (#"(\d{1,2}(?:\.\d)?)(?:度|℃|°C|°)"#, { .targetTemperature($0) })
        ]
        for (pattern, make) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                if let value = Double(ns.substring(with: match.range(at: 1))) {
                    ops.append(make(value))
                }
            }
            if !matches.isEmpty {
                text = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: String(consumed)
                )
            }
        }
        return ops
    }

    // MARK: - English Command Parser (Word-Boundary Tokenized)

    private static let englishRoomAliases: [String: [String]] = [
        "master bedroom": ["主卧", "卧室", "master bedroom", "master"],
        "second bedroom": ["次卧", "小卧室", "second bedroom", "guest"],
        "guest room": ["次卧", "小卧室", "guest room"],
        "living room": ["客厅", "living room", "living"],
        "dining room": ["餐厅", "dining room", "dining"],
        "study room": ["书房", "study"],
        "study": ["书房", "study"],
        "bedroom": ["卧室", "主卧", "bedroom"],
        "kitchen": ["厨房", "kitchen"],
        "balcony": ["阳台", "balcony"],
        "bathroom": ["卫生间", "浴室", "bathroom", "bath"],
        "entryway": ["玄关", "entryway", "entry"]
    ]

    private static let englishScopeWords: [String] = [
        "whole home", "entire home", "whole house", "everywhere", "everything", "all", "every"
    ]

    private static let englishCategoryWords: [(String, IntentDeviceCategory)] = [
        ("air conditioner", .climate), ("air conditioning", .climate),
        ("ceiling lights", .light), ("ceiling light", .light),
        ("bedside lamp", .light), ("desk lamp", .light), ("table lamp", .light),
        ("screen bar", .light), ("light strip", .light),
        ("robot vacuum", .vacuum), ("smart plug", .plug), ("space heater", .heater),
        ("standing fan", .fan), ("air purifiers", .airPurifier), ("air purifier", .airPurifier),
        ("purifiers", .airPurifier), ("purifier", .airPurifier),
        ("fresh air", .airPurifier), ("humidifiers", .airPurifier), ("humidifier", .airPurifier),
        ("lights", .light), ("light", .light), ("lamps", .light), ("lamp", .light),
        ("climate", .climate), ("ac", .climate),
        ("heater", .heater), ("dehumidifier", .dehumidifier), ("diffuser", .diffuser),
        ("fans", .fan), ("fan", .fan),
        ("plugs", .plug), ("plug", .plug), ("socket", .plug), ("outlet", .plug),
        ("vacuum", .vacuum),
        ("television", .tv), ("tv", .tv),
        ("cameras", .camera), ("camera", .camera),
        ("water valves", .valve), ("water valve", .valve),
        ("gas valves", .valve), ("gas valve", .valve),
        ("valves", .valve), ("valve", .valve)
    ]

    private static let englishFillers: [String] = [
        "please", "can", "could", "would", "you", "help", "me",
        "the", "my", "a", "an", "in", "at", "to", "by", "for", "into", "of",
        "set", "change", "switch", "adjust", "make", "it", "bit", "little",
        "mode", "room", "temperature", "temp", "brightness", "level", "speed"
    ]

    private static func parseEnglishCommand(
        _ utterance: String,
        devices: [SmartDevice],
        scenes: [HomeScene],
        panelRoom: BareCategoryCommand.Room?,
        usageOrder: [String]
    ) -> IntentPlan? {
        let lower = utterance.lowercased()
            .replacingOccurrences(of: #"[,!?;:'"“”‘’。，！？、]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        // Check scene activation ("activate sleep mode", "run focus scene")
        for scene in scenes where !scene.name.isEmpty {
            let sName = scene.name.lowercased()
            if lower == "activate \(sName)" || lower == "run \(sName)" || lower == "start \(sName)" || lower == "\(sName) scene" {
                return scenePlan(scene)
            }
        }

        var rest = " " + lower + " "
        var ops: [IntentOperation] = extractEnglishNumericOperations(&rest)

        // 1. Explicit device names (supports both English and Chinese names inside an English sentence)
        var explicitGroups: [[SmartDevice]] = []
        var byLowerName: [String: [SmartDevice]] = [:]
        var lowerNameOrder: [String] = []
        for dev in devices where !dev.name.isEmpty {
            let devLower = dev.name.lowercased()
            if byLowerName[devLower] == nil { lowerNameOrder.append(devLower) }
            byLowerName[devLower, default: []].append(dev)
        }
        for devLower in lowerNameOrder.sorted(by: { $0.count > $1.count }) {
            if consumeEnglishPhrase(devLower, from: &rest),
               let matched = byLowerName[devLower], !matched.isEmpty {
                explicitGroups.append(matched)
            }
        }

        // 2. Rooms, scope, and category words
        var matchedRoomKeys: [String] = []
        let allRoomKeys = Array(Set(englishRoomAliases.keys).union(devices.map { $0.roomName.lowercased() }.filter { !$0.isEmpty }))
            .sorted { $0.count > $1.count }
        for roomKey in allRoomKeys where consumeEnglishPhrase(roomKey, from: &rest) {
            matchedRoomKeys.append(roomKey)
        }

        var hasScope = false
        for scopeWord in englishScopeWords where consumeEnglishPhrase(scopeWord, from: &rest) {
            hasScope = true
        }

        // 3. Operations (ordered from specific multi-word phrases to shorter verbs, before bare category words
        // like "light" or "fan" so phrases such as "warm light", "night light", and "fan mode" stay intact)
        let oscPhrases: [(String, Bool)] = [
            ("stop oscillating", false), ("stop oscillation", false), ("stop swing", false),
            ("oscillation off", false), ("swing off", false),
            ("start oscillating", true), ("oscillation on", true), ("swing on", true),
            ("oscillate", true), ("oscillation", true), ("swing", true)
        ]
        for (p, val) in oscPhrases where consumeEnglishPhrase(p, from: &rest) {
            ops.append(.oscillation(val))
        }

        let fanPhrases: [(String, String)] = [
            ("fan speed high", "high"), ("high fan speed", "high"), ("high speed", "high"), ("max speed", "high"),
            ("fan speed medium", "medium"), ("medium fan speed", "medium"), ("medium speed", "medium"),
            ("fan speed low", "low"), ("low fan speed", "low"), ("low speed", "low"), ("min speed", "low"),
            ("fan speed auto", "auto"), ("auto fan speed", "auto"), ("auto speed", "auto"),
            ("sleep mode", "sleep"), ("favorite mode", "favorite")
        ]
        for (p, val) in fanPhrases where consumeEnglishPhrase(p, from: &rest) {
            ops.append(.fanSpeed(val))
        }

        let briStepPhrases: [(String, Int)] = [
            ("a bit darker", -20), ("a little darker", -20), ("a bit dimmer", -20), ("a little dimmer", -20),
            ("dimmer", -20), ("darker", -20),
            ("a bit brighter", 20), ("a little brighter", 20), ("brighter", 20)
        ]
        for (p, val) in briStepPhrases where consumeEnglishPhrase(p, from: &rest) {
            ops.append(.brightnessStep(val))
        }

        let tempStepPhrases: [(String, Double)] = [
            ("a bit warmer", 1), ("a little warmer", 1), ("warmer", 1), ("hotter", 1),
            ("a bit cooler", -1), ("a little cooler", -1), ("cooler", -1), ("colder", -1)
        ]
        for (p, val) in tempStepPhrases where consumeEnglishPhrase(p, from: &rest) {
            ops.append(.temperatureStep(val))
        }

        let effectPhrases: [(String, String)] = [
            ("moonlight mode", "Night"), ("moonlight", "Night"),
            ("night light mode", "Night"), ("night light", "Night"), ("night mode", "Night"),
            ("daylight mode", "Day"), ("daylight", "Day"), ("day mode", "Day")
        ]
        for (p, val) in effectPhrases where consumeEnglishPhrase(p, from: &rest) {
            ops.append(.lightEffect(val))
        }

        let briPhrases: [(String, Int)] = [
            ("minimum brightness", 10), ("dimmest", 10), ("dim", 20),
            ("maximum brightness", 100), ("max brightness", 100), ("full brightness", 100), ("brightest", 100)
        ]
        for (p, val) in briPhrases where consumeEnglishPhrase(p, from: &rest) {
            ops.append(.brightness(val))
        }

        let ctPhrases: [(String, Int)] = [
            ("warm light", 2700), ("warm white", 2700), ("yellow light", 2700),
            ("natural light", 4000), ("neutral white", 4000),
            ("white light", 6500), ("cool white", 6500), ("cold light", 6500)
        ]
        for (p, val) in ctPhrases where consumeEnglishPhrase(p, from: &rest) {
            ops.append(.colorTemperature(val))
        }

        let hvacPhrases: [(String, String)] = [
            ("cooling mode", "cool"), ("cool mode", "cool"), ("cooling", "cool"), ("cool", "cool"),
            ("heating mode", "heat"), ("heat mode", "heat"), ("heating", "heat"), ("heat", "heat"),
            ("dry mode", "dry"), ("dehumidify", "dry"),
            ("fan only mode", "fan_only"), ("fan only", "fan_only"), ("fan mode", "fan_only"),
            ("auto mode", "auto")
        ]
        for (p, val) in hvacPhrases where consumeEnglishPhrase(p, from: &rest) {
            ops.append(.hvacMode(val))
        }

        let powerPhrases: [(String, Bool)] = [
            ("turn on", true), ("switch on", true), ("power on", true), ("enable", true), ("open", true),
            ("turn off", false), ("switch off", false), ("power off", false), ("shut off", false), ("disable", false), ("close", false),
            ("off", false), ("on", true)
        ]
        for (p, val) in powerPhrases where consumeEnglishPhrase(p, from: &rest) {
            ops.append(.power(val))
        }

        var categories: Set<IntentDeviceCategory> = []
        for (phrase, cat) in englishCategoryWords where consumeEnglishPhrase(phrase, from: &rest) {
            categories.insert(cat)
        }

        // 4. Fillers
        for filler in englishFillers.sorted(by: { $0.count > $1.count }) {
            _ = consumeEnglishPhrase(filler, from: &rest)
        }

        guard rest.allSatisfy({ $0 == consumed || $0.isWhitespace }) else { return nil }
        guard let ops = reconcile(ops) else { return nil }

        var roomDeviceIds: Set<String> = []
        for key in matchedRoomKeys {
            let aliases = englishRoomAliases[key] ?? [key]
            let matched = devices.filter { dev in
                let rLower = dev.roomName.lowercased()
                return aliases.contains { rLower == $0.lowercased() || rLower.contains($0.lowercased()) }
            }
            if !matched.isEmpty {
                let resolved = disambiguateRoomDevices(matched, panelRoom: panelRoom)
                guard !resolved.isEmpty else { return nil }
                roomDeviceIds.formUnion(resolved)
            }
        }

        var explicitIds: [String] = []
        for group in explicitGroups {
            let narrowed = (group.count > 1 && !matchedRoomKeys.isEmpty)
                ? group.filter { roomDeviceIds.contains($0.id) }
                : group
            guard !narrowed.isEmpty else { return nil }
            let resolved = disambiguateRoomDevices(narrowed, panelRoom: panelRoom)
            guard !resolved.isEmpty else { return nil }
            explicitIds.append(contentsOf: resolved.filter { !explicitIds.contains($0) })
        }

        let isTurningOff = ops == [.power(false)]
        var targetIds: [String]
        let mustAcceptAll: Set<String> = Set(explicitIds)

        if !explicitIds.isEmpty {
            targetIds = explicitIds
        } else {
            let implied = impliedCategories(for: ops)
            let wanted = categories.isEmpty ? implied : categories
            if wanted == nil && !isTurningOff { return nil }
            guard hasScope || !matchedRoomKeys.isEmpty || wanted != nil else { return nil }

            if let bare = bareCategoryOutcome(
                ops: ops,
                wanted: wanted,
                hasScope: hasScope,
                hasRoomWord: !matchedRoomKeys.isEmpty,
                devices: devices,
                scenes: scenes,
                panelRoom: panelRoom,
                usageOrder: usageOrder
            ) {
                switch bare {
                case .plan(let plan): return plan
                case .targets(let ids): targetIds = ids
                }
            } else {
                let onlyActive = ops.allSatisfy(\.isRelative)
                let candidates = devices.filter { dev in
                    let category = IntentDeviceCategory(dev)
                    guard dev.isOnline, category.isAssistantControllable, dev.kind.acceptsControlWrites else { return false }
                    if category == .valve && !(wanted?.contains(.valve) ?? false) { return false }
                    if onlyActive && !dev.isActiveOn { return false }
                    if !matchedRoomKeys.isEmpty && !roomDeviceIds.contains(dev.id) { return false }
                    if let wanted, !wanted.contains(category) { return false }
                    return true
                }
                if !onlyActive && !hasScope && matchedRoomKeys.isEmpty && candidates.count != 1 { return nil }
                targetIds = candidates.map(\.id)
            }
        }

        let deviceById = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var intents: [DeviceIntent] = []
        for id in targetIds {
            guard let device = deviceById[id] else { return nil }
            let normalized = ops.compactMap { IntentValidator.normalize($0, for: device) }
            guard normalized.count == ops.count else {
                if mustAcceptAll.contains(id) { return nil }
                continue
            }
            intents.append(contentsOf: normalized.map { DeviceIntent(targetId: id, operation: $0) })
        }
        guard !intents.isEmpty else { return nil }

        return IntentPlan(
            intents: intents,
            reply: IntentReply.describe(intents, devices: devices, scenes: scenes),
            source: .local
        )
    }

    private static func consumeEnglishPhrase(_ phrase: String, from text: inout String) -> Bool {
        guard !phrase.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let isASCIIWord = phrase.unicodeScalars.allSatisfy { $0.isASCII }
        let pattern = isASCIIWord ? #"(?<![a-z0-9])"# + escaped + #"(?![a-z0-9])"# : escaped
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard regex.firstMatch(in: text, range: range) != nil else { return false }
        text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " \(consumed) ")
        return true
    }

    private static func extractEnglishNumericOperations(_ text: inout String) -> [IntentOperation] {
        var ops: [IntentOperation] = []
        let stepPattern = #"(?<![a-z])(increase|raise|up|decrease|lower|down)(?:\s+by)?\s+(\d{1,2})\s*(?:degrees?|deg|℃|°c|°)(?![a-z])"#
        if let regex = try? NSRegularExpression(pattern: stepPattern) {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let dir = ns.substring(with: match.range(at: 1))
                if let amount = Double(ns.substring(with: match.range(at: 2))) {
                    let sign: Double = (dir == "increase" || dir == "raise" || dir == "up") ? 1 : -1
                    ops.append(.temperatureStep(sign * amount))
                }
            }
            if !matches.isEmpty {
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(location: 0, length: ns.length), withTemplate: " \(consumed) "
                )
            }
        }

        let trailingStepPattern = #"(?<![a-z0-9])(\d{1,2})\s*(?:degrees?|deg|℃|°c|°)\s+(warmer|hotter|higher|cooler|colder|lower)(?![a-z])"#
        if let regex = try? NSRegularExpression(pattern: trailingStepPattern) {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                if let amount = Double(ns.substring(with: match.range(at: 1))) {
                    let dir = ns.substring(with: match.range(at: 2))
                    let sign: Double = (dir == "warmer" || dir == "hotter" || dir == "higher") ? 1 : -1
                    ops.append(.temperatureStep(sign * amount))
                }
            }
            if !matches.isEmpty {
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(location: 0, length: ns.length), withTemplate: " \(consumed) "
                )
            }
        }

        let patterns: [(String, (Double) -> IntentOperation)] = [
            (#"(?<![a-z0-9])(\d{4})\s*k(?![a-z0-9])"#, { .colorTemperature(Int($0)) }),
            (#"(?<![a-z0-9])(\d{1,3})\s*(?:%|percent)(?![a-z0-9])"#, { .brightness(Int($0)) }),
            (#"(?<![a-z0-9])(\d{1,2}(?:\.\d)?)\s*(?:degrees?\s*celsius|degrees?|deg|℃|°c|°)(?![a-z0-9])"#, { .targetTemperature($0) })
        ]
        for (pattern, make) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                if let val = Double(ns.substring(with: match.range(at: 1))) {
                    ops.append(make(val))
                }
            }
            if !matches.isEmpty {
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(location: 0, length: ns.length), withTemplate: " \(consumed) "
                )
            }
        }
        return ops
    }
}
