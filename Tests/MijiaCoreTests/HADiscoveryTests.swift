import Foundation
import Testing
@testable import MijiaCore

struct HADiscoveryTests {
    @Test("Parses mDNS _home-assistant._tcp zone output with UTF-8 and DNS-SD escaped names")
    func parseMDNSZoneRecords() {
        let zoneOutput = """
        Browsing for _home-assistant._tcp.local.
        DATE: ---Wed 21 Oct 2026---
        15:06:57.721  ...STARTING...
        _home-assistant._tcp                            PTR     我的家._home-assistant._tcp
        我的家._home-assistant._tcp                  SRV     0 0 8123 f7d5b92ef26b41ce9eba8980bdcb9a00.local. ; Replace with unicast FQDN
        我的家._home-assistant._tcp                  TXT     "location_name=我的家" "uuid=f7d5b92ef26b41ce9eba8980bdcb9a00" "version=2026.10.1" "external_url=" "internal_url=http://192.168.1.4:8123" "base_url=http://192.168.1.4:8123"
        """

        let found = HADiscovery.parseMDNSZoneOutput(zoneOutput) { _ in nil }
        #expect(found.count == 1)
        #expect(found.first?.baseURL == "http://192.168.1.4:8123")
        #expect(found.first?.locationName == "我的家")
        #expect(found.first?.version == "2026.10.1")
        #expect(found.first?.uuid == "f7d5b92ef26b41ce9eba8980bdcb9a00")
        #expect(found.first?.displaySummary == "我的家 (192.168.1.4:8123 · v2026.10.1)")
    }

    @Test("Unescapes DNS-SD decimal byte escapes and resolves SRV target host when internal_url is empty")
    func unescapeAndResolveSRVTarget() {
        // \230\136\145\231\154\132\229\174\182 is UTF-8 for "我的家", \032 is ASCII space
        #expect(HADiscovery.unescapeDNSSD(#"\230\136\145\231\154\132\229\174\182"#) == "我的家")
        #expect(HADiscovery.unescapeDNSSD(#"Home\032Assistant"#) == "Home Assistant")

        let zoneWithoutInternalURL = """
        _home-assistant._tcp                            PTR     Home\\032Assistant._home-assistant._tcp
        Home\\032Assistant._home-assistant._tcp         SRV     0 0 8123 ha-nas.local.
        Home\\032Assistant._home-assistant._tcp         TXT     "location_name=书房中枢" "version=2026.9.0" "internal_url=http://homeassistant.local:8123"
        """

        let resolved = HADiscovery.parseMDNSZoneOutput(zoneWithoutInternalURL) { host in
            host == "ha-nas.local" ? "192.168.31.88" : nil
        }
        #expect(resolved.count == 1)
        #expect(resolved.first?.baseURL == "http://192.168.31.88:8123")
        #expect(resolved.first?.locationName == "书房中枢")
        #expect(resolved.first?.version == "2026.9.0")
    }

