import Foundation
import MijiaCore

/// Turns live app state into the block a one-click feedback link carries into a GitHub issue (#29).
///
/// Kept out of the settings view so the privacy contract can be pinned by a test that first puts real
/// device names, room names, a LAN host and a token into the store: everything this composer reads is
/// either a count or a label from a closed set, so none of them can reach the URL.
enum FeedbackDiagnosticsComposer {
    @MainActor
    static func make(
        store: HomeStore,
        appVersion: String,
        osVersion: String,
        errorTimestamps: [Date],
        crashCount: Int,
        transport: DiagnosticsReportBuilder.TransportSummary?,
        platform: String = "macOS"
    ) -> FeedbackDiagnostics {
        var backends: [FeedbackBackendCount] = []
        for backend in [HomeBackend.xiaomiCloud, .homeAssistant] {
            let configured = backend == .xiaomiCloud ? store.hasMiSource : store.hasHASource
            guard configured else { continue }
            let matching = store.devices.filter {
                (store.deviceBackends[$0.id] ?? store.preferredLiveBackend) == backend
            }
            backends.append(
                FeedbackBackendCount(
                    label: backend.title,
                    deviceCount: matching.count,
                    onlineDeviceCount: matching.filter(\.isOnline).count
                )
            )
        }
        if backends.isEmpty {
            backends.append(
                FeedbackBackendCount(
                    label: store.connectionSourceSummary,
                    deviceCount: store.devices.count,
                    onlineDeviceCount: store.onlineDeviceCount
                )
            )
        }

        var signals: [FeedbackSignal] = []
        if !errorTimestamps.isEmpty {
            signals.append(FeedbackSignal(code: .errors, count: errorTimestamps.count))
        }
        if crashCount > 0 {
            signals.append(FeedbackSignal(code: .crashes, count: crashCount))
        }
        if let transport {
            if transport.isLocalNetworkBlocked {
                signals.append(FeedbackSignal(code: .localNetworkBlocked, count: 1))
            }
            if transport.cooldownDeviceCount > 0 {
                signals.append(FeedbackSignal(code: .lanCooldown, count: transport.cooldownDeviceCount))
            }
            if transport.cloudDeviceCount > 0 {
                signals.append(FeedbackSignal(code: .cloudFallback, count: transport.cloudDeviceCount))
            }
            if transport.blockedDeviceCount > 0 {
                signals.append(FeedbackSignal(code: .permissionBlocked, count: transport.blockedDeviceCount))
            }
        }

        return FeedbackDiagnostics(
            appVersion: appVersion,
            osVersion: osVersion,
            platform: platform,
            backends: backends,
            signals: signals,
            backendOption: FeedbackBackendOption.resolve(
                hasMiSource: store.hasMiSource,
                hasHomeAssistantSource: store.hasHASource,
                isDemo: store.homeBackend == .demo
            )
        )
    }
}
