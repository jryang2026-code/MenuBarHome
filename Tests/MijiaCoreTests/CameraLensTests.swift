import Testing
@testable import MijiaCore

struct CameraLensTests {
    @Test("Verified dual-lens models expose main and second lenses")
    func verifiedDualModelsExposeBothLenses() throws {
        let lenses = CameraLensCatalog.lenses(for: "isa.camera.500dh")
        #expect(lenses.map(\.role) == [.main, .secondary])
        #expect(lenses.map(\.channel) == [0, 1])
    }

    @Test("Unknown models stay single-lens")
    func unknownModelsHaveNoLensChoice() {
        #expect(CameraLensCatalog.lenses(for: "chuangmi.camera.81ac1").isEmpty)
    }

    @Test("A device name that says dual gets a lens choice before its model is catalogued")
    func namedDualCameraGetsLensChoice() {
        #expect(CameraLensCatalog.lenses(for: "vendor.camera.unknown", name: "客厅双摄").count == 2)
        #expect(CameraLensCatalog.lenses(for: "vendor.camera.unknown", name: "Front dual-lens").count == 2)
        #expect(CameraLensCatalog.lenses(for: "vendor.camera.unknown", name: "双镜头摄像机").count == 2)
        #expect(CameraLensCatalog.lenses(for: "vendor.camera.unknown", name: "客廳雙攝").count == 2)
        #expect(CameraLensCatalog.lenses(for: "vendor.camera.unknown", name: "雙鏡頭攝像機").count == 2)
    }

    @Test("A name that only contains those letters is still one lens")
    func substringAndNegationStaySingleLens() {
        #expect(CameraLensCatalog.lenses(for: "chuangmi.camera.81ac1", name: "客厅摄像机").isEmpty)
        #expect(CameraLensCatalog.lenses(for: "vendor.camera.unknown", name: "Individual").isEmpty)
        #expect(CameraLensCatalog.lenses(for: "vendor.camera.unknown", name: "不是双摄").isEmpty)
        #expect(CameraLensCatalog.lenses(for: "vendor.camera.unknown", name: "不是双镜头").isEmpty)
        #expect(CameraLensCatalog.lenses(for: "vendor.camera.unknown", name: "不是雙攝").isEmpty)
        #expect(CameraLensCatalog.lenses(for: "vendor.camera.unknown", name: "not dual").isEmpty)
    }

    @Test("Camera synthesis attaches the catalog to a known camera only")
    func synthesisAttachesLenses() throws {
        let base = CameraSpec(entityId: "camera.test", isOn: true)
        let dual = try #require(caseCamera(MiotSynthesizer.attachCameraLenses(.camera(base), model: "isa.camera.hlmax")))
        #expect(dual.lenses.count == 2)

        let single = try #require(caseCamera(MiotSynthesizer.attachCameraLenses(.camera(base), model: "chuangmi.camera.81ac1")))
        #expect(single.lenses.isEmpty)
    }

    @Test("Battery-camera hub models map to their indoor receiver")
    func batteryCameraHubMapping() {
        #expect(CameraHubCatalog.hubModel(for: "mxiang.camera.mwc11") == "mxiang.camera.mwc10")
        #expect(CameraHubCatalog.isHub(model: "mxiang.camera.mwc10"))
        #expect(!CameraHubCatalog.isHub(model: "mxiang.camera.mwc11"))
    }

    private func caseCamera(_ kind: DeviceKind) -> CameraSpec? {
        guard case .camera(let spec) = kind else { return nil }
        return spec
    }
}
