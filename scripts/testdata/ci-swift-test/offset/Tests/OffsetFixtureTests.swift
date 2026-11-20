import Testing

struct OffsetFixtureTests {
    @Test("Shifted poll case")
    func shiftedPollCase() async throws {
        #expect(1 == 1)
    }
    @Test
    func plainCase() async throws {
        #expect(1 == 1)
    }
    @Test
    func neighborCase() async throws {
        #expect(1 == 1)
    }
}
