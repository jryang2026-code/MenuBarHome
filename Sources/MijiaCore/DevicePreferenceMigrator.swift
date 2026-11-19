import Foundation

/// Merges one paired card's orphaned-side view preferences onto the canonical card id (#24).
///
/// When Home Assistant and the Mi cloud both hold history for the same physical device (the user
/// ran HA-only for a while, then Mi-only, then connected both), the dedup keeps one canonical id
/// and the other side's stored preferences — hidden, favorites, aliases, tile sizes — point at an
/// id no card ever uses again. This migrator folds those entries onto the canonical id:
///
/// - Hidden wins: if the orphaned side hid the device, the card stays hidden.
/// - Favorites merge by union; the canonical id inherits the orphan's position in the order.
/// - Aliases and tile sizes copy only onto a canonical id that has none of its own, so an
///   explicit setting on the winning side is never overwritten.
/// - The orphaned entries stay on disk, so returning to a single-source home still finds them.
///
/// Each pair merges once. Afterwards the canonical card's preferences belong to the user: an
/// unhide, an unstar or a cleared alias must not be undone by the orphan's still-stored entries.
/// `ViewPreferenceKeys.adoptedPreferencePairs` records finished pairs as a flat `canonical\u{1F}orphan`
/// string array — a shape `stringArray(forKey:)` returns exactly as written, without the bridging
/// casts a nested dictionary needs after a relaunch — and is written after the preference writes. A
/// crash between the two re-runs the merge on the next launch; every rule is a union or a
/// copy-if-absent, and nothing the user could have changed sits between them, so that re-run adds
/// nothing. A record that exists but cannot be read is not treated as empty: merging again would
/// undo the user's edits, so such a pair is left alone.
public enum DevicePreferenceMigrator {
    /// Which preference kinds this adoption carried over from the orphaned side. The store uses the
    /// kind flags to update its in-memory sets. `changed` reports preference writes only; recording
    /// the pair is bookkeeping. A pair that was already adopted returns `.none`.
    public struct Outcome: Equatable, Sendable {
        public let hidden: Bool
        public let favorite: Bool
        public let alias: Bool
        public let tileSize: Bool
        public let wroteDefaults: Bool

        public var changed: Bool { wroteDefaults }

        static let none = Outcome(hidden: false, favorite: false, alias: false, tileSize: false, wroteDefaults: false)
    }

