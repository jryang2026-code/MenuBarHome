import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct TVBridgeFrame: Sendable, Equatable {
    public var id: String
    public var method: String?
    public var params: Data?
    public var result: Data?
    public var error: String?
    public init(id: String = UUID().uuidString, method: String? = nil, params: Data? = nil, result: Data? = nil, error: String? = nil) { self.id=id; self.method=method; self.params=params; self.result=result; self.error=error }
    fileprivate func encoded() throws -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let method { object["method"] = method }
        if let params { object["params"] = try JSONSerialization.jsonObject(with: params) }
        if let result { object["result"] = try JSONSerialization.jsonObject(with: result) }
        if let error { object["error"] = error }
        return try JSONSerialization.data(withJSONObject: object)
    }
    fileprivate static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1024 * 1024, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = o["id"] as? String else { throw TVBridgeError.invalidFrame }
        let jsonData: (Any?) throws -> Data? = { value in try value.map { try JSONSerialization.data(withJSONObject: $0) } }
        return Self(id: id, method: o["method"] as? String, params: try jsonData(o["params"]), result: try jsonData(o["result"]), error: o["error"] as? String)
    }
}

public enum TVBridgeError: Error, Equatable { case disabled, invalidFrame, frameTooLarge, handshakeFailed, manifestMismatch, binaryMismatch, unsupportedCommand, notRunning, transport(String) }
public protocol TVBridgeTransport: Sendable { func request(_ frame: TVBridgeFrame) async throws -> TVBridgeFrame; func close() async }

public actor MockTVBridgeTransport: TVBridgeTransport {
    public var requests: [TVBridgeFrame] = []
    private let responder: @Sendable (TVBridgeFrame) throws -> TVBridgeFrame
    public init(responder: @escaping @Sendable (TVBridgeFrame) throws -> TVBridgeFrame) { self.responder = responder }
    public func request(_ frame: TVBridgeFrame) async throws -> TVBridgeFrame { requests.append(frame); return try responder(frame) }
    public func close() async {}
}

public final class StdioTVBridgeTransport: TVBridgeTransport, @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let lock = NSLock()
    public init(process: Process, input: FileHandle, output: FileHandle) { self.process=process; self.input=input; self.output=output }
    public func request(_ frame: TVBridgeFrame) async throws -> TVBridgeFrame {
        let payload = try frame.encoded() + Data([0x0a]); guard payload.count <= 8 * 1024 * 1024 else { throw TVBridgeError.frameTooLarge }
        try input.write(contentsOf: payload)
        var bytes = Data(); while true { let chunk = try output.read(upToCount: 4096) ?? Data(); if chunk.isEmpty { throw TVBridgeError.notRunning }; bytes.append(chunk); if let nl = bytes.firstIndex(of: 0x0a) { let line = bytes[..<nl]; return try TVBridgeFrame.decode(Data(line)) }; if bytes.count > 8 * 1024 * 1024 { throw TVBridgeError.frameTooLarge } }
    }
    public func close() async { if process.isRunning { process.terminate() } }
}

public struct TVBridgeMediaPlaybackState: Codable, Equatable, Sendable { public var state: String; public var volumePercent: Int; public var isMuted: Bool; public var isScreenOff: Bool; public var currentSource: String?; public var availableSources: [String]; public init(state: String = "idle", volumePercent: Int = 0, isMuted: Bool = false, isScreenOff: Bool = false, currentSource: String? = nil, availableSources: [String] = []) { self.state=state; self.volumePercent=volumePercent; self.isMuted=isMuted; self.isScreenOff=isScreenOff; self.currentSource=currentSource; self.availableSources=availableSources } }
public struct TVBridgeDeviceDescriptor: Codable, Equatable, Sendable { public var nativeId: String; public var model: String; public var name: String; public var roomName: String; public var isOnline: Bool; public var playback: TVBridgeMediaPlaybackState; public var supportsRemotePad: Bool; public init(nativeId: String, model: String, name: String, roomName: String, isOnline: Bool, playback: TVBridgeMediaPlaybackState = .init(), supportsRemotePad: Bool = false) { self.nativeId=nativeId; self.model=model; self.name=name; self.roomName=roomName; self.isOnline=isOnline; self.playback=playback; self.supportsRemotePad=supportsRemotePad } }
public struct TVBridgePollingContext: Codable, Equatable, Sendable { public var panelVisible: Bool; public var systemActive: Bool; public var lowPower: Bool; public init(panelVisible: Bool, systemActive: Bool, lowPower: Bool) { self.panelVisible=panelVisible; self.systemActive=systemActive; self.lowPower=lowPower } }

