import Foundation
import Testing
@testable import MijiaCore

/// #180: first launch teaches connect → search → All Off + Undo, and only ticks a step once the
/// user actually tried it.
struct OnboardingChecklistTests {
    static let livingLight = SmartDevice(
        id: "light_living",
        name: "客厅吸顶灯",
        roomId: "living",
        roomName: "客厅",
        model: "yeelink.light.ceiling20",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.living", isOn: true))
    )

    static let studyLight = SmartDevice(
        id: "light_study",
        name: "书房台灯",
        roomId: "study",
        roomName: "书房",
        model: "yeelink.light.lamp4",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.study", isOn: true))
    )

    @Test("Steps tick in order, and a real All Off completes the last step")
    func checkmarksFollowRealUse() {
        var checklist = OnboardingChecklist()
        #expect(checklist.nextStep == .connectAccount)
        #expect(checklist.completedSteps.isEmpty)

        checklist.hasConfiguredSource = true
        #expect(checklist.isComplete(.connectAccount))
        #expect(checklist.nextStep == .searchDevice)

        checklist.milestones.insert(.searchedDevice)
        #expect(checklist.nextStep == .allOffAndUndo)

        // A real All Off finishes the lesson. Undo is still recorded, and is not required.
        checklist.milestones.insert(.turnedAllOff)
        #expect(checklist.isComplete(.allOffAndUndo))
        #expect(checklist.isComplete)
        #expect(checklist.nextStep == nil)
        #expect(checklist.completedSteps == OnboardingStep.allCases)

        var rehearsed = OnboardingChecklist(hasConfiguredSource: true, milestones: [.searchedDevice, .rehearsedAllOff])
        #expect(rehearsed.isComplete(.allOffAndUndo))
        #expect(rehearsed.isComplete)
        rehearsed.milestones = [.undidAllOff]
        #expect(!rehearsed.isComplete(.allOffAndUndo))
    }

