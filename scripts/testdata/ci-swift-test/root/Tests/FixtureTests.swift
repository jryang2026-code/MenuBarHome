import Testing

struct FixtureTests {
    @Test("Flaky cover case")
    func flakyCover() async throws {
        #expect(1 == 1)
    }

    @Test("Flaky scene case")
    func flakyScene() async throws {
        #expect(1 == 1)
    }
}