public enum TVBridgeCommand: Equatable, Sendable { case power(Bool), wake, screenOff, setVolume(Double), setMute(Bool), selectSource(String), playPause, next, previous, seek(Double), remoteKey(String) }

public actor TVBridgePluginManager {
    private var config: TVBridgeConfig; private var transport: TVBridgeTransport?; private(set) public var isRunning = false; private var lastActive = Date.distantPast
    public init(config: TVBridgeConfig, transport: TVBridgeTransport? = nil) { self.config=config; self.transport=transport }
    public func updateConfig(_ config: TVBridgeConfig) async { self.config=config; if !config.isEnabled { await shutdown() } }
    public func startIfNeeded() async throws { guard config.isEnabled else { throw TVBridgeError.disabled }; guard transport != nil else { throw TVBridgeError.notRunning }; let p = try await call("initialize", ["protocolVersion":"1.0", "manifestDigest": config.expectedManifestDigest as Any]); if let expected=config.expectedManifestDigest, value(p, "manifestDigest") != expected { throw TVBridgeError.manifestMismatch }; lastActive=Date(); isRunning = true }
    public func snapshot() async throws -> [SmartDevice] { guard config.isEnabled else { throw TVBridgeError.disabled }; if transport == nil { try await startIfNeeded() }; let data=try await call("snapshot", [:]); let descriptors = try JSONDecoder().decode([TVBridgeDeviceDescriptor].self, from: data); lastActive=Date(); return descriptors.map(project) }
    public func healthPing() async throws { _ = try await call("health.ping", [:]) }
    public func execute(deviceId: String, command: TVBridgeCommand, capabilityGeneration: UInt64) async throws { guard config.isEnabled else { throw TVBridgeError.disabled }; if transport == nil { try await startIfNeeded() }; let verb = try map(command); _ = try await call("control.execute", ["deviceId":deviceId, "verb":verb, "grantId":UUID().uuidString, "capabilityGeneration":capabilityGeneration]); lastActive=Date() }
    public func updatePollingContext(_ context: TVBridgePollingContext) async { guard config.isEnabled, transport != nil else { return }; _ = try? await call("host.contextChanged", ["panelVisible":context.panelVisible,"systemActive":context.systemActive,"lowPower":context.lowPower]); if !context.panelVisible && !context.systemActive && Date().timeIntervalSince(lastActive) >= Double(config.idleShutdownSeconds) { await shutdown() } }
    public func shutdown() async { if let transport { await transport.close() }; transport=nil; isRunning = false }
    private func call(_ method: String, _ params: [String: Any]) async throws -> Data { guard let transport else { throw TVBridgeError.notRunning }; let data=try JSONSerialization.data(withJSONObject: params); let response=try await transport.request(TVBridgeFrame(method:method, params:data)); if let error=response.error { throw TVBridgeError.transport(error) }; return response.result ?? Data("{}".utf8) }
    private func value(_ data: Data, _ key: String) -> String? { (try? JSONSerialization.jsonObject(with:data) as? [String:Any])?[key] as? String }
    private func map(_ command: TVBridgeCommand) throws -> String { switch command { case .power: return "tv.power"; case .wake: return "tv.wake"; case .screenOff: return "tv.screenOff"; case .setVolume: return "media.setVolume"; case .setMute: return "media.setMute"; case .selectSource: return "media.selectSource"; case .playPause: return "media.playPause"; case .next: return "media.next"; case .previous: return "media.previous"; case .seek: return "media.seek"; case .remoteKey: return "remote.key" } }
    private func project(_ d: TVBridgeDeviceDescriptor) -> SmartDevice { let p=d.playback; let spec=TVSpec(mediaEntityId:d.nativeId,state:p.state,volumePercent:p.volumePercent,isMuted:p.isMuted,isScreenOff:p.isScreenOff,currentSource:p.currentSource,availableSources:p.availableSources,powerWritable:true,volumeWritable:true); return SmartDevice(id:"adapter:com.menubarhome.tv-bridge:\(d.nativeId)",name:d.name,roomId:d.roomName,roomName:d.roomName,model:d.model,isOnline:d.isOnline,kind:.tv(spec)) }
}
