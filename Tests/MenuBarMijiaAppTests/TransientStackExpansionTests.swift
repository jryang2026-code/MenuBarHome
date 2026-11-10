import Testing
@testable import MenuBarMijiaApp

struct TransientStackExpansionTests {
    @Test func hoveredSingleExpandsWhenSecondCardArrives() {
        #expect(!TransientStackExpansion.isExpanded(isHovered: true, cardCount: 1))
        #expect(TransientStackExpansion.isExpanded(isHovered: true, cardCount: 2))
    }

    @Test func hoveredStackReexpandsAfterCardReplacement() {
        let counts = [2, 1, 2]
        #expect(counts.map { TransientStackExpansion.isExpanded(isHovered: true, cardCount: $0) } == [true, false, true])
        #expect(!TransientStackExpansion.isExpanded(isHovered: false, cardCount: 2))
    }
}
