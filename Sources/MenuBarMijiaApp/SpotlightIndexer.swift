import AppKit
import CoreSpotlight
import Foundation
import MijiaCore
import UniformTypeIdentifiers
import os

/// Mirrors the home into the system Spotlight index (#575).
///
/// The store owns *what* may be indexed (`HomeStore.spotlightIndexEntries()`); this type owns *when*
/// and *how*: a 2 s debounce after a snapshot change (the same shape as the Raycast snapshot export,
/// so a burst of polled updates produces one pass), an incremental write keyed by item identifier,
/// and a full clear when the plan becomes empty.
///
/// Nothing here runs outside a real app bundle: `CSSearchableIndex.default()` is meaningless in
/// `swift test`, and a test must never touch the developer's own Spotlight index.
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    /// One index pass. Split from the CoreSpotlight calls so the debounce, the incremental removal
    /// bookkeeping and the "empty plan clears everything" rule can be tested without an index.
    struct Pass: Equatable {
        var items: [SpotlightIndexEntry]
        var removals: [String]
        var clearsAll: Bool
    }

    private static let logger = Logger(subsystem: "com.menubarmijia.app", category: "spotlight")

    /// Test seam: production waits two seconds after the last snapshot change.
    var debounce: Duration = .seconds(2)
    /// Test seam replacing `CSSearchableIndex.default()`.
    var writePass: ((Pass) async -> Void)?

    private var pending: Task<Void, Never>?
    private var lastSignature: String?
    private var indexedIdentifiers: Set<String> = []
    private var isStarted = false

    init() {}

    /// Installs the store sink and mirrors whatever the store already knows.
    func start(with store: HomeStore) {
        guard !isStarted else { return }
        isStarted = true
        store.onSpotlightIndexUpdate = { [weak self] update in
            self?.handle(update)
        }
        // Only mirror a home that has already loaded. Before the first snapshot the plan is empty
        // by construction, and acting on it would wipe the index on every launch.
        if store.hasReceivedInitialSnapshot {
            accept(store.spotlightIndexEntries())
        }
    }

    func handle(_ update: SpotlightIndexUpdate) {
        switch update {
        case .plan(let entries):
            accept(entries)
        case .clearNow:
            // Sign-out: no debounce, so the index never outlives the credentials by even one
            // interval. A pass that was already scheduled must not put the names back.
            pending?.cancel()
            pending = nil
            let signature = SpotlightIndexPlan.contentSignature(of: [])
            Task { @MainActor [weak self] in
                // `forceClear` because a stale index from an earlier launch must go too, even when
                // this process never wrote an item.
                await self?.apply([], signature: signature, forceClear: true)
            }
        }
    }

    /// Called for every snapshot change. The signature check means a poll that only changed a
    /// sensor reading schedules nothing at all.
    func accept(_ entries: [SpotlightIndexEntry]) {
        let signature = SpotlightIndexPlan.contentSignature(of: entries)
        guard signature != lastSignature else { return }
        pending?.cancel()
        let delay = debounce
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.apply(entries, signature: signature)
        }
    }

    /// Writes one plan now, remembering what it wrote so the next pass deletes exactly the entities
    /// that left the home. An empty plan is a deliberate clear (setting off, signed out, source
    /// removed) and must leave nothing behind.
    func apply(_ entries: [SpotlightIndexEntry], signature: String, forceClear: Bool = false) async {
        pending?.cancel()
        pending = nil
        let removals = SpotlightIndexPlan.removals(previous: indexedIdentifiers, current: entries)
        let clearsAll = entries.isEmpty && (forceClear || !indexedIdentifiers.isEmpty)
        lastSignature = signature
        indexedIdentifiers = Set(entries.map(\.itemIdentifier))
        let pass = Pass(items: entries, removals: removals, clearsAll: clearsAll)
        if let writePass {
            await writePass(pass)
            return
        }
        await Self.write(pass)
    }

    // MARK: - CoreSpotlight

    private static func write(_ pass: Pass) async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let index = CSSearchableIndex.default()
        do {
            if pass.clearsAll {
                try await index.deleteAllSearchableItems()
                return
            }
            if !pass.removals.isEmpty {
                try await index.deleteSearchableItems(withIdentifiers: pass.removals)
            }
            guard !pass.items.isEmpty else { return }
            try await index.indexSearchableItems(pass.items.map(searchableItem(for:)))
        } catch {
            // Indexing is best effort: a refused write must never break a snapshot application.
            logger.notice("Spotlight index write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One result. Everything Spotlight displays is the name, the room and the pinyin keywords; the
    /// item identifier and the deeplink a tap needs are the only places the snapshot id appears, and
    /// that id is the same one the local Raycast snapshot already stores (#575).
    static func searchableItem(for entry: SpotlightIndexEntry) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = entry.title
        attributes.displayName = entry.title
        attributes.keywords = entry.keywords
        if !entry.roomName.isEmpty {
            attributes.contentDescription = entry.kind == .device
                ? L10n.format("设备 · %@", "Device · %@", entry.roomName)
                : entry.roomName
        } else {
            attributes.contentDescription = switch entry.kind {
            case .room: L10n.tr("房间", "Room")
            case .scene: L10n.tr("场景", "Scene")
            case .device: L10n.tr("设备", "Device")
            }
        }
        // Spotlight hands the URL to `application(_:open:)` on a tap, which is the same path a
        // Raycast or web link takes: confirmation, screen-lock block and capability gate all apply.
        attributes.contentURL = entry.routeURL
        return CSSearchableItem(
            uniqueIdentifier: entry.itemIdentifier,
            domainIdentifier: entry.domainIdentifier,
            attributeSet: attributes
        )
    }
}
