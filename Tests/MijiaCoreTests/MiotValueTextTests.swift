import Foundation
import Testing
@testable import MijiaCore

/// UX-13 and UX-14: value-list words and units read in the language the person is using,
/// and a fault code is never the only thing the banner says.
struct MiotValueTextTests {
    /// A dryer publishes the same mode words as a washer (`bshcn.dry.2j7x10`: `Mix`, `Baby Care`,
    /// `Down Coat`, `Synthetic`). One shared table serves both, so a dryer menu must not read as a
    /// washing programme.
    @Test("A dryer mode word does not read as a washing programme")
    func dryerModesCarryNoWash() {
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(MiotValueText.display("Baby Care") == "婴童")
            #expect(MiotValueText.display("Down Coat") == "羽绒")
            for mode in ["Mix", "Baby Care", "Down Coat", "Synthetic", "Wool", "Cotton"] {
                #expect(!MiotValueText.display(mode).contains("洗"))
            }
            #expect(MiotValueText.display("Quick Wash") == "快速洗")
            #expect(MiotValueText.display("Rinse") == "漂洗")
        }
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(MiotValueText.display("Down Coat") == "羽絨")
            #expect(!MiotValueText.display("Down Coat").contains("洗"))
            #expect(MiotValueText.display("Quick Wash") == "快速洗")
        }
    }

    /// 洗 stays on wash, rinse, and spin. Every other programme name is shared with dryers.
    @Test("A programme whose words are not wash, rinse, or spin does not display 洗")
    func nonWashProgrammesDoNotSayWash() {
        let washWords: Set<String> = ["wash", "rinse", "spin"]
        for key in MiotValueText.programmeKeys {
            let words = Set(key.split(separator: " ").map(String.init))
            if !words.isDisjoint(with: washWords) { continue }
            for language in [AppLanguage.zhHans, AppLanguage.zhHant] {
                L10n.$overrideLanguage.withValue(language) {
                    let name = MiotValueText.display(key)
                    #expect(!name.contains("洗"), "\(key) in \(language.rawValue) displays \(name)")
                }
            }
        }
    }

    @Test("A selected value-list word uses the same names as the programme menu")
    func selectedOptionUsesTheTable() {
        let options = [
            MiotFacetOption(value: 0, label: "Day"),
            MiotFacetOption(value: 1, label: "Level1"),
        ]
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(reading(value: 0, options: options) == "白天")
            #expect(reading(value: 1, options: options) == "1 档")
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(reading(value: 0, options: options) == "Day")
            #expect(reading(value: 1, options: options) == "Level1")
        }
    }

    @Test("A bare fault code explains itself, and a known description keeps its code")
    func faults() {
        L10n.$overrideLanguage.withValue(.zhHans) {
            let code = MiotValueText.faultNotice("E3")
            #expect(code.message == "设备上报故障代码 E3，请查看说明书或米家 App")
            #expect(code.copyText == "E3")
            let numeric = MiotValueText.faultNotice("2")
            #expect(numeric.message == "设备上报故障代码 2，请查看说明书或米家 App")
            #expect(numeric.copyText == "2")
            let described = MiotValueText.faultNotice("Dehydration Fault")
            #expect(described.message == "故障 E3 · 衣物分布不平衡")
            #expect(described.copyText == "E3")
            let prose = MiotValueText.faultNotice("AquaStopOccured")
            #expect(prose.message == "故障 · 防漏水系统已激活")
            #expect(prose.copyText == "AquaStopOccured")
            let unknown = MiotValueText.faultNotice("ZZZ")
            #expect(unknown.message == "设备上报故障「ZZZ」，请查看说明书或米家 App")
            #expect(unknown.copyText == "ZZZ")
        }
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(
                MiotValueText.faultNotice("E3").message
                    == "裝置回報故障代碼 E3，請查看說明書或米家 App"
            )
            #expect(MiotValueText.faultNotice("Dehydration Fault").message == "故障 E3 · 衣物分佈不平衡")
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(
                MiotValueText.faultNotice("E3").message
                    == "The device reported fault code E3. Check the manual or the Mi Home app."
            )
            #expect(MiotValueText.faultNotice("E3").copyText == "E3")
            #expect(MiotValueText.faultNotice("Dehydration Fault").message == "Fault E3 · Dehydration Fault")
            #expect(MiotValueText.faultNotice("ZZZ").message.contains("ZZZ"))
        }
    }

    @Test("去处理 points at the locked control for the alarm, and nowhere when that control is already writable")
    func alarmTarget() {
        let status = facet(
            id: "2.4",
            kind: .reading,
            name: "water-pump-status",
            value: .number(4),
            options: [MiotFacetOption(value: 4, label: "Blocked")],
            writable: false
        )
        let pump = facet(id: "2.2", kind: .toggle, name: "water-pump", value: .bool(true))
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(
                MiotFacetText.lockedControlID(
                    forAlert: "水泵状态：堵塞",
                    controls: [status, pump],
                    allowsAdvancedWrites: false
                ) == "2.2"
            )
            #expect(
                MiotFacetText.lockedControlID(
                    forAlert: "水泵状态：堵塞",
                    controls: [status, pump],
                    allowsAdvancedWrites: true
                ) == nil
            )
            var allowed = pump
            allowed.writesByDefault = true
            #expect(
                MiotFacetText.lockedControlID(
                    forAlert: "水泵状态：堵塞",
                    controls: [status, allowed],
                    allowsAdvancedWrites: false
                ) == nil
            )
            var confirmed = pump
            confirmed.isConfirmedWrite = true
            #expect(
                MiotFacetText.lockedControlID(
                    forAlert: "水泵状态：堵塞",
                    controls: [status, confirmed],
                    allowsAdvancedWrites: false
                ) == nil
            )
        }
    }

    @Test("A Chinese alarm baked before a language switch still points at the pump facet")
    func alarmTargetSurvivesLanguageChange() {
        let status = facet(
            id: "2.4",
            kind: .reading,
            name: "water-pump-status",
            value: .number(4),
            options: [MiotFacetOption(value: 4, label: "Blocked")],
            writable: false
        )
        let pump = facet(id: "2.2", kind: .toggle, name: "water-pump", value: .bool(true))
        let baked = L10n.$overrideLanguage.withValue(.zhHans) {
            MiotFacetEngine.alertText(
                title: MiotFacetText.title(name: "water-pump-status", title: nil),
                propertyName: "water-pump-status",
                label: "Blocked"
            )
        }
        #expect(baked == "水泵状态：堵塞")
        L10n.$overrideLanguage.withValue(.en) {
            #expect(
                MiotFacetText.lockedControlID(
                    forAlert: baked,
                    controls: [status, pump],
                    allowsAdvancedWrites: false
                ) == "2.2"
            )
        }
    }

    @Test("The view-only sentence appears only when every writable facet is advanced-locked")
    func viewOnlyCopyRequiresEveryWriteLocked() {
        let locked = facet(id: "4.2", kind: .select, name: "mode", value: .number(0))
        var open = facet(id: "3.1", kind: .toggle, name: "brightness", value: .bool(true))
        open.writesByDefault = true
        #expect(MiotFacetText.showsAdvancedViewOnlyCopy(controls: [locked], allowsAdvancedWrites: false))
        #expect(!MiotFacetText.showsAdvancedViewOnlyCopy(controls: [locked, open], allowsAdvancedWrites: false))
        #expect(!MiotFacetText.showsAdvancedViewOnlyCopy(controls: [locked], allowsAdvancedWrites: true))
        #expect(!MiotFacetText.showsAdvancedViewOnlyCopy(controls: [], allowsAdvancedWrites: false))
    }

    @Test("A facet write sends the spec value, and a Chinese programme name sends nothing")
    @MainActor
    func writesKeepTheSpecWord() async throws {
        let mode = FacetControl(
            id: "2.2",
            kind: .select,
            name: "mode",
            title: nil,
            serviceName: "washer",
            value: .number(1),
            options: [MiotFacetOption(value: 1, label: "Quick Wash")],
            isWritable: true,
            writesByDefault: true,
            isHighValue: false,
            target: .property(entityId: "miot:washer:2", piid: 2)
        )
        #expect(
            HomeStore.facetCommand(for: mode, value: .number(1))
                == .setMiotProperty(entityId: "miot:washer:2", piid: 2, value: .number(1))
        )
        let haMode = FacetControl(
            id: "select.mode",
            kind: .select,
            name: "mode",
            title: nil,
            serviceName: "select",
            value: .number(1),
            options: [MiotFacetOption(value: 1, label: "Quick Wash")],
            isWritable: true,
            writesByDefault: true,
            isHighValue: false,
            target: .haProperty(entityId: "select.mode")
        )
        #expect(
            HomeStore.facetCommand(for: haMode, value: .number(1))
                == .setSelectOption(entityId: "select.mode", option: "Quick Wash")
        )

        let device = SmartDevice(
            id: "washer",
            name: "洗衣机",
            roomId: "balcony",
            roomName: "阳台",
            model: "test.washer",
            isOnline: true,
            kind: .appliance(ApplianceSpec(
                entityId: "miot:washer:2",
                isOn: true,
                powerPresent: true,
                powerWritable: true,
                currentMode: "Mix",
                availableModes: ["Mix", "Quick Wash"],
                modeWritable: true
            ))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [device], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.miotvalue.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()

        store.setApplianceMode("washer", mode: "混合")
        await Task.yield()
        #expect(await mock.executedCommands.isEmpty)
        if case .appliance(let spec) = store.devices.first?.kind {
            #expect(spec.currentMode == "Mix")
        } else {
            Issue.record("washer left the store")
        }

        store.setApplianceMode("washer", mode: "Quick Wash")
        await waitUntil { await mock.executedCommands.count == 1 }
        #expect(await mock.executedCommands == [
            .setSelectOption(entityId: "miot:washer:2", option: "Quick Wash")
        ])
    }

    private func reading(
        unit: String? = nil,
        number: Double? = nil,
        value: Int? = nil,
        kind: MiotFacetKind = .reading,
        options: [MiotFacetOption] = []
    ) -> String {
        let stored: JSONValue?
        if let value {
            stored = .number(Double(value))
        } else if let number {
            stored = .number(number)
        } else {
            stored = nil
        }
        return MiotFacetText.value(
            kind: kind,
            value: stored,
            unit: unit,
            scale: nil,
            options: options
        )
    }

    private func facet(
        id: String,
        kind: MiotFacetKind,
        name: String,
        value: JSONValue?,
        options: [MiotFacetOption] = [],
        writable: Bool = true
    ) -> FacetControl {
        FacetControl(
            id: id,
            kind: kind,
            name: name,
            title: nil,
            serviceName: "fish-tank",
            value: value,
            options: options,
            isWritable: writable,
            writesByDefault: false,
            isHighValue: false
        )
    }
}
