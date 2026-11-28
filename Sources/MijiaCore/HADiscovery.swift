import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import os
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Discovered Home Assistant Instance Model

/// Decides whether a Home Assistant found on the network may be offered as the new address (#18).
/// Offering is all it does: switching (and sending the token) always waits for the user.
public enum HAAddressPolicy {
    /// UserDefaults key for the instance id (mDNS `uuid`) of the Home Assistant the user chose.
    public static let rememberedUUIDKey = "ha_instance_uuid"
    /// A LAN scan after disconnects runs at most this often.
    public static let rediscoveryInterval: TimeInterval = 10 * 60

    /// - Returns: false for the current address, a dismissed one, or one whose id differs from the remembered id.
    public static func canOffer(
        _ candidate: HADiscoveredInstance,
        currentURL: String,
        rememberedUUID: String?,
        dismissedURLs: Set<String> = []
    ) -> Bool {
        let url = HAWebSocketProvider.normalizeBaseURL(candidate.baseURL)
        guard url != HAWebSocketProvider.normalizeBaseURL(currentURL), !dismissedURLs.contains(url) else { return false }
        guard let remembered = rememberedUUID?.trimmingCharacters(in: .whitespacesAndNewlines), !remembered.isEmpty else {
            return true
        }
        return candidate.uuid?.caseInsensitiveCompare(remembered) == .orderedSame
    }

    /// Pins the instance id of the Home Assistant the user is already talking to, so a look-alike on
    /// the network is filtered even when the address was typed by hand and never went through a
    /// suggestion (#18). Returns the uuid to remember, or nil when the current address does not match
    /// an identified discovered instance or one is already remembered.
    public static func uuidToPin(
        discovered: [HADiscoveredInstance],
        currentURL: String,
        rememberedUUID: String?
    ) -> String? {
        if let remembered = rememberedUUID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remembered.isEmpty {
            return nil
        }
        let current = HAWebSocketProvider.normalizeBaseURL(currentURL)
        return discovered.first {
            HAWebSocketProvider.normalizeBaseURL($0.baseURL) == current && $0.uuid != nil
        }?.uuid
    }
}

public struct HADiscoveredInstance: Equatable, Sendable, Identifiable {
    public var baseURL: String
    public var locationName: String
    public var version: String?
    public var uuid: String?
    public var source: String

    public var id: String { baseURL }

    public var hostAndPort: String {
        baseURL
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    public var displaySummary: String {
        if let version, !version.isEmpty {
            return "\(locationName) (\(hostAndPort) · v\(version))"
        }
        return "\(locationName) (\(hostAndPort))"
    }

    public init(
        baseURL: String,
        locationName: String = "Home Assistant",
        version: String? = nil,
        uuid: String? = nil,
        source: String = "mDNS"
    ) {
        self.baseURL = HAWebSocketProvider.normalizeBaseURL(baseURL)
        let trimmedName = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.locationName = trimmedName.isEmpty ? "Home Assistant" : trimmedName
        let trimmedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.version = trimmedVersion.isEmpty ? nil : trimmedVersion
        let trimmedUUID = uuid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.uuid = trimmedUUID.isEmpty ? nil : trimmedUUID
        self.source = source
    }
}

// MARK: - Home Assistant LAN Auto-Discovery (mDNS + ARP/HTTP Manifest Probe)

public enum HADiscovery {
    private static let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "HADiscovery")

