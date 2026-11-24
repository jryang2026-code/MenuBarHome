import Foundation
import Testing
@testable import MijiaCore

/// #174: pure Mac-context trigger evaluation, option decoding and per-signal edges.
struct MacContextAutomationTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 15) -> Date {
        utcCalendar.date(from: DateComponents(
            year: 2026,
            month: 6,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func event(
        _ trigger: AutomationTrigger,
        previous: MacContextSnapshot?,
        current: MacContextSnapshot,
        options: AutomationTriggerOptions = AutomationTriggerOptions(),
        at now: Date? = nil,
        calendar: Calendar? = nil
    ) -> AutomationTriggerEvent? {
        let rule = AutomationRule(
            trigger: trigger,
            action: .quickAction(.lightsOff),
            triggerOptions: options
        )
        return MacContextAutomation.events(
            for: rule,
            previous: previous,
            current: current,
            at: now ?? date(12),
            calendar: calendar ?? utcCalendar
        ).first
    }

    @Test("Rules stored before #174 decode with default options")
    func legacyRuleDecodesWithDefaults() throws {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "isEnabled": true,
            "trigger": "away",
            "action": ["kind": "quickAction", "quickAction": QuickAction.lightsOff.rawValue]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let rule = try JSONDecoder().decode(AutomationRule.self, from: data)

        #expect(rule.trigger == .away)
        #expect(rule.triggerOptions == AutomationTriggerOptions())
        #expect(rule.conditions.lastingMinutes == nil)
    }

    @Test("Trigger options round-trip and clamp out-of-range values")
    func optionsRoundTripAndClamp() throws {
        let options = AutomationTriggerOptions(
            batteryThresholdPercent: 0,
            wifiSSID: "  Home  ",
            focusModeName: "  睡眠  ",
            lateNightStartHour: 30,
            lateNightEndHour: -1,
            calendarLeadMinutes: 999
        )
        #expect(options.batteryThresholdPercent == 1)
        #expect(options.wifiSSID == "Home")
        #expect(options.focusModeName == "睡眠")
        #expect(options.lateNightWindow.startHour == 23)
        #expect(options.lateNightWindow.endHour == 0)
        #expect(options.calendarLeadMinutes == 60)

        let blankSSID = AutomationTriggerOptions(wifiSSID: "   ", focusModeName: "   ")
        #expect(blankSSID.wifiSSID == nil)
        #expect(blankSSID.focusModeName == nil)

        let decoded = try JSONDecoder().decode(
            AutomationTriggerOptions.self,
            from: JSONEncoder().encode(options)
        )
        #expect(decoded == options)
    }

    @Test("A lasting condition round-trips without changing existing condition keys")
    func lastingPayload() throws {
        let payload = Data(#"{"lastingMinutes":5,"wifi":{"kind":"inAny","ssids":["Home"]}}"#.utf8)
        let conditions = try JSONDecoder().decode(AutomationConditions.self, from: payload)
        #expect(conditions.lastingMinutes == 5)
        #expect(conditions.wifi == .inAny(["Home"]))
        #expect(conditions.timeWindow == .anytime)
        let encoded = try JSONEncoder().encode(conditions)
        let roundTrip = try JSONDecoder().decode(AutomationConditions.self, from: encoded)
        #expect(roundTrip == conditions)
    }

    @Test("Schedule JSON uses the Windows keys and omitted or empty weekdays mean daily")
    func scheduledPayload() throws {
        let payload = Data(#"{"scheduledTime":{"hour":0,"minute":15,"weekdays":[]}}"#.utf8)
        let options = try JSONDecoder().decode(AutomationTriggerOptions.self, from: payload)
        #expect(options.scheduledTime == ScheduledTime(hour: 0, minute: 15, weekdays: []))
        let encoded = try JSONEncoder().encode(options)
        let dictionary = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let schedule = try #require(dictionary["scheduledTime"] as? [String: Any])
        #expect(schedule["hour"] as? Int == 0)
        #expect(schedule["minute"] as? Int == 15)
        #expect(schedule["weekdays"] as? [Int] == [])
        #expect(event(.scheduledTime, previous: nil, current: MacContextSnapshot(), options: options, at: date(0, 15)) != nil)
        let daily = AutomationTriggerOptions(scheduledTime: ScheduledTime(hour: 0, minute: 15))
        #expect(event(.scheduledTime, previous: nil, current: MacContextSnapshot(), options: daily, at: date(0, 15)) != nil)
    }

    @Test("A spring-forward gap does not replay the missing minute and timezone changes move the schedule")
    func scheduledSpringForwardAndTimeZone() throws {
        var pacific = utcCalendar
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let formatter = ISO8601DateFormatter()
        let before = try #require(formatter.date(from: "2026-03-08T09:59:00Z"))
        let after = before.addingTimeInterval(60)
        let options = AutomationTriggerOptions(scheduledTime: ScheduledTime(hour: 2, minute: 30))
        let snapshot = MacContextSnapshot()
        #expect(event(.scheduledTime, previous: nil, current: snapshot, options: options, at: before, calendar: pacific) == nil)
        #expect(event(.scheduledTime, previous: nil, current: snapshot, options: options, at: after, calendar: pacific) == nil)
        let utcMatch = date(2, 30)
        #expect(event(.scheduledTime, previous: nil, current: snapshot, options: options, at: utcMatch, calendar: utcCalendar) != nil)
        #expect(event(.scheduledTime, previous: nil, current: snapshot, options: options, at: utcMatch, calendar: pacific) == nil)
    }

    @Test("A disabled rule never produces an event")
    func disabledRuleProducesNoEvent() {
        let rule = AutomationRule(
            trigger: .cameraInUse,
            action: .quickAction(.lightsOff),
            isEnabled: false
        )
        let current = MacContextSnapshot(cameraInUse: true)
        #expect(MacContextAutomation.events(
            for: rule,
            previous: MacContextSnapshot(),
            current: current,
            at: date(12)
        ).isEmpty)
    }

    @Test("Scheduled rules use local wall time and weekday mapping")
    func scheduledRulesUseLocalWallTimeAndWeekdays() {
        let rule = AutomationRule(
            trigger: .scheduledTime,
            action: .quickAction(.lightsOff),
            triggerOptions: AutomationTriggerOptions(
                scheduledTime: ScheduledTime(hour: 12, minute: 0, weekdays: [1])
            )
        )
        let monday = date(12, day: 15)
        let tuesday = date(12, day: 16)
        #expect(MacContextAutomation.events(for: rule, previous: nil, current: MacContextSnapshot(), at: monday, calendar: utcCalendar).count == 1)
        #expect(MacContextAutomation.events(for: rule, previous: nil, current: MacContextSnapshot(), at: tuesday, calendar: utcCalendar).isEmpty)
    }

    @Test("Camera and microphone fire only on the matching transition")
    func cameraAndMicrophoneTransitions() {
        let idle = MacContextSnapshot()
        var cameraOn = idle
        cameraOn.cameraInUse = true
        #expect(event(.cameraInUse, previous: idle, current: cameraOn) != nil)
        #expect(event(.cameraInUse, previous: cameraOn, current: cameraOn) == nil)
        #expect(event(.cameraNotInUse, previous: cameraOn, current: idle) != nil)
        #expect(event(.cameraInUse, previous: nil, current: cameraOn) == nil)

        var micOn = idle
        micOn.microphoneInUse = true
        #expect(event(.microphoneInUse, previous: idle, current: micOn) != nil)
        #expect(event(.microphoneInUse, previous: micOn, current: micOn) == nil)
        #expect(event(.microphoneNotInUse, previous: micOn, current: idle) != nil)
        #expect(event(.microphoneInUse, previous: nil, current: micOn) == nil)
    }

    @Test("Power connect, disconnect and the battery threshold use transitions")
    func powerAndBatteryTransitions() {
        let batteryHigh = MacContextSnapshot(powerSource: .battery, batteryPercent: 80)
        let ac = MacContextSnapshot(powerSource: .ac, batteryPercent: 80)
        #expect(event(.powerConnected, previous: batteryHigh, current: ac) != nil)
        #expect(event(.powerConnected, previous: ac, current: ac) == nil)
        #expect(event(.powerDisconnected, previous: ac, current: batteryHigh) != nil)
        #expect(event(.powerConnected, previous: nil, current: ac) == nil)

        let options = AutomationTriggerOptions(batteryThresholdPercent: 20)
        var batteryLow = batteryHigh
        batteryLow.batteryPercent = 19
        #expect(event(.batteryBelowThreshold, previous: batteryHigh, current: batteryLow, options: options) != nil)
        #expect(event(.batteryBelowThreshold, previous: batteryLow, current: batteryLow, options: options) == nil)
        #expect(event(.batteryBelowThreshold, previous: ac, current: batteryLow, options: options) != nil)
        #expect(event(.batteryBelowThreshold, previous: nil, current: batteryLow, options: options) == nil)
    }

    @Test("Wi-Fi join and leave can target one SSID or any network")
    func wifiTransitions() {
        let office = MacContextSnapshot(wifiSSID: "Office")
        let home = MacContextSnapshot(wifiSSID: "Home")
        let homeOnly = AutomationTriggerOptions(wifiSSID: "Home")

        #expect(event(.wifiNetworkJoined, previous: office, current: home, options: homeOnly) != nil)
        #expect(event(.wifiNetworkJoined, previous: office, current: home, options: .init(wifiSSID: "Work")) == nil)
        #expect(event(.wifiNetworkLeft, previous: home, current: office, options: homeOnly) != nil)
        #expect(event(.wifiNetworkLeft, previous: office, current: home, options: homeOnly) == nil)
        #expect(event(.wifiNetworkJoined, previous: office, current: home) != nil)
        #expect(event(.wifiNetworkJoined, previous: nil, current: home) == nil)

        let unauthorized = MacContextSnapshot(wifiSSID: nil, isWiFiAuthorized: false)
        #expect(event(.wifiNetworkLeft, previous: home, current: unauthorized, options: homeOnly) == nil)
        #expect(event(.wifiNetworkJoined, previous: unauthorized, current: home, options: homeOnly) == nil)
    }

    @Test("Focus on/off requires an observed transition, not a first snapshot")
    func focusTransitions() {
        let focusOff = MacContextSnapshot(isFocusActive: false)
        let focusOn = MacContextSnapshot(isFocusActive: true)

        #expect(event(.focusModeEnabled, previous: focusOff, current: focusOn) != nil)
        #expect(event(.focusModeEnabled, previous: focusOn, current: focusOn) == nil)
        #expect(event(.focusModeEnabled, previous: nil, current: focusOn) == nil)
        #expect(event(.focusModeDisabled, previous: focusOn, current: focusOff) != nil)
        #expect(event(.focusModeDisabled, previous: focusOff, current: focusOff) == nil)

        let permissionMissing = MacContextSnapshot(isFocusActive: nil)
        #expect(event(.focusModeEnabled, previous: permissionMissing, current: focusOn) == nil)
        #expect(event(.focusModeDisabled, previous: focusOn, current: permissionMissing) == nil)
    }

    @Test("Focus mode name rules match direct A to B switches, Focus off, and reject unknown mode names")
    func focusModeNameTransitions() {
        let sleepOption = AutomationTriggerOptions(focusModeName: "睡眠")
        let workOption = AutomationTriggerOptions(focusModeName: "工作")

        let off = MacContextSnapshot(isFocusActive: false, focusModeName: nil)
        let sleep = MacContextSnapshot(isFocusActive: true, focusModeName: "睡眠")
        let work = MacContextSnapshot(isFocusActive: true, focusModeName: "工作")
        let unnamed = MacContextSnapshot(isFocusActive: true, focusModeName: nil)
        let unknown = MacContextSnapshot(isFocusActive: true, focusModeName: "未知模式")
        let permissionMissing = MacContextSnapshot(isFocusActive: nil, focusModeName: "睡眠")

        // Off -> Sleep fires Sleep enabled, not Work enabled.
        #expect(event(.focusModeEnabled, previous: off, current: sleep, options: sleepOption) != nil)
        #expect(event(.focusModeEnabled, previous: off, current: sleep, options: workOption) == nil)

        // Direct Focus A (Sleep) -> Focus B (Work) fires Sleep disabled AND Work enabled.
        #expect(event(.focusModeDisabled, previous: sleep, current: work, options: sleepOption) != nil)
        #expect(event(.focusModeEnabled, previous: sleep, current: work, options: workOption) != nil)
        #expect(event(.focusModeEnabled, previous: sleep, current: work, options: sleepOption) == nil)

        // Generic boolean fallback (`focusModeName: nil`) does not refire on A -> B direct switch.
        #expect(event(.focusModeEnabled, previous: sleep, current: work) == nil)
        #expect(event(.focusModeDisabled, previous: sleep, current: work) == nil)

        // Direct Focus A (Sleep) -> Focus B without filter (`focusModeName: nil`) fires Sleep disabled.
        #expect(event(.focusModeDisabled, previous: sleep, current: unnamed, options: sleepOption) != nil)

        // Unknown / unlabelled mode name never triggers a named rule, and Focus -> Off fires disabled.
        #expect(event(.focusModeEnabled, previous: off, current: unknown, options: sleepOption) == nil)
        #expect(event(.focusModeEnabled, previous: off, current: unnamed, options: sleepOption) == nil)
        #expect(event(.focusModeDisabled, previous: sleep, current: off, options: sleepOption) != nil)
        #expect(event(.focusModeDisabled, previous: unknown, current: off, options: sleepOption) == nil)

        // Missing Focus permission never fabricates named transitions either.
        #expect(event(.focusModeEnabled, previous: permissionMissing, current: sleep, options: sleepOption) == nil)
        #expect(event(.focusModeDisabled, previous: sleep, current: permissionMissing, options: sleepOption) == nil)
    }

    @Test("Calendar fires inside the lead window and keys the dedupe by event")
    func calendarLeadWindow() {
        let now = date(10)
        let meeting = CalendarMeeting(
            id: "event-42",
            title: "Standup",
            startDate: now.addingTimeInterval(4 * 60),
            endDate: now.addingTimeInterval(34 * 60)
        )
        let snapshot = MacContextSnapshot(meetings: [meeting])
        let options = AutomationTriggerOptions(calendarLeadMinutes: 5)

        let fired = event(
            .calendarMeetingStartingSoon,
            previous: nil,
            current: snapshot,
            options: options,
            at: now
        )
        #expect(fired != nil)
        #expect(fired?.dedupeKey.contains("event-42") == true)

        #expect(event(
            .calendarMeetingStartingSoon,
            previous: nil,
            current: snapshot,
            options: .init(calendarLeadMinutes: 1),
            at: now
        ) == nil)
        #expect(event(
            .calendarMeetingStartingSoon,
            previous: nil,
            current: snapshot,
            options: options,
            at: now.addingTimeInterval(10 * 60)
        ) == nil)
    }

    @Test("All eligible calendar meetings become events in start order")
    func calendarMultipleMeetings() {
        let now = date(10)
        let first = CalendarMeeting(
            id: "first",
            title: "First",
            startDate: now.addingTimeInterval(10 * 60),
            endDate: now.addingTimeInterval(40 * 60)
        )
        let second = CalendarMeeting(
            id: "second",
            title: "Second",
            startDate: now.addingTimeInterval(20 * 60),
            endDate: now.addingTimeInterval(50 * 60)
        )
        let rule = AutomationRule(
            trigger: .calendarMeetingStartingSoon,
            action: .quickAction(.lightsOff),
            triggerOptions: AutomationTriggerOptions(calendarLeadMinutes: 30)
        )
        let events = MacContextAutomation.events(
            for: rule,
            previous: nil,
            current: MacContextSnapshot(meetings: [second, first]),
            at: now,
            calendar: utcCalendar
        )
        #expect(events.count == 2)
        #expect(events.map(\.dedupeKey).contains { $0.hasSuffix(".first") })
        #expect(events.map(\.dedupeKey).contains { $0.hasSuffix(".second") })
        #expect(events[0].dedupeKey.hasSuffix(".first"))
        #expect(events[1].dedupeKey.hasSuffix(".second"))
    }

    @Test("Late-night use fires inside the window only while the Mac is present")
    func lateNightWindow() {
        let options = AutomationTriggerOptions(lateNightStartHour: 23, lateNightEndHour: 6)
        let present = MacContextSnapshot(isUserPresent: true)
        let absent = MacContextSnapshot(isUserPresent: false)

        #expect(event(.lateNightUsage, previous: nil, current: present, options: options, at: date(23, 30)) != nil)
        #expect(event(.lateNightUsage, previous: nil, current: present, options: options, at: date(22, 30)) == nil)
        #expect(event(.lateNightUsage, previous: nil, current: present, options: options, at: date(12)) == nil)
        #expect(event(.lateNightUsage, previous: nil, current: absent, options: options, at: date(23, 30)) == nil)

        let fired = event(.lateNightUsage, previous: nil, current: present, options: options, at: date(23, 30))
        // From 23:30 until 06:00 the same night must not repeat the rule.
        #expect((fired?.cooldown ?? 0) > 6 * 60 * 60)
    }

    @Test("Late-night dedupe is anchored to one night")
    func lateNightNightlyKey() throws {
        let rule = AutomationRule(
            trigger: .lateNightUsage,
            action: .quickAction(.lightsOff),
            triggerOptions: AutomationTriggerOptions(lateNightStartHour: 23, lateNightEndHour: 6)
        )
        let present = MacContextSnapshot(isUserPresent: true)
        let beforeMidnight = try #require(MacContextAutomation.events(
            for: rule, previous: nil, current: present, at: date(23, 30), calendar: utcCalendar
        ).first)
        let afterMidnight = try #require(MacContextAutomation.events(
            for: rule, previous: nil, current: present, at: date(3, 30, day: 16), calendar: utcCalendar
        ).first)
        let nextNight = try #require(MacContextAutomation.events(
            for: rule, previous: nil, current: present, at: date(23, 30, day: 16), calendar: utcCalendar
        ).first)

        #expect(beforeMidnight.dedupeKey == afterMidnight.dedupeKey)
        #expect(beforeMidnight.dedupeKey != nextNight.dedupeKey)
        #expect(beforeMidnight.cooldown == AutomationPolicy.nightlyCooldown)
    }

    @Test("Only enabled rules contribute their required permissions")
    func requiredPermissions() {
        let rules = [
            AutomationRule(trigger: .wifiNetworkJoined, action: .quickAction(.lightsOff)),
            AutomationRule(trigger: .focusModeEnabled, action: .quickAction(.lightsOff)),
            AutomationRule(trigger: .calendarMeetingStartingSoon, action: .quickAction(.lightsOff)),
            AutomationRule(trigger: .cameraInUse, action: .quickAction(.lightsOff)),
            AutomationRule(trigger: .wifiNetworkLeft, action: .quickAction(.lightsOff), isEnabled: false)
        ]
        #expect(MacContextAutomation.requiredPermissions(for: rules) == [.location, .focus, .calendar])
    }

    @Test("Keyed cooldowns are independent and honor long windows")
    func keyedCooldown() throws {
        let suite = "test.mac.context.deduper.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let deduper = AutomationTriggerDeduper(defaults: defaults)
        #expect(deduper.shouldFire("calendar.1", at: start, cooldown: 600))
        #expect(!deduper.shouldFire("calendar.1", at: start.addingTimeInterval(300), cooldown: 600))
        #expect(deduper.shouldFire("calendar.1", at: start.addingTimeInterval(600), cooldown: 600))
        #expect(deduper.shouldFire("calendar.2", at: start.addingTimeInterval(10), cooldown: 600))
    }

    @Test("macOS trigger source registry exhaustively maps every supported trigger including scheduledTime")
    func macOSTriggerRegistryExhaustive() {
        #expect(!AutomationTrigger.macOSSupportedTriggers.isEmpty)
        #expect(Set(AutomationTrigger.macOSSupportedTriggers).count == AutomationTrigger.macOSSupportedTriggers.count)
        #expect(Set(AutomationTrigger.macOSSupportedTriggers) == Set(AutomationTrigger.allCases))
        #expect(Set(AutomationTrigger.macOSTriggerSources.keys) == Set(AutomationTrigger.macOSSupportedTriggers))

        for trigger in AutomationTrigger.macOSSupportedTriggers {
            let sources = AutomationTrigger.macOSTriggerSources[trigger] ?? []
            #expect(!sources.isEmpty)
            #expect(Set(sources).count == sources.count)
            #expect(trigger.isSupportedOnMacOS)
        }

        #expect(AutomationTrigger.scheduledTime.macOSSources == [.macContextObserver])
        #expect(AutomationTrigger.scheduledTime.usesMacContextObserver)
        #expect(AutomationTrigger.away.macOSSources == [
            .workspaceWillSleep, .workspaceScreensDidSleep, .distributedScreenLocked
        ])
        #expect(AutomationTrigger.back.macOSSources == [
            .workspaceDidWake, .workspaceScreensDidWake, .distributedScreenUnlocked
        ])
        #expect(AutomationTrigger.screenLocked.macOSSources == [.distributedScreenLocked, .awayArbitrator])
        #expect(AutomationTrigger.lidClosedSleep.macOSSources == [.workspaceWillSleep, .awayArbitrator])
        #expect(AutomationTrigger.systemSleep.macOSSources == [.workspaceWillSleep, .awayArbitrator])
        #expect(AutomationTrigger.externalDisplayConnected.macOSSources == [.screenParametersChanged])
        #expect(AutomationTrigger.externalDisplayDisconnected.macOSSources == [.screenParametersChanged])
        #expect(AutomationTrigger.frontmostAppBecame.macOSSources == [.workspaceDidActivateApplication])
        #expect(AutomationTrigger.frontmostAppLeft.macOSSources == [.workspaceDidActivateApplication])
        #expect(!AutomationTrigger.frontmostAppBecame.usesMacContextObserver)
        #expect(!AutomationTrigger.frontmostAppLeft.usesMacContextObserver)
    }

    @Test("Built-in meeting and movie templates create disabled rules with restore enabled and no pre-selected devices")
    func templatesCreateDisabledRestoreRulesWithoutDevices() throws {
        let meetingRules = AutomationRuleTemplate.meeting.makeRules()
        #expect(meetingRules.count == 2)
        #expect(Set(meetingRules.map(\.trigger)) == [.cameraInUse, .microphoneInUse])
        for rule in meetingRules {
            #expect(!rule.isEnabled)
            #expect(rule.restoreWhenContextEnds)
            #expect(rule.restoreTrigger == rule.trigger.defaultRestoreTrigger)
            #expect(!rule.canEnable)
            if case .devices(let ids, _) = rule.action {
                #expect(ids.isEmpty)
            } else {
                Issue.record("Expected device action for meeting template rule")
            }
        }

        let movieRules = AutomationRuleTemplate.movie.makeRules()
        #expect(movieRules.count == 1)
        let movie = try #require(movieRules.first)
        #expect(!movie.isEnabled)
        #expect(movie.trigger == .frontmostAppBecame)
        #expect(movie.restoreWhenContextEnds)
        #expect(movie.restoreTrigger == .frontmostAppLeft)
        #expect(movie.triggerOptions.frontmostAppBundleID == AutomationRuleTemplate.FrontmostAppPreset.iina.bundleID)
        #expect(!movie.canEnable)
        if case .devices(let ids, let isOn) = movie.action {
            #expect(ids.isEmpty)
            #expect(!isOn)
        } else {
            Issue.record("Expected device action for movie template rule")
        }

        // Choosing a high-risk device on a restore-on-exit turn-off rule still requires confirmation.
        let plug = SmartDevice(
            id: "plug_heater",
            name: "电暖器插座",
            roomId: "study",
            roomName: "书房",
            model: "cuco.plug.cp1",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.heater", isOn: true))
        )
        var configured = movie
        configured.action = .devices(ids: [plug.id], isOn: false)
        #expect(configured.canEnable)
        #expect(configured.highRiskConfirmation(devices: [plug]) != nil)

        // Bundle ID option normalizes whitespace and round-trips through JSON.
        let encoded = try JSONEncoder().encode(
            AutomationTriggerOptions(frontmostAppBundleID: "  org.videolan.vlc  ")
        )
        let decoded = try JSONDecoder().decode(AutomationTriggerOptions.self, from: encoded)
        #expect(decoded.frontmostAppBundleID == "org.videolan.vlc")
        #expect(AutomationTriggerOptions(frontmostAppBundleID: "   ").frontmostAppBundleID == nil)
    }

    @Test("Unavailable camera, microphone, or unknown power/battery readings never fabricate transitions")
    func unavailableSignalsBlockTransitions() {
        let camUnavailable = MacContextSnapshot(cameraInUse: false, isCameraUsageAvailable: false)
        let camActive = MacContextSnapshot(cameraInUse: true, isCameraUsageAvailable: true)
        #expect(event(.cameraInUse, previous: camUnavailable, current: camActive) == nil)
        #expect(event(.cameraNotInUse, previous: camActive, current: camUnavailable) == nil)

        let micUnavailable = MacContextSnapshot(microphoneInUse: false, isMicrophoneUsageAvailable: false)
        let micActive = MacContextSnapshot(microphoneInUse: true, isMicrophoneUsageAvailable: true)
        #expect(event(.microphoneInUse, previous: micUnavailable, current: micActive) == nil)
        #expect(event(.microphoneNotInUse, previous: micActive, current: micUnavailable) == nil)

        let unknownPower = MacContextSnapshot(powerSource: .unknown, batteryPercent: nil)
        let batteryMissingPercent = MacContextSnapshot(powerSource: .battery, batteryPercent: nil)
        let batteryLow = MacContextSnapshot(powerSource: .battery, batteryPercent: 10)
        let ac = MacContextSnapshot(powerSource: .ac, batteryPercent: 80)
        #expect(event(.powerConnected, previous: unknownPower, current: ac) == nil)
        #expect(event(.powerDisconnected, previous: unknownPower, current: batteryLow) == nil)
        #expect(event(.batteryBelowThreshold, previous: unknownPower, current: batteryLow) == nil)
        #expect(event(.batteryBelowThreshold, previous: batteryMissingPercent, current: batteryLow) == nil)
    }
}
