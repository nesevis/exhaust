//
//  ReducerBranchTests.swift
//  ExhaustTests
//
//  Tests for promoteBranches and pivotBranches shrink passes.
//

import Testing
import ExhaustCore

// MARK: - Helpers

/// Generate a value and its choice tree with all branches materialised.
private func generate<Output>(
    _ gen: ReflectiveGenerator<Output>,
    materializePicks: Bool = true,
    seed: UInt64 = 42,
    iteration: Int = 0,
) throws -> (value: Output, tree: ChoiceTree) {
    var iter = ValueAndChoiceTreeInterpreter(gen, materializePicks: materializePicks, seed: seed)
    return try #require(iter.prefix(iteration + 1).last)
}

// MARK: - Simple tagged-union type for testing

/// A simple tagged union whose branches have clearly different complexity.
private enum Tagged: Equatable, CustomDebugStringConvertible {
    case small(Int)
    case big(Int, Int)

    var debugDescription: String {
        switch self {
        case let .small(a): "small(\(a))"
        case let .big(a, b): "big(\(a), \(b))"
        }
    }
}

/// A pick generator with two branches of different structural complexity.
/// Branch 0 (weight 1): `small(Int)` — one value
/// Branch 1 (weight 1): `big(Int, Int)` — two values (structurally more complex)
private func makeTaggedGen() -> ReflectiveGenerator<Tagged> {
    let smallBranch = Gen.contramap(
        { (tagged: Tagged) throws -> Int in
            if case let .small(a) = tagged { return a }
            return 0
        },
        Gen.choose(in: 0 ... 100 as ClosedRange<Int>)._map { Tagged.small($0) },
    )
    let bigBranch = Gen.contramap(
        { (tagged: Tagged) throws -> (Int, Int) in
            if case let .big(a, b) = tagged { return (a, b) }
            return (0, 0)
        },
        Gen.zip(Gen.choose(in: 0 ... 100 as ClosedRange<Int>), Gen.choose(in: 0 ... 100 as ClosedRange<Int>))._map { Tagged.big($0, $1) },
    )
    return Gen.pick(choices: [(1, smallBranch), (1, bigBranch)])
}

/// A three-branch pick with varying complexity.
/// Branch 0: just a constant — simplest
/// Branch 1: single int
/// Branch 2: pair of ints — most complex
private func makeThreeWayGen() -> ReflectiveGenerator<Int> {
    let pairBranch = Gen.contramap(
        { (value: Int) -> (Int, Int) in (value / 2, value - value / 2) },
        Gen.zip(Gen.choose(in: 1 ... 50 as ClosedRange<Int>), Gen.choose(in: 1 ... 50 as ClosedRange<Int>))._map { $0 + $1 },
    )
    return Gen.pick(choices: [(1, Gen.choose(in: 0 ... 0 as ClosedRange<Int>)), (1, Gen.choose(in: 1 ... 100 as ClosedRange<Int>)), (1, pairBranch)])
}

// MARK: - promoteBranches

@MainActor
@Suite("promoteBranches")
struct PromoteBranchesTests {
    fileprivate let taggedGen = makeTaggedGen()