    public static func adopt(
        canonicalID: String,
        orphanedID: String,
        defaults: UserDefaults
    ) -> Outcome {
        guard !canonicalID.isEmpty, !orphanedID.isEmpty, canonicalID != orphanedID,
              let pairKey = encodedPair(canonicalID, orphanedID),
              let adopted = storedPairs(in: defaults) else {
            return .none
        }
        guard !adopted.contains(pairKey) else { return .none }

        var hidden = false
        var favorite = false
        var alias = false
        var tileSize = false
        var wroteDefaults = false

        // Hidden wins: the orphaned side hid this device, so the merged card must stay hidden.
        let hiddenIDs = defaults.stringArray(forKey: ViewPreferenceKeys.hiddenDeviceIds) ?? []
        if hiddenIDs.contains(orphanedID) {
            hidden = true
            if !hiddenIDs.contains(canonicalID) {
                defaults.set(hiddenIDs + [canonicalID], forKey: ViewPreferenceKeys.hiddenDeviceIds)
                wroteDefaults = true
            }
        }

        // A favorite on either side keeps the card starred; the order slot follows the orphan.
        let favoriteIDs = defaults.stringArray(forKey: ViewPreferenceKeys.favoriteDeviceIds) ?? []
        if favoriteIDs.contains(orphanedID) {
            favorite = true
            if !favoriteIDs.contains(canonicalID) {
                defaults.set(favoriteIDs + [canonicalID], forKey: ViewPreferenceKeys.favoriteDeviceIds)
                wroteDefaults = true
            }
            var order = defaults.stringArray(forKey: ViewPreferenceKeys.favoriteOrder) ?? []
            if !order.contains(canonicalID) {
                if let index = order.firstIndex(of: orphanedID) {
                    order.insert(canonicalID, at: index + 1)
                } else {
                    order.append(canonicalID)
                }
                defaults.set(order, forKey: ViewPreferenceKeys.favoriteOrder)
                wroteDefaults = true
            }
        }

        // An alias only fills a canonical id without one of its own.
        var aliases = decodeStringDictionary(ViewPreferenceKeys.deviceAliases, defaults: defaults)
        if let orphanAlias = aliases[orphanedID],
           !orphanAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (aliases[canonicalID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aliases[canonicalID] = orphanAlias
            encodeStringDictionary(aliases, key: ViewPreferenceKeys.deviceAliases, defaults: defaults)
            alias = true
            wroteDefaults = true
        }

        // Tile sizes are keyed by bare device id or `<page>|<device id>`; copy per key.
        var sizes = decodeStringDictionary(ViewPreferenceKeys.tileSizes, defaults: defaults)
        var copiedAnySize = false
        for (key, value) in sizes where keyTargetsDeviceID(key, orphanedID) {
            let canonicalKey = retargetedKey(key, from: orphanedID, to: canonicalID)
            // `DeviceLayoutPrefs` drops a bare `.auto` on save, so copying it is meaningless.
            if sizes[canonicalKey] == nil, !(value == "auto" && !canonicalKey.contains("|")) {
                sizes[canonicalKey] = value
                copiedAnySize = true
            }
        }
        if copiedAnySize {
            encodeStringDictionary(sizes, key: ViewPreferenceKeys.tileSizes, defaults: defaults)
            tileSize = true
            wroteDefaults = true
        }

        // Last write. Recorded even when nothing was copied, so a canonical alias the user clears
        // later is not refilled from the orphan.
        defaults.set(adopted + [pairKey], forKey: ViewPreferenceKeys.adoptedPreferencePairs)

        return Outcome(
            hidden: hidden,
            favorite: favorite,
            alias: alias,
            tileSize: tileSize,
            wroteDefaults: wroteDefaults
        )
    }

    /// `"<canonical id>" + separator + "<orphaned id>"`; a unit separator never appears in a Home
    /// Assistant entity id or a Mi did.
    private static let pairSeparator: Character = "\u{1F}"

    /// Finished pairs in the flat persisted form, or nil when a value exists but cannot be understood.
    /// The previous build of this fix stored `[canonical id: [orphaned id]]`; that shape is still read
    /// and rewritten flat on the next merge, so an upgrade never loses the record.
    private static func storedPairs(in defaults: UserDefaults) -> [String]? {
        guard let raw = defaults.object(forKey: ViewPreferenceKeys.adoptedPreferencePairs) else {
            return []
        }
        if let flat = raw as? [String] {
            return flat.allSatisfy { decodedPair($0) != nil } ? flat : nil
        }
        if let legacy = raw as? [String: Any] {
            var migrated: [String] = []
            for canonicalID in legacy.keys.sorted() {
                let orphans: [String]
                switch legacy[canonicalID] {
                case let list as [String]: orphans = list
                case let single as String: orphans = [single]
                default: return nil
                }
                for orphanedID in orphans {
                    guard let encoded = encodedPair(canonicalID, orphanedID) else { return nil }
                    migrated.append(encoded)
                }
            }
            return migrated
        }
        return nil
    }

    private static func encodedPair(_ canonicalID: String, _ orphanedID: String) -> String? {
        guard !canonicalID.isEmpty, !orphanedID.isEmpty, canonicalID != orphanedID,
              !canonicalID.contains(pairSeparator), !orphanedID.contains(pairSeparator) else {
            return nil
        }
        return "\(canonicalID)\(pairSeparator)\(orphanedID)"
    }

    private static func decodedPair(_ encoded: String) -> (canonicalID: String, orphanedID: String)? {
        let parts = encoded.split(separator: pairSeparator, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// `true` for `"<device id>"` and `"<page>|<device id>"` (the last `|` segment is the id).
    private static func keyTargetsDeviceID(_ key: String, _ deviceID: String) -> Bool {
        guard let separator = key.lastIndex(of: "|") else { return key == deviceID }
        return key[key.index(after: separator)...] == Substring(deviceID)
    }

    private static func retargetedKey(_ key: String, from orphanedID: String, to canonicalID: String) -> String {
        guard let separator = key.lastIndex(of: "|") else { return canonicalID }
        return "\(key[..<key.index(after: separator)])\(canonicalID)"
    }

    private static func decodeStringDictionary(_ key: String, defaults: UserDefaults) -> [String: String] {
        guard let raw = defaults.string(forKey: key),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func encodeStringDictionary(_ dictionary: [String: String], key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(dictionary),
              let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: key)
    }
}
