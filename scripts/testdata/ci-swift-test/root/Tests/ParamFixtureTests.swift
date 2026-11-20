import Testing

struct ParamFixtureTests {
    @Test("Fold layout picks the first card", arguments: [1, 2])
    func foldLayout(value: Int) async throws {
        #expect(value == 0)
    }
}
