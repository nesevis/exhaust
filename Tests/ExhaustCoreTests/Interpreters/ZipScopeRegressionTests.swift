//
//  ZipScopeRegressionTests.swift
//  Exhaust
//
//  Pins the zip fallback-decomposition fix. ChoiceTree group nodes are untagged, so a two-generator zip whose first child flattens as a two-child group (a monadic bind, a two-branch pick) was misread as a monadic wrapper [zipCallee, continuation]: exact-mode replay of the tree's own flattening rejected, and guided mode silently dropped values to PRNG. The fix arbitrates by the prefix's self-delimiting subtree spans (zips are fixed-arity) and scopes zip children from those spans. Found by the self-fuzzing harness.
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Zip scope regressions")
struct ZipScopeRegressionTests {
    @Test("Zip with a monadic bind as first child exact-replays its own flattening", arguments: [UInt64(1), 7, 42])
    func bindFirstChildExactRoundTrip(seed: UInt64) throws {
        let gen = Gen.zip(boundRangeGen(), Gen.choose(in: 0 ... 5))
        try assertExactRoundTrip(gen, seed: seed, equals: ==)
    }

    @Test("Zip with monadic binds as both children exact-replays its own flattening", arguments: [UInt64(1), 7, 42])
    func bindBothChildrenExactRoundTrip(seed: UInt64) throws {
        let gen = Gen.zip(boundRangeGen(), boundRangeGen())
        try assertExactRoundTrip(gen, seed: seed, equals: ==)
    }

    @Test("Zip with a monadic bind as last child exact-replays its own flattening", arguments: [UInt64(1), 7, 42])
    func bindLastChildExactRoundTrip(seed: UInt64) throws {
        let gen = Gen.zip(Gen.choose(in: 0 ... 5), boundRangeGen())
        try assertExactRoundTrip(gen, seed: seed, equals: ==)
    }

    @Test("Three-child zip with binds exact-replays its own flattening", arguments: [UInt64(1), 7])
    func threeChildZipExactRoundTrip(seed: UInt64) throws {
        let gen = Gen.zip(boundRangeGen(), Gen.choose(in: 0 ... 5), boundRangeGen())
        try assertExactRoundTrip(gen, seed: seed, equals: ==)
    }

    @Test("Guided replay of an untouched prefix carries every value forward", arguments: [UInt64(1), 7, 42])
    func guidedCarryForward(seed: UInt64) throws {
        let gen = Gen.zip(boundRangeGen(), Gen.choose(in: 0 ... 5))
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 10)
        while let (value, tree) = try iterator.next() {
            let sequence = ChoiceSequence.flatten(tree)
            guard case let .success(materialized, _, _) = Materializer.materialize(
                gen, prefix: sequence, mode: .guided(seed: 99, fallbackTree: tree)
            ) else {
                Issue.record("Guided materialization failed on an untouched prefix, seed \(seed)")
                return
            }
            #expect(materialized == value, "Guided replay drifted from \(value) to \(materialized), seed \(seed)")
        }
    }

    /// The reducer-side half of the defect: reduced trees for a zip whose first child is a two-branch pick take the ambiguous shape, so the reducer's own reported sequence failed to materialize. Mirrors the closed-loop invariant of the MetaGenerator suite for this shape.
    @Test("Reduced sequence of a pick-first-child zip materializes to the reported value")
    func reducedTreeClosedLoop() throws {
        let recipe = GenRecipe.combinator(.zipped(
            .combinator(.optional(.leaf(.justInt(0)))),
            .combinator(.recursive(base: .leaf(.justInt(0)), maxDepth: 2))
        ))
        let gen = buildGenerator(from: recipe)
        let property = failingProperty(for: recipe.outputType)
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 3, maxRuns: 3)
        var checked = 0
        while let (value, tree) = try iterator.next() {
            guard property(value) == false else {
                continue
            }
            guard case let .reduced(sequence, reducedTree, shrunk) = try Interpreters.choiceGraphReduce(
                gen: gen, tree: tree, config: .init(maxStalls: 2), property: property
            ) else {
                continue
            }
            guard case let .success(materialized, _, _) = Materializer.materialize(
                gen, prefix: sequence, mode: .exact, fallbackTree: reducedTree
            ) else {
                Issue.record("Reduced sequence failed to materialize for \(recipe)")
                return
            }
            #expect(anyEquals(materialized, shrunk), "Reduced sequence materialized to \(materialized), not \(shrunk)")
            checked += 1
        }
        #expect(checked > 0, "The sweep must reach at least one reduction")
    }
}

// MARK: - Helpers

/// A monadic bind whose bound range depends on the inner draw — flattens as a two-child group, the shape that collided with the wrapper reading.
private func boundRangeGen() -> Generator<Int> {
    Gen.choose(in: -50 ... -14).bind { lowerBound in
        Gen.choose(in: lowerBound ... (lowerBound + 50))
    }
}

private func assertExactRoundTrip<Output>(
    _ gen: Generator<Output>,
    seed: UInt64,
    equals: (Output, Output) -> Bool
) throws {
    var iterator = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 10)
    var checked = 0
    while let (value, tree) = try iterator.next() {
        let sequence = ChoiceSequence.flatten(tree)
        switch Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) {
            case let .success(materialized, freshTree, _):
                #expect(equals(materialized, value), "Exact replay produced \(materialized), not \(value), seed \(seed)")
                #expect(ChoiceSequence.flatten(freshTree) == sequence, "Re-flattening changed the sequence, seed \(seed)")
            case .rejected, .failed:
                Issue.record("Exact materialization rejected the tree's own flattening, seed \(seed)")
                return
        }
        checked += 1
    }
    #expect(checked > 0)
}
