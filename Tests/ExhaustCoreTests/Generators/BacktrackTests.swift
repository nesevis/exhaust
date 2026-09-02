//
//  BacktrackTests.swift
//  Exhaust
//

import ExhaustCore
import Foundation
import Testing

@Suite("backtrack combinator")
struct BacktrackTests {
    // MARK: - Audition

    @Test("A producing arm wins over a withdrawing arm")
    func producingArmWins() throws {
        let gen = alwaysGen(arms: [(1, Gen.just(Int?.none)), (1, Gen.choose(in: 1 ... 10).liftToOptional())])
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 100)
        var produced = 0
        while let value = try iterator.next() {
            #expect((1 ... 10).contains(value))
            produced += 1
        }
        #expect(produced == 100)
    }

    @Test("A user-listed nil arm is dead weight")
    func nilArmIsDeadWeight() throws {
        let gen = alwaysGen(arms: [(1, Gen.just(Int?.none)), (1, Gen.just(Int?.some(3)))])
        var iterator = ValueInterpreter(gen, seed: 7, maxRuns: 50)
        while let value = try iterator.next() {
            #expect(value == 3)
        }
    }

    @Test("Value and tree interpreters agree on a partial-arm generator")
    func valueAndTreeInterpretersAgree() throws {
        let gen = partialArmGen()
        var valueIterator = ValueInterpreter(gen, seed: 1983, maxRuns: 100)
        var treeIterator = ValueAndChoiceTreeInterpreter(gen, seed: 1983, maxRuns: 100)
        var compared = 0
        while let value = try valueIterator.next() {
            let (treeValue, _) = try #require(try treeIterator.next())
            #expect(value == treeValue)
            compared += 1
        }
        #expect(compared == 100)
    }

    @Test("A failed arm leaves no filter observations behind")
    func failedArmLeavesNoFilterObservations() throws {
        let observedThenWithdrawn: Generator<Int?> = Gen.filter(
            Gen.choose(in: 0 ... 9),
            type: .rejectionSampling,
            predicate: { _ in true },
            sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
        ).map { _ in nil }
        let gen = alwaysGen(arms: [(1, observedThenWithdrawn), (1, Gen.just(Int?.some(1)))])
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 3, maxRuns: 20)
        while let (value, _) = try iterator.next() {
            #expect(value == 1)
        }
        #expect(iterator.filterObservations.isEmpty)
    }

    // MARK: - Exhaustion

    @Test("always: exhaustion ends the run and fires the call-site hook")
    func alwaysExhaustionEndsRun() throws {
        let hook = Flag()
        let gen: Generator<Int> = Gen.backtrack(
            always: [(1, Gen.just(Int?.none)), (1, Gen.choose(in: 0 ... 9).map { _ in Int?.none })],
            onExhausted: { hook.raise() }
        )
        var valueIterator = ValueInterpreter(gen, seed: 5, maxRuns: 10)
        #expect(try valueIterator.next() == nil)
        #expect(hook.isRaised)

        var treeIterator = ValueAndChoiceTreeInterpreter(gen, seed: 5, maxRuns: 10)
        #expect(try treeIterator.next() == nil)
    }

    @Test("failable: exhaustion records the absent arm")
    func failableExhaustionRecordsAbsentArm() throws {
        let gen = failableGen(arms: [(1, Gen.just(Int?.none)), (1, Gen.choose(in: 0 ... 9).map { _ in Int?.none })])
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 5, maxRuns: 5)
        var seen = 0
        while let (value, tree) = try iterator.next() {
            #expect(value == nil)
            let branch = try #require(branches(in: tree).first)
            #expect(branch.id == 2)
            #expect(branch.branchCount == 3)
            seen += 1
        }
        #expect(seen == 5)
    }

    @Test("failable: a producing arm is preferred over absence")
    func failableProducesWhenAnArmCan() throws {
        let gen = failableGen(arms: [(1, Gen.just(Int?.none)), (1, Gen.choose(in: 1 ... 10).liftToOptional())])
        var iterator = ValueInterpreter(gen, seed: 11, maxRuns: 50)
        while let value = try iterator.next() {
            #expect(value != nil)
        }
    }

    // MARK: - Reflection and replay

    @Test("Reflection recovers the producing arm and exact replay reproduces the value")
    func reflectionRoundTrips() throws {
        let gen = alwaysGen(arms: [(1, Gen.just(Int?.none)), (1, Gen.choose(in: 1 ... 10).liftToOptional())])
        let tree = try #require(try Interpreters.reflect(gen, with: 7))
        let branch = try #require(branches(in: tree).first)
        #expect(branch.id == 1)
        #expect(branch.branchCount == 2)

        let result = Materializer.materialize(gen, prefix: ChoiceSequence.flatten(tree), mode: .exact)
        guard case let .success(value, _, _) = result else {
            Issue.record("Expected exact replay of the reflected tree to succeed, got \(result)")
            return
        }
        #expect(value == 7)
    }

    @Test("Reflecting nil through a failable node selects the absent arm")
    func reflectingNilSelectsAbsentArm() throws {
        let gen = failableGen(arms: [(1, Gen.choose(in: 1 ... 10).liftToOptional())])
        let tree = try #require(try Interpreters.reflect(gen, with: nil))
        let branch = try #require(branches(in: tree).first)
        #expect(branch.id == 1)

        let result = Materializer.materialize(gen, prefix: ChoiceSequence.flatten(tree), mode: .exact)
        guard case let .success(value, _, _) = result else {
            Issue.record("Expected exact replay of the reflected tree to succeed, got \(result)")
            return
        }
        #expect(value == nil)
    }

    @Test("Exact materialization rejects a recorded arm that no longer produces; guided re-auditions")
    func exactRejectsGuidedReauditions() throws {
        let gen = alwaysGen(arms: [(1, Gen.just(Int?.none)), (1, Gen.choose(in: 1 ... 10).liftToOptional())])
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 1)
        let (_, tree) = try #require(try iterator.next())
        let pivoted = try pivotingBranch(in: ChoiceSequence.flatten(tree), to: 0)

        let exact = Materializer.materialize(gen, prefix: pivoted, mode: .exact)
        guard case .rejected = exact else {
            Issue.record("Expected exact mode to reject the withdrawn arm, got \(exact)")
            return
        }

        let guided = Materializer.materialize(gen, prefix: pivoted, mode: .guided(seed: 9, fallbackTree: nil))
        guard case let .success(value, guidedTree, _) = guided else {
            Issue.record("Expected guided mode to re-audition, got \(guided)")
            return
        }
        #expect((1 ... 10).contains(value))
        let winner = try #require(branches(in: guidedTree).first)
        #expect(winner.id == 1)
    }

    @Test("Flat guided materialization truncates the withdrawn arm's marker")
    func flatGuidedTruncatesWithdrawnMarker() throws {
        let gen = alwaysGen(arms: [(1, Gen.just(Int?.none)), (1, Gen.choose(in: 1 ... 10).liftToOptional())])
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 1)
        let (_, tree) = try #require(try iterator.next())
        let pivoted = try pivotingBranch(in: ChoiceSequence.flatten(tree), to: 0)

        let flat = Materializer.materializeAnyFlat(gen.erase(), prefix: pivoted, mode: .guided(seed: 9, fallbackTree: nil))
        guard case let .success(_, sequence, _) = flat else {
            Issue.record("Expected flat guided materialization to succeed, got \(flat)")
            return
        }
        let markers = sequence.compactMap { entry -> ChoiceSequenceValue.Branch? in
            guard case let .branch(branch) = entry else { return nil }
            return branch
        }
        #expect(markers.count == 1)
        #expect(markers.first?.id == 1)

        let treeResult = Materializer.materialize(gen, prefix: pivoted, mode: .guided(seed: 9, fallbackTree: nil))
        guard case let .success(_, guidedTree, _) = treeResult else {
            Issue.record("Expected guided materialization to succeed, got \(treeResult)")
            return
        }
        #expect(sequence == ChoiceSequence.flatten(guidedTree))
    }

    @Test("Flipping a failable node to its absent arm materializes nil in both modes")
    func flipToAbsentArm() throws {
        let gen = failableGen(arms: [(1, Gen.choose(in: 1 ... 10).liftToOptional())])
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 1)
        let (_, tree) = try #require(try iterator.next())
        let pivoted = try pivotingBranch(in: ChoiceSequence.flatten(tree), to: 1)

        for mode in [Materializer.Mode.exact, .guided(seed: 3, fallbackTree: nil)] {
            let result = Materializer.materialize(gen, prefix: pivoted, mode: mode)
            guard case let .success(value, _, _) = result else {
                Issue.record("Expected the absent arm to materialize, got \(result)")
                continue
            }
            #expect(value == nil)
        }
    }

    @Test("Unselected backtrack branches minimize to their lowest producing arm")
    func unselectedBranchesMinimizeToLowestProducingArm() throws {
        let inner = alwaysGen(arms: [(1, Gen.just(Int?.none)), (1, Gen.just(Int?.some(5))), (1, Gen.just(Int?.some(6)))])
        let outer: Generator<Int> = Gen.pick(choices: [(1, inner), (1, Gen.just(1))])
        // A tree whose outer pick took the plain branch, so the backtrack node is the unselected alternative.
        var tree: ChoiceTree?
        for seed in 0 ..< 32 as Range<UInt64> where tree == nil {
            var iterator = ValueAndChoiceTreeInterpreter(outer, seed: seed, maxRuns: 1)
            let (value, candidate) = try #require(try iterator.next())
            if value == 1 {
                tree = candidate
            }
        }
        let prefix = try ChoiceSequence.flatten(#require(tree))

        let result = Materializer.materialize(outer, prefix: prefix, mode: .exact, materializePicks: true)
        guard case let .success(_, fullTree, _) = result else {
            Issue.record("Expected exact materialization with branch alternatives to succeed, got \(result)")
            return
        }
        let innerFingerprint = try #require(backtrackChoices(of: inner)?.first?.fingerprint)
        let minimized = selectedBranchIDs(in: fullTree, fingerprint: innerFingerprint)
        #expect(minimized == [1], "Minimize should skip the withdrawing arm 0 and stop at arm 1, got \(minimized)")
    }

    @Test("The choice graph reads a backtrack node as a plain pick")
    func graphReadsNodeAsPlainPick() throws {
        let gen = alwaysGen(arms: [(1, Gen.just(Int?.none)), (1, Gen.choose(in: 1 ... 10).liftToOptional())])
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 1)
        let (_, tree) = try #require(try iterator.next())
        let graph = ChoiceGraph.build(from: tree)
        let picks = graph.nodes.compactMap { node -> PickMetadata? in
            guard case let .pick(metadata) = node.kind else { return nil }
            return metadata
        }
        #expect(picks.count == 1)
        #expect(picks.first?.branchCount == 2)
        #expect(picks.first?.selectedID == 1)
    }

    // MARK: - Tuning opacity

    @Test("Offline tuning passes return a backtrack node unchanged, arms included")
    func tuningLeavesNodeUnchanged() throws {
        let gen = tunableGen()
        let predicate: (Int) -> Bool = { $0 <= 100 }

        let tuned = try GeneratorTuning.tune(gen, samples: 50, seed: 42, predicate: predicate)
        try expectUntouched(tuned)

        let smoothed = AdaptiveSmoothing.smooth(gen)
        try expectUntouched(smoothed)

        let baked = try ChoiceGradientTuner.tune(gen, predicate: predicate, warmupRuns: 20, sampleCount: 5, seed: 42)
        try expectUntouched(baked)
    }

    @Test("Online CGS draws a backtrack node with its declared weights")
    func onlineCGSUsesDeclaredWeights() throws {
        let gen = alwaysGen(arms: [
            (1, Gen.choose(in: 1 ... 100).liftToOptional()),
            (1, Gen.choose(in: 901 ... 1000).liftToOptional()),
        ])
        let predicate: (Int) -> Bool = { $0 <= 100 }
        var iterator = OnlineCGSInterpreter(gen, predicate: predicate, sampleCount: 20, seed: 42, maxRuns: 400)
        var hits = 0
        var total = 0
        while let value = try iterator.next() {
            if predicate(value) { hits += 1 }
            total += 1
        }
        #expect(total == 400)
        let hitRate = Double(hits) / Double(total)
        #expect(hitRate > 0.35 && hitRate < 0.65, "Declared 1:1 weights should split evenly, got \(hitRate)")
    }

    @Test("The always: unwrap throws rather than traps when handed nil")
    func alwaysUnwrapThrows() throws {
        let gen = alwaysGen(arms: [(1, Gen.choose(in: 1 ... 10).liftToOptional())])
        guard case let .impure(operation: .transform(.isomorph(forward, _, _, _), _), _) = gen else {
            Issue.record("Expected the always: node to be an isomorph over the pick")
            return
        }
        #expect(throws: GeneratorError.self) {
            _ = try forward(Int?.none as Any)
        }
        #expect(try forward(Int?.some(4) as Any) as? Int == 4)
    }
}

