import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A TV or smart display discovered on the local private LAN (mDNS/DNS-SD, SSDP/DIAL, or Xiaomi HTTP 6095).
public struct TVBridgeDiscoveredDevice: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int?
    public var brand: String
    public var model: String?
    public var suggestedDriver: TVBridgeDeviceConfig.Driver?
    public var macAddress: String?
    public var sources: [String]

    public init(
        name: String, host: String, port: Int? = nil, brand: String, model: String? = nil,
        suggestedDriver: TVBridgeDeviceConfig.Driver? = nil, macAddress: String? = nil, sources: [String] = []
    ) {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = cleanHost
        self.name = cleanName.isEmpty ? cleanHost : cleanName
        self.host = cleanHost
        self.port = port
        self.brand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = cleanModel?.isEmpty == false ? cleanModel : nil
        self.suggestedDriver = suggestedDriver
        self.macAddress = macAddress.flatMap(DeviceIdentityNormalizer.macAddress(from:))
        self.sources = Array(Set(sources.filter { !$0.isEmpty })).sorted()
    }
}

/// Parsed SSDP M-SEARCH response metadata restricted to private-LAN targets.
public struct TVBridgeSSDPResponse: Equatable, Sendable {
    public var location: URL?
    public var host: String
    public var server: String?
    public var st: String?
    public var usn: String?
}

/// Read-only LAN TV discovery over mDNS/DNS-SD, SSDP/DIAL, and Xiaomi/Redmi HTTP 6095 probe.
/// All discovered endpoints are validated as private-LAN-only; no credentials are read or sent.
public enum TVBridgeDiscovery {
    public static let mdnsServiceTypes = [
        "_androidtvremote2._tcp", "_googlecast._tcp", "_airplay._tcp", "_mitv._tcp", "_xbmc-jsonrpc-h._tcp",
    ]
    public static let ssdpSearchTargets = [
        "urn:dial-multiscreen-org:service:dial:1",
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "urn:lge-com:service:webos-second-screen:1",
    ]

    private static let maxXMLBytes = 64 * 1024
    private static let max6095Hosts = 32
    private static let maxSSDPPackets = 64

    // MARK: - Private-LAN Validation

