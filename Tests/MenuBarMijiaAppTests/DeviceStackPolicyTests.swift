import Foundation
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

@Suite("Liquid Glass DeviceStack & Room Badge Policies")
struct DeviceStackPolicyTests {
    private static func makeLight(_ id: String, name: String = "吸顶灯", roomId: String = "study", roomName: String = "书房") -> SmartDevice {
        SmartDevice(
            id: id,
            name: name,
            roomId: roomId,
            roomName: roomName,
            model: "test.light",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.\(id)", isOn: true))
        )
    }

    @Test("Single-device kind and room stacks render open without a redundant section header")
    func singleDeviceKindAndRoomStacksDropHeader() {
        let singleKind = DeviceStack(
            id: "kind:vacuum",
            source: .kind(.vacuum),
            title: "扫地机",
            devices: [Self.makeLight("v1", name: "扫地机器人", roomId: "living", roomName: "客厅")]
        )
        #expect(singleKind.isOpen(expandedStacks: []))
        #expect(!singleKind.showsHeader(totalStacks: 4))
        #expect(!singleKind.canCollapse())
        #expect(singleKind.showsRoomBadge(totalStacks: 4))

        let singleRoom = DeviceStack(
            id: "room:kitchen",
            source: .room("kitchen"),
            title: "厨房",
            devices: [Self.makeLight("f1", name: "对开门冰箱", roomId: "kitchen", roomName: "厨房")]
        )
        #expect(singleRoom.isOpen(expandedStacks: []))
        #expect(!singleRoom.showsHeader(totalStacks: 4))
        #expect(!singleRoom.canCollapse())
        // With no "厨房 1" header above it, the single card carries the room badge itself.
        #expect(singleRoom.showsRoomBadge(totalStacks: 4))
    }

    @Test("Multi-device kind and room stacks fold by default and show a collapsible header when expanded")
    func multiDeviceKindAndRoomStacksKeepCollapsibleHeader() {
        let devices = [
            Self.makeLight("l1", name: "主灯", roomId: "living", roomName: "客厅"),
            Self.makeLight("l2", name: "筒灯", roomId: "living", roomName: "客厅")
        ]
        let kindStack = DeviceStack(id: "kind:light", source: .kind(.light), title: "灯", devices: devices)
        #expect(!kindStack.isOpen(expandedStacks: []))
        #expect(kindStack.isOpen(expandedStacks: ["kind:light"]))
        #expect(kindStack.showsHeader(totalStacks: 3))
        #expect(kindStack.showsHeaderCount)
        #expect(kindStack.canCollapse())
        #expect(!kindStack.canCollapse(isEditingLayout: true))
        #expect(kindStack.showsRoomBadge(totalStacks: 3))

        let roomStack = DeviceStack(id: "room:living", source: .room("living"), title: "客厅", devices: devices)
        #expect(!roomStack.isOpen(expandedStacks: []))
        #expect(roomStack.isOpen(expandedStacks: ["room:living"]))
        #expect(roomStack.showsHeader(totalStacks: 3))
        #expect(roomStack.showsHeaderCount)
        #expect(roomStack.canCollapse())
        // Expanded multi-device room stacks already name the room in the header, so cards drop the badge.
        #expect(!roomStack.showsRoomBadge(totalStacks: 3))
    }

    @Test("A stack matching the active list cut opens automatically without repeating the cut header")
    func stackMatchingListCutAutoOpensWithoutHeader() {
        let devices = [
            Self.makeLight("l1", name: "主灯", roomId: "living", roomName: "客厅"),
            Self.makeLight("l2", name: "筒灯", roomId: "living", roomName: "客厅")
        ]
        let roomStack = DeviceStack(id: "room:living", source: .room("living"), title: "客厅", devices: devices)
        #expect(roomStack.isOpen(expandedStacks: [], listCut: .room("living")))
        #expect(!roomStack.showsHeader(totalStacks: 2, listCut: .room("living")))
        #expect(!roomStack.canCollapse(listCut: .room("living")))
        #expect(!roomStack.showsRoomBadge(totalStacks: 2, listCut: .room("living")))

        let kindStack = DeviceStack(id: "kind:light", source: .kind(.light), title: "灯", devices: devices)
        #expect(kindStack.isOpen(expandedStacks: [], listCut: .kind(.light)))
        #expect(!kindStack.showsHeader(totalStacks: 2, listCut: .kind(.light)))
        #expect(!kindStack.canCollapse(listCut: .kind(.light)))
        #expect(kindStack.showsRoomBadge(totalStacks: 2, listCut: .kind(.light)))
        // Under a room cut, even kind/favorite stacks omit per-card room badges since the whole page is that room.
        #expect(!kindStack.showsRoomBadge(totalStacks: 2, listCut: .room("living")))
    }

