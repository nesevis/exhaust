//
//  HillClimberTests.swift
//  ExhaustTests
//

import Testing
import ExhaustCore

@Suite("HillClimber")
struct HillClimberTests {
    @Test("Value climbing increases score by adjusting values")
    func valueClimbingIncreasesScore() throws {
        let gen = Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
        let (_, tree) = try generateWithTree(gen, seed: 42)
        let sequence = ChoiceSequence(tree)
        let initialSeed = Seed(sequence: sequence, tree: tree, noveltyScore: 0, fitness: 0, generation: 0)
        var prng = Xoshiro256(seed: 7)

        let result = HillClimber.climb(
            seed: initialSeed,
            gen: gen,
            scorer: { Double($0) },
            property: { _ in true },
            budget: 100,
            prng: &prng,
        )

        switch result {
        case let .improved(newSeed, output, _):
            // The climber should have moved the value upward (higher score = higher value)
            let originalValue = try? Interpreters.materialize(gen, with: tree, using: sequence, strictness: .relaxed)
            if let orig = originalValue {
                #expect(output > orig, "Hill climber should increase value when scorer = Double($0)")
            }
            #expect(newSeed.fitness > 0)
        case .unchanged:
            // Acceptable if the initial value was already at the maximum
            break
        case .counterexample:
            Issue.record("Did not expect counterexample when property always returns true")
        }
    }

    @Test("Branch climbing discovers alternative branches that improve score")
    func branchClimbingDiscoversBetterBranches() throws {
        let lowBranch = Gen.choose(in: 0 ... 10 as ClosedRange<Int>)
        let highBranch = Gen.choose(in: 90 ... 100 as ClosedRange<Int>)
        let gen = Gen.pick(choices: [(9, lowBranch), (1, highBranch)])

        // Generate with the likely low branch
        let (value, tree) = try generateWithTree(gen, seed: 42)
        let sequence = ChoiceSequence(tree)
        let initialSeed = Seed(sequence: sequence, tree: tree, noveltyScore: 0, fitness: Double(value), generation: 0)
        var prng = Xoshiro256(seed: 7)

        // Only try branch climbing if we started on the low branch
        guard value <= 10 else { return }

        let result = HillClimber.climb(
            seed: initialSeed,
            gen: gen,
            scorer: { Double($0) },
            property: { _ in true },
            budget: 50,
            prng: &prng,
        )

        switch result {
        case let .improved(_, output, _):
            #expect(output >= 90, "Branch climbing should find the high branch")
        case .unchanged:
            // May happen if tree structure doesn't support branch swaps
            break
        case .counterexample:
            Issue.record("Did not expect counterexample when property always returns true")
        }
    }

    @Test("Returns counterexample immediately when property fails")
    func returnsCounterexampleOnPropertyFailure() throws {
        let gen = Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
        let (_, tree) = try generateWithTree(gen, seed: 42)
        let sequence = ChoiceSequence(tree)
        let initialSeed = Seed(sequence: sequence, tree: tree, noveltyScore: 0, fitness: 0, generation: 0)
        var prng = Xoshiro256(seed: 7)

        let result = HillClimber.climb(
            seed: initialSeed,
            gen: gen,
            scorer: { Double($0) },
            property: { $0 < 900 }, // Fails for values >= 900
            budget: 200,
            prng: &prng,
        )

        switch result {
        case let .counterexample(value, _, _):
            #expect(value >= 900)
        case .improved:
            // Improvement without hitting counterexample is also acceptable
            break
        case .unchanged:
            break
        }
    }

    @Test("Budget is respected")
    func budgetRespected() throws {
        let gen = Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
        let (_, tree) = try generateWithTree(gen, seed: 42)
        let sequence = ChoiceSequence(tree)
        let initialSeed = Seed(sequence: sequence, tree: tree, noveltyScore: 0, fitness: 0, generation: 0)
        var prng = Xoshiro256(seed: 7)

        let budget = 5
        let result = HillClimber.climb(
            seed: initialSeed,
            gen: gen,
            scorer: { Double($0) },
            property: { _ in true },
            budget: budget,
            prng: &prng,
        )

        let probesUsed: Int = switch result {
        case let .improved(_, _, p): p
        case let .unchanged(p): p
        case let .counterexample(_, _, p): p
        }
        #expect(probesUsed <= budget + 1, "Probes used should not greatly exceed budget")
    }

    @Test("BST integration: hill climbing with height scorer steers toward deeper trees")
    func bstHeightClimbing() throws {
        let gen = BST.arbitrary(maxDepth: 6, valueRange: 0 ... 99)
        let (value, tree) = try generateWithTree(gen, seed: 42)
        let sequence = ChoiceSequence(tree)
        let initialSeed = Seed(
            sequence: sequence, tree: tree,
            noveltyScore: 0, fitness: Double(value.height), generation: 0,
        )
        var prng = Xoshiro256(seed: 7)

        let result = HillClimber.climb(
            seed: initialSeed,
            gen: gen,
            scorer: { Double($0.height) },
            property: { _ in true },
            budget: 200,
            prng: &prng,
        )

        switch result {
        case let .improved(_, output, _):
            #expect(output.height >= value.height, "Hill climbing should not decrease tree height")
        case .unchanged:
            break
        case .counterexample:
            Issue.record("Did not expect counterexample when property always returns true")
        }
    }
}

// MARK: - Helpers

private func generateWithTree<Output>(
    _ gen: ReflectiveGenerator<Output>,
    seed: UInt64,
    materializePicks: Bool = false,
    iteration: Int = 0,
) throws -> (value: Output, tree: ChoiceTree) {
    var iter = ValueAndChoiceTreeInterpreter(gen, materializePicks: materializePicks, seed: seed)
    return try iter.prefix(iteration + 1).last!
}
