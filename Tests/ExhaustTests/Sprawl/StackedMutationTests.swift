import ExhaustCore
import ExhaustTestSupport
import Testing
@testable import Exhaust

@Suite("Stacked-mutation determinism tests")
struct StackedMutationTests {
    @Test("A run with every search-power knob on is deterministic under a pinned seed")
    func stackedRunIsSeedStable() {
        func runOutcome(seed: UInt64) -> (attempts: Int, forms: Set<String>) {
            var experiments = SprawlExperiments()
            experiments.stackedMutation = true
            experiments.banditBands = true
            experiments.powerSchedule = true
            let runner = SprawlRunner(
                gen: Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                property: { value in
                    value > 940 ? .fail(.returnedFalse) : .pass
                },
                source: SyntheticCoverageSource<Int>(edgeCount: 32, edges: { value in
                    [value & 0b111, 8 + ((value >> 3) & 0b111)]
                }),
                configuration: SprawlRunnerConfiguration(
                    budgetNanoseconds: 60_000_000_000,
                    seed: seed,
                    attemptLimit: 1200,
                    experiments: experiments
                )
            )
            let result = runner.run()
            return (result.totalAttempts, Set(result.clusters.map(\.reducedDescription)))
        }
        let first = runOutcome(seed: 17)
        let second = runOutcome(seed: 17)
        #expect(first.attempts == second.attempts)
        #expect(first.forms == second.forms)
        #expect(first.forms.contains("941"))
    }
}