    @Test("Milestones persist across launches and recording is idempotent")
    @MainActor
    func milestonesPersist() {
        let suite = "test.onboarding.persist.\(UUID().uuidString)"
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [], scenes: []))
        let first = HomeStore(provider: mock, defaultsSuiteName: suite)
        #expect(first.onboardingMilestones.isEmpty)
        #expect(first.askWhenUnsureBeforeAIActions)

        first.recordOnboardingMilestone(.searchedDevice)
        first.recordOnboardingMilestone(.searchedDevice)
        #expect(first.onboardingMilestones == [.searchedDevice])
        #expect(first.onboardingChecklist.isComplete(.searchDevice))

        first.askWhenUnsureBeforeAIActions = false

        let second = HomeStore(provider: mock, defaultsSuiteName: suite)
        #expect(second.onboardingMilestones == [.searchedDevice])
        #expect(second.onboardingChecklist.isComplete(.searchDevice))
        #expect(second.askWhenUnsureBeforeAIActions == false)
        #expect(second.aiConfirmationPolicy.askWhenUnsure == false)
    }

    @Test("All Off and its undo record the third step")
    @MainActor
    func allOffAndUndoRecordMilestones() async throws {
        let snapshot = SynthesizedHome(
            rooms: [
                RoomArea(id: "living", name: "客厅", sortOrder: 1),
                RoomArea(id: "study", name: "书房", sortOrder: 2)
            ],
            devices: [Self.livingLight, Self.studyLight],
            scenes: []
        )
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: snapshot),
            defaultsSuiteName: "test.onboarding.alloff.\(UUID().uuidString)"
        )
        try await store.waitForTestSnapshot()

        store.turnAllOff()
        #expect(store.onboardingMilestones.contains(.turnedAllOff))
        #expect(store.onboardingChecklist.isComplete(.allOffAndUndo))

        #expect(store.undoTurnAllOff() != nil)
        #expect(store.onboardingMilestones.contains(.undidAllOff))
    }

    @Test("The guide hands the dashboard back once a source is configured, and hides only after all three steps")
    func presentationTransitions() {
        let fresh = OnboardingChecklist(hasConfiguredSource: false)
        #expect(OnboardingPresentation.resolve(
            checklist: fresh, hasCompletedOnboarding: false, isReopened: false
        ) == .fullGuide)

        let connected = OnboardingChecklist(hasConfiguredSource: true)
        #expect(OnboardingPresentation.resolve(
            checklist: connected, hasCompletedOnboarding: false, isReopened: false
        ) == .dashboardChecklist)

        var partial = connected
        partial.milestones = [.searchedDevice]
        #expect(OnboardingPresentation.resolve(
            checklist: partial, hasCompletedOnboarding: false, isReopened: false
        ) == .dashboardChecklist)
        partial.milestones.insert(.turnedAllOff)
        #expect(OnboardingPresentation.resolve(
            checklist: partial, hasCompletedOnboarding: false, isReopened: false
        ) == .hidden)

        var complete = connected
        complete.milestones = [.searchedDevice, .turnedAllOff, .undidAllOff]
        #expect(OnboardingPresentation.resolve(
            checklist: complete, hasCompletedOnboarding: false, isReopened: false
        ) == .hidden)
        #expect(OnboardingPresentation.resolve(
            checklist: complete, hasCompletedOnboarding: true, isReopened: false
        ) == .hidden)
        // Reopening from Settings reviews the guide without replacing the dashboard.
        #expect(OnboardingPresentation.resolve(
            checklist: complete, hasCompletedOnboarding: true, isReopened: true
        ) == .dashboardChecklist)
        #expect(OnboardingPresentation.resolve(
            checklist: fresh, hasCompletedOnboarding: true, isReopened: true
        ) == .fullGuide)
        #expect(OnboardingPresentation.resolve(
            checklist: fresh, hasCompletedOnboarding: true, isReopened: false
        ) == .hidden)
    }

    @Test("Connecting swaps the full guide for the dashboard checklist and keeps it until every step is tried")
    @MainActor
    func storePresentationAfterConnecting() async throws {
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [], scenes: [])),
            defaultsSuiteName: "test.onboarding.presentation.\(UUID().uuidString)"
        )
        for _ in 0..<50 {
            if case .connected = store.connectionStatus { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.hasConfiguredHomeSource)
        #expect(store.onboardingPresentation == .dashboardChecklist)
        #expect(store.shouldShowOnboarding)
        #expect(!store.showsFullOnboardingGuide)
        #expect(store.showsOnboardingChecklist)

        // Search leaves the checklist up. A real All Off finishes the last step.
        store.recordOnboardingMilestone(.searchedDevice)
        #expect(store.onboardingPresentation == .dashboardChecklist)
        store.recordOnboardingMilestone(.turnedAllOff)
        #expect(store.onboardingPresentation == .hidden)
        #expect(!store.shouldShowOnboarding)

        // Reopening while connected shows the checklist, not the full-screen connect form.
        store.reopenOnboarding()
        #expect(store.onboardingPresentation == .dashboardChecklist)
        store.completeOnboarding()
        #expect(store.onboardingPresentation == .hidden)
    }

    @Test("Undoing something other than All Off does not tick the All Off lesson")
    @MainActor
    func onlyAllOffUndoCounts() async throws {
        let snapshot = SynthesizedHome(
            rooms: [RoomArea(id: "living", name: "客厅", sortOrder: 1)],
            devices: [Self.livingLight],
            scenes: []
        )
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: snapshot),
            defaultsSuiteName: "test.onboarding.undo-source.\(UUID().uuidString)"
        )
        try await store.waitForTestSnapshot()

        store.executeQuickAction(.lightsOff)
        #expect(store.undoBanner != nil)
        #expect(store.undoBanner?.isAllOff == false)
        #expect(store.undoTurnAllOff() != nil)
        #expect(!store.onboardingMilestones.contains(.undidAllOff))

        store.turnAllOff()
        #expect(store.undoBanner?.isAllOff == true)
        #expect(store.undoTurnAllOff() != nil)
        #expect(store.onboardingMilestones.contains(.undidAllOff))
    }

    @Test("The All Off lesson is a dry run, then a later real All Off still runs")
    @MainActor
    func allOffLessonIsADryRun() async throws {
        let snapshot = SynthesizedHome(
            rooms: [RoomArea(id: "living", name: "客厅", sortOrder: 1)],
            devices: [Self.livingLight, Self.studyLight],
            scenes: []
        )
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.onboarding.rehearse.\(UUID().uuidString)"
        )
        try await store.waitForTestSnapshot()
        store.recordOnboardingMilestone(.searchedDevice)
        #expect(store.onboardingChecklist.nextStep == .allOffAndUndo)
        #expect(store.allOffLessonIsActive)

        let rehearsal = store.rehearseAllOff()
        #expect(rehearsal == nil)
        #expect(store.onboardingMilestones.contains(.rehearsedAllOff))
        #expect(!store.onboardingMilestones.contains(.turnedAllOff))
        #expect(store.onboardingChecklist.isComplete(.allOffAndUndo))
        #expect(store.devices.allSatisfy { $0.isActiveOn })
        let title = try #require(store.undoBanner?.title)
        #expect(title.hasPrefix("演练：将关闭 2 台（未实际执行）"))
        #expect(title.contains("客厅吸顶灯"))
        #expect(title.contains("书房台灯"))
        #expect(store.undoBanner?.restoreCommands.isEmpty == true)

        await Task.yield()
        let duringLesson = await mock.executedCommands
        #expect(duringLesson.isEmpty)

        // Dismissing the rehearsal banner must not send a restore or claim the home came back.
        #expect(store.undoTurnAllOff() == nil)
        #expect(store.toastNotice == nil)

        let real = store.turnAllOff()
        let task = try #require(real)
        await task.value
        let sent = await mock.executedCommands
        #expect(!sent.isEmpty)
        #expect(store.onboardingMilestones.contains(.turnedAllOff))
        #expect(store.devices.contains { !$0.isActiveOn })
    }

    @Test("URL, Raycast, and App Intent All Off still writes while the lesson is pending")
    @MainActor
    func urlAllOffWritesDuringLesson() async throws {
        let snapshot = SynthesizedHome(
            rooms: [RoomArea(id: "living", name: "客厅", sortOrder: 1)],
            devices: [Self.livingLight, Self.studyLight],
            scenes: []
        )
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.onboarding.url-alloff.\(UUID().uuidString)"
        )
        try await store.waitForTestSnapshot()
        store.recordOnboardingMilestone(.searchedDevice)
        #expect(store.allOffLessonIsActive)

        let outcome = await store.executeBuiltInURLScene(.allOff)
        #expect(outcome.isError == false)
        #expect(store.onboardingMilestones.contains(.turnedAllOff))
        #expect(!store.onboardingMilestones.contains(.rehearsedAllOff))
        #expect(store.devices.contains { !$0.isActiveOn })
        let sent = await mock.executedCommands
        #expect(!sent.isEmpty)
    }

    @Test("A blocked Mi session hides the lesson, so a hold is a real refused All Off")
    @MainActor
    func blockedSessionSkipsTheRehearsal() async throws {
        let suite = "test.onboarding.blocked.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        #expect(MiSessionStore.save(
            MiSession(
                userId: "42",
                cUserId: "c",
                ssecurity: "s",
                serviceToken: "tok",
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            defaults: defaults
        ))
        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            devices: [Self.livingLight, Self.studyLight],
            scenes: []
        ))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        store.recordOnboardingMilestone(.searchedDevice)
        #expect(store.miSessionBlocksControl)
        #expect(!store.allOffLessonIsActive, "the blocked notice hides the getting-started row")

        let task = try #require(store.rehearseAllOff())
        #expect(await task.value == .refusedByMiSession)
        #expect(store.undoBanner == nil, "a blocked session never shows a rehearsal banner")
        #expect(!store.onboardingMilestones.contains(.rehearsedAllOff))
        #expect(!store.onboardingMilestones.contains(.turnedAllOff))
        #expect(store.toastNotice?.persistent == true)
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("Undoing a rehearsal banner stays silent when the session expired afterwards")
    @MainActor
    func rehearsalUndoNeverPromptsForAnExpiredSession() async throws {
        let suite = "test.onboarding.rehearsal-undo-blocked.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        #expect(MiSessionStore.save(
            MiSession(
                userId: "42",
                cUserId: "c",
                ssecurity: "s",
                serviceToken: "tok",
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            defaults: defaults
        ))
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.livingLight], scenes: [])),
            defaultsSuiteName: suite
        )
        try await store.waitForTestSnapshot()
        #expect(store.miSessionBlocksControl)
        // A rehearsal banner that outlives the session still has no restores to refuse.
        store.scheduleUndoBanner(
            title: "演练：将关闭 1 台（未实际执行）",
            restoreCommands: [],
            previousDevices: store.devices,
            deviceCount: 1,
            isAllOff: false
        )

        #expect(store.undoTurnAllOff() == nil)
        #expect(store.undoBanner == nil)
        #expect(store.toastNotice == nil, "a rehearsal undo never prompts for the expired session")
    }
}