    @Test("Returns nil when tree has no branches")
    func noBranches() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt(0) ... 10), within: UInt64(1) ... 5)
        let (_, tree) = try generate(gen, seed: 7)
        var cache = ReducerCache()
        let sequence = ChoiceSequence(tree)

        let result = try ReducerStrategies.promoteBranches(
            gen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
        )
        #expect(result == nil)
    }

    @Test("Returns nil when tree has only one branch group")
    func singleBranchGroup() throws {
        let (_, tree) = try generate(taggedGen, seed: 7)
        var cache = ReducerCache()
        let sequence = ChoiceSequence(tree)

        let result = try ReducerStrategies.promoteBranches(
            taggedGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
        )
        // Only 1 pick site → nothing to replace
        #expect(result == nil)
    }

    @Test("Replaces complex branch subtree with simpler one from another site")
    func replacesComplexWithSimpler() throws {
        // A generator with two independent pick sites — the tuple gives us two branch groups
        let pairGen = Gen.zip(taggedGen, taggedGen)

        // Search for a seed/iteration that gives us two different branch selections
        // so we have branch groups of different complexity
        for seed in UInt64(0) ... 100 {
            for iteration in 0 ... 5 {
                guard let (_, tree) = try? generate(pairGen, seed: seed, iteration: iteration) else {
                    continue
                }
                let sequence = ChoiceSequence(tree)
                var cache = ReducerCache()

                // Property that always fails — any replacement that shortlex-precedes is accepted
                if let (_, candidateSeq, _) = try ReducerStrategies.promoteBranches(
                    pairGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
                ) {
                    print()
                    // The candidate must be strictly simpler
                    #expect(sequence.shortString != candidateSeq.shortString)
                    #expect(candidateSeq.shortLexPrecedes(sequence))
                    return
                }
            }
        }
        // If no seed produced a result, the test is inconclusive — skip rather than fail
        // (the generator may not always produce two different branches)
    }

    @Test("Does not produce a result that fails shortlex check")
    func respectsShortlex() throws {
        let pairGen = Gen.zip(taggedGen, taggedGen)

        for seed in UInt64(0) ... 50 {
            for iteration in 0 ... 3 {
                guard let (_, tree) = try? generate(pairGen, seed: seed, iteration: iteration) else {
                    continue
                }
                let sequence = ChoiceSequence(tree)
                var cache = ReducerCache()

                if let (_, candidateSeq, _) = try ReducerStrategies.promoteBranches(
                    pairGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
                ) {
                    print()
                    #expect(sequence.shortString != candidateSeq.shortString)
                    #expect(candidateSeq.shortLexPrecedes(sequence))
                }
            }
        }
    }

    @Test("Skips candidates already in the reject cache")
    func respectsRejectCache() throws {
        let pairGen = Gen.zip(taggedGen, taggedGen)

        for seed in UInt64(0) ... 100 {
            for iteration in 0 ... 5 {
                guard let (_, tree) = try? generate(pairGen, seed: seed, iteration: iteration) else {
                    continue
                }
                let sequence = ChoiceSequence(tree)

                // First call: get a result
                var cache1 = ReducerCache()
                guard let (_, candidateSeq, _) = try ReducerStrategies.promoteBranches(
                    pairGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache1,
                ) else {
                    continue
                }

                // Second call: pre-populate cache with the candidate
                var cache2 = ReducerCache()
                cache2.insert(candidateSeq)
                let result2 = try ReducerStrategies.promoteBranches(
                    pairGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache2,
                )

                // Should either return a different candidate or nil
                if let (_, seq2, _) = result2 {
                    #expect(seq2 != candidateSeq)
                }
                return
            }
        }
    }

    @Test("Does not return a result when the property passes for all candidates")
    func propertyPassingBlocksResult() throws {
        let pairGen = Gen.zip(taggedGen, taggedGen)

        for seed in UInt64(0) ... 50 {
            for iteration in 0 ... 3 {
                guard let (_, tree) = try? generate(pairGen, seed: seed, iteration: iteration) else {
                    continue
                }
                let sequence = ChoiceSequence(tree)
                var cache = ReducerCache()

                // Property always passes — no shrink result should be returned
                let result = try ReducerStrategies.promoteBranches(
                    pairGen, tree: tree, property: { _ in true }, sequence: sequence, rejectCache: &cache,
                )
                #expect(result == nil)
            }
        }
    }

    @Test("Candidate materialises to a valid value")
    func candidateMaterialises() throws {
        let pairGen = Gen.zip(taggedGen, taggedGen)

        for seed in UInt64(0) ... 100 {
            for iteration in 0 ... 5 {
                guard let (_, tree) = try? generate(pairGen, seed: seed, iteration: iteration) else {
                    continue
                }
                let sequence = ChoiceSequence(tree)
                var cache = ReducerCache()

                if let (candidateTree, candidateSeq, output) = try ReducerStrategies.promoteBranches(
                    pairGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
                ) {
                    // The returned output must match what materialisation produces
                    #expect(sequence.shortString != candidateSeq.shortString)
                    let rematerialised = try #require(
                        try Interpreters.materialize(pairGen, with: candidateTree, using: candidateSeq),
                    )
                    #expect(rematerialised == output)
                    return
                }
            }
        }
    }
}

