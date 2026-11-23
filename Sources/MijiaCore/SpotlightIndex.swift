import Foundation

// MARK: - Spotlight Index (#575)
//
// Devices, rooms and scenes are mirrored into the system Spotlight index so ⌘Space finds them
// without opening the panel first. Two rules keep this from becoming a privacy leak:
//
// 1. **Everything Spotlight shows is a name.** Title, subtitle and keywords are the device, room and
//    scene names plus their pinyin forms; `SpotlightIndexEntry` has no field for a host, an address,
//    a token or a credential, so none can be indexed by accident.
// 2. **The feature is opt-in.** `HomePreferences.spotlightIndexEnabled` defaults to `false`: the
//    system index survives in `~/Library/Metadata` and is read by system surfaces the app does not
//    control, so mirroring a home there is a decision the user makes, not one an upgrade makes.
//
// The one identifier that does reach the index is the entity id, inside `itemIdentifier` and the
// deeplink a tap opens — a result has to lead somewhere. It is the same id the Raycast snapshot
// already persists locally in `Application Support`, and every write path is gated on the opt-in
// setting, so this adds no new class of exposure; hashing it would not either, since a Xiaomi DID is
// a short numeric string any local reader could enumerate.
//
// The plan is a pure value: the app-side `SpotlightIndexer` only translates entries into
// `CSSearchableItem`s and writes them, so every mapping decision is covered by unit tests that do
// not touch the real index.

/// One indexable home entity. The fields are exactly what Spotlight is allowed to see.
public struct SpotlightIndexEntry: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case device
        case room
        case scene
    }

    public let kind: Kind
    /// Snapshot id. Stays out of every human-readable field except the deeplink.
    public let entityId: String
    public let title: String
    /// Already localised through `L10n.displayRoomName`, empty for a room entry.
    public let roomName: String
    /// Normalised name/room forms plus pinyin, so `keshiding` and `kstd` both match 客厅顶灯.
    public let keywords: [String]
    public let domainIdentifier: String

    public init(
        kind: Kind,
        entityId: String,
        title: String,
        roomName: String,
        keywords: [String],
        domainIdentifier: String
    ) {
        self.kind = kind
        self.entityId = entityId
        self.title = title
        self.roomName = roomName
        self.keywords = keywords
        self.domainIdentifier = domainIdentifier
    }

    /// Stable `CSSearchableItem` identifier: an entity keeps one item across reindexes, which is
    /// what lets the indexer delete exactly what left the home instead of rebuilding everything.
    public var itemIdentifier: String { "\(SpotlightIndexPlan.itemPrefix)\(kind.rawValue).\(entityId)" }

    /// What a Spotlight tap opens. Devices and rooms only navigate (`focus` never writes a device);
    /// a scene goes through the existing `scene` route, which keeps the external-link confirmation
    /// and the screen-lock block in front of the write.
    public var routeURL: URL? {
        switch kind {
        case .device: return SpotlightIndexPlan.deeplink(route: "focus", key: "device", value: entityId)
        case .room: return SpotlightIndexPlan.deeplink(route: "focus", key: "room", value: entityId)
        case .scene: return SpotlightIndexPlan.deeplink(route: "scene", key: "name", value: entityId)
        }
    }
}

public enum SpotlightIndexPlan {
    /// Prefix of every item this app owns. `itemPrefix` + `kind.entityId` is the whole identifier.
    public static let itemPrefix = "menubarmijia.spotlight."
    /// Domain prefix; one domain per source so turning a connection off can delete only its items.
    public static let domainPrefix = "menubarmijia."
    /// A 400-device home plus rooms and scenes is already unusual; the cap keeps a runaway snapshot
    /// from turning into thousands of system index writes.
    public static let maximumEntries = 600

    public static func domain(for backend: HomeBackend) -> String {
        domainPrefix + backend.rawValue
    }

    /// Splits `menubarmijia.spotlight.<kind>.<entityId>` back into its parts.
    ///
    /// The entity id may itself contain dots (`light.living_room`), so only the first dot after the
    /// kind separates it: a Home Assistant entity id must survive the round trip unchanged.
    public static func identity(forItemIdentifier identifier: String) -> (kind: SpotlightIndexEntry.Kind, entityId: String)? {
        guard identifier.hasPrefix(itemPrefix) else { return nil }
        let remainder = identifier.dropFirst(itemPrefix.count)
        guard let separator = remainder.firstIndex(of: ".") else { return nil }
        guard let kind = SpotlightIndexEntry.Kind(rawValue: String(remainder[remainder.startIndex..<separator])) else {
            return nil
        }
        let entityId = String(remainder[remainder.index(after: separator)...])
        guard !entityId.isEmpty else { return nil }
        return (kind, entityId)
    }