struct PanelNoticeTests {
    @Test("One notice is shown, blocked ahead of security, then suggestion, then expiring")
    func priorityKeepsASingleSlot() {
        let soon = Date(timeIntervalSince1970: 1_700_000_000)
        let plaintext = HAPlaintextPrompt.asking("http://203.0.113.5:8123")
        let address = HADiscoveredInstance(baseURL: "http://203.0.113.9:8123", locationName: "客厅")

        #expect(PanelNotice.slot(miExpired: false, expiringSoon: nil, plaintext: nil, address: nil) == nil)

        let blocked = PanelNotice.slot(
            miExpired: true, expiringSoon: soon, plaintext: plaintext, address: address
        )
        #expect(blocked?.kind == .miBlocked)
        #expect(blocked?.extraCount == 3)
        #expect(blocked?.hidesChecklist == true)

        let security = PanelNotice.slot(
            miExpired: false, expiringSoon: soon, plaintext: plaintext, address: address
        )
        #expect(security?.kind == .haPlaintext(plaintext))
        #expect(security?.extraCount == 2)
        #expect(security?.hidesChecklist == true)

        let declined = HAPlaintextPrompt.declined("http://203.0.113.5:8123")
        let declinedSlot = PanelNotice.slot(
            miExpired: false, expiringSoon: nil, plaintext: declined, address: nil
        )
        #expect(declinedSlot?.hidesChecklist == true)

        let suggestion = PanelNotice.slot(
            miExpired: false, expiringSoon: soon, plaintext: nil, address: address
        )
        #expect(suggestion?.kind == .haAddress(address))
        #expect(suggestion?.extraCount == 1)
        #expect(suggestion?.hidesChecklist == false)

        let expiring = PanelNotice.slot(
            miExpired: false, expiringSoon: soon, plaintext: nil, address: nil
        )
        #expect(expiring?.kind == .miExpiringSoon(soon))
        #expect(expiring?.extraCount == 0)
        #expect(expiring?.hidesChecklist == false)
        #expect(PanelNotice.extraReminderLabel(count: 1) == "还有 1 条提醒")
        #expect(PanelNotice.extraReminderLabel(count: 2) == "还有 2 条提醒")
    }

