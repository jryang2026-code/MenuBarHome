@testable import MijiaCore

extension SmartDevice {
    var coverSpec: CoverSpec? {
        guard case .cover(let spec) = kind else { return nil }
        return spec
    }
}
