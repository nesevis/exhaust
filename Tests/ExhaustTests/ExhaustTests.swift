import Testing
@testable import Exhaust

@Test func example() async throws {
    let gen = boolArrayGen()
    let results = Interpreters.generate(gen) ?? []
    #expect(Set(results).count == 2)
}