    /// Accepts only private RFC1918 IPv4 addresses or valid `.local` hostnames (no loopback/public/IMDS).
    public static func validatedLANHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return HADiscovery.isAllowedLANDiscoveryHost(host) ? host : nil
    }

    /// Accepts private LAN endpoints allowed for manual TV bridge configuration (`LocalNetworkEndpoint`, no loopback/public).
    public static func validatedConfiguredHost(_ raw: String) -> String? {
        if let lan = validatedLANHost(raw) { return lan }
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host != "localhost",
              !host.contains("@"), !host.contains("/"), !host.contains("\\"),
              !host.contains(":"), !host.contains("["), !host.contains("]"),
              !host.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        if let cls = EndpointAddressClass(numericAddress: host) { return cls == .lan ? host : nil }
        guard let suffix = [".lan", ".home.arpa", ".internal"].first(where: { host.hasSuffix($0) }) else { return nil }
        let stem = host.dropLast(suffix.count)
        guard !stem.isEmpty, stem != "localhost" else { return nil }
        let labels = stem.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            guard !label.isEmpty, label.count <= 63, let f = label.first, let l = label.last,
                  f.isASCII && (f.isLetter || f.isNumber), l.isASCII && (l.isLetter || l.isNumber) else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { return nil }
        return host
    }

    /// Validates an SSDP `LOCATION` URL: `http://` only, no userinfo, private-LAN host, valid port.
    public static func validatedSSDPLocationURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              let comp = URLComponents(string: trimmed), comp.scheme?.lowercased() == "http",
              comp.user == nil, comp.password == nil, let host = comp.host, validatedLANHost(host) != nil,
              comp.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
        return comp.url
    }

    // MARK: - Brand & Driver Classification

    public struct Classification: Equatable, Sendable {
        public var brand: String
        public var model: String?
        public var driver: TVBridgeDeviceConfig.Driver?
        public var defaultPort: Int?
    }

    /// Filters out Macs, iPhones, iPads and HomePods advertising `_airplay._tcp`.
    public static func isLikelyNonTVAirPlay(name: String, model: String?, txt: [String: String]) -> Bool {
        let m = (model ?? txt["model"] ?? "").lowercased()
        if m.hasPrefix("appletv") { return false }
        if ["mac", "imac", "iphone", "ipad", "ipod", "audioaccessory", "homepod", "watch"].contains(where: { m.hasPrefix($0) }) { return true }
        let lowerName = name.lowercased()
        return m.isEmpty && ["macbook", "imac", "homepod", "iphone", "ipad"].contains(where: { lowerName.contains($0) })
    }

    public static func classify(
        name: String, manufacturer: String? = nil, model: String? = nil,
        server: String? = nil, serviceType: String? = nil, txt: [String: String] = [:]
    ) -> Classification {
        let resolvedModel = [model, txt["md"], txt["model"], txt["am"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let svc = (serviceType ?? "").lowercased()
        let haystack = [name, manufacturer ?? "", resolvedModel ?? "", server ?? "", svc,
                        txt["manufacturer"] ?? "", txt["mf"] ?? "", txt["fn"] ?? ""].joined(separator: " ").lowercased()
        let has: ([String]) -> Bool = { tokens in tokens.contains { haystack.contains($0) } }

        if svc.contains("_mitv") || svc.contains("_mi-connect")
            || has(["xiaomi", "redmi", "mitv", "mibox", "patchwall", "rmmnt", "g pro 27u", "小米电视", "红米电视", "红米显示器", "小米显示器"]) {
            return Classification(brand: "Xiaomi / Redmi", model: resolvedModel, driver: .xiaomi_mitv_6095, defaultPort: 6095)
        }
        if has(["webos", "lg electronics", "lge ", "lge-", "lg smart tv", "lg tv", "webos-second-screen"]) {
            return Classification(brand: "LG", model: resolvedModel, driver: .lg_webos_ssap, defaultPort: 3001)
        }
        if has(["hisense", "vidaa", "海信"]) {
            return Classification(brand: "Hisense", model: resolvedModel, driver: .hisense_vidaa_mqtt, defaultPort: 36669)
        }
        if has(["sony", "bravia", "索尼"]) {
            return Classification(brand: "Sony", model: resolvedModel, driver: .sony_bravia_psk, defaultPort: 80)
        }
        if has(["samsung", "tizen", "三星"]) {
            return Classification(brand: "Samsung", model: resolvedModel, driver: .samsung_tizen_ws, defaultPort: 8002)
        }
        if has(["tcl", "ffalcon", "tnscreen", "雷鸟"]) {
            return Classification(brand: "TCL / FFALCON", model: resolvedModel, driver: .tcl_ffalcon_tnscreen, defaultPort: 6553)
        }
        if svc.contains("_xbmc") || has(["kodi", "xbmc"]) {
            return Classification(brand: "Kodi", model: resolvedModel, driver: .kodi_jsonrpc, defaultPort: 8080)
        }
        if has(["mediarenderer", "avtransport", "dlna"]) {
            return Classification(brand: "DLNA", model: resolvedModel, driver: .dlna_dmr, defaultPort: 1900)
        }
        if svc.contains("_androidtvremote2") || has(["android tv", "google tv"]) {
            return Classification(brand: "Android TV", model: resolvedModel, driver: .android_adb_lan, defaultPort: 5555)
        }
        if svc.contains("_googlecast") || has(["chromecast"]) {
            return Classification(brand: "Google Cast", model: resolvedModel, driver: .android_adb_lan, defaultPort: 5555)
        }
        if svc.contains("_airplay") || has(["appletv", "apple tv"]) {
            return Classification(brand: "AirPlay", model: resolvedModel, driver: nil, defaultPort: nil)
        }
        return Classification(brand: "Smart TV", model: resolvedModel, driver: nil, defaultPort: nil)
    }

    // MARK: - Parsers

    /// Parses `dns-sd -Z <serviceType> local.` zone output into private-LAN TV candidates.
    public static func parseMDNSZoneOutput(
        _ output: String, serviceType: String, hostResolver: (String) -> String? = HADiscovery.resolveHostIPv4
    ) -> [TVBridgeDiscoveredDevice] {
        struct Partial { var instanceName: String; var srvPort: Int?; var srvTarget: String?; var txt: [String: String] = [:]; var hasRecord = false }
        let cleanSvc = serviceType.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let marker = ".\(cleanSvc)"
        var order: [String] = []
        var records: [String: Partial] = [:]

        for rawLine in output.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix(";") { continue }
            guard let range = rawLine.range(of: marker) else { continue }
            let prefixRaw = String(rawLine[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if prefixRaw.isEmpty || prefixRaw.hasPrefix(cleanSvc) { continue }
            let after = String(rawLine[range.upperBound...])
            let instanceName = HADiscovery.unescapeDNSSD(prefixRaw)
            if records[instanceName] == nil { order.append(instanceName); records[instanceName] = Partial(instanceName: instanceName) }
            let uncommented = (!after.contains("\"") ? after.split(separator: ";", maxSplits: 1).first.map(String.init) : nil) ?? after
            let tokens = uncommented.split(whereSeparator: \.isWhitespace).map(String.init)
            if let srvIdx = tokens.firstIndex(of: "SRV"), srvIdx + 4 < tokens.count {
                records[instanceName]?.srvPort = Int(tokens[srvIdx + 3])
                records[instanceName]?.srvTarget = tokens[srvIdx + 4]
                records[instanceName]?.hasRecord = true
            } else if let txtRange = after.range(of: "TXT") {
                for (k, v) in HADiscovery.parseTXTRecordTokens(String(after[txtRange.upperBound...])) { records[instanceName]?.txt[k.lowercased()] = v }
                records[instanceName]?.hasRecord = true
            }
        }

        var found: [TVBridgeDiscoveredDevice] = []
        for key in order {
            guard let rec = records[key], rec.hasRecord else { continue }
            let friendly = sanitizeDisplayText(rec.txt["fn"] ?? rec.instanceName)
            if cleanSvc.lowercased().contains("_airplay"), isLikelyNonTVAirPlay(name: friendly, model: rec.txt["model"], txt: rec.txt) { continue }
            guard let rawTarget = rec.srvTarget, let validTarget = validatedLANHost(rawTarget) else { continue }
            let host: String = if HADiscovery.isPrivateLANIPv4(validTarget) {
                validTarget
            } else if let resolved = hostResolver(validTarget).flatMap(validatedLANHost), HADiscovery.isPrivateLANIPv4(resolved) {
                resolved
            } else { validTarget }
            let cls = classify(name: friendly, manufacturer: rec.txt["manufacturer"] ?? rec.txt["mf"],
                               model: rec.txt["md"] ?? rec.txt["model"], serviceType: cleanSvc, txt: rec.txt)
            let mac = [rec.txt["mac"], rec.txt["bt"], rec.txt["deviceid"]]
                .compactMap { $0.flatMap(DeviceIdentityNormalizer.macAddress(from:)) }.first
            found.append(TVBridgeDiscoveredDevice(
                name: friendly, host: host, port: cls.defaultPort ?? rec.srvPort, brand: cls.brand,
                model: cls.model, suggestedDriver: cls.driver, macAddress: mac, sources: ["mDNS (\(cleanSvc))"]
            ))
        }
        return mergeDiscovered(found)
    }

    /// Parses an SSDP HTTP response packet, rejecting non-LAN or spoofed `LOCATION` headers.
    public static func parseSSDPResponse(_ raw: String, senderHost: String? = nil) -> TVBridgeSSDPResponse? {
        let lines = raw.components(separatedBy: .newlines)
        guard let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              firstLine.uppercased().hasPrefix("HTTP/1.") && firstLine.contains("200") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !val.isEmpty { headers[key] = val }
        }
        var location: URL?
        if let rawLoc = headers["location"] {
            guard let safeURL = validatedSSDPLocationURL(rawLoc) else { return nil }
            location = safeURL
        }
        guard let host = (location?.host.flatMap(validatedLANHost)) ?? senderHost.flatMap(validatedLANHost) else { return nil }
        return TVBridgeSSDPResponse(location: location, host: host, server: headers["server"], st: headers["st"], usn: headers["usn"])
    }

    /// Parses a UPnP/DIAL XML device description into a discovered TV candidate.
    public static func parseUPnPDeviceDescription(
        _ xml: String, host: String, ssdpServer: String? = nil, ssdpST: String? = nil
    ) -> TVBridgeDiscoveredDevice? {
        guard let safeHost = validatedLANHost(host) else { return nil }
        let friendly = sanitizeDisplayText(xmlTagValue("friendlyName", in: xml) ?? "")
        let manufacturer = sanitizeDisplayText(xmlTagValue("manufacturer", in: xml) ?? "")
        let model = sanitizeDisplayText(xmlTagValue("modelName", in: xml) ?? xmlTagValue("modelDescription", in: xml) ?? "")
        let name = friendly.isEmpty ? (model.isEmpty ? safeHost : model) : friendly
        let cls = classify(name: name, manufacturer: manufacturer, model: model, server: ssdpServer, serviceType: ssdpST)
        return TVBridgeDiscoveredDevice(
            name: name, host: safeHost, port: cls.defaultPort, brand: cls.brand,
            model: cls.model, suggestedDriver: cls.driver, sources: ["SSDP"]
        )
    }

    /// Parses Xiaomi/Redmi TV HTTP 6095 `/request?action=isalive` JSON response.
    public static func parseXiaomi6095Alive(_ data: Data, host: String) -> TVBridgeDiscoveredDevice? {
        guard let safeHost = validatedLANHost(host), !data.isEmpty, data.count <= maxXMLBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let status = root["status"] as? Int, status != 0 { return nil }
        let payload = (root["data"] as? [String: Any]) ?? root
        let rawName = (payload["devicename"] as? String) ?? (payload["deviceName"] as? String) ?? ""
        let rawMac = (payload["wifimac"] as? String) ?? (payload["ethmac"] as? String) ?? (payload["mac"] as? String)
        let rawModel = (payload["model"] as? String) ?? (payload["platform"] as? String)
        let hasSignature = ((root["status"] as? Int) == 0 && (root["data"] is [String: Any]))
            || !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rawMac != nil
        guard hasSignature else { return nil }
        let name = sanitizeDisplayText(rawName)
        let model = rawModel.map(sanitizeDisplayText).flatMap { $0.isEmpty ? nil : $0 }
        return TVBridgeDiscoveredDevice(
            name: name.isEmpty ? "Xiaomi / Redmi TV" : name, host: safeHost, port: 6095,
            brand: "Xiaomi / Redmi", model: model, suggestedDriver: .xiaomi_mitv_6095,
            macAddress: rawMac, sources: ["HTTP 6095"]
        )
    }

    /// Deduplicates candidates by host, preferring verified 6095/primary drivers and merging MAC/model/sources.
    public static func mergeDiscovered(_ items: [TVBridgeDiscoveredDevice]) -> [TVBridgeDiscoveredDevice] {
        var byHost: [String: TVBridgeDiscoveredDevice] = [:]
        for item in items {
            guard validatedLANHost(item.host) != nil else { continue }
            guard let existing = byHost[item.host] else { byHost[item.host] = item; continue }
            let incomingWins = rank(item) > rank(existing)
            var winner = incomingWins ? item : existing
            let loser = incomingWins ? existing : item
            if winner.name == winner.host && loser.name != loser.host { winner.name = loser.name }
            if winner.model == nil { winner.model = loser.model }
            if winner.macAddress == nil { winner.macAddress = loser.macAddress }
            winner.sources = Array(Set(winner.sources + loser.sources)).sorted()
            byHost[item.host] = winner
        }
        return byHost.values.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra > rb }
            if a.name != b.name { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
            return a.host < b.host
        }
    }

    private static func rank(_ d: TVBridgeDiscoveredDevice) -> Int {
        var score = (d.sources.contains("HTTP 6095") ? 40 : 0) + (d.sources.contains("SSDP") ? 10 : 0)
        if let driver = d.suggestedDriver {
            score += driver.isPrimary ? 30 : (driver == .dlna_dmr || driver == .android_adb_lan ? 5 : 20)
        }
        return score + (d.macAddress != nil ? 2 : 0) + (d.model != nil ? 1 : 0)
    }

    // MARK: - Live LAN Discovery

    public static func discoverOnLAN(arpHostsProvider: (@Sendable () -> [String])? = nil) async -> [TVBridgeDiscoveredDevice] {
        // Avoid `async let` around `Task.detached` (swiftlang/swift#87571).
        let mdnsTask = Task { await Self.queryMDNSAll() }
        let ssdpTask = Task.detached(priority: .userInitiated) { Self.querySSDPResponses() }
        let arpTask = Task.detached(priority: .utility) { arpHostsProvider?() ?? HADiscovery.queryARPHosts() }
        let mdnsDevices = await mdnsTask.value
        let ssdpResponses = await ssdpTask.value
        let arpHosts = await arpTask.value
        let ssdpDevices = await fetchSSDPDescriptions(ssdpResponses)

        var probeHosts: [String] = []
        var seenHosts: Set<String> = []
        for raw in mdnsDevices.map(\.host) + ssdpDevices.map(\.host) + ssdpResponses.map(\.host) + arpHosts {
            guard probeHosts.count < max6095Hosts, let safe = validatedLANHost(raw),
                  HADiscovery.isPrivateLANIPv4(safe), seenHosts.insert(safe).inserted else { continue }
            probeHosts.append(safe)
        }
        let xiaomiDevices = await probeXiaomi6095(hosts: probeHosts)
        return mergeDiscovered(mdnsDevices + ssdpDevices + xiaomiDevices)
    }

    // MARK: - Platform Transport Helpers

    private static func queryMDNSAll() async -> [TVBridgeDiscoveredDevice] {
        #if canImport(Darwin)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/dns-sd") else { return [] }
        return await withTaskGroup(of: [TVBridgeDiscoveredDevice].self) { group in
            for service in mdnsServiceTypes {
                group.addTask {
                    await Task.detached(priority: .userInitiated) {
                        guard let out = runDNSSD(serviceType: service) else { return [] }
                        return parseMDNSZoneOutput(out, serviceType: service)
                    }.value
                }
            }
            var collected: [TVBridgeDiscoveredDevice] = []
            for await batch in group { collected.append(contentsOf: batch) }
            return collected
        }
        #else
        return []
        #endif
    }

    #if canImport(Darwin)
    private static func runDNSSD(serviceType: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        proc.arguments = ["-t", "1", "-Z", serviceType, "local."]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    #endif

    private static func querySSDPResponses() -> [TVBridgeSSDPResponse] {
        #if canImport(Darwin)
        let sock = socket(AF_INET, Int32(SOCK_DGRAM), Int32(IPPROTO_UDP))
        guard sock >= 0 else { return [] }
        defer { close(sock) }
        var dst = sockaddr_in(); dst.sin_family = sa_family_t(AF_INET); dst.sin_port = UInt16(1900).bigEndian
        guard inet_pton(AF_INET, "239.255.255.250", &dst.sin_addr) == 1 else { return [] }
        for st in ssdpSearchTargets {
            let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(st)\r\n\r\n"
            msg.utf8CString.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                withUnsafePointer(to: &dst) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(sock, base, max(0, rawBuf.count - 1), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                } }
            }
        }
        let deadline = Date().addingTimeInterval(1.2)
        var results: [TVBridgeSSDPResponse] = []; var seenKeys: Set<String> = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while results.count < maxSSDPPackets {
            let remMs = Int((deadline.timeIntervalSinceNow * 1000).rounded(.down))
            guard remMs > 0 else { break }
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&pfd, 1, Int32(min(remMs, 1200))) <= 0 { break }
            var srcAddr = sockaddr_in(); var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &srcAddr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(sock, base, buf.count, 0, $0, &srcLen)
                } }
            }
            guard n > 0 else { continue }
            var ipBuf = [UInt8](repeating: 0, count: Int(INET_ADDRSTRLEN)); var addrCopy = srcAddr.sin_addr
            let senderIP: String? = inet_ntop(AF_INET, &addrCopy, &ipBuf, socklen_t(INET_ADDRSTRLEN)) != nil
                ? String(decoding: ipBuf.prefix { $0 != 0 }, as: UTF8.self) : nil
            if let parsed = parseSSDPResponse(String(decoding: buffer.prefix(n), as: UTF8.self), senderHost: senderIP),
               seenKeys.insert(parsed.location?.absoluteString ?? parsed.host).inserted {
                results.append(parsed)
            }
        }
        return results
        #else
        return []
        #endif
    }

    private static func makeNoRedirectSession(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 0.25
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
    }

    private static func fetchSSDPDescriptions(_ responses: [TVBridgeSSDPResponse]) async -> [TVBridgeDiscoveredDevice] {
        guard !responses.isEmpty else { return [] }
        let session = makeNoRedirectSession(timeout: 0.8)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskGroup(of: TVBridgeDiscoveredDevice?.self) { group in
            for resp in responses {
                group.addTask {
                    if let url = resp.location, validatedSSDPLocationURL(url.absoluteString) != nil,
                       (try? await HAPlaintextConsent.validateConnectionAddress(url)) != nil {
                        var req = URLRequest(url: url); req.timeoutInterval = 0.8
                        if let (data, httpResp) = try? await session.data(for: req),
                           let http = httpResp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                           data.count <= maxXMLBytes, let xml = String(data: data, encoding: .utf8),
                           let parsed = parseUPnPDeviceDescription(xml, host: resp.host, ssdpServer: resp.server, ssdpST: resp.st) {
                            return parsed
                        }
                    }
                    let cls = classify(name: resp.host, server: resp.server, serviceType: resp.st)
                    guard cls.driver != nil else { return nil }
                    return TVBridgeDiscoveredDevice(
                        name: cls.brand == "Smart TV" ? resp.host : "\(cls.brand) (\(resp.host))",
                        host: resp.host, port: cls.defaultPort, brand: cls.brand, model: cls.model,
                        suggestedDriver: cls.driver, sources: ["SSDP"]
                    )
                }
            }
            var out: [TVBridgeDiscoveredDevice] = []
            for await item in group { if let item { out.append(item) } }
            return out
        }
    }

    private static func probeXiaomi6095(hosts: [String]) async -> [TVBridgeDiscoveredDevice] {
        guard !hosts.isEmpty else { return [] }
        let session = makeNoRedirectSession(timeout: 0.7)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskGroup(of: TVBridgeDiscoveredDevice?.self) { group in
            for host in hosts {
                group.addTask {
                    guard let safeHost = validatedLANHost(host),
                          let url = URL(string: "http://\(safeHost):6095/request?action=isalive") else { return nil }
                    var req = URLRequest(url: url); req.timeoutInterval = 0.7
                    guard let (data, resp) = try? await session.data(for: req),
                          let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
                    return parseXiaomi6095Alive(data, host: safeHost)
                }
            }
            var out: [TVBridgeDiscoveredDevice] = []
            for await item in group { if let item { out.append(item) } }
            return out
        }
    }

    private static func xmlTagValue(_ tag: String, in xml: String) -> String? {
        guard let startRange = xml.range(of: "<\(tag)>", options: .caseInsensitive),
              let endRange = xml.range(of: "</\(tag)>", options: .caseInsensitive, range: startRange.upperBound..<xml.endIndex) else { return nil }
        return String(xml[startRange.upperBound..<endRange.lowerBound])
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizeDisplayText(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
