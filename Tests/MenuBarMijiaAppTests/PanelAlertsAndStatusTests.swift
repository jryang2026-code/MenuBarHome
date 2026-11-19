import AppKit
import Carbon
import SwiftUI
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

extension PanelPresentationTests {
@Suite("WP2a Panel Alerts and Footer Connection Status", .serialized)
@MainActor
struct PanelAlertsAndStatusTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_729_000_000)

    private func makeIsolatedStore(
        backend: HomeBackend = .xiaomiCloud,
        hasMi: Bool = true,
        hasHA: Bool = false
    ) -> (store: HomeStore, suiteName: String) {
        let suiteName = "com.menubarmijia.tests.wp2a.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        ud.removePersistentDomain(forName: suiteName)
        ud.set(true, forKey: "onboarding_completed_v1")
        ud.set(backend.rawValue, forKey: "home_backend")
        if hasMi {
            _ = MiSessionStore.save(Self.validMiSession(), defaults: ud)
        }
        let store = HomeStore(
            provider: DemoHomeProvider(),
            defaultsSuiteName: suiteName
        )
        store.homeBackend = backend
        store.hasHASource = hasHA
        var connected: Set<HomeBackend> = []
        if hasMi { connected.insert(.xiaomiCloud) }
        if hasHA { connected.insert(.homeAssistant) }
        store.connectedBackends = connected
        return (store, suiteName)
    }

    private static func validMiSession(expiresAt: Date? = Date().addingTimeInterval(86_400 * 10)) -> MiSession {
        MiSession(
            userId: "123456",
            cUserId: "c123",
            ssecurity: Data(repeating: 7, count: 16).base64EncodedString(),
            serviceToken: "st-valid",
            expiresAt: expiresAt
        )
    }

    private func recordedSafety(id: String, title: String, turnOffCommand: DeviceCommand? = nil) -> PanelActivity {
        let alert = SafetyAlert(
            id: id,
            deviceId: "dev-\(id)",
            title: title,
            body: "\(title) body",
            turnOffCommand: turnOffCommand
        )
        let recorded = RecordedSafetyAlert(alert: alert, scope: "mi:cn:123456", date: Self.fixedNow)
        return PanelActivity(
            id: recorded.id,
            kind: .safety(recorded),
            date: Self.fixedNow,
            isDismissible: true
        )
    }

    @Test("Alert tiering pins hazards, doorbell, missed timers, active away-aware sensors, and high-power/long-run alerts while routing offline & low-battery into the 32pt ordinary capsule")
    func alertTieringAndAwayCondition() {
        let (store, suite) = makeIsolatedStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let smoke = recordedSafety(id: "sensor:smoke:s1#smoke", title: "厨房烟雾告警")
        let gas = recordedSafety(id: "sensor:gas:g1#gas", title: "厨房燃气告警")
        let leak = recordedSafety(id: "sensor:leak:l1#leak", title: "卫生间浸水告警")
        let ring = DoorbellRing(deviceId: "cam-1", entityId: "event.cam1_doorbell", firedAt: "2026-10-15T12:00:00Z")
        let doorbell = PanelActivity(
            id: ring.key,
            kind: .doorbell(ring),
            date: Self.fixedNow,
            isDismissible: true
        )
        let contact = recordedSafety(id: "sensor:contact:c1#contact", title: "大门门窗打开")
        let motion = recordedSafety(id: "sensor:motion:m1#motion", title: "玄关有人移动")
        let highPower = recordedSafety(
            id: "longrun:plug-1",
            title: "取暖器插座已开启超过 45 分钟",
            turnOffCommand: .setSwitch(entityId: "switch.plug1", isOn: false)
        )
        let longClimate = recordedSafety(
            id: "longrun:ac-1",
            title: "卧室空调已连续运行 4 小时",
            turnOffCommand: .setClimatePower(entityId: "climate.ac1", isOn: false, fallbackMode: "cool")
        )
        let offline = recordedSafety(id: "offline:light-1", title: "书房台灯已离线")
        let battery = recordedSafety(id: "battery:sensor-1", title: "温湿度计电量低 (10%)")

        store.setSensorAlertEnabled(.contact, true)
        store.setSensorAlertEnabled(.motion, true)
        store.sensorAlertsOnlyWhenAway = false

        // Pass non-urgent items before urgent items to verify urgent hazards (smoke/gas/leak) are ordered first in pinned.
        let all = [contact, motion, highPower, longClimate, doorbell, smoke, gas, leak, offline, battery]
        let tiered = ActivityStackPolicy.partition(activities: all, store: store)
        #expect(tiered.pinned.map(\.id) == [
            smoke.id, gas.id, leak.id,
            contact.id, motion.id, highPower.id, longClimate.id, doorbell.id,
        ])
        #expect(tiered.ordinary.map(\.id) == [offline.id, battery.id])

        // SensorAlertKind.parse parses only the 5 real kinds and returns nil for unknown prefixes.
        #expect(SensorAlertKind.parse(fromAlertId: smoke.id) == .smoke)
        #expect(SensorAlertKind.parse(fromAlertId: gas.id) == .gas)
        #expect(SensorAlertKind.parse(fromAlertId: leak.id) == .leak)
        #expect(SensorAlertKind.parse(fromAlertId: contact.id) == .contact)
        #expect(SensorAlertKind.parse(fromAlertId: motion.id) == .motion)
        #expect(SensorAlertKind.parse(fromAlertId: "sensor:lock:lk1#lock") == nil)
        #expect(SensorAlertKind.parse(fromAlertId: "offline:light-1") == nil)

        // Turning on sensorAlertsOnlyWhenAway while Mac never went away demotes away-honoring contact/motion
        // from pinned top cards while keeping smoke/gas/leak/doorbell/highPower/longClimate pinned.
        store.sensorAlertsOnlyWhenAway = true
        store.awayGap.includesAway = false
        let tieredAtHome = ActivityStackPolicy.partition(activities: all, store: store)
        let atHomePinnedIds = tieredAtHome.pinned.map(\.id)
        #expect(!atHomePinnedIds.contains(contact.id))
        #expect(!atHomePinnedIds.contains(motion.id))
        #expect(atHomePinnedIds.contains(smoke.id))
        #expect(atHomePinnedIds.contains(gas.id))
        #expect(atHomePinnedIds.contains(leak.id))
        #expect(atHomePinnedIds.contains(doorbell.id))
        #expect(atHomePinnedIds.contains(highPower.id))
        #expect(atHomePinnedIds.contains(longClimate.id))

        // When awayGap.includesAway is true, contact and motion are pinned again.
        store.awayGap.includesAway = true
        let tieredAway = ActivityStackPolicy.partition(activities: all, store: store)
        let awayPinnedIds = tieredAway.pinned.map(\.id)
        #expect(awayPinnedIds.contains(contact.id))
        #expect(awayPinnedIds.contains(motion.id))

        // Disabling contact sensor alert removes contact from pinned top cards even when awayGap is open.
        store.setSensorAlertEnabled(.contact, false)
        let tieredContactOff = ActivityStackPolicy.partition(activities: all, store: store)
        let contactOffPinnedIds = tieredContactOff.pinned.map(\.id)
        #expect(!contactOffPinnedIds.contains(contact.id))
        #expect(contactOffPinnedIds.contains(motion.id))
    }

    @Test("Classic activity stack caps height at expandedViewportHeight when 6 pinned alerts + 2 missed timers are present and keeps intrinsic height when small")
    func classicActivityStackBoundedHeight() {
        _ = NSApplication.shared
        let (store, suite) = makeIsolatedStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let pinnedAlerts = [
            recordedSafety(id: "sensor:smoke:s1#smoke", title: "厨房烟雾告警"),
            recordedSafety(id: "sensor:gas:g1#gas", title: "厨房燃气告警"),
            recordedSafety(id: "sensor:leak:l1#leak", title: "卫生间浸水告警"),
            recordedSafety(id: "longrun:plug-1", title: "取暖器插座已开启超过 45 分钟", turnOffCommand: .setSwitch(entityId: "switch.plug1", isOn: false)),
            recordedSafety(id: "longrun:ac-1", title: "卧室空调已连续运行 4 小时", turnOffCommand: .setClimatePower(entityId: "climate.ac1", isOn: false, fallbackMode: "cool")),
            recordedSafety(id: "longrun:kettle-1", title: "厨房电水壶持续高功率运行", turnOffCommand: .setSwitch(entityId: "switch.kettle1", isOn: false)),
        ]
        let missedTimers = [
            ScheduledCommand(
                id: UUID(),
                reply: "关闭客厅吸顶灯",
                fireDate: Self.fixedNow.addingTimeInterval(-120),
                plan: IntentPlan(intents: [DeviceIntent(targetId: "d1", operation: .power(false))], reply: "关闭客厅吸顶灯", source: .local),
                sourceScope: store.connectionScopeIdentifier
            ),
            ScheduledCommand(
                id: UUID(),
                reply: "关闭卧室空调",
                fireDate: Self.fixedNow.addingTimeInterval(-60),
                plan: IntentPlan(intents: [DeviceIntent(targetId: "d2", operation: .power(false))], reply: "关闭卧室空调", source: .local),
                sourceScope: store.connectionScopeIdentifier
            ),
        ]

        let compactCap: CGFloat = 230
        let heavyStack = ClassicActivityStackView(
            activities: pinnedAlerts,
            missedTimers: missedTimers,
            store: store,
            isExpanded: .constant(false),
            expandedViewportHeight: compactCap,
            dismiss: { _ in },
            clear: {},
            label: { _ in "Alert" },
            content: { activity in
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(describing: activity.id)).font(.headline)
                    Text("Detailed safety alert description line").font(.caption)
                }
                .padding(10)
            }
        )
        .frame(width: 340)
        let heavyHost = NSHostingView(rootView: heavyStack)
        heavyHost.layoutSubtreeIfNeeded()
        #expect(heavyHost.fittingSize.height == compactCap)

        let singleStack = ClassicActivityStackView(
            activities: [pinnedAlerts[0]],
            missedTimers: [],
            store: store,
            isExpanded: .constant(false),
            expandedViewportHeight: compactCap,
            dismiss: { _ in },
            clear: {},
            label: { _ in "Alert" },
            content: { _ in Text("Single Alert").padding(10) }
        )
        .frame(width: 340)
        let singleHost = NSHostingView(rootView: singleStack)
        singleHost.layoutSubtreeIfNeeded()
        #expect(singleHost.fittingSize.height > 0)
        #expect(singleHost.fittingSize.height < 100)

        // Missed timers alone (with zero safety/notice activities) render in both Classic and Liquid Glass activity stacks.
        for theme in PanelTheme.allCases {
            let missedOnlyStack = ActivityStackView(
                activities: [],
                missedTimers: missedTimers,
                store: store,
                isExpanded: .constant(false),
                expandedViewportHeight: theme == .classic ? compactCap : nil,
                theme: theme,
                dismiss: { _ in },
                clear: {},
                label: { _ in "" },
                content: { _ in EmptyView() }
            )
            .frame(width: 340)
            let missedOnlyHost = NSHostingView(rootView: missedOnlyStack)
            missedOnlyHost.layoutSubtreeIfNeeded()
            #expect(missedOnlyHost.fittingSize.height > 80)
        }
    }

    @Test("Ordinary reminder capsule summary and one-click clear leave pinned cards and missed timers untouched")
    func ordinaryCapsuleSummaryAndClearIsolation() {
        let (store, suite) = makeIsolatedStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        store.devices = [
            SmartDevice(id: "s1", name: "烟雾传感器", roomId: "k", roomName: "厨房", model: "lumi.sensor_smoke", isOnline: true, kind: .sensor(SensorSpec())),
            SmartDevice(id: "d1", name: "客厅吸顶灯", roomId: "l", roomName: "客厅", model: "yeelink.light.ceiling", isOnline: false, kind: .light(LightSpec(entityId: "light.d1", isOn: false))),
            SmartDevice(id: "d2", name: "卧室传感器", roomId: "b", roomName: "卧室", model: "miaomiaoce.sensor_ht", isOnline: true, kind: .sensor(SensorSpec(battery: 9))),
        ]

        let smokeAlert = SafetyAlert(id: "sensor:smoke:s1#smoke", deviceId: "s1", title: "厨房烟雾告警", body: "body")
        let offlineAlert = SafetyAlert(id: "offline:d1", deviceId: "d1", title: "客厅吸顶灯已离线", body: "body")
        let batteryAlert = SafetyAlert(id: "battery:d2", deviceId: "d2", title: "卧室传感器电量低 (9%)", body: "body")

        store.recordSafetyAlerts([smokeAlert, offlineAlert, batteryAlert], now: Self.fixedNow)
        let missed = ScheduledCommand(
            id: UUID(),
            reply: "关闭客厅吸顶灯",
            fireDate: Self.fixedNow.addingTimeInterval(-60),
            plan: IntentPlan(
                intents: [DeviceIntent(targetId: "d1", operation: .power(false))],
                reply: "关闭客厅吸顶灯",
                source: .local
            ),
            sourceScope: store.connectionScopeIdentifier
        )
        store.missedScheduledCommands = [missed]

        let labels = ["客厅吸顶灯已离线", "卧室传感器电量低 (9%)"]
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(ActivityStackPolicy.ordinaryCapsuleSummary(labels: ["客厅吸顶灯已离线"]) == "客厅吸顶灯已离线")
            #expect(ActivityStackPolicy.ordinaryCapsuleSummary(labels: labels) == "客厅吸顶灯已离线 等 2 条提醒")
        }
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(ActivityStackPolicy.ordinaryCapsuleSummary(labels: labels) == "客厅吸顶灯已离线 等 2 條提醒")
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(ActivityStackPolicy.ordinaryCapsuleSummary(labels: labels) == "客厅吸顶灯已离线 and 1 more")
        }

        let before = ActivityStackPolicy.partition(activities: store.panelActivities, store: store)
        #expect(before.pinned.count == 1)
        #expect(before.ordinary.count == 2)

        // Clearing ordinary reminders must only dismiss the ordinary tier, keeping pinned smoke & missed timer intact.
        for item in before.ordinary {
            store.dismissActivity(item)
        }
        let after = ActivityStackPolicy.partition(activities: store.panelActivities, store: store)
        #expect(after.ordinary.isEmpty)
        #expect(after.pinned.map(\.id) == ["sensor:smoke:s1#smoke"])
        #expect(store.missedScheduledCommands.map(\.id) == [missed.id])
    }

    @Test("A sole source shows its real disconnect instead of connecting forever")
    func soleSourceKeepsDisconnectedStatus() {
        let (store, suite) = makeIsolatedStore(backend: .homeAssistant, hasMi: false, hasHA: true)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.connectedBackends = []
        store.sourceStatuses = [:]
        store.connectionStatus = .disconnected("401 invalid token")

        let status = PanelConnectionStatusPresentation.resolve(store: store)
        #expect(status.badge == .reauthRequired)
        #expect(status.sources.first { $0.id == "ha" }?.badge == .reauthRequired)
    }

    @Test("Footer connection status copy follows §4.1 and §4.2 across zh-Hans, zh-Hant, and en")
    func footerConnectionStatusCopy() {
        // 1. All healthy
        do {
            let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: true, hasHA: true)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            store.connectionStatus = .connected
            store.sourceStatuses = [.xiaomiCloud: .connected, .homeAssistant: .connected]

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "设备同步正常")
                #expect(status.badge == .online)
                #expect(!status.iconName.isEmpty)
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "裝置同步正常")
            }
            L10n.$overrideLanguage.withValue(.en) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Devices synced")
            }
        }

        // 2. Partial unavailable: Xiaomi down, HA online -> "米家暂不可用，部分设备暂无数据"
        do {
            let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: true, hasHA: true)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            store.connectionStatus = .connected
            store.sourceStatuses = [.xiaomiCloud: .disconnected("timeout"), .homeAssistant: .connected]

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "米家暂不可用，部分设备暂无数据")
                #expect(status.badge == .degraded)
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "米家暫不可用，部分裝置暫無資料")
            }
            L10n.$overrideLanguage.withValue(.en) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Xiaomi Home unavailable; some devices have no data")
            }
        }

        // 3. Partial unavailable: HA down, Xiaomi online -> "Home Assistant 暂不可用，部分设备暂无数据"
        do {
            let (store, suite) = makeIsolatedStore(backend: .homeAssistant, hasMi: true, hasHA: true)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            store.connectionStatus = .connected
            store.sourceStatuses = [.xiaomiCloud: .connected, .homeAssistant: .disconnected("unreachable")]

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Home Assistant 暂不可用，部分设备暂无数据")
                #expect(status.badge == .degraded)
            }
        }

        // 3b. Dual-source with one online and the other still connecting must report connecting rather than false degraded "暂不可用"
        do {
            let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: true, hasHA: true)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            store.connectionStatus = .connected
            store.sourceStatuses = [.xiaomiCloud: .connecting, .homeAssistant: .connected]

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.badge == .connecting)
                #expect(status.text == "正在连接米家…")
            }

            store.sourceStatuses = [.xiaomiCloud: .connected, .homeAssistant: .connecting]
            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.badge == .connecting)
                #expect(status.text == "正在连接 Home Assistant…")
            }
        }

        // 3c. Dual-source with HA credentials rejected (401) while Xiaomi is online must say the key needs
        // updating and offer the connection entry, like the HA-only path, not a transient outage.
        do {
            let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: true, hasHA: true)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            store.connectionStatus = .connected
            store.sourceStatuses = [.xiaomiCloud: .connected, .homeAssistant: .disconnected("401 Unauthorized")]

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Home Assistant 凭据或地址需更新")
                #expect(status.badge == .reauthRequired)
                #expect(status.inlineActionTitle == "查看连接")
                #expect(status.inlineAction == .openDetail)
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Home Assistant 憑據或位址需更新")
                #expect(status.inlineActionTitle == "查看連線")
            }
            L10n.$overrideLanguage.withValue(.en) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Home Assistant credentials or address need attention")
                #expect(status.inlineActionTitle == "Check Connection")
            }
        }

        // 4. Only LG TV online while Xiaomi is unavailable -> "米家暂不可用，LG 电视仍可控制"
        do {
            let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: true, hasHA: false)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            store.connectionStatus = .disconnected("offline")
            store.sourceStatuses = [.xiaomiCloud: .disconnected("offline")]
            store.lgConfig = LGWebOSConfig(isEnabled: true, host: "192.168.1.55", clientKey: "lg-key")
            store.devices = [
                SmartDevice(
                    id: LGWebOSProtocol.deviceId,
                    name: "客厅 LG 电视",
                    roomId: "living",
                    roomName: "客厅",
                    model: "lg.webos.tv",
                    isOnline: true,
                    kind: .tv(TVSpec(mediaEntityId: LGWebOSProtocol.mediaEntityId, state: "on", volumePercent: 20))
                )
            ]

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "米家暂不可用，LG 电视仍可控制")
                #expect(status.badge == .degraded)
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "米家暫不可用，LG 電視仍可控制")
            }
            L10n.$overrideLanguage.withValue(.en) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Xiaomi Home unavailable; LG TV still controllable")
            }
        }

        // 5. Demo mode -> "示例家庭，不会控制真实设备" + "连接真实家庭"
        do {
            let (store, suite) = makeIsolatedStore(backend: .demo, hasMi: false, hasHA: false)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "示例家庭，不会控制真实设备")
                #expect(status.inlineActionTitle == "连接真实家庭")
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "示例家庭，不會控制真實裝置")
                #expect(status.inlineActionTitle == "連接真實家庭")
            }
            L10n.$overrideLanguage.withValue(.en) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Demo home; won't control real devices")
                #expect(status.inlineActionTitle == "Connect a Real Home")
            }
        }

        // 6. Not connected / not configured -> "还没连接家居平台" + "去连接"
        do {
            let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: false, hasHA: false)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "还没连接家居平台")
                #expect(status.inlineActionTitle == "去连接")
                #expect(status.badge == .notConfigured)
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "還沒連接家居平台")
                #expect(status.inlineActionTitle == "去連接")
            }
            L10n.$overrideLanguage.withValue(.en) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "No smart home platform connected")
                #expect(status.inlineActionTitle == "Connect")
            }

            // 6b. Uncertain config/credential read -> fail-closed retryable status (never "not connected")
            store.identityMigrationDiagnostic = "vault_read_failed"
            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "配置或凭据读取受阻")
                #expect(status.inlineActionTitle == "重试读取")
                #expect(status.inlineAction == .retryIdentityMigration)
                #expect(status.badge == .degraded)
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "設定或憑據讀取受阻")
                #expect(status.inlineActionTitle == "重試讀取")
            }
            L10n.$overrideLanguage.withValue(.en) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Could not read settings or credentials")
                #expect(status.inlineActionTitle == "Retry Reading")
            }
        }

        // 7. Credential expired -> "米家登录已过期" + inline action "重新扫码", while primary status button still opens detail popover
        do {
            let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: true, hasHA: false)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let expiredSession = Self.validMiSession(expiresAt: Self.fixedNow.addingTimeInterval(-3600))
            store.miAccounts = [MiAccount(session: expiredSession)]
            store.miSessionExpiresAt = expiredSession.expiresAt

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "米家登录已过期")
                #expect(status.inlineActionTitle == "重新扫码")
                #expect(status.inlineAction == .presentMiReauth)
                #expect(status.badge == .reauthRequired)
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "米家登入已過期")
                #expect(status.inlineActionTitle == "重新掃碼")
            }
            L10n.$overrideLanguage.withValue(.en) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Xiaomi Home session expired")
                #expect(status.inlineActionTitle == "Re-scan")
            }
        }

        // 8. HA plaintext http declined -> dedicated status text + inline action to open connection settings
        do {
            let (store, suite) = makeIsolatedStore(backend: .homeAssistant, hasMi: false, hasHA: true)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            store.haPlaintextPrompt = .declined("http://example.com:8123")

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "未连接 Home Assistant（已拒绝明文 http）")
                #expect(status.inlineActionTitle == "改用 https…")
                #expect(status.inlineAction == .openConnectionSettings)
                #expect(status.badge == .reauthRequired)
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "未連接 Home Assistant（已拒絕明文 http）")
                #expect(status.inlineActionTitle == "改用 https…")
            }
            L10n.$overrideLanguage.withValue(.en) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Home Assistant not connected (plaintext http declined)")
                #expect(status.inlineActionTitle == "Use https…")
            }
        }
    }

    @Test("Ordinary reminder capsule's xmark is announced as clearing all reminders, not collapsing, in all three languages")
    func ordinaryCapsuleClearAccessibilityLabel() {
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(ActivityStackPolicy.ordinaryClearAccessibilityLabel() == "清除全部普通提醒")
        }
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(ActivityStackPolicy.ordinaryClearAccessibilityLabel() == "清除全部普通提醒")
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(ActivityStackPolicy.ordinaryClearAccessibilityLabel() == "Dismiss all reminders")
        }
    }

    @Test("Connection status detail provides actual per-source online state, settings entry, and keyboard routing for Tab, Return, Space, and Esc")
    func statusDetailAndKeyboardEscapeRouting() {
        let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: true, hasHA: true)
        defer {
            PanelConnectionDetailState.shared.dismiss(restoreFocus: false)
            PanelConnectionDetailState.shared.clearStatusControlFocus()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        store.connectionStatus = .connected
        store.sourceStatuses = [.xiaomiCloud: .connected, .homeAssistant: .disconnected("502 Bad Gateway")]

        L10n.$overrideLanguage.withValue(.zhHans) {
            let presentation = PanelConnectionStatusPresentation.resolve(store: store)
            #expect(presentation.sources.count == 2)
            #expect(presentation.sources.first(where: { $0.id == "mi" })?.isOnline == true)
            #expect(presentation.sources.first(where: { $0.id == "ha" })?.isOnline == false)
        }

        func route(_ key: PanelKeyRouter.Key, _ context: PanelKeyRouter.Context) -> PanelKeyRouter.Action {
            PanelKeyRouter.beforeSearch(key, context) ?? PanelKeyRouter.afterSearch(key, context)
        }

        // 1. When a device card is focused, Tab moves focus to the footer connection status control while device card keys stay intact.
        let deviceFocusedContext = PanelKeyRouter.Context(hasFocusedDevice: true)
        #expect(route(PanelKeyRouter.Key(code: kVK_UpArrow), deviceFocusedContext) == .moveFocus(-1))
        #expect(route(PanelKeyRouter.Key(code: kVK_DownArrow), deviceFocusedContext) == .moveFocus(1))
        #expect(route(PanelKeyRouter.Key(code: kVK_LeftArrow), deviceFocusedContext) == .adjustFocusedDevice(-1))
        #expect(route(PanelKeyRouter.Key(code: kVK_RightArrow), deviceFocusedContext) == .adjustFocusedDevice(1))
        #expect(route(PanelKeyRouter.Key(code: kVK_Space, characters: " "), deviceFocusedContext) == .toggleFocusedDevice)
        #expect(route(PanelKeyRouter.Key(code: kVK_Return), deviceFocusedContext) == .toggleFocusedDevice)
        #expect(route(PanelKeyRouter.Key(code: kVK_Tab), deviceFocusedContext) == .focusConnectionStatus)

        // 2. When the footer connection status control is focused, Return and Space pass through to activate it,
        // Esc clears status focus, Tab cycles back to rooms, and ↑/↓ move back into device cards.
        let statusFocusedContext = PanelKeyRouter.Context(isConnectionStatusFocused: true)
        #expect(route(PanelKeyRouter.Key(code: kVK_Return), statusFocusedContext) == .passThrough)
        #expect(route(PanelKeyRouter.Key(code: kVK_ANSI_KeypadEnter), statusFocusedContext) == .passThrough)
        #expect(route(PanelKeyRouter.Key(code: kVK_Space, characters: " "), statusFocusedContext) == .passThrough)
        #expect(route(PanelKeyRouter.Key(code: kVK_Escape), statusFocusedContext) == .clearConnectionStatusFocus)
        #expect(route(PanelKeyRouter.Key(code: kVK_UpArrow), statusFocusedContext) == .moveFocus(-1))
        #expect(route(PanelKeyRouter.Key(code: kVK_DownArrow), statusFocusedContext) == .moveFocus(1))
        #expect(route(PanelKeyRouter.Key(code: kVK_Tab), statusFocusedContext) == .cycleRoom(1))

        // 2b. A digit while the status control is focused selects the device and hands focus over to it,
        // so the Return/Space that follows toggles the device instead of opening the connection popover.
        #expect(route(PanelKeyRouter.Key(code: kVK_ANSI_2, characters: "2"), statusFocusedContext) == .selectQuickIndexClearingStatusFocus(2))
        #expect(route(PanelKeyRouter.Key(code: kVK_ANSI_2, characters: "2"), PanelKeyRouter.Context()) == .selectQuickIndex(2))

        // 3. Tab without device focus cycles through rooms and includes connection status at the wrap boundary.
        store.rooms = [
            RoomArea(id: "living", name: "客厅"),
            RoomArea(id: "bed", name: "卧室"),
        ]
        store.selectRoom(nil)
        PanelConnectionDetailState.shared.clearStatusControlFocus()

        HotkeyAndNotificationManager.shared.cycleRoomOrConnectionStatus(delta: 1, store: store)
        #expect(store.selectedRoomId == "living")
        #expect(!PanelConnectionDetailState.shared.isStatusControlFocused)

        HotkeyAndNotificationManager.shared.cycleRoomOrConnectionStatus(delta: 1, store: store)
        #expect(store.selectedRoomId == "bed")
        #expect(!PanelConnectionDetailState.shared.isStatusControlFocused)

        HotkeyAndNotificationManager.shared.cycleRoomOrConnectionStatus(delta: 1, store: store)
        #expect(PanelConnectionDetailState.shared.isStatusControlFocused)

        HotkeyAndNotificationManager.shared.cycleRoomOrConnectionStatus(delta: 1, store: store)
        #expect(!PanelConnectionDetailState.shared.isStatusControlFocused)
        #expect(store.selectedRoomId == nil)

        // 4. When connection detail popover is open, Esc closes it before search or device shortcuts,
        // and Return, Space, Tab, and arrows pass through before search can swallow them.
        let contextWithDetail = PanelKeyRouter.Context(
            isShowingConnectionDetail: true,
            hasExpandedDevice: true,
            hasFocusedDevice: true
        )
        #expect(PanelKeyRouter.beforeSearch(PanelKeyRouter.Key(code: kVK_Escape), contextWithDetail) == .dismissConnectionDetail)
        #expect(PanelKeyRouter.beforeSearch(PanelKeyRouter.Key(code: kVK_Return), contextWithDetail) == .passThrough)
        #expect(PanelKeyRouter.beforeSearch(PanelKeyRouter.Key(code: kVK_Space, characters: " "), contextWithDetail) == .passThrough)
        #expect(PanelKeyRouter.beforeSearch(PanelKeyRouter.Key(code: kVK_Tab), contextWithDetail) == .passThrough)
        #expect(PanelKeyRouter.beforeSearch(PanelKeyRouter.Key(code: kVK_DownArrow), contextWithDetail) == .passThrough)
    }

    @Test("Footer connection status handles all-disabled, dual-source Mi-disabled, and partial Mi session expiry calmly")
    func footerDisabledAndPartialMiAccountStates() {
        // (a) Single Xiaomi account disabled -> calm turned-off copy + openConnectionSettings, no fault badge
        do {
            let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: true, hasHA: false)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let accountId = store.miAccounts[0].id
            store.setMiAccountEnabled(false, id: accountId)

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "连接已停用 · 点此重新启用")
                #expect(status.badge == .turnedOff)
                #expect(status.inlineAction == .openConnectionSettings)
                #expect(status.inlineActionTitle == "去启用")
                #expect(status.sources.first(where: { $0.id == "mi" })?.badge == .turnedOff)
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "連線已停用 · 點此重新啟用")
                #expect(status.inlineActionTitle == "去啟用")
            }
            L10n.$overrideLanguage.withValue(.en) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Connections turned off · Turn one back on")
                #expect(status.inlineActionTitle == "Turn On")
            }
        }

        // (b) Dual-source with Xiaomi disabled + Home Assistant online -> "设备同步正常" (.online), not stuck on connecting
        do {
            let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: true, hasHA: true)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            store.serverURLString = "http://192.168.1.10:8123"
            let accountId = store.miAccounts[0].id
            store.setMiAccountEnabled(false, id: accountId)
            store.connectedBackends = [.homeAssistant]
            store.sourceStatuses = [.homeAssistant: .connected]
            store.connectionStatus = .connected

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "设备同步正常")
                #expect(status.badge == .online)
                #expect(status.inlineAction == nil)
                #expect(status.sources.first(where: { $0.id == "mi" })?.badge == .turnedOff)
                #expect(status.sources.first(where: { $0.id == "mi" })?.statusText == "连接已停用")
                #expect(status.sources.first(where: { $0.id == "ha" })?.badge == .online)
            }
        }

        // (c) Two Xiaomi accounts: valid Account A disabled + expired Account B enabled -> .reauthRequired
        do {
            let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: false, hasHA: false)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let validA = MiAccount(session: MiSession(
                userId: "10001", cUserId: "ca", ssecurity: "c2VjcmV0", serviceToken: "tok-a",
                region: "cn", expiresAt: Self.fixedNow.addingTimeInterval(86_400 * 30)
            ))
            let expiredB = MiAccount(session: MiSession(
                userId: "20002", cUserId: "cb", ssecurity: "c2VjcmV0", serviceToken: "tok-b",
                region: "de", expiresAt: Self.fixedNow.addingTimeInterval(-3600)
            ))
            store.miAccounts = [validA, expiredB]
            store.registerNewlyConfiguredScope(validA.id, connection: .xiaomiCloud)
            store.registerNewlyConfiguredScope(expiredB.id, connection: .xiaomiCloud)
            store.setMiAccountEnabled(false, id: validA.id)

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.badge == .reauthRequired)
                #expect(status.text == "米家登录已过期")
                #expect(status.inlineAction == .presentMiReauth)
            }
        }
    }

    @Test("DisableConnectionConfirmation list separator and Add Account Traditional Chinese copy match locale rules")
    func disableConfirmationListSeparatorAndZhHantAddAccountCopy() {
        let account = MiAccount(session: Self.validMiSession())
        let confirmation = MiAccountSection.DisableConnectionConfirmation(
            account: account,
            itemsToPause: [
                AffectedReferenceItem(
                    kind: .waitingTimer, id: "t1", name: "Timer One",
                    connectionScopes: [account.id], affectedTargetIds: ["d1"],
                    affectedCapabilities: [.connection(.xiaomiCloud)]
                ),
                AffectedReferenceItem(
                    kind: .automationRule, id: "r1", name: "Rule Two",
                    connectionScopes: [account.id], affectedTargetIds: ["d1"],
                    affectedCapabilities: [.connection(.xiaomiCloud)]
                ),
            ],
            generation: 1
        )

        L10n.$overrideLanguage.withValue(.en) {
            #expect(confirmation.messageText.contains("Timer One, Rule Two"))
            #expect(!confirmation.messageText.contains("、"))
        }
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(confirmation.messageText.contains("Timer One、Rule Two"))
        }
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(L10n.tr("添加账号", "Add Account") == "新增帳號")
        }
    }
}
}
