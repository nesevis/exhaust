import ExhaustTestSupport
import Foundation
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

        let result = try Interpreters.choiceGraphReduceCollectingStats(
            gen: pairGen.gen,
            tree: generated.tree,
            output: generated.value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2, enabledEncoders: [.bindPivot]),
            property: pairProperty
        )

        let reduced = try #require(result.outcome.counterexample)
        #expect(reduced.1 == (3, 2))
        #expect(result.stats.encoderCounts[.bindPivot]?.accepted == 1)
    }

    @Test("The full encoder set reaches the smaller inner")
    func defaultConfigurationReachesSmallerInner() throws {
        let generated = try generate(pairGen.gen, seed: pairSeed)
        try #require(generated.value == (1, 0))

        let result = try Interpreters.choiceGraphReduceCollectingStats(
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

        let result = try Interpreters.choiceGraphReduceCollectingStats(
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

        let result = try Interpreters.choiceGraphReduceCollectingStats(
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

    /// Every leaf of the starting input is at its target, so the structural cycle stalls with nothing converged-but-movable. Without the release cycle the run would end there and the bind pivot scope, deferred until the release, would never be dispatched.
    @Test("Releasing the bind-inner deferral is followed by a cycle that dispatches the deferred scopes")
    func deferralReleaseGetsACycle() throws {
        let generated = try generate(pairGen.gen, seed: pairSeed)
        try #require(generated.value == (1, 0))

        let result = try Interpreters.choiceGraphReduceCollectingStats(
            gen: pairGen.gen,
            tree: generated.tree,
            output: generated.value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2, enabledEncoders: [.bindPivot]),
            property: pairProperty
        )

        #expect(result.stats.cycles >= 2)
        #expect((result.stats.encoderCounts[.bindPivot]?.emitted ?? 0) > 0)
    }

    // MARK: - Probe Loop

    @Test("A lift that fails produces no probes")
    func failedLiftIsInert() throws {
        let fixture = try nestedFixture()
        var encoder = GraphBindPivotEncoder(lift: { _, _ in nil })
        encoder.start(scope: fixture.scope)

        var buffer = fixture.scope.baseSequence
        #expect(encoder.nextProbe(into: &buffer, lastAccepted: false) == nil)
    }

    @Test("A lift longer than the base sequence produces no probes")
    func longerLiftIsGated() throws {
        let fixture = try nestedFixture()
        let longer = try generate(Gen.arrayOf(Gen.choose(in: UInt64(0) ... 5), within: 40 ... 40), seed: 1).tree
        try #require(ChoiceSequence.flatten(longer).count > fixture.scope.baseSequence.count)
        var encoder = GraphBindPivotEncoder(lift: { _, _ in longer })
        encoder.start(scope: fixture.scope)

        var buffer = fixture.scope.baseSequence
        #expect(encoder.nextProbe(into: &buffer, lastAccepted: false) == nil)
    }

    /// The bound subtree is a pick with one same-family descendant, so the encoder lifts the plain pivot and then the transplant of that descendant. Each lift yields its lifted sequence as a probe, then the loop runs dry and stays dry.
    @Test("Transplant seeds are lifted after the plain pivot until the seeds run out")
    func transplantSeedsAreLiftedInOrder() throws {
        let fixture = try nestedFixture()
        let liftCount = UnsafeSendableBox(0)
        var encoder = GraphBindPivotEncoder(lift: { candidate, fallbackTree in
            liftCount.value += 1
            guard case let .success(_, tree, _) = Materializer.materializeAny(
                nestedGen.gen.erase(),
                prefix: candidate,
                mode: .guided(seed: 0, fallbackTree: fallbackTree),
                fallbackTree: fallbackTree,
                materializePicks: true
            ) else {
                return nil
            }
            return tree
        })
        encoder.start(scope: fixture.scope)

        var buffer = fixture.scope.baseSequence
        var probes: [ChoiceSequence] = []
        while let mutation = encoder.nextProbe(into: &buffer, lastAccepted: false) {
            guard case .branchSelected(fixture.pickNodeID, 0) = mutation else {
                Issue.record("Unexpected mutation \(mutation)")
                break
            }
            probes.append(buffer)
        }

        #expect(liftCount.value == 2)
        #expect(probes.count == 2)
        #expect(probes.allSatisfy { $0.count < fixture.scope.baseSequence.count })
        #expect(encoder.nextProbe(into: &buffer, lastAccepted: false) == nil)
    }
}

// MARK: - Helpers

private let pairSeed: UInt64 = 6
private let countedArraySeed: UInt64 = 10
private let nestedSeed: UInt64 = 4

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

/// A unary term of the given depth: every level picks between a constant and one more level. All the picks share one call site, so they form one self-similarity family.
private func termGen(depth: Int) -> ReflectiveGenerator<Int> {
    if depth <= 0 {
        return .just(0)
    }
    return .oneOf(.just(1), .lazy { termGen(depth: depth - 1).map { $0 + 1 } })
}

/// Both inner branches yield two, so the bound term regenerates identically after a pivot; the second branch carries a zip the first does not. The bound subtree is the term's top pick, whose nested pick is a transplant donor.
private let nestedGen: ReflectiveGenerator<(UInt64, Int)> = ReflectiveGenerator<UInt64>.oneOf(
    .just(2),
    Gen.zip(Gen.choose(in: UInt64(2) ... 2), Gen.choose(in: UInt64(0) ... 0))
        .map { first, _ in first }
        .wrapped(isReflective: true)
)
.bind { count in
    termGen(depth: Int(count)).map { (count, $0) }
}

/// The nested fixture drawn at its pinned seed: inner on the zip branch, term two levels deep, as a bind pivot scope targeting the constant inner branch.
private func nestedFixture() throws -> (scope: EncoderInput, pickNodeID: Int) {
    let generated = try generate(nestedGen.gen, seed: nestedSeed)
    try #require(generated.value == (2, 2))
    guard case let .success(_, tree, _) = Materializer.materializeAny(
        nestedGen.gen.erase(),
        prefix: ChoiceSequence.flatten(generated.tree),
        mode: .exact,
        fallbackTree: generated.tree,
        materializePicks: true
    ) else {
        throw FixtureError.materialization
    }
    let graph = ChoiceGraph.build(from: tree)
    let sequence = ChoiceSequence(tree)

    let bindNodeID = try #require(graph.nodes.indices.first { index in
        if case .bind = graph.nodes[index].kind {
            return true
        }
        return false
    })
    guard case let .bind(bindMetadata) = graph.nodes[bindNodeID].kind else {
        throw FixtureError.shape
    }
    let innerChildID = graph.nodes[bindNodeID].children[bindMetadata.innerChildIndex]
    let boundChildID = graph.nodes[bindNodeID].children[bindMetadata.boundChildIndex]
    var pickNodeID: Int?
    var stack = [innerChildID]
    while let current = stack.popLast() {
        if case .pick = graph.nodes[current].kind {
            pickNodeID = current
            break
        }
        stack.append(contentsOf: graph.nodes[current].children)
    }
    let pick = try #require(pickNodeID)
    guard case let .pick(pickMetadata) = graph.nodes[pick].kind,
          pickMetadata.selectedID == 1
    else {
        throw FixtureError.shape
    }

    let scope = BindPivotScope(
        bindNodeID: bindNodeID,
        pickNodeID: pick,
        targetBranchID: 0,
        boundSubtreeSize: graph.nodes[boundChildID].positionRange?.count ?? 0,
        estimatedProbes: 1
    )
    return (
        EncoderInput(
            transformation: GraphTransformation(
                operation: .minimize(.bindPivot(scope)),
                priority: DispatchPriority(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
            ),
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        ),
        pick
    )
}

private enum FixtureError: Error {
    case materialization
    case shape
}