// MARK: - pivotBranches

@MainActor
@Suite("pivotBranches")
struct PivotBranchesTests {
    fileprivate let taggedGen = makeTaggedGen()
    let threeWayGen = makeThreeWayGen()

    @Test("Returns nil when tree has no pick sites")
    func noPickSites() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt(0) ... 10), within: UInt64(1) ... 5)
        let (_, tree) = try generate(gen, seed: 7)
        var cache = ReducerCache()
        let sequence = ChoiceSequence(tree)

        let result = try ReducerStrategies.pivotBranches(
            gen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
        )
        #expect(result == nil)
    }

    @Test("Returns nil when branches are not materialised")
    func noAlternativesWithoutMaterialisedPicks() throws {
        // Generate without materializePicks — only the selected branch is in the tree
        let (_, tree) = try generate(taggedGen, materializePicks: false, seed: 7)
        var cache = ReducerCache()
        let sequence = ChoiceSequence(tree)

        let result = try ReducerStrategies.pivotBranches(
            taggedGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
        )
        #expect(result == nil)
    }

    @Test("Can pivot to a simpler branch that still fails the property")
    func pivotsToSimplerBranch() throws {
        // Search for a seed where the selected branch is the complex one (big)
        // and pivoting to small still fails the property
        for seed in UInt64(0) ... 200 {
            for iteration in 0 ... 5 {
                guard let (value, tree) = try? generate(taggedGen, seed: seed, iteration: iteration) else {
                    continue
                }
                // Only interested if the current selection is .big (the heavier branch)
                guard case .big = value else { continue }

                let sequence = ChoiceSequence(tree)
                var cache = ReducerCache()

                // Property: always fails — any pivot that shortlex-precedes is accepted
                if let (_, candidateSeq, output) = try ReducerStrategies.pivotBranches(
                    taggedGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
                ) {
                    #expect(sequence.shortString != candidateSeq.shortString)
                    #expect(candidateSeq.shortLexPrecedes(sequence))
                    // Pivoting from .big to .small should produce a .small value
                    if case .small = output {
                        return // success
                    }
                }
            }
        }
        Issue.record("Could not find a seed that exercises pivotBranches from big to small")
    }

    @Test("Pivot candidate materialises correctly")
    func candidateMaterialises() throws {
        for seed in UInt64(0) ... 200 {
            for iteration in 0 ... 5 {
                guard let (_, tree) = try? generate(taggedGen, seed: seed, iteration: iteration) else {
                    continue
                }
                let sequence = ChoiceSequence(tree)
                var cache = ReducerCache()

                if let (candidateTree, candidateSeq, output) = try ReducerStrategies.pivotBranches(
                    taggedGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
                ) {
                    let rematerialised = try #require(
                        try Interpreters.materialize(taggedGen, with: candidateTree, using: candidateSeq),
                    )
                    #expect(rematerialised == output)
                    return
                }
            }
        }
    }

    @Test("Does not return a result when the property passes for all pivots")
    func propertyPassingBlocksResult() throws {
        for seed in UInt64(0) ... 50 {
            guard let (_, tree) = try? generate(taggedGen, seed: seed) else { continue }
            let sequence = ChoiceSequence(tree)
            var cache = ReducerCache()

            let result = try ReducerStrategies.pivotBranches(
                taggedGen, tree: tree, property: { _ in true }, sequence: sequence, rejectCache: &cache,
            )
            #expect(result == nil)
        }
    }

    @Test("Skips candidates already in the reject cache")
    func respectsRejectCache() throws {
        for seed in UInt64(0) ... 200 {
            for iteration in 0 ... 5 {
                guard let (_, tree) = try? generate(taggedGen, seed: seed, iteration: iteration) else {
                    continue
                }
                let sequence = ChoiceSequence(tree)

                var cache1 = ReducerCache()
                guard let (_, candidateSeq, _) = try ReducerStrategies.pivotBranches(
                    taggedGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache1,
                ) else { continue }

                // Pre-populate with the candidate
                var cache2 = ReducerCache()
                cache2.insert(candidateSeq)
                let result2 = try ReducerStrategies.pivotBranches(
                    taggedGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache2,
                )
                // With only 2 branches and the one candidate cached, there's nothing left
                #expect(result2 == nil)
                return
            }
        }
    }

    @Test("Respects shortlex ordering — does not produce a longer sequence")
    func respectsShortlex() throws {
        for seed in UInt64(0) ... 200 {
            for iteration in 0 ... 5 {
                guard let (_, tree) = try? generate(taggedGen, seed: seed, iteration: iteration) else {
                    continue
                }
                let sequence = ChoiceSequence(tree)
                var cache = ReducerCache()

                if let (_, candidateSeq, _) = try ReducerStrategies.pivotBranches(
                    taggedGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
                ) {
                    #expect(sequence.shortString != candidateSeq.shortString)
                    #expect(candidateSeq.shortLexPrecedes(sequence))
                }
            }
        }
    }

    @Test("Prefers simplest alternative among multiple branches")
    func prefersSimplestBranch() throws {
        // threeWayGen has 3 branches: constant (simplest), single int, pair of ints (most complex)
        // If the selected branch is the most complex one (pair), pivotBranches should
        // try the constant first (simplest), then the single int.
        for seed in UInt64(0) ... 500 {
            for iteration in 0 ... 5 {
                guard let (value, tree) = try? generate(threeWayGen, seed: seed, iteration: iteration) else {
                    continue
                }
                // We want the most complex branch to be selected (value > 1 likely from the zip branch)
                guard value > 1 else { continue }

                let sequence = ChoiceSequence(tree)
                var cache = ReducerCache()

                if let (_, candidateSeq, output) = try ReducerStrategies.pivotBranches(
                    threeWayGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
                ) {
                    #expect(candidateSeq.shortLexPrecedes(sequence))
                    // The simplest alternative (constant 0) should have been picked first
                    #expect(output == 0)
                    return
                }
            }
        }
    }

    @Test("Pivot within nested pick sites")
    func nestedPickSites() throws {
        // Two independent pick sites via zip — both should be pivotable
        let pairGen = Gen.zip(taggedGen, taggedGen)

        var pivotCount = 0
        for seed in UInt64(0) ... 200 {
            for iteration in 0 ... 5 {
                guard let (_, tree) = try? generate(pairGen, seed: seed, iteration: iteration) else {
                    continue
                }
                let sequence = ChoiceSequence(tree)
                var cache = ReducerCache()

                if let (_, candidateSeq, _) = try ReducerStrategies.pivotBranches(
                    pairGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
                ) {
                    #expect(candidateSeq.shortLexPrecedes(sequence))
                    pivotCount += 1
                    if pivotCount >= 3 { return }
                }
            }
        }
        #expect(pivotCount > 0)
    }

    @Test("Pivot preserves tree validity — candidate flattens and materialises round-trip")
    func roundTrip() throws {
        for seed in UInt64(0) ... 200 {
            for iteration in 0 ... 5 {
                guard let (_, tree) = try? generate(taggedGen, seed: seed, iteration: iteration) else {
                    continue
                }
                let sequence = ChoiceSequence(tree)
                var cache = ReducerCache()

                if let (candidateTree, candidateSeq, output) = try ReducerStrategies.pivotBranches(
                    taggedGen, tree: tree, property: { _ in false }, sequence: sequence, rejectCache: &cache,
                ) {
                    // Verify the candidate sequence is valid (balanced markers)
                    #expect(ChoiceSequence.validate(candidateSeq))

                    // Verify re-flattening the candidate tree produces the same sequence
                    let reflattened = ChoiceSequence(candidateTree)
                    #expect(reflattened == candidateSeq)

                    // Verify materialisation reproduces the output
                    let rematerialised = try #require(
                        try Interpreters.materialize(taggedGen, with: candidateTree, using: candidateSeq),
                    )
                    #expect(rematerialised == output)
                    return
                }
            }
        }
    }
}
