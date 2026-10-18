import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped reducer integration")
struct ScopedReducerIntegrationTests {
    @Test("Non-bind generator reduces to expected counterexample")
    func nonBindReduction() throws {
        let gen = Gen.choose(in: UInt64(0) ... 1000)

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (value, tree) = try #require(try iterator.next())
        try #require(value > 5)

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, output: value, config: .init(maxStalls: 2)) {
                $0 < 5
            }.counterexample
        )

        #expect(output == 5)
    }

    @Test("CollectingStats returns valid statistics")
    func collectingStatsReturnsStats() throws {
        let gen = Gen.choose(in: UInt64(0) ... 100)

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (value, tree) = try #require(try iterator.next())
        try #require(value > 10)

        let result = Interpreters.choiceGraphReduceCollectingStats(
            gen: gen,
            tree: tree,
            output: value,
            config: .init(maxStalls: 2)
        ) { $0 < 10 }

        if case .reduced = result.outcome {
            // Reduction succeeded
        } else {
            Issue.record("Expected .reduced outcome")
        }
        #expect(result.stats.cycles > 0)
        #expect(result.stats.totalMaterializations > 0)
    }
}