// MARK: - Helpers

private func alwaysGen(arms: [(weight: UInt64, generator: Generator<Int?>)]) -> Generator<Int> {
    Gen.backtrack(always: arms)
}

private func failableGen(arms: [(weight: UInt64, generator: Generator<Int?>)]) -> Generator<Int?> {
    Gen.backtrack(failable: arms)
}

/// An arm that withdraws on odd draws beside one that always produces, so auditions fail and retry on roughly half the visits.
private func partialArmGen() -> Generator<Int> {
    alwaysGen(arms: [
        (3, Gen.choose(in: 0 ... 9).map { $0.isMultiple(of: 2) ? $0 : nil }),
        (1, Gen.choose(in: 100 ... 109).liftToOptional()),
    ])
}

/// A backtrack node whose single arm is an ordinary tunable pick, so a pass that descends into arms is caught by the inner weights changing.
private func tunableGen() -> Generator<Int> {
    let inner: Generator<Int> = Gen.pick(choices: [
        (1, Gen.choose(in: 1 ... 100)),
        (1, Gen.choose(in: 901 ... 1000)),
    ])
    return alwaysGen(arms: [(1, inner.liftToOptional()), (1, Gen.just(Int?.some(50)))])
}

private func expectUntouched(_ gen: Generator<Int>) throws {
    let choices = try #require(backtrackChoices(of: gen))
    #expect(choices.count == 2)
    #expect(choices.allSatisfy { $0.isBacktrack })
    #expect(choices.map(\.weight) == [1, 1])
    let innerChoices = try #require(firstPickChoices(in: choices[0].generator))
    #expect(innerChoices.map(\.weight) == [1, 1])
    #expect(innerChoices.allSatisfy { $0.isBacktrack == false })
}

