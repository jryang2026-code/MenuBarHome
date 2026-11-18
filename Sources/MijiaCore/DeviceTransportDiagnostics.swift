import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(Network)
import Network
#endif

public enum LocalNetworkBlockedFeature: String, Codable, Hashable, Sendable, CaseIterable { case xiaomiLAN, homeAssistant, lgWebOS }
public enum DeviceTransportRoute: String, Codable, Equatable, Sendable, CaseIterable { case lan, cloud, cooldown, localNetworkBlocked }

public enum LocalNetworkPermissionClassifier {
    public static let dnsPolicyDeniedCode: Int32 = -65570, dnsNoAuthCode: Int32 = -65555
    public static func isDeniedPOSIXCode(_ code: Int32) -> Bool { code == EPERM || code == EACCES }
    public static func isDeniedDNSCode(_ code: Int32) -> Bool { code == dnsPolicyDeniedCode || code == dnsNoAuthCode }

    #if canImport(Network)
    public static func isDeniedNWConnection(error: NWError?, unsatisfiedReason: NWPath.UnsatisfiedReason?) -> Bool {
        if unsatisfiedReason == .localNetworkDenied { return true }
        switch error {
        case .posix(let code)?: return code == .EPERM || code == .EACCES
        case .dns(let dnsCode)?: return isDeniedDNSCode(Int32(dnsCode))
        default: return false
        }
    }
    #endif

    public static func isDeniedConnectionError(_ error: any Error, targetHost: String?, isGeneralNetworkSatisfied: Bool = true) -> Bool {
        if (error as? MiIOError) == .localNetworkDenied { return true }
        #if canImport(Network)
        if let nwError = error as? NWError, isDeniedNWConnection(error: nwError, unsatisfiedReason: nil) { return true }
        #endif
        var current: NSError? = error as NSError
        for _ in 0..<8 {
            guard let nsError = current else { break }
            let code32 = Int32(truncatingIfNeeded: nsError.code)
            if (nsError.domain == NSPOSIXErrorDomain && isDeniedPOSIXCode(code32)) || isDeniedDNSCode(code32) { return true }
            if let sc = (nsError.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber)?.intValue {
                let sc32 = Int32(truncatingIfNeeded: sc)
                let sd = (nsError.userInfo["_kCFStreamErrorDomainKey"] as? NSNumber)?.intValue
                if (sd == 1 && isDeniedPOSIXCode(sc32)) || isDeniedDNSCode(sc32) { return true }
            }
            if nsError.domain == NSURLErrorDomain, nsError.code == URLError.notConnectedToInternet.rawValue,
               isGeneralNetworkSatisfied, isLocalTargetHost(targetHost) { return true }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private static func isLocalTargetHost(_ rawHost: String?) -> Bool {
        guard var host = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !host.isEmpty else { return false }
        while host.hasSuffix(".") { host.removeLast() }
        return HADiscovery.isPrivateLANIPv4(host) || LocalMiIOClient.isPrivateRFC1918IPv4(host) || (host.hasSuffix(".local") && host != "localhost.local")
    }
}

public struct DeviceTransportDiagnostics: Codable, Equatable, Sendable {
    public var route: DeviceTransportRoute
    public var rttMs: Int?
    public var consecutiveFailures: Int
    public var usedBroadcastRecovery: Bool

    public init(route: DeviceTransportRoute, rttMs: Int? = nil, consecutiveFailures: Int = 0, usedBroadcastRecovery: Bool = false) {
        self.route = route; self.rttMs = rttMs; self.consecutiveFailures = consecutiveFailures; self.usedBroadcastRecovery = usedBroadcastRecovery
    }

    public static func quantizeRTT(_ rawMilliseconds: Int) -> Int {
        let clamped = max(1, rawMilliseconds)
        return clamped < 5 ? clamped : ((clamped + 2) / 5) * 5
    }
}

extension DiagnosticsReportBuilder {
    public struct TransportSummary: Equatable, Sendable {
        public var lanDeviceCount, cloudDeviceCount, cooldownDeviceCount, blockedDeviceCount, broadcastRecoveredCount: Int
        public var medianLANRTTMs: Int?
        public var isLocalNetworkBlocked: Bool

        public init(
            lanDeviceCount: Int, cloudDeviceCount: Int, cooldownDeviceCount: Int = 0,
            blockedDeviceCount: Int = 0, broadcastRecoveredCount: Int = 0,
            medianLANRTTMs: Int? = nil, isLocalNetworkBlocked: Bool = false
        ) {
            self.lanDeviceCount = lanDeviceCount; self.cloudDeviceCount = cloudDeviceCount
            self.cooldownDeviceCount = cooldownDeviceCount; self.blockedDeviceCount = blockedDeviceCount
            self.broadcastRecoveredCount = broadcastRecoveredCount; self.medianLANRTTMs = medianLANRTTMs
            self.isLocalNetworkBlocked = isLocalNetworkBlocked
        }
    }
}

public enum DeviceTransportSummary {
    public static func summarize(
        _ diagnostics: [String: DeviceTransportDiagnostics], localNetworkBlocks: Set<LocalNetworkBlockedFeature> = []
    ) -> DiagnosticsReportBuilder.TransportSummary? {
        if diagnostics.isEmpty && localNetworkBlocks.isEmpty { return nil }
        var lan = 0, cloud = 0, cooldown = 0, blocked = 0, recovered = 0, lanRTTs: [Int] = []
        for diag in diagnostics.values {
            if diag.usedBroadcastRecovery { recovered += 1 }
            switch diag.route {
            case .lan: lan += 1; if let rtt = diag.rttMs { lanRTTs.append(rtt) }
            case .cloud: cloud += 1
            case .cooldown: cooldown += 1
            case .localNetworkBlocked: blocked += 1
            }
        }
        lanRTTs.sort()
        let medianRTT: Int? = lanRTTs.isEmpty ? nil : (lanRTTs.count % 2 == 1 ? lanRTTs[lanRTTs.count / 2] : (lanRTTs[lanRTTs.count / 2 - 1] + lanRTTs[lanRTTs.count / 2]) / 2)
        return DiagnosticsReportBuilder.TransportSummary(
            lanDeviceCount: lan, cloudDeviceCount: cloud, cooldownDeviceCount: cooldown, blockedDeviceCount: blocked,
            broadcastRecoveredCount: recovered, medianLANRTTMs: medianRTT, isLocalNetworkBlocked: !localNetworkBlocks.isEmpty || blocked > 0
        )
    }
}
