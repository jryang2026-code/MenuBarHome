import Foundation
import os

/// Full Mi Cloud discovery, shared by the live provider and the on-demand skipped-device scan.
///
/// The two halves are separate because the provider repeats only the device half on its periodic
/// refresh, while a scan runs both once. Keeping them here means the panel and the scan cannot
/// disagree about which devices an account has (#76, #67).
public enum MiCloudDiscovery {
    private static let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "MiCloudDiscovery")

    /// The room half. `error` is set when `homeRooms()` failed for a reason other than an expired
    /// session; an expired session throws instead, because no later call can succeed.
    public struct RoomOutcome: Sendable {
        public var rooms: [MiRoom]
        public var error: (any Error)?

        public init(rooms: [MiRoom], error: (any Error)? = nil) {
            self.rooms = rooms
            self.error = error
        }
    }

    /// The device half: every device the account can see, plus the rooms the by-home fallback
    /// extended so those devices stay visible when one home is selected.
    public struct DeviceOutcome: Sendable {
        public var devices: [MiDeviceRecord]
        public var rooms: [MiRoom]
        /// Room dids the by-did lookup returned nothing for (IR remotes, removed devices). The
        /// periodic refresh skips them so it does not spend a request on them every time.
        public var unresolvedRoomDids: Set<String>

        public init(
            devices: [MiDeviceRecord],
            rooms: [MiRoom],
            unresolvedRoomDids: Set<String> = []
        ) {
            self.devices = devices
            self.rooms = rooms
            self.unresolvedRoomDids = unresolvedRoomDids
        }
    }

    /// Rooms first: they name the dids the unfiltered device list leaves out (#134).
    public static func rooms(_ api: any MiCloudAPI) async throws -> RoomOutcome {
        do {
            return RoomOutcome(rooms: try await api.homeRooms())
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            logger.notice("Room list unavailable, devices go to 全屋: \(error.localizedDescription, privacy: .public)")
            return RoomOutcome(rooms: [], error: error)
        }
    }

    /// The device list, the by-did lookup for room devices the list omits, and the per-home fallback
    /// that reaches homes shared with this account.
    public static func devices(
        _ api: any MiCloudAPI,
        rooms: [MiRoom],
        retryUnresolved: Bool,
        previousUnresolved: Set<String> = []
    ) async throws -> DeviceOutcome {
        var list = try await api.deviceList()
        let listed = Set(list.map(\.did))
        var unresolved = retryUnresolved ? [] : previousUnresolved
        var firstLookupError: (any Error)?
        var missingSet = Set(rooms.flatMap(\.dids)).subtracting(listed)
        missingSet.subtract(unresolved)
        let missing = missingSet.sorted()
        if !missing.isEmpty {
            do {
                let extra = try await api.devices(dids: missing).filter { !listed.contains($0.did) }
                list += extra
                unresolved.formUnion(missingSet.subtracting(extra.map(\.did)))
                logger.info("Mi cloud shared-home devices: \(extra.count, privacy: .public) of \(missing.count, privacy: .public) room dids not in the device list")
            } catch MiCloudError.sessionExpired {
                throw MiCloudError.sessionExpired
            } catch {
                firstLookupError = firstLookupError ?? error
                logger.error("Shared-home device lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let fallback = try await homeFallback(api, rooms: rooms, list: &list, unresolved: unresolved, firstError: &firstLookupError)
        if fallback.devices.isEmpty, let firstLookupError {
            throw firstLookupError
        }
        return DeviceOutcome(
            devices: fallback.devices,
            rooms: fallback.rooms,
            unresolvedRoomDids: unresolved
        )
    }

    /// One pass over every home that names both an id and an owner uid. A home whose devices the
    /// list did not resolve is asked for by `v2/home/home_device_list`, which is the only endpoint
    /// that answers for a home another account shared with this one (#76, #67).
    private static func homeFallback(
        _ api: any MiCloudAPI,
        rooms: [MiRoom],
        list: inout [MiDeviceRecord],
        unresolved: Set<String>,
        firstError: inout (any Error)?
    ) async throws -> (devices: [MiDeviceRecord], rooms: [MiRoom]) {
        var homes: [(homeId: String, ownerUid: String)] = []
        for room in rooms where !room.homeId.isEmpty {
            guard let ownerUid = room.ownerUid, !ownerUid.isEmpty else { continue }
            guard !homes.contains(where: { $0.homeId == room.homeId }) else { continue }
            homes.append((homeId: room.homeId, ownerUid: ownerUid))
        }
        guard !homes.isEmpty else { return (list, rooms) }

        var updatedRooms = rooms
        var known = Set(list.map(\.did))
        for home in homes {
            let homeDids = Set(updatedRooms.filter { $0.homeId == home.homeId }.flatMap(\.dids))
            let resolved = list.filter { homeDids.contains($0.did) }.count
            let stillMissing = !homeDids.intersection(unresolved).isEmpty
            guard resolved == 0 || stillMissing else { continue }
            do {
                let found = try await api.homeDevices(homeId: home.homeId, ownerUid: home.ownerUid)
                var added = 0
                for record in found where !known.contains(record.did) {
                    known.insert(record.did)
                    list.append(record)
                    added += 1
                }
                appendMissingDids(found, homeId: home.homeId, rooms: &updatedRooms)
                if added > 0 {
                    logger.info("Mi cloud home \(home.homeId, privacy: .public): \(added, privacy: .public) extra devices")
                }
            } catch MiCloudError.sessionExpired {
                throw MiCloudError.sessionExpired
            } catch {
                firstError = firstError ?? error
                logger.error("Home device lookup failed for \(home.homeId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return (list, updatedRooms)
    }

    /// Adds each device the returned home list named when neither it nor its split parent is already
    /// assigned to a room of that home. Keeping split keys whose parent already lives in a named room
    /// out of `home_<id>` preserves `MiotSynthesizer`'s parent-room inheritance instead of pulling
    /// them into 全屋.
    private static func appendMissingDids(_ records: [MiDeviceRecord], homeId: String, rooms: inout [MiRoom]) {
        let listedInHome = Set(rooms.filter { $0.homeId == homeId }.flatMap(\.dids))
        var seen: Set<String> = []
        let extra = records.compactMap { record -> String? in
            if listedInHome.contains(record.did) { return nil }
            if let parent = record.splitParentDid, listedInHome.contains(parent) { return nil }
            return seen.insert(record.did).inserted ? record.did : nil
        }
        guard !extra.isEmpty else { return }
        let targetId = "home_\(homeId)"
        if let index = rooms.firstIndex(where: { $0.id == targetId }) {
            var room = rooms[index]
            for did in extra where !room.dids.contains(did) {
                room.dids.append(did)
            }
            rooms[index] = room
            return
        }
        let sibling = rooms.first { $0.homeId == homeId }
        rooms.append(MiRoom(
            id: targetId,
            name: "",
            dids: extra,
            homeId: homeId,
            homeName: sibling?.homeName ?? "",
            isSharedHome: sibling?.isSharedHome ?? false,
            ownerUid: sibling?.ownerUid
        ))
    }
}
