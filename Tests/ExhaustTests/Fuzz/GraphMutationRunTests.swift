import ExhaustCore
import ExhaustTestSupport
import Testing
@testable import Exhaust

@Suite("Graph-mutation run tests")
struct GraphMutationRunTests {
    @Test("A run with the graphMutation knob on is deterministic under a pinned seed and still finds faults")
    func graphMutationRunIsSeedStable() {
        func runOutcome(seed: UInt64) -> (attempts: Int, forms: Set<String>) {
            var experiments = FuzzExperiments()
            experiments.graphMutation = true
            experiments.banditBands = true
            experiments.stackedMutation = true
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
        let first = runOutcome(seed: 23)
        let second = runOutcome(seed: 23)
        #expect(first.attempts == second.attempts)
        #expect(first.forms == second.forms)
        #expect(first.forms.isEmpty == false)
    }

    @Test("A run with the pairMutation knob on is deterministic under a pinned seed and still finds faults")
    func pairMutationRunIsSeedStable() {
        func runOutcome(seed: UInt64) -> (attempts: Int, forms: Set<String>) {
            var experiments = FuzzExperiments()
            experiments.graphMutation = true
            experiments.pairMutation = true
            experiments.banditBands = true
            experiments.stackedMutation = true
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
        let first = runOutcome(seed: 29)
        let second = runOutcome(seed: 29)
        #expect(first.attempts == second.attempts)
        #expect(first.forms == second.forms)
        #expect(first.forms.isEmpty == false)
    }

    @Test("A run with the campaignMutation knob on is deterministic under a pinned seed and still finds faults")
    func campaignRunIsSeedStable() {
        func runOutcome(seed: UInt64) -> (attempts: Int, forms: Set<String>) {
            var experiments = FuzzExperiments()
            experiments.graphMutation = true
            experiments.pairMutation = true
            experiments.campaignMutation = true
            experiments.banditBands = true
            experiments.stackedMutation = true
            experiments.powerSchedule = true
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
                    attemptLimit: 3000,
                    experiments: experiments
                )
            )
            let result = runner.run()
            return (result.counts.totalAttempts, Set(result.clusters.map(\.reducedDescription)))
        }
        let first = runOutcome(seed: 31)
        let second = runOutcome(seed: 31)
        #expect(first.attempts == second.attempts)
        #expect(first.forms == second.forms)
        #expect(first.forms.isEmpty == false)
    }

    @Test("The stall gate opens within a starved run and campaigns evaluate candidates")
    func campaignsFire() {
        var experiments = FuzzExperiments()
        experiments.campaignMutation = true
        let runner = FuzzRunner(
            gen: Gen.zip(
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
            ),
            property: { _ in .pass },
            // A two-edge map saturates immediately, so admissions stop and every parent's quiet-child counter climbs past the gate.
            source: SyntheticCoverageSource<(Int, Int, Int)>(edgeCount: 2, edges: { _ in [0, 1] }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 41,
                attemptLimit: 3000,
                experiments: experiments
            )
        )
        let result = runner.run()
        #expect(result.counts.campaignAttempts > 0)
    }

    @Test("Campaigns on a bind-bearing generator stay deterministic and materializable")
    func campaignRunWithBindRegions() {
        func runOutcome(seed: UInt64) -> (attempts: Int, discards: Int) {
            var experiments = FuzzExperiments()
            experiments.campaignMutation = true
            experiments.banditBands = true
            let runner = FuzzRunner(
                gen: Gen.choose(in: 1 ... 5 as ClosedRange<Int>).bindReified { length in
                    Gen.arrayOf(Gen.choose(in: 0 ... 1000 as ClosedRange<Int>), exactly: UInt64(length))
                },
                property: { values in
                    values.reduce(0, +) > 4200 ? .fail(.returnedFalse) : .pass
                },
                source: SyntheticCoverageSource<[Int]>(edgeCount: 32, edges: { values in
                    [values.count & 0b111, 8 + ((values.first ?? 0) & 0b111)]
                }),
                configuration: FuzzRunnerConfiguration(
                    budgetNanoseconds: 60_000_000_000,
                    seed: seed,
                    attemptLimit: 3000,
                    experiments: experiments
                )
            )
            let result = runner.run()
            return (result.counts.totalAttempts, result.counts.discardedAttempts)
        }
        let first = runOutcome(seed: 37)
        let second = runOutcome(seed: 37)
        #expect(first.attempts == second.attempts)
        #expect(first.discards == second.discards)
    }
}
