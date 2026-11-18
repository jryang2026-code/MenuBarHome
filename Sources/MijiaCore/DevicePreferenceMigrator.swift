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
/// Every rule is a union or a copy-if-absent, so re-running the adoption changes nothing.
public enum DevicePreferenceMigrator {
    /// Which preference kinds the orphaned side holds, and whether this adoption actually wrote
    /// anything. The store uses the kind flags to update its in-memory sets; `changed` is false on
    /// a repeated adoption, so idempotent re-runs never churn the defaults.
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
        guard !canonicalID.isEmpty, !orphanedID.isEmpty, canonicalID != orphanedID else {
            return .none
        }

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

        return Outcome(
            hidden: hidden,
            favorite: favorite,
            alias: alias,
            tileSize: tileSize,
            wroteDefaults: wroteDefaults
        )
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
