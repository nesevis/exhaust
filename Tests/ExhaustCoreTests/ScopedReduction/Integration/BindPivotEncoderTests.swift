import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Reducer: bind pivot")
struct BindPivotEncoderTests {
    // MARK: - End to End

    /// A pick inside a bind's inner selects the dependent leaf's range. Under the larger inner branch the leaf's failing value is its reduction target; under the smaller inner branch the failing value lies in the part of the range the old inner never admitted. A plain pivot carries the old value across and passes, so the smaller inner is only reachable with the bound leaf enumerated after the pivot.
    @Test("A pivot of the bind inner is accepted with the bound leaf re-searched")
    func pivotWithCoveringSearchIsAccepted() throws {
        let generated = try generate(pairGen.gen, seed: pairSeed)
        try #require(generated.value == (1, 0))

        let result = Interpreters.choiceGraphReduceCollectingStats(
            gen: pairGen.gen,
            tree: generated.tree,
            output: generated.value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2, enabledEncoders: [.bindPivot]),
            property: pairProperty
        )

        let reduced = try #require(result.outcome.counterexample)
        #expect(reduced.1 == (3, 2))
        #expect(result.stats.encoderCounts[.bindPivot]?.accepted == 1)
        // Every leaf of the starting input is at its target, so the structural cycle stalls with nothing converged-but-movable. Without the release cycle the run would end there and the bind pivot scope, deferred until the release, would never be dispatched.
        #expect(result.stats.cycles >= 2)
        #expect((result.stats.encoderCounts[.bindPivot]?.emitted ?? 0) > 0)
    }

    @Test("The full encoder set reaches the smaller inner")
    func defaultConfigurationReachesSmallerInner() throws {
        let generated = try generate(pairGen.gen, seed: pairSeed)
        try #require(generated.value == (1, 0))

        let result = Interpreters.choiceGraphReduceCollectingStats(
            gen: pairGen.gen,
            tree: generated.tree,
            output: generated.value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2),
            property: pairProperty
        )

        let reduced = try #require(result.outcome.counterexample)
        #expect(reduced.1 == (3, 2))
    }

    /// The same shape with the smaller inner widening the bound range past what the covering enumerates. The failing value sits one below the upper bound, where the edge probes look.
    @Test("A single bound leaf with a large domain is searched at its range ends")
    func largeSingleLeafDomainIsSearched() throws {
        let gen = makePairGen(smallerInner: 100)
        let generated = try generate(gen.gen, seed: pairSeed)
        try #require(generated.value == (1, 0))

        let result = Interpreters.choiceGraphReduceCollectingStats(
            gen: gen.gen,
            tree: generated.tree,
            output: generated.value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2, enabledEncoders: [.bindPivot]),
            property: pairProperty
        )

        let reduced = try #require(result.outcome.counterexample)
        #expect(reduced.1 == (100, 99))
    }

    /// The inner alternative carries more leaves than the selected branch, but the bound subtree it selects is smaller, so the whole sequence shrinks. A leaf-count gate on the inner alone would have hidden this pivot.
    @Test("An inner branch with more leaves is lifted when the bound subtree shrinks more")
    func innerWithMoreLeavesIsLiftedWhenTotalShrinks() throws {
        let generated = try generate(countedArrayGen.gen, seed: countedArraySeed)
        try #require(generated.value.0 == 6 && generated.value.1.last == 5)

        let result = Interpreters.choiceGraphReduceCollectingStats(
            gen: countedArrayGen.gen,
            tree: generated.tree,
            output: generated.value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2, enabledEncoders: [.bindPivot]),
            property: { pair in pair.1.last != pair.0 - 1 }
        )

        let reduced = try #require(result.outcome.counterexample)
        #expect(reduced.1 == (1, [0]))
        #expect(result.stats.encoderCounts[.bindPivot]?.accepted == 1)
    }
}

// MARK: - Helpers

private let pairSeed: UInt64 = 6
private let countedArraySeed: UInt64 = 10

/// The inner pick's first branch is a bare constant, its second a zip of two pinned values, so the first branch is the shortlex-smaller alternative. The bound leaf ranges over `0 ... inner`.
private func makePairGen(smallerInner: UInt64) -> ReflectiveGenerator<(UInt64, UInt64)> {
    ReflectiveGenerator<UInt64>.oneOf(
        .just(smallerInner),
        Gen.zip(Gen.choose(in: UInt64(1) ... 1), Gen.choose(in: UInt64(0) ... 0))
            .map { first, _ in first }
            .wrapped(isReflective: true)
    )
    .bind { count in
        Gen.choose(in: UInt64(0) ... count)
            .map { (count, $0) }
            .wrapped(isReflective: false)
    }
}

private let pairGen = makePairGen(smallerInner: 3)

/// Fails on `(1, 0)` and `(3, 2)`: the bound value one below the inner.
private let pairProperty: @Sendable ((UInt64, UInt64)) -> Bool = { pair in
    pair.1 != pair.0 - 1
}

/// The inner pick's first branch is a constant six with no leaves, its second a zip of two pinned values yielding one. The bound array has exactly `inner` elements, so the second branch costs three more inner entries and five fewer bound elements.
private let countedArrayGen: ReflectiveGenerator<(UInt64, [UInt64])> = ReflectiveGenerator<UInt64>.oneOf(
    .just(6),
    Gen.zip(Gen.choose(in: UInt64(1) ... 1), Gen.choose(in: UInt64(0) ... 0))
        .map { first, _ in first }
        .wrapped(isReflective: true)
)
.bind { count in
    Gen.arrayOf(Gen.choose(in: UInt64(0) ... 5), within: count ... count)
        .map { (count, $0) }
        .wrapped(isReflective: false)
}
