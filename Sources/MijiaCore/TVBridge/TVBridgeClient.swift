#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct TVBridgeRPCError: Equatable, Sendable { public let code: Int; public let message: String; public init(code: Int, message: String) { self.code=code; self.message=message } }
public struct TVBridgeFrame: Sendable, Equatable {
    public var id: String; public var method: String?; public var params: Data?; public var result: Data?; public var error: TVBridgeRPCError?
    public init(id: String = UUID().uuidString, method: String? = nil, params: Data? = nil, result: Data? = nil, error: TVBridgeRPCError? = nil) { self.id=id; self.method=method; self.params=params; self.result=result; self.error=error }
    fileprivate func encoded() throws -> Data { var o:[String:Any] = ["jsonrpc":"2.0","id":id]; if let method{o["method"] = method}; if let params{o["params"] = try JSONSerialization.jsonObject(with:params)}; if let result{o["result"] = try JSONSerialization.jsonObject(with:result)}; if let error{o["error"] = ["code":error.code,"message":error.message]}; return try JSONSerialization.data(withJSONObject:o) }
    fileprivate static func decode(_ data: Data) throws -> Self { guard data.count <= 8*1024*1024, let o=try JSONSerialization.jsonObject(with:data) as? [String:Any], (o["jsonrpc"] as? String) == "2.0", let id=o["id"] as? String else { throw TVBridgeError.invalidFrame }; func d(_ x:Any?) throws -> Data? { try x.map { try JSONSerialization.data(withJSONObject:$0) } }; var e:TVBridgeRPCError?; if let x=o["error"] as? [String:Any], let c=x["code"] as? Int, let m=x["message"] as? String { e=TVBridgeRPCError(code:c,message:m) } else if let m=o["error"] as? String { e=TVBridgeRPCError(code:-32000,message:m) }; return Self(id:id,method:o["method"] as? String,params:try d(o["params"]),result:try d(o["result"]),error:e) }
}
public enum TVBridgeError: Error, Equatable { case disabled, invalidFrame, frameTooLarge, manifestMismatch, binaryMismatch, unsupportedCommand, notRunning, rpcError(code:Int,message:String), transport(String) }
public protocol TVBridgeTransport: Sendable { func request(_ frame: TVBridgeFrame) async throws -> TVBridgeFrame; func close() async }
public actor MockTVBridgeTransport: TVBridgeTransport { public var requests:[TVBridgeFrame]=[]; public private(set) var closeCount=0; private let responder:@Sendable (TVBridgeFrame)throws->TVBridgeFrame; public init(responder:@escaping @Sendable (TVBridgeFrame)throws->TVBridgeFrame){self.responder=responder}; public func request(_ f:TVBridgeFrame)throws->TVBridgeFrame{requests.append(f);return try responder(f)}; public func close()async{closeCount += 1} }

