import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Coverage-guided mutation review regressions")
struct CoverageGuidedMutationReviewTests {
    @Test("Bandit credit excludes a splice arm that could not affect the child")
    func ineffectiveSpliceIsNotRecorded() {
        var experiments = FuzzExperiments()
        experiments.banditBands = true
        let runner = FuzzRunner(
            gen: Gen.choose(in: 0 ... 10 as ClosedRange<Int>),
            property: { _ in .pass },
            source: SyntheticCoverageSource<Int>(edgeCount: 2, edges: { _ in [0] }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: seedSelectingSplice(),
                experiments: experiments
            )
        )
        let parentSequence: ChoiceSequence = [
            .value(ChoiceSequenceValue.Value(
                choice: ChoiceValue(5, tag: .int64),
                validRange: 0 ... 10,
                isRangeExplicit: true
            )),
        ]
        let admission = runner.corpus.offer(
            sequence: parentSequence,
            tree: .just,
            hits: [(edge: 0, hitCount: 1)],
            convergence: 1,
            generation: 0,
            phase: .sampling
        )
        guard case let .admitted(parentIndex, _) = admission else {
            Issue.record("Expected the sole parent to be admitted")
            return
        }

        let (_, armsMask) = runner.nextCandidate(
            from: runner.corpus.entries[parentIndex]
        )
        let spliceMask = UInt8(1) << UInt8(MutationArm.splice.rawValue)
        #expect(armsMask & spliceMask == 0)
    }
}

private func seedSelectingSplice() -> UInt64 {
    for seed in UInt64(0) ..< 1000 {
        var generator = Xoshiro256(seed: seed)
        _ = generator.next(upperBound: 3)
        let banditDraw = Double(generator.next() >> 11) / Double(1 << 53)
        if banditDraw >= 0.75 {
            return seed
        }
    }
    preconditionFailure("Expected to find a seed selecting the splice arm")
}
