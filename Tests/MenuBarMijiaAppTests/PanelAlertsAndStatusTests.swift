import AppKit
import Carbon
import SwiftUI
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

@Suite("WP2a Panel Alerts and Footer Connection Status")
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
        let lock = recordedSafety(id: "sensor:lock:lk1#lock", title: "门锁异常")
        let vibration = recordedSafety(id: "sensor:vibration:v1#vibration", title: "窗户震动")
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

        let all = [smoke, gas, leak, doorbell, contact, motion, lock, vibration, highPower, longClimate, offline, battery]
        let tiered = ActivityStackPolicy.partition(activities: all, store: store)
        #expect(tiered.pinned.map(\.id) == [
            smoke.id, gas.id, leak.id, doorbell.id,
            contact.id, motion.id, lock.id, vibration.id,
            highPower.id, longClimate.id,
        ])
        #expect(tiered.ordinary.map(\.id) == [offline.id, battery.id])

        // Turning on sensorAlertsOnlyWhenAway while Mac never went away demotes away-honoring contact/motion/vibration
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
        }

        // 7. Credential expired -> "米家登录已过期 · 重新扫码"
        do {
            let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: true, hasHA: false)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let expiredSession = Self.validMiSession(expiresAt: Self.fixedNow.addingTimeInterval(-3600))
            store.miAccounts = [MiAccount(session: expiredSession)]
            store.miSessionExpiresAt = expiredSession.expiresAt

            L10n.$overrideLanguage.withValue(.zhHans) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "米家登录已过期 · 重新扫码")
                #expect(status.badge == .reauthRequired)
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "米家登入已過期 · 重新掃碼")
            }
            L10n.$overrideLanguage.withValue(.en) {
                let status = PanelConnectionStatusPresentation.resolve(store: store)
                #expect(status.text == "Xiaomi Home session expired · Re-scan")
            }
        }
    }

    @Test("Connection status detail provides actual per-source online state, settings entry, and Esc focus restoration")
    func statusDetailAndKeyboardEscapeRouting() {
        let (store, suite) = makeIsolatedStore(backend: .xiaomiCloud, hasMi: true, hasHA: true)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.connectionStatus = .connected
        store.sourceStatuses = [.xiaomiCloud: .connected, .homeAssistant: .disconnected("502 Bad Gateway")]

        L10n.$overrideLanguage.withValue(.zhHans) {
            let presentation = PanelConnectionStatusPresentation.resolve(store: store)
            #expect(presentation.sources.count == 2)
            #expect(presentation.sources.first(where: { $0.id == "mi" })?.isOnline == true)
            #expect(presentation.sources.first(where: { $0.id == "ha" })?.isOnline == false)
        }

        // Esc closes connection status detail before collapsing device or hiding the panel.
        let key = PanelKeyRouter.Key(code: kVK_Escape)
        let contextWithDetail = PanelKeyRouter.Context(
            isShowingConnectionDetail: true,
            hasExpandedDevice: true,
            hasFocusedDevice: true
        )
        let action = PanelKeyRouter.beforeSearch(key, contextWithDetail) ?? PanelKeyRouter.afterSearch(key, contextWithDetail)
        #expect(action == .dismissConnectionDetail)
    }
}