public final class StdioTVBridgeTransport: TVBridgeTransport, @unchecked Sendable {
    public static let defaultRequestTimeout: TimeInterval = 15.0
    private let process: Process; private let processBirth: SupervisedProcessIdentity.Birth?; private let input: FileHandle; private let output: FileHandle; private let requestTimeout: TimeInterval; private let ioQueue = DispatchQueue(label: "com.menubarhome.tv-bridge.stdio"); private let stderrRing = StderrRing(); private var buffer = Data()
    private struct LiveEntry { let process: Process; let birth: SupervisedProcessIdentity.Birth? }
    internal var childProcess: Process { process }
    public var recentStderr: String { stderrRing.snapshot() }
    private struct SendableHandle: @unchecked Sendable { let handle: FileHandle }
    public init(process: Process, input: FileHandle, output: FileHandle, errorOutput: FileHandle? = nil, requestTimeout: TimeInterval = StdioTVBridgeTransport.defaultRequestTimeout) {
        self.process = process; self.processBirth = process.isRunning ? SupervisedProcessIdentity.Birth.capture(pid: process.processIdentifier) : nil
        self.input = input; self.output = output; self.requestTimeout = max(0.05, requestTimeout)
        if let errHandle = errorOutput {
            let box = SendableHandle(handle: errHandle); let ring = self.stderrRing
            DispatchQueue.global(qos: .utility).async { while let c = try? box.handle.read(upToCount: 2048), !c.isEmpty { ring.append(c) } }
        }
    }
    public static func launch(binaryPath: String, dataDir: URL, manifestPath: URL, requestTimeout: TimeInterval = defaultRequestTimeout) throws -> Self {
        let p = Process(); let i = Pipe(); let o = Pipe(); let e = Pipe()
        p.executableURL = URL(fileURLWithPath: binaryPath); p.arguments = []; p.currentDirectoryURL = dataDir
        p.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": dataDir.path, "MBH_DATA_DIR": dataDir.path, "MBH_MANIFEST_PATH": manifestPath.path]
        p.standardInput = i; p.standardOutput = o; p.standardError = e; try p.run()
        let transport = Self(process: p, input: i.fileHandleForWriting, output: o.fileHandleForReading, errorOutput: e.fileHandleForReading, requestTimeout: requestTimeout)
        LiveProcesses.shared.insert(p, birth: transport.processBirth); return transport
    }
    public static func sanitizeStderr(_ raw: String) -> String {
        var text = String(raw.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" })
        for (p, r) in [(#"([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s@]+@"#, "$1[REDACTED]@"), (#"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+"#, "$1 [REDACTED]"), (#"(?i)(["']?(?:credential|client[-_]?key|password|passwd|token|psk|secret|authorization|cookie|pin)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,&;}\]]+)"#, "$1[REDACTED]")] {
            if let rx = try? NSRegularExpression(pattern: p) { text = rx.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: r) }
        }
        return text
    }
    private final class StderrRing: @unchecked Sendable {
        private let lock = NSLock(); private var lines: [String] = []; private var bytes = 0; private var pending = ""
        func append(_ data: Data) {
            let chunk = String(decoding: data, as: UTF8.self); guard !chunk.isEmpty else { return }
            lock.withLock {
                pending.append(chunk)
                while let nl = pending.firstIndex(of: "\n") { push(String(pending[..<nl])); pending.removeSubrange(...nl) }
                if pending.utf8.count > 512 { push(String(pending.prefix(512))); pending.removeAll(keepingCapacity: true) }
            }
        }
        func snapshot() -> String {
            lock.withLock { var out = lines; let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines); if !tail.isEmpty { out.append(StdioTVBridgeTransport.sanitizeStderr(tail)) }; return out.joined(separator: "\n") }
        }
        private func push(_ raw: String) {
            let clean = StdioTVBridgeTransport.sanitizeStderr(raw).trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }
            let clipped = clean.count > 384 ? String(clean.prefix(384)) + "…" : clean
            lines.append(clipped); bytes += clipped.utf8.count
            while (lines.count > 32 || bytes > 4096), !lines.isEmpty { bytes -= lines.removeFirst().utf8.count }
        }
    }
    private static func posixPoll(fd: Int32, events: Int16, timeoutMs: Int32) -> (Int32, Int16) {
        var pfd = pollfd(fd: fd, events: events, revents: 0)
        #if canImport(Darwin)
        return (Darwin.poll(&pfd, 1, timeoutMs), pfd.revents)
        #elseif canImport(Glibc)
        return (Glibc.poll(&pfd, 1, timeoutMs), pfd.revents)
        #else
        return (1, 0)
        #endif
    }
    private static func posixRead(fd: Int32, buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(fd, buffer, count)
        #elseif canImport(Glibc)
        return Glibc.read(fd, buffer, count)
        #else
        return 0
        #endif
    }
    public func request(_ frame: TVBridgeFrame) async throws -> TVBridgeFrame {
        try await withCheckedThrowingContinuation { cont in ioQueue.async { do { cont.resume(returning: try self.readFrame(frame)) } catch { cont.resume(throwing: error) } } }
    }
    private func readFrame(_ frame: TVBridgeFrame) throws -> TVBridgeFrame {
        let deadline = Date().addingTimeInterval(requestTimeout); let payload = try frame.encoded() + Data([10]); guard payload.count <= 8 * 1024 * 1024 else { throw TVBridgeError.frameTooLarge }
        let (wrc, wrev) = Self.posixPoll(fd: input.fileDescriptor, events: Int16(POLLOUT), timeoutMs: Int32(max(1, min(Int(Int32.max), Int((deadline.timeIntervalSinceNow * 1000).rounded(.down))))))
        if wrc == 0 { throw TVBridgeError.transport("RPC write timed out") }; if wrc < 0 || (wrev & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 { throw TVBridgeError.notRunning }
        try input.write(contentsOf: payload); let outFD = output.fileDescriptor; var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            if let nl = buffer.firstIndex(of: 10) { let line = Data(buffer[..<nl]); buffer.removeSubrange(...nl); let decoded = try TVBridgeFrame.decode(line); guard decoded.id == frame.id else { throw TVBridgeError.invalidFrame }; return decoded }
            let remMs = Int((deadline.timeIntervalSinceNow * 1000).rounded(.down))
            let (rc, _) = remMs > 0 ? Self.posixPoll(fd: outFD, events: Int16(POLLIN), timeoutMs: Int32(min(remMs, Int(Int32.max)))) : (0, 0)
            if rc == 0 { let detail = recentStderr; throw TVBridgeError.transport(detail.isEmpty ? "RPC request timed out" : "RPC request timed out: \(detail)") }
            if rc < 0 { if errno == EINTR { continue }; throw TVBridgeError.notRunning }
            let n = tmp.withUnsafeMutableBytes { Self.posixRead(fd: outFD, buffer: $0.baseAddress!, count: $0.count) }
            if n < 0 { if errno == EINTR { continue }; throw TVBridgeError.notRunning }; guard n > 0 else { throw TVBridgeError.notRunning }
            buffer.append(tmp, count: n); guard buffer.count <= 8 * 1024 * 1024 else { throw TVBridgeError.frameTooLarge }
        }
    }
    public func close() async { await terminateProcessAsync() }
    private static func isStillOwned(_ process: Process, birth: SupervisedProcessIdentity.Birth?) -> Bool {
        guard process.isRunning, process.processIdentifier > 1 else { return false }
        #if canImport(Darwin)
        if let birth { return SupervisedProcessIdentity.Birth.capture(pid: process.processIdentifier) == birth }
        #endif
        return true
    }
    private static func reapAsync(_ process: Process) async {
        guard process.processIdentifier > 0 else { return }
        if !process.isRunning {
            process.waitUntilExit()
            return
        }
        await Task.detached(priority: .userInitiated) {
            process.waitUntilExit()
        }.value
    }
    private func terminateProcessAsync(gracePeriod: TimeInterval = 0.2) async {
        defer { LiveProcesses.shared.remove(process) }
        guard Self.isStillOwned(process, birth: processBirth) else {
            if process.processIdentifier > 0 && !process.isRunning { process.waitUntilExit() }
            return
        }
        process.terminate()
        let steps = max(1, Int((max(gracePeriod, 0) / 0.02).rounded(.up)))
        for _ in 0..<steps {
            guard Self.isStillOwned(process, birth: processBirth) else {
                await Self.reapAsync(process)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard Self.isStillOwned(process, birth: processBirth) else {
            await Self.reapAsync(process)
            return
        }
        _ = kill(process.processIdentifier, SIGKILL)
        await Self.reapAsync(process)
    }
    private static func terminateEntries(_ entries: [LiveEntry], gracePeriod: TimeInterval) {
        let active = entries.filter { isStillOwned($0.process, birth: $0.birth) }
        guard !active.isEmpty else { return }
        for entry in active { entry.process.terminate() }
        let deadline = Date().addingTimeInterval(max(gracePeriod, 0))
        while Date() < deadline {
            if active.allSatisfy({ !isStillOwned($0.process, birth: $0.birth) }) {
                for entry in active { entry.process.waitUntilExit() }
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let killed = active.filter { isStillOwned($0.process, birth: $0.birth) }
        for entry in killed { _ = kill(entry.process.processIdentifier, SIGKILL) }
        for entry in active { entry.process.waitUntilExit() }
    }
    /// Kills the child without taking the request `lock`: `SIGTERM` → short wait → `SIGKILL` (matching `SupervisedProcess`).
    public func terminateProcessImmediately(gracePeriod: TimeInterval = 0.2) {
        defer { LiveProcesses.shared.remove(process) }
        Self.terminateEntries([LiveEntry(process: process, birth: processBirth)], gracePeriod: gracePeriod)
    }
    /// App quit: sends `SIGTERM`, waits briefly, then escalates stubborn bridge children to `SIGKILL`.
    public static func terminateAllImmediately(gracePeriod: TimeInterval = 0.2) { terminateEntries(LiveProcesses.shared.drain(), gracePeriod: gracePeriod) }
    private final class LiveProcesses: @unchecked Sendable {
        static let shared = LiveProcesses()
        private let lock = NSLock(); private var processes: [ObjectIdentifier: LiveEntry] = [:]
        func insert(_ p: Process, birth: SupervisedProcessIdentity.Birth?) { lock.withLock { processes[ObjectIdentifier(p)] = LiveEntry(process: p, birth: birth) } }
        func remove(_ p: Process) { lock.withLock { _ = processes.removeValue(forKey: ObjectIdentifier(p)) } }
        func drain() -> [LiveEntry] { lock.withLock { let all = Array(processes.values); processes.removeAll(); return all } }
    }
}

public struct TVBridgeNowPlayingPayload: Codable, Sendable {
 public var state: MediaPlaybackState.Status?; public var title: String?; public var subtitle: String?; public var appName: String?; public var artworkURL: String?; public var artworkUri: String?; public var artworkURI: String?; public var durationSec: Double?; public var positionSec: Double?; public var positionUpdatedAt: String?; public var playbackRate: Double?; public var canPlayPause: Bool?; public var canSeek: Bool?; public var canSkipTrack: Bool?
 func playback() -> MediaPlaybackState? { guard let state else { return nil }; let date = positionUpdatedAt.flatMap { value in let f=ISO8601DateFormatter(); f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]; return f.date(from:value) ?? { f.formatOptions=[.withInternetDateTime]; return f.date(from:value) }() }; return MediaPlaybackState(state: state, title: title, subtitle: subtitle, appName: appName, artworkURL: artworkURL ?? artworkUri ?? artworkURI, durationSec: durationSec, positionSec: positionSec, positionUpdatedAt: date, playbackRate: playbackRate, canPlayPause: canPlayPause ?? false, canSeek: canSeek ?? false, canSkipTrack: canSkipTrack ?? false) }
}
public struct TVBridgeDeviceDescriptor: Codable, Equatable, Sendable {
 public var nativeId:String; public var name:String; public var kind:String; public var online:Bool; public var state:String; public var volume:Int; public var muted:Bool; public var source:String?; public var availableSources:[String]; public var supportsRemotePad:Bool; public var nowPlaying:MediaPlaybackState?; public var roomName:String?
 /// Normalized (12 lowercase hex) MACs from `identity.macAddresses` or `macAddress`; the host dedupes on them.
 public var macAddresses:[String]
 public init(nativeId:String,name:String,kind:String="tv",online:Bool,state:String,volume:Int,muted:Bool,source:String?=nil,availableSources:[String]=[],supportsRemotePad:Bool=false,nowPlaying:MediaPlaybackState?=nil,roomName:String?=nil,macAddresses:[String]=[]){self.macAddresses=macAddresses.compactMap(DeviceIdentityNormalizer.macAddress(from:));self.nativeId=nativeId;self.name=name;self.kind=kind;self.online=online;self.state=state;self.volume=volume;self.muted=muted;self.source=source;self.availableSources=availableSources;self.supportsRemotePad=supportsRemotePad;self.nowPlaying=nowPlaying;self.roomName=roomName}
 enum CodingKeys:String,CodingKey{case nativeId,name,kind,online,state,volume,muted,source,availableSources,supportsRemotePad,nowPlaying,roomName,identity,macAddress}
 struct Identity:Codable{var macAddresses:[String]?}
 public init(from decoder: Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self); nativeId=try c.decode(String.self,forKey:.nativeId); name=try c.decode(String.self,forKey:.name); online=try c.decodeIfPresent(Bool.self,forKey:.online) ?? false; kind=try c.decodeIfPresent(String.self,forKey:.kind) ?? "tv"; state=try c.decodeIfPresent(String.self,forKey:.state) ?? (online ? "on" : "off"); volume=try c.decodeIfPresent(Int.self,forKey:.volume) ?? 0; muted=try c.decodeIfPresent(Bool.self,forKey:.muted) ?? false; source=try c.decodeIfPresent(String.self,forKey:.source); availableSources=try c.decodeIfPresent([String].self,forKey:.availableSources) ?? []; supportsRemotePad=try c.decodeIfPresent(Bool.self,forKey:.supportsRemotePad) ?? true; roomName=try c.decodeIfPresent(String.self,forKey:.roomName); nowPlaying=try c.decodeIfPresent(TVBridgeNowPlayingPayload.self,forKey:.nowPlaying)?.playback(); var raw:[String]=try c.decodeIfPresent(Identity.self,forKey:.identity)?.macAddresses ?? []; if let single=try c.decodeIfPresent(String.self,forKey:.macAddress){raw.append(single)}; let normalized:[String]=raw.compactMap { DeviceIdentityNormalizer.macAddress(from:$0) }; macAddresses=Array(Set(normalized)).sorted() }
 public func encode(to encoder: Encoder) throws { var c=encoder.container(keyedBy:CodingKeys.self); try c.encode(nativeId,forKey:.nativeId); try c.encode(name,forKey:.name); try c.encode(kind,forKey:.kind); try c.encode(online,forKey:.online); try c.encode(state,forKey:.state); try c.encode(volume,forKey:.volume); try c.encode(muted,forKey:.muted); try c.encodeIfPresent(source,forKey:.source); try c.encode(availableSources,forKey:.availableSources); try c.encode(supportsRemotePad,forKey:.supportsRemotePad); try c.encodeIfPresent(roomName,forKey:.roomName); try c.encodeIfPresent(nowPlaying,forKey:.nowPlaying); if !macAddresses.isEmpty { try c.encode(Identity(macAddresses:macAddresses),forKey:.identity) } }
}
public struct TVBridgeSnapshot: Codable, Sendable { public var capturedAt:String?; public var devices:[TVBridgeDeviceDescriptor] }
public struct TVBridgePollingContext: Codable, Equatable, Sendable { public var panelVisible:Bool; public var systemActive:Bool; public var lowPower:Bool; public init(panelVisible:Bool,systemActive:Bool,lowPower:Bool){self.panelVisible=panelVisible;self.systemActive=systemActive;self.lowPower=lowPower} }
public enum TVBridgeCommand: Equatable, Sendable { case power(Bool),wake,screenOff,setVolume(Double),setMute(Bool),selectSource(String),playPause,next,previous,seek(Double),remoteKey(String) }

public actor TVBridgePluginManager {
 private var config:TVBridgeConfig; private var transport:TVBridgeTransport?; private let transportFactory: (@Sendable (TVBridgeConfig) throws -> TVBridgeTransport)?; private let credentialResolver: (@Sendable (String) -> String?)?; private(set) public var isRunning=false; private var lastActive=Date.distantPast
 /// Row id → normalized MACs from the last snapshot plus the configured `macAddress`.
 public private(set) var hardwareIdentifiers:[String:[String]]=[:]
 public init(config:TVBridgeConfig,transport:TVBridgeTransport?=nil,transportFactory: (@Sendable (TVBridgeConfig) throws -> TVBridgeTransport)?=nil,credentialResolver: (@Sendable (String) -> String?)?=nil){self.config=config;self.transport=transport;self.transportFactory=transportFactory;self.credentialResolver=credentialResolver}
 public func updateConfig(_ c:TVBridgeConfig)async{config=c;if !c.isEnabled{await shutdown()}}
 public func startIfNeeded(capabilityGeneration: UInt64 = 1) async throws { guard config.isEnabled else { throw TVBridgeError.disabled }; if isRunning { return }; do { if let p=config.binaryPath,let e=config.expectedBinarySHA256 { try verifyBinary(at:URL(fileURLWithPath:p),expected:e) }; if transport == nil { if let factory=transportFactory { transport=try factory(config) } else if let path=config.binaryPath { let dir=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("MenuBarMijia/TVBridge",isDirectory:true); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); let manifest=URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("adapter-manifest.json"); transport=try StdioTVBridgeTransport.launch(binaryPath:path,dataDir:dir,manifestPath:manifest) } }; guard transport != nil else { throw TVBridgeError.notRunning }; let devices=config.devices.map { d -> [String:Any] in var x:[String:Any] = ["nativeId":d.nativeId,"driver":d.driver.rawValue,"host":d.host,"name":d.name,"roomName":d.roomName]; if let p=d.port{x["port"]=p}; if let m=d.macAddress{x["mac"]=m}; if let slot=d.credentialSlot,let c=credentialResolver?(slot){x["credential"]=c}; return x }; let gen=max(UInt64(1),capabilityGeneration); let result=try await call("initialize",["supportedProtocolVersions":["1.0"],"capabilityGeneration":gen,"config":["devices":devices]]); if let e=config.expectedManifestDigest,value(result,"manifestDigest") != e { throw TVBridgeError.manifestMismatch }; isRunning=true; lastActive=Date() } catch { await transport?.close(); transport=nil; isRunning=false; throw error } }
 public func snapshot(capabilityGeneration: UInt64 = 1)async throws->[SmartDevice]{guard config.isEnabled else{throw TVBridgeError.disabled};if !isRunning { try await startIfNeeded(capabilityGeneration: capabilityGeneration) };let d=try JSONDecoder().decode(TVBridgeSnapshot.self,from:try await call("snapshot",[:]));lastActive=Date();var ids:[String:[String]]=[:];for x in d.devices{let configured=config.devices.first{$0.nativeId == x.nativeId}?.macAddress.flatMap(DeviceIdentityNormalizer.macAddress(from:));let all=Array(Set(x.macAddresses+(configured.map{[$0]} ?? []))).sorted();if !all.isEmpty{ids["adapter:com.menubarhome.tv-bridge:\(x.nativeId)"]=all}};hardwareIdentifiers=ids;return d.devices.map(project)}
 public func healthPing()async throws{_ = try await call("health.ping",[:])}
 public func execute(deviceId:String,command:TVBridgeCommand,capabilityGeneration:UInt64)async throws{guard config.isEnabled else{throw TVBridgeError.disabled};let gen=max(UInt64(1),capabilityGeneration);if !isRunning { try await startIfNeeded(capabilityGeneration: gen) };let (v,a)=map(command);let n=deviceId.hasPrefix("adapter:com.menubarhome.tv-bridge:") ? String(deviceId.dropFirst("adapter:com.menubarhome.tv-bridge:".count)):deviceId;_ = try await call("control.execute",["nativeId":n,"verb":v,"args":a,"grantId":UUID().uuidString,"capabilityGeneration":gen]);lastActive=Date()}
 public func updatePollingContext(_ c:TVBridgePollingContext,capabilityGeneration:UInt64?=nil)async{guard config.isEnabled,transport != nil else{return};var p:[String:Any] = ["panelVisible":c.panelVisible,"systemActive":c.systemActive,"lowPower":c.lowPower];if let g=capabilityGeneration{p["capabilityGeneration"]=g};_ = try? await call("host.contextChanged",p);if !c.panelVisible && !c.systemActive && Date().timeIntervalSince(lastActive)>=Double(config.idleShutdownSeconds){await shutdown()}}
 public func shutdown()async{if transport != nil{_ = try? await call("shutdown",[:]);await transport?.close()};transport=nil;isRunning=false}
 private func call(_ m:String,_ p:[String:Any])async throws->Data { guard let t=transport else { throw TVBridgeError.notRunning }; let request=TVBridgeFrame(method:m,params:try JSONSerialization.data(withJSONObject:p)); do { let r=try await t.request(request); guard r.id == request.id else { await transport?.close(); transport=nil; isRunning=false; throw TVBridgeError.invalidFrame }; if let e=r.error { throw TVBridgeError.rpcError(code:e.code,message:e.message) }; return r.result ?? Data("{}".utf8) } catch let e as TVBridgeError { if case .rpcError = e { throw e }; await transport?.close(); transport=nil; isRunning=false; throw e } catch { await transport?.close(); transport=nil; isRunning=false; throw error } }
 private func value(_ d:Data,_ k:String)->String?{(try? JSONSerialization.jsonObject(with:d) as? [String:Any])?[k] as? String}
 private func verifyBinary(at u: URL, expected: String) throws {
#if canImport(CryptoKit)
  let d = SHA256.hash(data: try Data(contentsOf: u)).map { String(format: "%02x", $0) }.joined()
  guard d.caseInsensitiveCompare(expected) == .orderedSame else { throw TVBridgeError.binaryMismatch }
#else
  throw TVBridgeError.binaryMismatch
#endif
 }
 private func map(_ c:TVBridgeCommand)->(String,[String:Any]){switch c{case .power(let x):return("power.set",["isOn":x]);case .wake:return("power.wake",[:]);case .screenOff:return("power.screenOff",[:]);case .setVolume(let x):return("volume.set",["level":Int((x*100).rounded())]);case .setMute(let x):return("mute.set",["isMuted":x]);case .selectSource(let x):return("input.select",["source":x]);case .playPause:return("media.playPause",[:]);case .next:return("media.next",[:]);case .previous:return("media.previous",[:]);case .seek(let x):return("media.seek",["positionSec":x]);case .remoteKey(let x):return("remote.key",["key":x])}}
 private func project(_ d:TVBridgeDeviceDescriptor)->SmartDevice{let x=TVSpec(mediaEntityId:d.nativeId,state:d.state,volumePercent:d.volume,isMuted:d.muted,isScreenOff:d.state == "off",currentSource:d.source,availableSources:d.availableSources,powerWritable:true,volumeWritable:true,playback:d.nowPlaying,supportsRemotePad:d.supportsRemotePad);return SmartDevice(id:"adapter:com.menubarhome.tv-bridge:\(d.nativeId)",name:d.name,roomId:d.roomName ?? "tv-bridge",roomName:d.roomName ?? config.devices.first(where:{$0.nativeId == d.nativeId})?.roomName ?? "",model:d.kind,isOnline:d.online,kind:.tv(x))}
}

#if DEBUG
extension TVBridgeFrame { static func decodeForTesting(_ data: Data) throws -> TVBridgeFrame { try decode(data) } }
#endif