    @Test("The live store shows only the higher notice when expiry and plaintext are both set")
    @MainActor
    func storeShowsOneNotice() async throws {
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [], scenes: [])),
            defaultsSuiteName: "test.notice.slot.\(UUID().uuidString)"
        )
        store.haPlaintextPrompt = .asking("http://203.0.113.5:8123")
        store.pendingHAAddressSuggestion = HADiscoveredInstance(baseURL: "http://203.0.113.9:8123")
        let slot = try #require(store.panelNoticeSlot)
        if case .haPlaintext(.asking("http://203.0.113.5:8123")) = slot.kind {
        } else {
            Issue.record("Expected the plaintext notice, got \(slot.kind)")
        }
        #expect(slot.extraCount == 1)
        #expect(slot.hidesChecklist)
    }

    @Test("The blocked banner already carries the expiry toast's message and Scan action")
    func blockedNoticeSupersedesTheExpiryToast() {
        let blocked = PanelNoticeSlot(kind: .miBlocked, extraCount: 0)
        let expiryToast = ToastNotice(
            message: HomeStore.miSessionBlockedMessage,
            isError: true,
            action: ToastAction(title: "扫码", kind: .presentMiReauth),
            persistent: true
        )
        #expect(blocked.repeats(expiryToast))
        // Anything else keeps its own slot: an ordinary toast, another action, or another notice.
        #expect(!blocked.repeats(ToastNotice(message: "已关闭 2 台设备")))
        #expect(!blocked.repeats(ToastNotice(
            message: "Home Assistant 未连接",
            isError: true,
            action: ToastAction(title: "设置", kind: .openConnectionSettings),
            persistent: true
        )))
        let expiring = PanelNoticeSlot(
            kind: .miExpiringSoon(Date(timeIntervalSince1970: 1_700_000_000)),
            extraCount: 0
        )
        #expect(!expiring.repeats(expiryToast))
    }

    @Test("Kind chips stay hidden until 全部 is opened again or a kind filter is on")
    func kindChipsStayHiddenByDefault() {
        #expect(!KindChipRowPolicy.isShown(listCut: .all, revealed: false))
        #expect(KindChipRowPolicy.isShown(listCut: .all, revealed: true))
        #expect(!KindChipRowPolicy.isShown(listCut: .room("living"), revealed: true))
        #expect(KindChipRowPolicy.isShown(listCut: .kind(.light), revealed: false))
    }
}
