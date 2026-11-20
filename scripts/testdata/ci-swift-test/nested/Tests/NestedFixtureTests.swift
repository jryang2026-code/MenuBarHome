import Testing

struct NestedFixtureTests {
    @Test("Nested helper case")
    func nestedHelperCase() async throws {
        final class SelectionBox: @unchecked Sendable {
            func set(_ next: String?) {}
        }
        let selection = SelectionBox()
        selection.set("h1")
        #expect(true)
    }
}