private func backtrackChoices(of gen: Generator<Int>) -> ContiguousArray<ReflectiveOperation.PickTuple>? {
    guard case let .impure(operation: .transform(_, inner), _) = gen else { return nil }
    return firstPickChoices(in: inner)
}

/// Descends through single-inner wrappers to the first pick.
private func firstPickChoices(in gen: AnyGenerator) -> ContiguousArray<ReflectiveOperation.PickTuple>? {
    switch gen {
        case .pure:
            return nil
        case let .impure(operation, _):
            switch operation {
                case let .pick(choices, _):
                    return choices
                case let .contramap(_, next), let .prune(next), let .resize(_, next):
                    return firstPickChoices(in: next)
                case let .transform(_, inner):
                    return firstPickChoices(in: inner)
                case let .filter(inner, _, _, _, _), let .classify(inner, _, _), let .unique(inner, _, _):
                    return firstPickChoices(in: inner)
                default:
                    return nil
            }
    }
}

/// The selected branch markers of `tree`, in flattening order.
private func branches(in tree: ChoiceTree) -> [ChoiceSequenceValue.Branch] {
    ChoiceSequence.flatten(tree).compactMap { entry in
        guard case let .branch(branch) = entry else { return nil }
        return branch
    }
}

/// The ids of the selected branches at the pick site with `fingerprint`, including picks nested beneath an unselected outer branch.
private func selectedBranchIDs(in tree: ChoiceTree, fingerprint: UInt64) -> [UInt64] {
    let shortFingerprint = String(format: "%08X", fingerprint & 0xFFFF_FFFF)
    return tree.debugDescription.split(separator: "\n").compactMap { line -> UInt64? in
        guard line.contains("✅branch(fingerprint: \(shortFingerprint),") else {
            return nil
        }
        guard let idRange = line.range(of: "id: ") else { return nil }
        let digits = line[idRange.upperBound...].prefix { $0.isNumber }
        return UInt64(digits)
    }
}

/// Rewrites the single branch marker in `sequence` to select `id`, leaving the recorded body in place as a pivoted prefix would.
private func pivotingBranch(in sequence: ChoiceSequence, to id: UInt64) throws -> ChoiceSequence {
    var rewritten = sequence
    let index = try #require(rewritten.firstIndex { entry in
        if case .branch = entry { return true }
        return false
    })
    guard case let .branch(branch) = rewritten[index] else {
        throw PivotError.noBranch
    }
    rewritten[index] = .branch(.init(id: id, branchCount: branch.branchCount, fingerprint: branch.fingerprint))
    return rewritten
}

private enum PivotError: Error {
    case noBranch
}

private final class Flag: @unchecked Sendable {
    private(set) var isRaised = false

    func raise() {
        isRaised = true
    }
}
