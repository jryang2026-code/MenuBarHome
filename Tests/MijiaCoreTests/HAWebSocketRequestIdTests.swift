import Foundation
import Testing
@testable import MijiaCore

struct HAWebSocketRequestIdTests {
    private static let baseURL = "http://192.0.2.10:8123"
    fileprivate static let onStates = #"[{"entity_id":"light.visible","state":"on","attributes":{"friendly_name":"Desk light"}},{"entity_id":"light.hidden","state":"on","attributes":{}}]"#

    @Test(
        "A late camera-stream result in the old 1000...9999 id window does not drop the Home Assistant connection",
        .timeLimit(.minutes(1))
    )
    func lateStreamResultInLegacyIdWindowStaysConnected() async throws {
        let socket = RequestIdSocket()
        let streamTimeout = Hold()
        let provider = HAWebSocketProvider(
            baseURLString: Self.baseURL,
            token: "ha-token",
            rediscover: { _ in [] },
            allowsToken: { _ in true }
        )
        await provider.setTestSeams(
            connectOverride: nil,
            reconnectSleep: { _ in await Hold.forever() },
            webSocketFactory: { _ in socket },
            streamRequestTimeout: { await streamTimeout.park() }
        )

        let log = ProviderEventLog()
        let collecting = Task {
            for await event in provider.events() {
                await log.append(event)
            }
        }

        await log.waitUntilConnected()
        await log.waitUntilDeskLight(isOn: true)

        while await socket.maxCommandId() < 1000 {
            await provider.refreshNow()
        }

        let resolve = Task {
            try await provider.resolveCameraStream(for: Self.camera)
        }
        let cameraId = await socket.waitForCameraId()
        #expect((1000...9999).contains(cameraId))

        await streamTimeout.release()
        let source = try await resolve.value
        #expect(source == .mjpeg(URL(string: "\(Self.baseURL)/api/camera_proxy_stream/camera.door?token=abc123")!))

        let pingId = await socket.maxCommandId() + 1
        #expect((1000...9999).contains(pingId))
        await socket.push(
            #"{"id":\#(cameraId),"type":"result","success":true,"result":{"url":"/api/hls/camera.door/playlist.m3u8"}}"#
        )
        await socket.push(
            #"{"id":\#(pingId),"type":"result","success":true,"result":null}"#
        )
        await socket.push(
            #"{"type":"event","event":{"event_type":"state_changed","data":{"new_state":{"entity_id":"light.visible","state":"off","attributes":{"friendly_name":"Desk light"}}}}}"#
        )

        let outcome = await log.waitForLateReplyOutcome()
        #expect(outcome == .deskLightTurnedOff)

        await provider.shutdown()
        await collecting.value
    }

    private static let camera = SmartDevice(
        id: "ha-cam",
        name: "门口",
        roomId: "door",
        roomName: "门口",
        model: "generic.camera",
        isOnline: true,
        kind: .camera(CameraSpec(
            entityId: "switch.door_cam",
            isOn: true,
            streamEntityId: "camera.door",
            snapshotPath: "/api/camera_proxy/camera.door?token=abc123"
        ))
    )
}

private actor Hold {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    static func forever() async {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }

    func park() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        let parked = waiters
        waiters.removeAll()
        for waiter in parked {
            waiter.resume()
        }
    }
}

private actor ProviderEventLog {
    enum LateReplyOutcome: Equatable {
        case deskLightTurnedOff
        case disconnected
    }

    private var events: [HomeProviderEvent] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func append(_ event: HomeProviderEvent) {
        events.append(event)
        resumeWaiters()
    }

    func waitUntilConnected() async {
        await waitUntil { event in
            if case .statusChanged(let status) = event, status == .connected { return true }
            return false
        }
    }

    func waitUntilDeskLight(isOn expected: Bool) async {
        await waitUntil { event in
            guard case .snapshotUpdated(let home) = event else { return false }
            return Self.deskLight(in: home)?.isActiveOn == expected
        }
    }

    func waitForLateReplyOutcome() async -> LateReplyOutcome {
        while true {
            if events.contains(where: Self.isDisconnected) { return .disconnected }
            if events.contains(where: Self.isDeskLightOff) { return .deskLightTurnedOff }
            await park()
        }
    }

    private func waitUntil(_ matches: (HomeProviderEvent) -> Bool) async {
        while !events.contains(where: matches) {
            await park()
        }
    }

    private func park() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    private func resumeWaiters() {
        let parked = waiters
        waiters.removeAll()
        for waiter in parked {
            waiter.resume()
        }
    }

    private static func isDisconnected(_ event: HomeProviderEvent) -> Bool {
        if case .statusChanged(.disconnected) = event { return true }
        return false
    }

    private static func isDeskLightOff(_ event: HomeProviderEvent) -> Bool {
        guard case .snapshotUpdated(let home) = event else { return false }
        return deskLight(in: home)?.isActiveOn == false
    }

    private static func deskLight(in home: SynthesizedHome) -> SmartDevice? {
        home.devices.first { device in
            guard case .light = device.kind else { return false }
            return device.name == "Desk light"
        }
    }
}

private actor RequestIdSocket: HAWebSocketConnection {
    private var phase = 0
    private var pending: [Data] = []
    private var receiveWaiter: CheckedContinuation<Data, Error>?
    private var sentIDs: [Int] = []
    private var cameraId: Int?
    private var cameraWaiter: CheckedContinuation<Int, Never>?
    private var isCancelled = false

    nonisolated func resume() {}

    func send(_ text: String) async throws {
        guard !isCancelled else { throw CancellationError() }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String,
              let id = Self.intValue(object["id"]) else {
            return
        }
        sentIDs.append(id)
        if type == "camera/stream" {
            cameraId = id
            cameraWaiter?.resume(returning: id)
            cameraWaiter = nil
            return
        }
        let result: String
        switch id {
        case 1:
            result = #"[{"area_id":"office","name":"Office"}]"#
        case 2:
            result = "[]"
        case 3:
            result = #"[{"entity_id":"light.visible","area_id":"office"},{"entity_id":"light.hidden","hidden_by":"user"}]"#
        case 5:
            result = "null"
        default:
            result = HAWebSocketRequestIdTests.onStates
        }
        enqueue(Data(#"{"id":\#(id),"type":"result","success":true,"result":\#(result)}"#.utf8))
    }

    func receive() async throws -> Data {
        guard !isCancelled else { throw CancellationError() }
        phase += 1
        if phase == 1 {
            return Data(#"{"type":"auth_required"}"#.utf8)
        }
        if phase == 2 {
            return Data(#"{"type":"auth_ok"}"#.utf8)
        }
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            if isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                receiveWaiter = continuation
            }
        }
    }

    nonisolated func cancel() {
        Task { await self.markCancelled() }
    }

    func maxCommandId() -> Int {
        sentIDs.max() ?? 0
    }

    func waitForCameraId() async -> Int {
        if let cameraId { return cameraId }
        return await withCheckedContinuation { continuation in
            if let cameraId {
                continuation.resume(returning: cameraId)
            } else {
                cameraWaiter = continuation
            }
        }
    }

    func push(_ json: String) {
        enqueue(Data(json.utf8))
    }

    private func enqueue(_ data: Data) {
        if let waiter = receiveWaiter {
            receiveWaiter = nil
            waiter.resume(returning: data)
        } else {
            pending.append(data)
        }
    }

    private func markCancelled() {
        isCancelled = true
        receiveWaiter?.resume(throwing: CancellationError())
        receiveWaiter = nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }
}