    /// Unescapes DNS-SD zone file escaping (e.g. `\032` for space or `\230\136\145` for UTF-8 bytes).
    public static func unescapeDNSSD(_ raw: String) -> String {
        var bytes: [UInt8] = []
        let chars = Array(raw.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                if i + 3 < chars.count,
                   let d1 = Self.decimalDigit(chars[i + 1]),
                   let d2 = Self.decimalDigit(chars[i + 2]),
                   let d3 = Self.decimalDigit(chars[i + 3]) {
                    let val = d1 * 100 + d2 * 10 + d3
                    if val <= 255 {
                        bytes.append(UInt8(val))
                        i += 4
                        continue
                    }
                }
                let nextScalar = chars[i + 1]
                for b in String(nextScalar).utf8 {
                    bytes.append(b)
                }
                i += 2
            } else {
                for b in String(c).utf8 {
                    bytes.append(b)
                }
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func decimalDigit(_ scalar: UnicodeScalar) -> Int? {
        guard scalar.value >= 48 && scalar.value <= 57 else { return nil }
        return Int(scalar.value - 48)
    }

    /// Parses quoted `"key=value"` pairs from a DNS-SD TXT line.
    public static func parseTXTRecordTokens(_ rawTXTPart: String) -> [String: String] {
        var result: [String: String] = [:]
        var inQuotes = false
        var current = ""
        let scalars = Array(rawTXTPart.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let ch = scalars[i]
            if ch == "\\" && i + 1 < scalars.count {
                current.unicodeScalars.append(ch)
                current.unicodeScalars.append(scalars[i + 1])
                i += 2
                continue
            }
            if ch == "\"" {
                if inQuotes {
                    let unescaped = unescapeDNSSD(current)
                    if let eqIdx = unescaped.firstIndex(of: "=") {
                        let key = String(unescaped[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let val = String(unescaped[unescaped.index(after: eqIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !key.isEmpty {
                            result[key] = val
                        }
                    }
                    current = ""
                    inQuotes = false
                } else {
                    inQuotes = true
                    current = ""
                }
            } else if inQuotes {
                current.unicodeScalars.append(ch)
            }
            i += 1
        }
        return result
    }

    /// Builds a discovered instance from mDNS TXT and SRV fields.
    public static func buildInstance(
        instanceName: String?,
        txt: [String: String],
        srvPort: Int = 8123,
        srvTarget: String? = nil,
        source: String = "mDNS",
        hostResolver: (String) -> String? = resolveHostIPv4
    ) -> HADiscoveredInstance? {
        let port = srvPort > 0 ? srvPort : 8123
        let cleanTarget = srvTarget?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        let internalURL = Self.validLANHTTPURL(txt["internal_url"])
        let baseURL = Self.validLANHTTPURL(txt["base_url"])
        let validTarget = cleanTarget.flatMap { Self.isAllowedLANDiscoveryHost($0) ? $0 : nil }

        let chosenURL: String?
        if let internalURL, Self.urlHasIPv4Host(internalURL) {
            chosenURL = internalURL
        } else if let baseURL, Self.urlHasIPv4Host(baseURL) {
            chosenURL = baseURL
        } else if let validTarget,
                  let resolvedTargetIP = hostResolver(validTarget)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  Self.isPrivateLANIPv4(resolvedTargetIP) {
            chosenURL = "http://\(resolvedTargetIP):\(port)"
        } else if let internalURL {
            chosenURL = internalURL
        } else if let baseURL {
            chosenURL = baseURL
        } else if let validTarget {
            chosenURL = Self.validLANHTTPURL("http://\(validTarget):\(port)")
        } else {
            chosenURL = nil
        }

        guard let finalURL = chosenURL else { return nil }

        let locName: String
        if let txtName = txt["location_name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !txtName.isEmpty {
            locName = txtName
        } else if let instanceName = instanceName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !instanceName.isEmpty {
            locName = instanceName
        } else {
            locName = "Home Assistant"
        }

        return HADiscoveredInstance(
            baseURL: finalURL,
            locationName: locName,
            version: txt["version"],
            uuid: txt["uuid"],
            source: source
        )
    }

    /// Parses the zone output of `dns-sd -Z _home-assistant._tcp local.`.
    public static func parseMDNSZoneOutput(
        _ output: String,
        hostResolver: (String) -> String? = resolveHostIPv4
    ) -> [HADiscoveredInstance] {
        struct PartialRecord {
            var instanceName: String
            var srvPort: Int = 8123
            var srvTarget: String?
            var txt: [String: String] = [:]
            var hasSRVOrTXT: Bool = false
        }

        var order: [String] = []
        var byInstance: [String: PartialRecord] = [:]
        let marker = "._home-assistant._tcp"

        for rawLine in output.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix(";") { continue }

            guard let markerRange = rawLine.range(of: marker) else { continue }
            let prefixRaw = String(rawLine[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let afterMarker = String(rawLine[markerRange.upperBound...])

            // Ignore PTR header lines where prefix starts with _home-assistant._tcp
            if prefixRaw.hasPrefix("_home-assistant._tcp") { continue }

            let instanceName = unescapeDNSSD(prefixRaw)
            if byInstance[instanceName] == nil {
                order.append(instanceName)
                byInstance[instanceName] = PartialRecord(instanceName: instanceName)
            }

            let uncommentedAfter: String = if let semiIdx = afterMarker.firstIndex(of: ";"),
                                              !afterMarker.contains("\"") {
                String(afterMarker[..<semiIdx])
            } else {
                afterMarker
            }

            let tokens = uncommentedAfter
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)

            if let srvIdx = tokens.firstIndex(of: "SRV"), srvIdx + 4 < tokens.count {
                if let port = Int(tokens[srvIdx + 3]) {
                    byInstance[instanceName]?.srvPort = port
                }
                byInstance[instanceName]?.srvTarget = tokens[srvIdx + 4]
                byInstance[instanceName]?.hasSRVOrTXT = true
            } else if let txtRange = afterMarker.range(of: "TXT") {
                let txtPayload = String(afterMarker[txtRange.upperBound...])
                let parsedTXT = parseTXTRecordTokens(txtPayload)
                for (k, v) in parsedTXT {
                    byInstance[instanceName]?.txt[k] = v
                }
                byInstance[instanceName]?.hasSRVOrTXT = true
            }
        }

        var results: [HADiscoveredInstance] = []
        var seenURLs: Set<String> = []

        for key in order {
            guard let rec = byInstance[key], rec.hasSRVOrTXT else { continue }
            if let inst = buildInstance(
                instanceName: rec.instanceName,
                txt: rec.txt,
                srvPort: rec.srvPort,
                srvTarget: rec.srvTarget,
                source: "mDNS",
                hostResolver: hostResolver
            ) {
                if seenURLs.insert(inst.baseURL).inserted {
                    results.append(inst)
                }
            }
        }
        return results
    }

    /// Active local IPv4 interface address and subnet mask used to scope LAN fallback sweeps.
    public struct LANIPv4Interface: Equatable, Sendable {
        public let name: String
        public let address: String
        public let netmask: String
        public init(name: String, address: String, netmask: String) {
            self.name = name; self.address = address; self.netmask = netmask
        }
    }

    struct HTTPProbeResponse: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    public static let defaultPort: Int = 8123
    public static let commonLANHostnames: [String] = ["homeassistant.local", "hassio.local", "hass.local"]
    private static let maxSubnetSweeps: Int = 4
    private static let tcpSweepBatchSize: Int = 48
    private static let tcpSweepTimeoutMs: Int = 450
    private static let httpProbeMaxConcurrency: Int = 16
    private static let httpProbeRequestTimeout: TimeInterval = 1.2
    private static let httpProbeResourceTimeout: TimeInterval = 2.0

    /// Parses private LAN IPv4 addresses from `arp -an` or `arp -a` output, skipping `(incomplete)` rows.
    public static func parseARPTableHosts(_ arpOutput: String) -> [String] {
        var hosts: [String] = []
        var seen: Set<String> = []
        for line in arpOutput.components(separatedBy: .newlines) {
            if line.localizedCaseInsensitiveContains("(incomplete)") { continue }
            guard let openParen = line.firstIndex(of: "("),
                  let closeParen = line[openParen...].firstIndex(of: ")") else { continue }
            let ip = String(line[line.index(after: openParen)..<closeParen]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isPrivateLANIPv4(ip), seen.insert(ip).inserted { hosts.append(ip) }
        }
        return hosts
    }

    /// Generates deduplicated private LAN IPv4 host candidates for active interfaces' `/24` (or narrower) subnets.
    public static func subnetCandidateHosts(
        for interfaces: [LANIPv4Interface],
        excluding excludedIPs: Set<String> = [],
        maxSubnets: Int = 4
    ) -> [String] {
        guard maxSubnets > 0 else { return [] }
        let ordered = interfaces.sorted { interfacePriority($0.name) < interfacePriority($1.name) }
        var seenSubnets: Set<UInt64> = []
        var seenIPs: Set<String> = excludedIPs
        var candidates: [String] = []

        for iface in ordered {
            guard isPrivateLANIPv4(iface.address), let addr = parseIPv4UInt32(iface.address) else { continue }
            let rawMask = parseIPv4UInt32(iface.netmask)
            let validMask: UInt32 = rawMask.flatMap { ($0 != 0 && ((~$0) & ((~$0) &+ 1)) == 0) ? $0 : nil } ?? 0xFFFF_FF00
            // Clamp wider masks (/8, /16, /23) to /24; preserve narrower (/25../30).
            let effectiveMask = validMask | 0xFFFF_FF00
            let network = addr & effectiveMask
            let broadcast = network | ~effectiveMask
            guard broadcast > network &+ 1 else { continue }
            let key = (UInt64(network) << 32) | UInt64(effectiveMask)
            guard seenSubnets.insert(key).inserted else { continue }
            if seenSubnets.count > maxSubnets { break }

            var cur = network &+ 1
            while cur < broadcast {
                let ip = "\((cur >> 24) & 0xFF).\((cur >> 16) & 0xFF).\((cur >> 8) & 0xFF).\(cur & 0xFF)"
                if isPrivateLANIPv4(ip), seenIPs.insert(ip).inserted { candidates.append(ip) }
                cur &+= 1
            }
        }
        return candidates
    }

    private static func interfacePriority(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.hasPrefix("en") || lower.hasPrefix("eth") || lower.hasPrefix("wl") { return 0 }
        if ["bridge", "vmenet", "docker", "br-", "virbr", "vbox"].contains(where: { lower.hasPrefix($0) }) { return 2 }
        return 1
    }

    private static func parseIPv4UInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, !(part.count > 1 && part.first == "0"),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            result = (result << 8) | octet
        }
        return result
    }

    /// Checks whether HTTP response data from `/manifest.json` belongs to Home Assistant.
    public static func isHomeAssistantManifest(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = obj["name"] as? String, name.localizedCaseInsensitiveContains("Home Assistant") { return true }
            if let shortName = obj["short_name"] as? String, shortName.localizedCaseInsensitiveContains("Home Assistant") { return true }
            if (obj["start_url"] as? String) == "/?homescreen=1",
               let icons = obj["icons"] as? [[String: Any]],
               icons.contains(where: { ($0["src"] as? String)?.contains("/static/icons/") == true }) {
                return true
            }
        }
        if let text = String(data: data, encoding: .utf8),
           text.contains("io.homeassistant") || text.contains("\"Home Assistant\"") { return true }
        return false
    }

    /// Checks whether HTTP response from `/auth/providers` identifies Home Assistant.
    public static func isHomeAssistantAuthProvidersResponse(statusCode: Int, data: Data) -> Bool {
        guard (200...299).contains(statusCode), !data.isEmpty,
              let providers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return providers.contains { entry in
            let type = (entry["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if type == "homeassistant" { return true }
            return type == "trusted_networks" && (entry["name"] as? String)?.localizedCaseInsensitiveContains("Home Assistant") == true
        }
    }

    /// Checks whether HTTP response from `/api/` identifies Home Assistant (200 `API running.` or 401 with HA/aiohttp signature).
    public static func isHomeAssistantAPIResponse(statusCode: Int, headers: [String: String], data: Data) -> Bool {
        if (200...299).contains(statusCode),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (obj["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "API running." {
            return true
        }
        guard statusCode == 401 else { return false }
        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard body == "401: Unauthorized" || body.localizedCaseInsensitiveContains("Home Assistant") else { return false }
        if body.localizedCaseInsensitiveContains("Home Assistant") { return true }
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        if let server = lowered["server"],
           server.localizedCaseInsensitiveContains("aiohttp") || server.localizedCaseInsensitiveContains("Home Assistant") { return true }
        if let auth = lowered["www-authenticate"], auth.localizedCaseInsensitiveContains("Home Assistant") { return true }
        return lowered.keys.contains(where: { $0.hasPrefix("x-ha-") || $0.contains("home-assistant") })
    }

    /// Merges mDNS and HTTP-probed instances, keeping rich mDNS metadata when URLs match.
    public static func mergeInstances(
        mdns: [HADiscoveredInstance],
        probed: [HADiscoveredInstance]
    ) -> [HADiscoveredInstance] {
        var merged: [HADiscoveredInstance] = []
        var indexByURL: [String: Int] = [:]

        for item in mdns {
            if indexByURL[item.baseURL] == nil {
                indexByURL[item.baseURL] = merged.count
                merged.append(item)
            }
        }
        for item in probed {
            if indexByURL[item.baseURL] == nil {
                indexByURL[item.baseURL] = merged.count
                merged.append(item)
            }
        }
        return merged
    }

    // MARK: - Live LAN Discovery Entry Point

    public static func discoverOnLAN(currentURLHint: String? = nil) async -> [HADiscoveredInstance] {
        await discoverOnLAN(
            currentURLHint: currentURLHint,
            queryMDNS: { Self.queryMDNSInstances() },
            queryARP: { Self.queryARPHosts() },
            activeInterfaces: { Self.activeLANIPv4Interfaces() },
            scanOpenPort: { hosts in Self.scanOpenTCPPortHosts(hosts, port: UInt16(Self.defaultPort)) },
            probeURLs: { urls in await Self.probeCandidateURLs(urls) }
        )
    }

    static func discoverOnLAN(
        currentURLHint: String? = nil,
        queryMDNS: @escaping @Sendable () -> [HADiscoveredInstance],
        queryARP: @escaping @Sendable () -> [String],
        activeInterfaces: @escaping @Sendable () -> [LANIPv4Interface],
        scanOpenPort: @escaping @Sendable ([String]) -> [String],
        probeURLs: @escaping @Sendable ([String]) async -> [HADiscoveredInstance]
    ) async -> [HADiscoveredInstance] {
        // Concurrent without `async let`: that form wrapped around `Task.detached` mis-orders the
        // task allocations on x86_64 Debug builds (swiftlang/swift#87571).
        let mdnsTask = Task.detached(priority: .userInitiated) { queryMDNS() }

        var initialCandidates: [String] = []
        var seenCandidates: Set<String> = []
        var probedDefaultPortIPs: Set<String> = []

        func addCandidate(_ raw: String, into list: inout [String]) {
            guard let norm = Self.validLANHTTPURL(raw),
                  seenCandidates.insert(norm).inserted else { return }
            list.append(norm)
            if let comps = URLComponents(string: norm),
               comps.scheme?.lowercased() == "http",
               (comps.port ?? 80) == Self.defaultPort,
               let host = comps.host,
               Self.isPrivateLANIPv4(host) {
                probedDefaultPortIPs.insert(host)
            }
        }

        if let hint = currentURLHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            addCandidate(hint, into: &initialCandidates)
        }
        addCandidate(KeychainHelper.defaultNASURL, into: &initialCandidates)
        for hostname in Self.commonLANHostnames {
            addCandidate("http://\(hostname):\(Self.defaultPort)", into: &initialCandidates)
        }

        let arpHosts = await Task.detached(priority: .utility) {
            queryARP()
        }.value
        for ip in arpHosts {
            addCandidate("http://\(ip):\(Self.defaultPort)", into: &initialCandidates)
        }

        let candidatesForInitialProbe = initialCandidates
        let initialProbeTask = Task { await probeURLs(candidatesForInitialProbe) }

        let mdnsFound = await mdnsTask.value
        var probed = await initialProbeTask.value

        var extraMDNSCandidates: [String] = []
        for inst in mdnsFound {
            addCandidate(inst.baseURL, into: &extraMDNSCandidates)
        }
        if !extraMDNSCandidates.isEmpty {
            let extraProbed = await probeURLs(extraMDNSCandidates)
            probed.append(contentsOf: extraProbed)
        }

        var merged = mergeInstances(mdns: mdnsFound, probed: probed)

        // Fallback: when mDNS + common hostnames + ARP find nothing (e.g. Docker bridge HA on a
        // NAS whose IP is not cached in ARP), actively sweep active private /24 subnets on :8123.
        if merged.isEmpty && !Task.isCancelled {
            let excluded = probedDefaultPortIPs
            let openHosts = await Task.detached(priority: .utility) {
                let interfaces = activeInterfaces()
                let sweepHosts = Self.subnetCandidateHosts(
                    for: interfaces,
                    excluding: excluded,
                    maxSubnets: Self.maxSubnetSweeps
                )
                guard !sweepHosts.isEmpty else { return [String]() }
                return scanOpenPort(sweepHosts)
            }.value

            var sweepCandidates: [String] = []
            for ip in openHosts {
                addCandidate("http://\(ip):\(Self.defaultPort)", into: &sweepCandidates)
            }
            if !sweepCandidates.isEmpty && !Task.isCancelled {
                let sweepProbed = await probeURLs(sweepCandidates)
                probed.append(contentsOf: sweepProbed)
                merged = mergeInstances(mdns: mdnsFound, probed: probed)
            }
        }

        // Prefer instances confirmed reachable by HTTP probe first, followed by remaining mDNS results
        let reachableSet = Set(probed.map(\.baseURL))
        let sorted = merged.sorted { a, b in
            let aReachable = reachableSet.contains(a.baseURL)
            let bReachable = reachableSet.contains(b.baseURL)
            if aReachable != bReachable { return aReachable }
            let aIsIP = urlHasIPv4Host(a.baseURL)
            let bIsIP = urlHasIPv4Host(b.baseURL)
            if aIsIP != bIsIP { return aIsIP }
            return false
        }

        if let first = sorted.first {
            logger.info("Discovered Home Assistant on LAN: \(first.displaySummary, privacy: .public)")
        }
        return sorted
    }

    // MARK: - Platform Helpers

    public static func resolveHostIPv4(_ host: String) -> String? {
        let clean = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !clean.isEmpty else { return nil }
        if isPrivateLANIPv4(clean) { return clean }

        #if canImport(Darwin)
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(clean, nil, &hints, &res)
        guard status == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }

        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let info = ptr {
            if info.pointee.ai_family == AF_INET, let addrPtr = info.pointee.ai_addr {
                let sinPtr = UnsafeRawPointer(addrPtr).assumingMemoryBound(to: sockaddr_in.self)
                var addr = sinPtr.pointee.sin_addr
                var buffer = [UInt8](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
                    if isPrivateLANIPv4(ip) {
                        return ip
                    }
                }
            }
            ptr = info.pointee.ai_next
        }
        #endif
        return nil
    }

    private static func queryMDNSInstances() -> [HADiscoveredInstance] {
        #if canImport(Darwin)
        guard let output = runCommand(
            executable: "/usr/bin/dns-sd",
            arguments: ["-t", "2", "-Z", "_home-assistant._tcp", "local."]
        ) else {
            return []
        }
        return parseMDNSZoneOutput(output)
        #else
        return []
        #endif
    }

    static func queryARPHosts() -> [String] {
        #if canImport(Darwin)
        guard let output = runCommand(
            executable: "/usr/sbin/arp",
            arguments: ["-an"]
        ) else {
            return []
        }
        return parseARPTableHosts(output)
        #else
        return []
        #endif
    }

    static func activeLANIPv4Interfaces() -> [LANIPv4Interface] {
        #if canImport(Darwin) || canImport(Glibc)
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(first) }
        var interfaces: [LANIPv4Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            let flags = Int32(ifa.ifa_flags)
            guard (flags & Int32(IFF_UP)) != 0, (flags & Int32(IFF_RUNNING)) != 0,
                  (flags & Int32(IFF_LOOPBACK)) == 0, (flags & Int32(IFF_POINTOPOINT)) == 0,
                  let addrPtr = ifa.ifa_addr, Int32(addrPtr.pointee.sa_family) == AF_INET,
                  let ip = ipv4String(from: UnsafeRawPointer(addrPtr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr),
                  isPrivateLANIPv4(ip) else { continue }
            let mask = ifa.ifa_netmask
                .flatMap { Int32($0.pointee.sa_family) == AF_INET ? ipv4String(from: UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr) : nil }
                ?? "255.255.255.0"
            interfaces.append(LANIPv4Interface(name: ifa.ifa_name.map { String(cString: $0) } ?? "", address: ip, netmask: mask))
        }
        return interfaces
        #else
        return []
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func ipv4String(from addr: in_addr) -> String? {
        var copy = addr
        var buffer = [UInt8](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func closeSocketFD(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }
    #endif

    /// Bounded non-blocking TCP port check using `poll(2)` over RFC1918 private LAN IPv4 hosts.
    static func scanOpenTCPPortHosts(
        _ hosts: [String], port: UInt16 = UInt16(defaultPort),
        batchSize: Int = tcpSweepBatchSize, timeoutMs: Int = tcpSweepTimeoutMs
    ) -> [String] {
        #if canImport(Darwin) || canImport(Glibc)
        let safeHosts = hosts.filter { isPrivateLANIPv4($0) }
        guard !safeHosts.isEmpty, port > 0 else { return [] }
        let step = max(1, min(batchSize, 64))
        let waitMs = max(50, timeoutMs)
        var openHosts: [String] = []
        var offset = 0
        while offset < safeHosts.count && !Task.isCancelled {
            let end = min(offset + step, safeHosts.count)
            openHosts.append(contentsOf: scanTCPBatch(Array(safeHosts[offset..<end]), port: port, timeoutMs: waitMs))
            offset = end
        }
        return openHosts
        #else
        return []
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func scanTCPBatch(_ hosts: [String], port: UInt16, timeoutMs: Int) -> [String] {
        var immediateOpen: [String] = []
        var pending: [(host: String, fd: Int32)] = []
        pending.reserveCapacity(hosts.count)
        defer { for item in pending where item.fd >= 0 { closeSocketFD(item.fd) } }
        #if canImport(Darwin)
        let sockType = SOCK_STREAM
        #else
        let sockType = Int32(SOCK_STREAM.rawValue)
        #endif

        for host in hosts {
            guard !Task.isCancelled else { break }
            let fd = socket(AF_INET, sockType, 0)
            guard fd >= 0 else { continue }
            #if canImport(Darwin)
            var noSigPipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            #endif
            let flags = fcntl(fd, F_GETFL, 0)
            if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 { closeSocketFD(fd); continue }
            var addr = sockaddr_in()
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { closeSocketFD(fd); continue }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if rc == 0 { closeSocketFD(fd); immediateOpen.append(host) }
            else if errno == EINPROGRESS { pending.append((host, fd)) }
            else { closeSocketFD(fd) }
        }

        var pollOpen: [String] = []
        if !pending.isEmpty {
            var pollfds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            var active = pending.count
            let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
            while active > 0 && !Task.isCancelled {
                let rem = deadline - ContinuousClock.now
                let remMs = Int(rem.components.seconds) * 1000 + Int(rem.components.attoseconds / 1_000_000_000_000_000)
                if remMs <= 0 { break }
                let ready = poll(&pollfds, nfds_t(pollfds.count), Int32(min(50, max(1, remMs))))
                if ready < 0 { if errno == EINTR { continue }; break }
                if ready == 0 { continue }
                for idx in pollfds.indices where pollfds[idx].fd >= 0 && pollfds[idx].revents != 0 {
                    let fd = pending[idx].fd
                    if (pollfds[idx].revents & Int16(POLLOUT)) != 0 {
                        var sockErr: Int32 = 0
                        var errLen = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &errLen) == 0 && sockErr == 0 {
                            pollOpen.append(pending[idx].host)
                        }
                    }
                    closeSocketFD(fd); pending[idx].fd = -1; pollfds[idx].fd = -1; pollfds[idx].revents = 0
                    active -= 1
                }
            }
        }
        let openSet = Set(immediateOpen).union(pollOpen)
        return hosts.filter { openSet.contains($0) }
    }
    #endif

    #if canImport(Darwin)
    private static func runCommand(executable: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }
    #endif

    private static func probeCandidateURLs(_ urls: [String]) async -> [HADiscoveredInstance] {
        guard !urls.isEmpty else { return [] }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = httpProbeRequestTimeout
        config.timeoutIntervalForResource = httpProbeResourceTimeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: HARedirectBlockingDelegate.shared, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return await probeCandidateURLs(
            urls, maxConcurrency: httpProbeMaxConcurrency,
            validateAddress: { try await HAPlaintextConsent.validateConnectionAddress($0) },
            fetch: { url in
                var req = URLRequest(url: url)
                req.timeoutInterval = httpProbeRequestTimeout
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                let headers = Dictionary(uniqueKeysWithValues: http.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) })
                return HTTPProbeResponse(statusCode: http.statusCode, headers: headers, data: data)
            }
        )
    }

    static func probeCandidateURLs(
        _ urls: [String], maxConcurrency: Int = httpProbeMaxConcurrency,
        validateAddress: @escaping @Sendable (URL) async throws -> Void = { _ in },
        fetch: @escaping @Sendable (URL) async throws -> HTTPProbeResponse
    ) async -> [HADiscoveredInstance] {
        guard !urls.isEmpty else { return [] }
        let limit = max(1, min(maxConcurrency, urls.count))
        return await withTaskGroup(of: (Int, HADiscoveredInstance?).self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < urls.count, !Task.isCancelled else { return }
                let idx = nextIndex; let baseURL = urls[idx]; nextIndex += 1
                group.addTask {
                    let found = await probeSingleCandidate(baseURL, validateAddress: validateAddress, fetch: fetch)
                    return (idx, found)
                }
            }
            for _ in 0..<limit { enqueueNext() }
            var indexed: [(Int, HADiscoveredInstance)] = []
            for await (idx, found) in group {
                if let found { indexed.append((idx, found)) }
                enqueueNext()
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func probeSingleCandidate(
        _ baseURL: String,
        validateAddress: @Sendable (URL) async throws -> Void = { _ in },
        fetch: @Sendable (URL) async throws -> HTTPProbeResponse
    ) async -> HADiscoveredInstance? {
        guard let safeBase = Self.validLANHTTPURL(baseURL), let manifestURL = URL(string: "\(safeBase)/manifest.json") else { return nil }
        if !urlHasIPv4Host(safeBase) {
            guard (try? await validateAddress(manifestURL)) != nil else { return nil }
        }
        // 1. /manifest.json — transport failure aborts early so dead hosts never burn extra timeouts.
        guard let manifestResp = try? await fetch(manifestURL) else { return nil }
        if (200...299).contains(manifestResp.statusCode), Self.isHomeAssistantManifest(manifestResp.data) {
            return HADiscoveredInstance(baseURL: safeBase, locationName: "Home Assistant", source: "HTTP")
        }
        // 2. /auth/providers — unauthenticated Home Assistant login metadata.
        if let url = URL(string: "\(safeBase)/auth/providers"), let resp = try? await fetch(url),
           Self.isHomeAssistantAuthProvidersResponse(statusCode: resp.statusCode, data: resp.data) {
            return HADiscoveredInstance(baseURL: safeBase, locationName: "Home Assistant", source: "HTTP")
        }
        // 3. /api/ — 401 with HA/aiohttp signature or 200 "API running.".
        if let url = URL(string: "\(safeBase)/api/"), let resp = try? await fetch(url),
           Self.isHomeAssistantAPIResponse(statusCode: resp.statusCode, headers: resp.headers, data: resp.data) {
            return HADiscoveredInstance(baseURL: safeBase, locationName: "Home Assistant", source: "HTTP")
        }
        return nil
    }

    static func isAllowedLANDiscoveryHost(_ rawHost: String) -> Bool {
        var host = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty,
              host != "localhost",
              host != "localhost.local",
              !host.contains("@"),
              !host.contains(":"),
              !host.contains("["),
              !host.contains("]") else {
            return false
        }
        if isPrivateLANIPv4(host) {
            return true
        }
        guard host.hasSuffix(".local") else {
            return false
        }
        let stem = host.dropLast(".local".count)
        guard !stem.isEmpty, stem != "localhost" else { return false }
        let labels = stem.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.count <= 63,
                  let first = label.first,
                  let last = label.last,
                  first.isASCII && (first.isLetter || first.isNumber),
                  last.isASCII && (last.isLetter || last.isNumber) else {
                return false
            }
            return label.allSatisfy { ch in
                ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-")
            }
        }
    }

    private static func validLANHTTPURL(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              isAllowedLANDiscoveryHost(host) else {
            return nil
        }
        if let port = components.port, !(1...65535).contains(port) {
            return nil
        }
        return HAWebSocketProvider.normalizeBaseURL(trimmed)
    }

    private static func urlHasIPv4Host(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host else { return false }
        return isPrivateLANIPv4(host)
    }

    public static func isLocalNetworkBlockedError(_ error: any Error, urlString: String, isGeneralNetworkSatisfied: Bool = true) -> Bool {
        let host = URL(string: HAWebSocketProvider.normalizeBaseURL(urlString))?.host?.lowercased()
        return LocalNetworkPermissionClassifier.isDeniedConnectionError(error, targetHost: host, isGeneralNetworkSatisfied: isGeneralNetworkSatisfied)
    }

    public static func isPrivateLANIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var nums: [Int] = []
        nums.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty,
                  part.count <= 3,
                  !(part.count > 1 && part.first == "0"),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let val = Int(part),
                  (0...255).contains(val) else {
                return false
            }
            nums.append(val)
        }
        guard nums[3] != 0 && nums[3] != 255 else { return false }
        if nums[0] == 10 { return true }
        if nums[0] == 192 && nums[1] == 168 { return true }
        if nums[0] == 172 && (16...31).contains(nums[1]) { return true }
        return false
    }
}
