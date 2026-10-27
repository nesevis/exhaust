import Testing
@testable import ExhaustCore

@Suite("Post-cycle action ordering")
struct PostCycleSchedulingTests {
    @Test("Relation follows confirmation on the adopted graph unless the deadline expired", arguments: [false, true])
    func relationFollowsConfirmation(expires: Bool) throws {
        let leaf = Gen.choose(in: UInt64(0) ... 100)
        let generator = Gen.zip(leaf, leaf, leaf)
        let start = (UInt64(50), UInt64(6), UInt64(9))
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var now: UInt64 = 0
        var calls: [(UInt64, UInt64, UInt64)] = []
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: 10,
                enabledEncoders: [.convergenceConfirmation, .relationSearch]
            ),
            collectStats: true,
            currentNanoseconds: { now },
            property: { value in
                calls.append(value)
                now = expires ? 10 : 0
                return value.0 < 49 || value.1 == 0 || value.1 * 3 != value.2 * 2
            }
        )
        runner.graph.markLeavesConverged()
        runner.stallBudget = 0

        #expect(runner.runPostCycleActions([.confirmConvergence, .relationPass]) == (expires ? .deadline : .completed))

        let output = try #require(runner.incumbent.output as? (UInt64, UInt64, UInt64))
        #expect(output == (expires ? (49, 6, 9) : (49, 2, 3)))
        #expect(calls.first?.0 == 49)
        #expect(calls.contains { $0 == (49, 2, 3) } == (expires == false))
        #expect(runner.stats.encoderProbesAccepted[.convergenceConfirmation] == 1)
        #expect(runner.stats.encoderProbesAccepted[.relationSearch, default: 0] == (expires ? 0 : 1))
        #expect(runner.incumbent.sequence == ChoiceSequence(runner.incumbent.tree))
        #expect(runner.stallBudget == 2)
    }

    @Test("Relaxation is skipped after an earlier scheduled action improves the counterexample")
    func relaxationWaitsForAnotherStall() throws {
        let arms = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 100)),
            (1, Gen.choose(in: UInt64(200) ... 300)),
        ])
        let generator = Gen.zip(arms, Gen.choose(in: UInt64(0) ... 100))
        let start = (UInt64(250), UInt64(80))
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var calls = 0
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 2, enabledEncoders: [.branchPivot]),
            collectStats: true,
            property: { _ in
                calls += 1
                return false
            }
        )

        #expect(runner.runPostCycleActions([.improvingPivots, .relaxRound]) == .completed)

        #expect(calls == 1)
        #expect(runner.stats.relaxImprovingAcceptances == 1)
        // The skip must be caused by acceptance, not by an empty relaxation candidate set.
        let candidates = RelaxCandidateCursor(
            sequence: runner.incumbent.sequence,
            graph: runner.graph,
            limit: 1,
            isEncoderEnabled: runner.isEncoderEnabled
        )
        #expect(candidates.candidateCount > 0)
    }
}