    /// Where a Spotlight tap on that identifier leads, or `nil` when the identifier is not ours.
    public static func route(forItemIdentifier identifier: String) -> URL? {
        guard let identity = identity(forItemIdentifier: identifier) else { return nil }
        return SpotlightIndexEntry(
            kind: identity.kind,
            entityId: identity.entityId,
            title: "",
            roomName: "",
            keywords: [],
            domainIdentifier: ""
        ).routeURL
    }

    /// `menumijia://<route>?<key>=<value>`, percent-encoded through `URLComponents` so a device id
    /// with a space or a slash cannot turn into a second path segment.
    public static func deeplink(route: String, key: String, value: String) -> URL? {
        var components = URLComponents()
        components.scheme = AppURLParser.scheme
        components.host = route
        components.queryItems = [URLQueryItem(name: key, value: value)]
        return components.url
    }

    /// Builds the full plan. `backend` resolves which source serves a card (the store already knows
    /// this per device); rooms and scenes inherit the home's active backend.
    ///
    /// `hiddenIds` are devices the user hid in the panel: they stay out of the index, because a
    /// Spotlight hit would otherwise be the one place a hidden device still shows up.
    public static func entries(
        devices: [SmartDevice],
        rooms: [RoomArea],
        scenes: [HomeScene],
        hiddenIds: Set<String> = [],
        aliases: [String: String] = [:],
        homeDomain: String,
        backend: (String) -> HomeBackend
    ) -> [SpotlightIndexEntry] {
        var entries: [SpotlightIndexEntry] = []
        entries.reserveCapacity(min(maximumEntries, devices.count + rooms.count + scenes.count))

        for device in devices where !hiddenIds.contains(device.id) {
            let title = PanelSearch.alias(for: device, aliases: aliases) ?? device.name
            let roomName = L10n.displayRoomName(device.roomName)
            entries.append(SpotlightIndexEntry(
                kind: .device,
                entityId: device.id,
                title: title,
                roomName: roomName,
                keywords: keywords(name: title, roomName: device.roomName),
                domainIdentifier: domain(for: backend(device.id))
            ))
        }

        for room in rooms {
            let name = L10n.displayRoomName(room.name)
            entries.append(SpotlightIndexEntry(
                kind: .room,
                entityId: room.id,
                title: name,
                roomName: "",
                keywords: keywords(name: name, roomName: room.name),
                domainIdentifier: homeDomain
            ))
        }

        for scene in scenes {
            entries.append(SpotlightIndexEntry(
                kind: .scene,
                entityId: scene.id,
                title: scene.name,
                roomName: "",
                keywords: keywords(name: scene.name, roomName: ""),
                domainIdentifier: homeDomain
            ))
        }

        // Deterministic order keeps the content signature stable, so an unchanged home writes nothing.
        return Array(entries.prefix(maximumEntries))
            .sorted { $0.itemIdentifier < $1.itemIdentifier }
    }

    /// Name and room in their written form plus the pinyin forms the panel search already uses.
    public static func keywords(name: String, roomName: String) -> [String] {
        var result: [String] = []
        func append(_ raw: String) {
            let normalized = PanelSearch.normalize(raw)
            guard !normalized.isEmpty, !result.contains(normalized) else { return }
            result.append(normalized)
        }
        append(name)
        append(roomName == name ? "" : roomName)
        if let syllables = PanelSearch.Pinyin.syllables(name) {
            append(syllables.joined())
            append(PanelSearch.Pinyin.initials(of: syllables))
        }
        if !roomName.isEmpty, let syllables = PanelSearch.Pinyin.syllables(roomName) {
            append(syllables.joined())
            append(PanelSearch.Pinyin.initials(of: syllables))
        }
        return result
    }

    /// FNV-1a over the entries' identity and visible text. Equal signatures mean the index is
    /// already correct, so a poll that reorders devices or bumps a sensor reading writes nothing.
    public static func contentSignature(of entries: [SpotlightIndexEntry]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x1f
            hash = hash &* 0x0000_0100_0000_01b3
        }
        for entry in entries {
            mix(entry.itemIdentifier)
            mix(entry.title)
            mix(entry.roomName)
            mix(entry.domainIdentifier)
            mix(entry.keywords.joined(separator: "\u{1}"))
        }
        return String(hash, radix: 16)
    }

    /// Items to delete after a reindex: everything the previous plan had and the new one does not.
    public static func removals(previous: Set<String>, current: [SpotlightIndexEntry]) -> [String] {
        let next = Set(current.map(\.itemIdentifier))
        return previous.subtracting(next).sorted()
    }
}
