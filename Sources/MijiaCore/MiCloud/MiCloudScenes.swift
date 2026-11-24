import Foundation

public struct MiCloudScene: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let homeId: String
    let ownerUid: String

    static func decode(_ result: JSONValue, homeId: String, ownerUid: String) -> [Self] {
        var seen = Set<String>()
        return (result["manual_scene_info_list"]?.arrayValue ?? []).compactMap { row in
            guard let id = row["scene_id"]?.idString,
                  !id.isEmpty, !id.contains(":"), !id.contains("/"),
                  seen.insert(id).inserted else { return nil }
            let name = (row["scene_name"]?.stringValue ?? row["name"]?.stringValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Self(id: id, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                        homeId: homeId, ownerUid: ownerUid)
        }
    }

    static func accountID(for entityId: String) -> String? {
        guard MiAccountScope.localId(of: entityId).hasPrefix("mi-scene:") else { return nil }
        return MiAccountScope.owner(of: entityId)
    }

    func entityID(accountID: String) -> String {
        MiAccountScope.id("mi-scene:\(homeId):\(id)", account: accountID)
    }
}

extension MiCloudClient {
    private static let sceneAPI = "appgateway/miot/appsceneservice/AppSceneService"

    public func manualScenes(homeId: String, ownerUid: String) async throws -> [MiCloudScene] {
        let result = try await request("\(Self.sceneAPI)/GetSimpleSceneList", data: .object([
            "app_version": .number(12), "get_type": .number(2),
            "home_id": .string(homeId), "owner_uid": Self.miIdValue(ownerUid),
        ]))
        return MiCloudScene.decode(result, homeId: homeId, ownerUid: ownerUid)
    }

    public func runManualScene(_ scene: MiCloudScene) async throws {
        _ = try await request("\(Self.sceneAPI)/NewRunScene", data: .object([
            "scene_id": .string(scene.id), "scene_type": .number(2), "phone_id": .string("null"),
            "home_id": .string(scene.homeId), "owner_uid": Self.miIdValue(scene.ownerUid),
        ]))
    }
}