    @Test("Parses ARP table private LAN IPv4 addresses and validates Home Assistant manifest.json")
    func arpAndManifestValidation() {
        let arpSample = """
        ? (192.168.1.1) at 60:be:b4:8:e4:19 on en0 ifscope [ethernet]
        ? (192.168.1.4) at 0:11:32:f7:71:4b on en0 ifscope [ethernet]
        ? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        ? (169.254.169.254) at 60:be:b4:8:e4:19 on en0 [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
        ? (192.168.50.12) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
        """
        let ips = HADiscovery.parseARPTableHosts(arpSample)
        #expect(ips == ["192.168.1.1", "192.168.1.4", "192.168.50.12"])

        let validManifest = Data(##"{"name":"Home Assistant","short_name":"Home Assistant","theme_color":"#2980b9"}"##.utf8)
        let invalidManifest = Data(#"{"name":"Synology DiskStation"}"#.utf8)
        #expect(HADiscovery.isHomeAssistantManifest(validManifest) == true)
        #expect(HADiscovery.isHomeAssistantManifest(invalidManifest) == false)

        let mdnsInst = HADiscoveredInstance(baseURL: "http://192.168.1.4:8123", locationName: "我的家", version: "2026.10.1", uuid: "u1", source: "mDNS")
        let httpInst = HADiscoveredInstance(baseURL: "http://192.168.1.4:8123", locationName: "Home Assistant", source: "HTTP")
        let merged = HADiscovery.mergeInstances(mdns: [mdnsInst], probed: [httpInst])
        #expect(merged.count == 1)
        #expect(merged.first?.locationName == "我的家")
        #expect(merged.first?.version == "2026.10.1")
    }

    @Test("HomeStore applies discovered LAN Home Assistant instance to serverURLString")
    @MainActor
    func storeAppliesDiscoveredHA() {
        let suite = "test.ha.discovery.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(store.serverURLString == KeychainHelper.defaultNASURL)

        let discovered = HADiscoveredInstance(
            baseURL: "http://192.168.1.4:8123/",
            locationName: "我的群晖之家",
            version: "2026.10.1",
            uuid: "f7d5b92ef26b41ce9eba8980bdcb9a00"
        )
        store.applyDiscoveredHAInstance(discovered, reconnectProvider: false)

        #expect(store.serverURLString == "http://192.168.1.4:8123")
        #expect(store.serverHostSummary == "192.168.1.4")
        #expect(store.homeName == "我的群晖之家")
        #expect(store.discoveredHAInstances.first?.baseURL == "http://192.168.1.4:8123")
    }

    @Test("HAWebSocketProvider.describeConnectionError explains macOS Local Network block on LAN -1009")
    func describeConnectionErrorLANBlock() {
        let lanOffline = URLError(.notConnectedToInternet)
        let lanMessage = HAWebSocketProvider.describeConnectionError(
            lanOffline,
            baseURLString: "http://192.168.1.4:8123"
        )
        #expect(lanMessage.contains("本地网络") || lanMessage.contains("Local Network"))

        let mdnsMessage = HAWebSocketProvider.describeConnectionError(
            lanOffline,
            baseURLString: "http://homeassistant.local:8123"
        )
        #expect(mdnsMessage.contains("本地网络") || mdnsMessage.contains("Local Network"))

        let publicMessage = HAWebSocketProvider.describeConnectionError(
            lanOffline,
            baseURLString: "https://demo.ui.nabu.casa"
        )
        #expect(!publicMessage.contains("隐私与安全性") && !publicMessage.contains("Privacy & Security"))

        let authMessage = HAWebSocketProvider.describeConnectionError(
            HomeProviderError.unauthorized,
            baseURLString: "http://192.168.1.4:8123"
        )
        #expect(authMessage == HomeProviderError.unauthorized.errorDescription)
    }

    @Test("LAN discovery drops external_url and rejects public, loopback, and non-.local hosts")
    func rejectsExternalPublicAndLoopbackTargets() {
        #expect(HADiscovery.buildInstance(
            instanceName: "Cloud Only",
            txt: ["external_url": "https://ha.example.com"],
            hostResolver: { _ in nil }
        ) == nil)

        #expect(HADiscovery.buildInstance(
            instanceName: "Public Internal",
            txt: [
                "internal_url": "http://8.8.8.8:8123",
                "base_url": "https://ha.example.com",
                "external_url": "https://ha.example.com",
            ],
            hostResolver: { _ in nil }
        ) == nil)

        #expect(HADiscovery.buildInstance(
            instanceName: "Loopback",
            txt: [
                "internal_url": "http://127.0.0.1:8123",
                "base_url": "http://localhost:8123",
            ],
            srvTarget: "localhost.",
            hostResolver: { _ in "127.0.0.1" }
        ) == nil)

        #expect(HADiscovery.buildInstance(
            instanceName: "Foreign SRV",
            txt: [:],
            srvTarget: "evil.example.com.",
            hostResolver: { _ in "192.168.1.88" }
        ) == nil)

        #expect(HADiscovery.buildInstance(
            instanceName: "Public Resolver Answer",
            txt: [:],
            srvTarget: "ha-box.local.",
            hostResolver: { _ in "8.8.8.8" }
        )?.baseURL == "http://ha-box.local:8123")

        let mdnsLocal = HADiscovery.buildInstance(
            instanceName: "LAN mDNS",
            txt: [
                "internal_url": "http://homeassistant.local:8123",
                "external_url": "https://ha.example.com",
            ],
            hostResolver: { _ in nil }
        )
        #expect(mdnsLocal?.baseURL == "http://homeassistant.local:8123")

        #expect(HADiscovery.isAllowedLANDiscoveryHost("192.168.1.25"))
        #expect(HADiscovery.isAllowedLANDiscoveryHost("ha-nas.local."))
        #expect(!HADiscovery.isAllowedLANDiscoveryHost("localhost"))
        #expect(!HADiscovery.isAllowedLANDiscoveryHost("localhost.local"))
        #expect(!HADiscovery.isAllowedLANDiscoveryHost("127.0.0.1"))
        #expect(!HADiscovery.isAllowedLANDiscoveryHost("192.0.2.10"))
        #expect(!HADiscovery.isAllowedLANDiscoveryHost("8.8.8.8"))
        #expect(!HADiscovery.isAllowedLANDiscoveryHost("example.com"))
    }

    @Test("ARP parser skips (incomplete) neighbor rows")
    func arpParserSkipsIncompleteEntries() {
        let arpSample = """
        ? (192.168.1.1) at 60:be:b4:8:e4:19 on en14 ifscope [ethernet]
        ? (192.168.1.4) at (incomplete) on en14 ifscope [ethernet]
        ? (192.168.1.167) at 0:11:32:f7:71:4c on en14 ifscope [ethernet]
        ? (192.168.1.212) at (INCOMPLETE) on en0 ifscope [ethernet]
        """
        #expect(HADiscovery.parseARPTableHosts(arpSample) == ["192.168.1.1", "192.168.1.167"])
    }

    @Test("Subnet candidate generator clamps to /24 or narrower, deduplicates, excludes non-RFC1918 and caps subnets")
    func subnetCandidateGeneration() {
        let interfaces: [HADiscovery.LANIPv4Interface] = [
            .init(name: "bridge100", address: "192.168.64.1", netmask: "255.255.255.248"),
            .init(name: "en13", address: "169.254.72.197", netmask: "255.255.0.0"),
            .init(name: "lo0", address: "127.0.0.1", netmask: "255.0.0.0"),
            .init(name: "en9", address: "203.0.113.10", netmask: "255.255.255.0"),
            .init(name: "en0", address: "192.168.1.181", netmask: "255.255.0.0"),
            .init(name: "en14", address: "192.168.1.107", netmask: "255.255.255.0"),
        ]
        let hosts = HADiscovery.subnetCandidateHosts(for: interfaces, excluding: ["192.168.1.1", "192.168.1.107"], maxSubnets: 4)
        #expect(hosts.count == 258 && hosts.first == "192.168.1.2" && hosts.contains("192.168.1.4"))
        #expect(!hosts.contains("192.168.1.1") && !hosts.contains("192.168.1.107") && !hosts.contains("192.168.1.0") && !hosts.contains("192.168.1.255"))
        #expect(Array(hosts.suffix(6)) == (1...6).map { "192.168.64.\($0)" })

        let capped = HADiscovery.subnetCandidateHosts(
            for: [
                .init(name: "en0", address: "172.16.1.5", netmask: "255.255.255.252"),
                .init(name: "en1", address: "172.16.2.5", netmask: "255.255.255.252"),
                .init(name: "en2", address: "172.16.3.5", netmask: "255.255.255.252"),
            ],
            maxSubnets: 2
        )
        #expect(capped == ["172.16.1.5", "172.16.1.6", "172.16.2.5", "172.16.2.6"])
    }

    @Test("Recognizes Home Assistant via manifest, /auth/providers, and /api/ signatures while rejecting non-HA servers")
    func robustHAResponseRecognition() async {
        let customManifest = Data(#"{"name":"My Smart Home","start_url":"/?homescreen=1","icons":[{"src":"/static/icons/favicon-192x192.png"}]}"#.utf8)
        let authProvidersOK = Data(#"[{"name":"Home Assistant Local","id":null,"type":"homeassistant"}]"#.utf8)
        let ha401Body = Data("401: Unauthorized".utf8)
        #expect(HADiscovery.isHomeAssistantManifest(customManifest))
        #expect(HADiscovery.isHomeAssistantAuthProvidersResponse(statusCode: 200, data: authProvidersOK))
        #expect(!HADiscovery.isHomeAssistantAuthProvidersResponse(statusCode: 404, data: authProvidersOK))
        #expect(!HADiscovery.isHomeAssistantAuthProvidersResponse(statusCode: 200, data: Data(#"[{"type":"oidc"}]"#.utf8)))
        #expect(HADiscovery.isHomeAssistantAPIResponse(statusCode: 401, headers: ["Server": "Python/3.13 aiohttp/3.11.11"], data: ha401Body))
        #expect(HADiscovery.isHomeAssistantAPIResponse(statusCode: 200, headers: [:], data: Data(#"{"message":"API running."}"#.utf8)))
        #expect(!HADiscovery.isHomeAssistantAPIResponse(statusCode: 401, headers: ["Server": "nginx/1.26.0"], data: ha401Body))
        #expect(!HADiscovery.isHomeAssistantAPIResponse(statusCode: 401, headers: ["Server": "Python/3.13 aiohttp/3.11.11"], data: Data("Forbidden".utf8)))

        let viaAuth = await HADiscovery.probeSingleCandidate("http://192.168.1.4:8123") { url in
            url.path == "/auth/providers"
                ? .init(statusCode: 200, headers: [:], data: authProvidersOK)
                : .init(statusCode: 404, headers: [:], data: Data())
        }
        #expect(viaAuth?.baseURL == "http://192.168.1.4:8123")

        let viaAPI401 = await HADiscovery.probeSingleCandidate("http://192.168.1.4:8123") { url in
            url.absoluteString.hasSuffix("/api/")
                ? .init(statusCode: 401, headers: ["Server": "Python/3.13 aiohttp/3.11.11"], data: ha401Body)
                : .init(statusCode: 404, headers: [:], data: Data())
        }
        #expect(viaAPI401?.baseURL == "http://192.168.1.4:8123")

        let requestedPaths = LockedPaths()
        let deadHost = await HADiscovery.probeSingleCandidate("http://192.168.1.99:8123") { url in
            requestedPaths.append(url.path)
            throw URLError(.cannotConnectToHost)
        }
        #expect(deadHost == nil && requestedPaths.snapshot() == ["/manifest.json"])

        let publicProbe = await HADiscovery.probeSingleCandidate("http://8.8.8.8:8123") { _ in
            Issue.record("Public host must never be probed")
            return .init(statusCode: 200, headers: [:], data: Data())
        }
        #expect(publicProbe == nil)

        let dnsRejected = await HADiscovery.probeSingleCandidate(
            "http://homeassistant.local:8123",
            validateAddress: { _ in throw HAEndpointResolutionError.publicAddressForLocalPlaintext },
            fetch: { _ in
                Issue.record("DNS-rejected .local host must never be fetched")
                return .init(statusCode: 200, headers: [:], data: Data())
            }
        )
        #expect(dnsRejected == nil)
    }

    @Test("LAN discovery sweeps active /24 subnet when mDNS and ARP miss, and skips sweep when mDNS hits")
    func discoverOnLANFallbackSweepOrchestration() async {
        let sweptHosts = LockedPaths()
        let foundViaSweep = await HADiscovery.discoverOnLAN(
            currentURLHint: nil,
            queryMDNS: { [] },
            queryARP: { ["192.168.1.1"] },
            activeInterfaces: { [.init(name: "en0", address: "192.168.1.107", netmask: "255.255.255.0")] },
            scanOpenPort: { hosts in
                hosts.forEach { sweptHosts.append($0) }
                return hosts.contains("192.168.1.4") ? ["192.168.1.4"] : []
            },
            probeURLs: { urls in
                urls.compactMap { $0 == "http://192.168.1.4:8123" ? HADiscoveredInstance(baseURL: $0, locationName: "Home Assistant", source: "HTTP") : nil }
            }
        )
        let swept = sweptHosts.snapshot()
        #expect(foundViaSweep.map(\.baseURL) == ["http://192.168.1.4:8123"] && swept.contains("192.168.1.4") && !swept.contains("192.168.1.1"))

        let skippedSweep = LockedPaths()
        let foundViaMDNS = await HADiscovery.discoverOnLAN(
            currentURLHint: nil,
            queryMDNS: { [HADiscoveredInstance(baseURL: "http://192.168.1.4:8123", locationName: "NAS HA", version: "2026.11.0", source: "mDNS")] },
            queryARP: { [] },
            activeInterfaces: { [.init(name: "en0", address: "192.168.1.107", netmask: "255.255.255.0")] },
            scanOpenPort: { hosts in hosts.forEach { skippedSweep.append($0) }; return [] },
            probeURLs: { _ in [] }
        )
        #expect(foundViaMDNS.map(\.baseURL) == ["http://192.168.1.4:8123"] && skippedSweep.snapshot().isEmpty)
    }
}

private final class LockedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}
