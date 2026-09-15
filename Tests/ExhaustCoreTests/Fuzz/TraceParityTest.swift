import Foundation
import Testing
@testable import ExhaustCore

@Suite("Trace parity with picks")
struct TraceParityPickTest {
    @Test("Seeded run with a pick generator produces identical arm counts across two runs")
    func pickGeneratorDeterminism() {
        func run() -> FuzzRunCounts {
            var experiments = FuzzExperiments()
            experiments.graphMutation = true
            experiments.pairMutation = true
            let branchA: Generator<Int> = Gen.zip(
                Gen.choose(in: 0 ... 500 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 500 as ClosedRange<Int>)
            ).map { $0.0 + $0.1 }
            let branchB: Generator<Int> = Gen.zip(
                Gen.choose(in: 0 ... 500 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 500 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 500 as ClosedRange<Int>)
            ).map { $0.0 + $0.1 + $0.2 }
            let generator = Gen.pick(choices: [(1, branchA), (1, branchB)])
            let source = SyntheticCoverageSource<Int>(edgeCount: 16, edges: { value in
                [value & 0b111, 8 + ((value >> 3) & 0b111)]
            })
            let runner = FuzzRunner(
                gen: generator,
                property: { value in
                    value > 1200 ? .fail(.returnedFalse) : .pass
                },
                source: source,
                configuration: FuzzRunnerConfiguration(
                    budgetNanoseconds: 60_000_000_000,
                    seed: 1337,
                    attemptLimit: 20000,
                    experiments: experiments
                )
            )
            return runner.run().counts
        }
        let first = run()
        let second = run()
        for arm in MutationArm.allCases {
            #expect(
                first.mutationArms.draws(arm: arm) == second.mutationArms.draws(arm: arm),
                "Draw count diverged for \(arm)"
            )
            #expect(
                first.mutationArms.misses(arm: arm) == second.mutationArms.misses(arm: arm),
                "Miss count diverged for \(arm)"
            )
            #expect(
                first.mutationArms.admissions(arm: arm) == second.mutationArms.admissions(arm: arm),
                "Admission count diverged for \(arm)"
            )
        }
        #expect(first.totalAttempts == second.totalAttempts)
        let totalDraws = MutationArm.allCases.reduce(0) { $0 + first.mutationArms.draws(arm: $1) }
        #expect(totalDraws > 0, "No mutation draws at all")
    }
}
