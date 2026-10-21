import ExhaustCore
import ExhaustTestSupport
import Testing
@testable import Exhaust

@Suite("Graph-mutation run tests")
struct GraphMutationRunTests {
    @Test("Graph and pair mutation preserve seeded replay and find faults", arguments: [(false, UInt64(23)), (true, UInt64(29))])
    func graphMutationRunIsSeedStable(pairMutation: Bool, seed: UInt64) {
        func runOutcome(seed: UInt64) -> (attempts: Int, forms: Set<String>) {
            var experiments = FuzzExperiments()
            experiments.graphMutation = true
            experiments.pairMutation = pairMutation
            experiments.banditBands = true
            let runner = FuzzRunner(
                gen: Gen.zip(
                    Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                    Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                    Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
                ),
                property: { value in
                    value.0 + value.1 + value.2 > 2800 ? .fail(.returnedFalse) : .pass
                },
                source: SyntheticCoverageSource<(Int, Int, Int)>(edgeCount: 32, edges: { value in
                    [value.0 & 0b111, 8 + (value.1 & 0b111), 16 + (value.2 & 0b111)]
                }),
                configuration: FuzzRunnerConfiguration(
                    budgetNanoseconds: 60_000_000_000,
                    seed: seed,
                    attemptLimit: 1500,
                    experiments: experiments
                )
            )
            let result = runner.run()
            return (result.counts.totalAttempts, Set(result.clusters.map(\.reducedDescription)))
        }
        let first = runOutcome(seed: seed)
        let second = runOutcome(seed: seed)
        #expect(first.attempts == second.attempts)
        #expect(first.forms == second.forms)
        #expect(first.forms.isEmpty == false)
    }
}