    @Test("Favorites hide their header when they are the sole group on screen, and custom groups keep theirs")
    func favoritesAndCustomGroupHeaderPolicies() {
        let singleFav = DeviceStack(
            id: "fav",
            source: .favorites,
            title: "常用",
            devices: [Self.makeLight("l1")]
        )
        #expect(!singleFav.showsHeader(totalStacks: 1))
        #expect(singleFav.showsHeader(totalStacks: 2))
        #expect(!singleFav.showsHeaderCount)

        let multiFav = DeviceStack(
            id: "fav",
            source: .favorites,
            title: "常用",
            devices: [Self.makeLight("l1"), Self.makeLight("l2")]
        )
        #expect(!multiFav.showsHeader(totalStacks: 1))
        #expect(multiFav.showsHeader(totalStacks: 2))
        #expect(multiFav.showsHeaderCount)

        // Custom groups always keep their header so a newly created 1-device group stays named and editable,
        // while still omitting the redundant "1" count badge.
        let singleCustomGroup = DeviceStack(
            id: "group:desk",
            source: .group("desk"),
            title: "办公桌",
            devices: [Self.makeLight("l1")]
        )
        #expect(singleCustomGroup.showsHeader(totalStacks: 1))
        #expect(singleCustomGroup.showsHeader(totalStacks: 3))
        #expect(!singleCustomGroup.showsHeaderCount)
    }

    @Test("DeviceRoomBadge suppresses empty or already-mentioned room names while keeping distinct rooms")
    func roomBadgeDeduplication() {
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(DeviceRoomBadge.label(roomName: "", title: "智能插座", showRoomBadge: true) == nil)
            #expect(DeviceRoomBadge.label(roomName: "   ", title: "智能插座", showRoomBadge: true) == nil)
            #expect(DeviceRoomBadge.label(roomName: "客厅", title: "扫地机器人", showRoomBadge: false) == nil)

            // Distinct room names stay visible.
            #expect(DeviceRoomBadge.label(roomName: "客厅", title: "扫地机器人", showRoomBadge: true) == "客厅")
            #expect(DeviceRoomBadge.label(roomName: "厨房", title: "对开门冰箱", showRoomBadge: true) == "厨房")
            #expect(DeviceRoomBadge.label(roomName: "书房", title: "踢脚线电暖器", showRoomBadge: true) == "书房")
            #expect(DeviceRoomBadge.label(roomName: "书房", title: "政治面貌帅的 REDMI G Pro 27U", showRoomBadge: true) == "书房")

            // Titles that already include the room drop the duplicate badge.
            #expect(DeviceRoomBadge.label(roomName: "客厅", title: "客厅温湿度计", showRoomBadge: true) == nil)
            #expect(DeviceRoomBadge.label(roomName: "客厅", title: "客厅电视", showRoomBadge: true) == nil)
            #expect(DeviceRoomBadge.label(roomName: "书房", title: "书房吸顶灯", showRoomBadge: true) == nil)
            #expect(DeviceRoomBadge.label(roomName: "客厅", title: "新风机 客厅", showRoomBadge: true) == nil)

            // Short ASCII room names respect word boundaries so "Den" or "2" never false-match substrings.
            #expect(DeviceRoomBadge.label(roomName: "Den", title: "Garden Lamp", showRoomBadge: true) == "Den")
            #expect(DeviceRoomBadge.label(roomName: "Den", title: "Den Lamp", showRoomBadge: true) == nil)
            #expect(DeviceRoomBadge.label(roomName: "2", title: "REDMI G Pro 27U", showRoomBadge: true) == "2")
        }

        L10n.$overrideLanguage.withValue(.en) {
            #expect(DeviceRoomBadge.label(roomName: "客厅", title: "Living Room AC", showRoomBadge: true) == nil)
            #expect(DeviceRoomBadge.label(roomName: "客厅", title: "Robot Vacuum", showRoomBadge: true) == "Living Room")
        }
    }

    @Test("Headerless room and kind stacks forward parent actions to the card context menu")
    func headerlessStackMenuPreservesRoomAndKindActions() {
        L10n.$overrideLanguage.withValue(.zhHans) {
            let singleRoom = DeviceStack(
                id: "room:kitchen",
                source: .room("kitchen"),
                title: "厨房",
                devices: [Self.makeLight("f1", name: "对开门冰箱", roomId: "kitchen", roomName: "厨房")]
            )
            // Even in a 1-room home (`canReorderRooms == false`), Rename Room stays reachable on the card.
            #expect(
                singleRoom.headerlessMenuDescriptor(
                    showsHeader: false,
                    canReorderRooms: false,
                    canReorderKinds: false
                ) == DeviceStack.HeaderlessMenuDescriptor(title: "房间：厨房", symbol: "house")
            )
            // When the header is visible, the header itself hosts the menu so the card does not duplicate it.
            #expect(
                singleRoom.headerlessMenuDescriptor(
                    showsHeader: true,
                    canReorderRooms: true,
                    canReorderKinds: true
                ) == nil
            )

            let homelessRoom = DeviceStack(
                id: "room:-",
                source: .room(nil),
                title: "其他",
                devices: [Self.makeLight("u1", name: "智能插座", roomId: "", roomName: "")]
            )
            #expect(
                homelessRoom.headerlessMenuDescriptor(
                    showsHeader: false,
                    canReorderRooms: true,
                    canReorderKinds: true
                ) == nil
            )

            let singleKind = DeviceStack(
                id: "kind:light",
                source: .kind(.light),
                title: "灯",
                devices: [Self.makeLight("l1")]
            )
            #expect(
                singleKind.headerlessMenuDescriptor(
                    showsHeader: false,
                    canReorderRooms: false,
                    canReorderKinds: true
                )?.title == "类型：灯"
            )
            // With only one kind in the home, there is nothing to reorder for kinds.
            #expect(
                singleKind.headerlessMenuDescriptor(
                    showsHeader: false,
                    canReorderRooms: false,
                    canReorderKinds: false
                ) == nil
            )
        }
    }

    @MainActor
    @Test("Sole online Favorites stack keeps its header when accompanied by the bottom offline drawer, and manually opened >8 single-device stacks remain collapsible")
    func favoritesHeaderWithOfflineDrawerAndOverviewFoldedCollapse() async throws {
        let suiteName = "com.menubarmijia.tests.stackpolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let favLight = Self.makeLight("fav_1", name: "客厅主灯", roomId: "living", roomName: "客厅")
        var offlineLight = Self.makeLight("off_1", name: "离线筒灯", roomId: "bedroom", roomName: "卧室")
        offlineLight.isOnline = false

        let rooms = [
            RoomArea(id: "living", name: "客厅", sortOrder: 0),
            RoomArea(id: "bedroom", name: "卧室", sortOrder: 1),
            RoomArea(id: "study", name: "书房", sortOrder: 2),
        ]
        let provider = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: rooms,
            devices: [favLight, offlineLight],
            scenes: []
        ))
        let store = HomeStore(provider: provider, defaultsSuiteName: suiteName)
        try await store.waitForTestSnapshot()
        store.favoriteDeviceIds = ["fav_1"]
        store.favoriteOrder = ["fav_1"]

        // Bugbot 4623917115: onlineStacks has 1 item (`fav`), but total stacks is 2 (`fav` + `offline`),
        // so `常用` keeps its section header to contrast against `离线或未通电` below it.
        let panelWithOffline = ControlCenterPanel(store: store)
        let stacksWithOffline = panelWithOffline.deviceStacks
        let onlineStacks = stacksWithOffline.filter { $0.source != .offline }
        #expect(onlineStacks.map(\.id) == ["fav"])
        #expect(stacksWithOffline.map(\.id) == ["fav", PanelDeviceOrganizer.offlineSectionId])
        #expect(onlineStacks[0].showsHeader(totalStacks: stacksWithOffline.count) == true)

        // P2-4: 7 pinned favorites + 2 single-device rooms (total 9 > 8):
        // room:bedroom (8th) opens in initial overview, while room:study (9th) folds into overviewFolded.
        // Even if the user expands stacks (e.g. initialOfflineExpanded or manual expand), overviewFolded
        // stays independent of expandedStacks so room:study keeps its collapsible header without displacing room:bedroom.
        var nineDevices: [SmartDevice] = (1...7).map { idx in
            Self.makeLight("fav_\(idx)", name: "常用灯 \(idx)", roomId: "living", roomName: "客厅")
        }
        nineDevices.append(Self.makeLight("bed_single", name: "卧室床头灯", roomId: "bedroom", roomName: "卧室"))
        nineDevices.append(Self.makeLight("study_single", name: "书房台灯", roomId: "study", roomName: "书房"))
        store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(rooms: rooms, devices: nineDevices, scenes: [])))
        let favIds = (1...7).map { "fav_\($0)" }
        store.favoriteDeviceIds = Set(favIds)
        store.favoriteOrder = favIds

        let overEightPanel = ControlCenterPanel(store: store)
        let nineStacks = overEightPanel.deviceStacks
        let folded = overEightPanel.overviewFoldedStackIds(in: nineStacks)
        #expect(folded == ["room:study"])
        let bedroomStack = try #require(nineStacks.first(where: { $0.id == "room:bedroom" }))
        let studyStack = try #require(nineStacks.first(where: { $0.id == "room:study" }))
        #expect(overEightPanel.isStackOpen(bedroomStack, overviewFolded: folded) == true)
        #expect(overEightPanel.isStackOpen(studyStack, overviewFolded: folded) == false)
        // Once manually expanded, `folded.contains(studyStack.id)` remains true -> header + Collapse button stay shown.
        let showsHeaderWhenExpanded = studyStack.showsHeader(totalStacks: nineStacks.count, listCut: store.listCut)
            || folded.contains(studyStack.id)
        let canCollapseWhenExpanded = studyStack.canCollapse(listCut: store.listCut)
            || folded.contains(studyStack.id)
        #expect(showsHeaderWhenExpanded == true)
        #expect(canCollapseWhenExpanded == true)
    }
}
