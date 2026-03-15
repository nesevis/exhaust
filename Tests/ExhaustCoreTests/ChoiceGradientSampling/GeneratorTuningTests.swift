//
//  GeneratorTuningTests.swift
//  ExhaustTests
//
//  Tests for the offline generator tuning algorithm.
//

import ExhaustCore
import Foundation
import Testing

@Suite("Choice Gradient Sampling")
struct GeneratorTuningTests {
    // MARK: - Filter Integration

    @Test("Filter adaptation uses the filter's own predicate to adapt inner generator")
    func filterAdaptation() throws {
        let innerGen = Gen.choose(in: 1 ... 1000)
        let gen: ReflectiveGenerator<Int> = .impure(
            operation: .filter(gen: innerGen.erase(), fingerprint: 0, filterType: .auto, predicate: { ($0 as! Int) < 200 }),
            continuation: { .pure($0 as! Int) },
        )

        // The outer predicate is irrelevant — filter's predicate should drive adaptation
        let tuned = try GeneratorTuning.tune(
            gen,
            samples: 50,
            seed: 42,
            predicate: { (_: Int) in true },
        )

        // Verify that the tuned generator structure contains a filter with an tuned inner gen
        guard case let .impure(.filter(tunedInner, _, _, _), _) = tuned else {
            Issue.record("Expected tuned generator to be a filter")
            return
        }

        // The inner generator should now be a pick (from chooseBits subdivision)
        // rather than the original chooseBits, because CGS tuned it using the filter predicate
        guard case let .impure(.pick(choices), _) = tunedInner else {
            Issue.record("Expected inner generator to be tuned into a pick, got \(tunedInner)")
            return
        }

        // The low-range subrange should have higher weight since the filter predicate favours < 200
        let firstWeight = choices.first?.weight ?? 0
        let lastWeight = choices.last?.weight ?? 0
        #expect(firstWeight >= lastWeight,
                "Low subrange should have equal or higher weight than high subrange")
    }

    // MARK: - Zero-weight Branches

    @Test("Zero-weight branches are preserved in tuned structure")
    func zeroWeightBranchesPreserved() throws {
        // One branch always satisfies, one never does
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: 1 ... 10)),
            (1, Gen.choose(in: 901 ... 1000)),
        ])

        let predicate: (Int) -> Bool = { $0 <= 10 }

        let tuned = try GeneratorTuning.tune(
            gen,
            samples: 50,
            seed: 42,
            predicate: predicate,
        )

        // Inspect the tuned structure: should have 2 branches still
        guard case let .impure(.pick(choices), _) = tuned else {
            Issue.record("Expected tuned generator to be a pick")
            return
        }

        #expect(choices.count == 2, "Both branches should be preserved (including weight-0)")
    }

    @Test("All-zero fallback restores weight 1")
    func allZeroFallback() throws {
        // Predicate that nothing can satisfy
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: 1 ... 10)),
            (1, Gen.choose(in: 11 ... 20)),
        ])

        let predicate: (Int) -> Bool = { _ in false }

        let tuned = try GeneratorTuning.tune(
            gen,
            samples: 20,
            seed: 42,
            predicate: predicate,
        )

        guard case let .impure(.pick(choices), _) = tuned else {
            Issue.record("Expected tuned generator to be a pick")
            return
        }

        // All weights should be restored to 1
        #expect(choices.allSatisfy { $0.weight == 1 },
                "All-zero fallback should restore weights to 1, got \(choices.map(\.weight))")
    }

    // MARK: - Deterministic Seeding

    @Test("Same seed produces same tuned structure")
    func deterministicSeeding() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: 1 ... 500)),
            (1, Gen.choose(in: 501 ... 1000)),
        ])
        let predicate: (Int) -> Bool = { $0 <= 250 }

        let tuned1 = try GeneratorTuning.tune(
            gen, samples: 50, seed: 42, predicate: predicate,
        )
        let tuned2 = try GeneratorTuning.tune(
            gen, samples: 50, seed: 42, predicate: predicate,
        )

        // Generate from both and verify identical output
        var values1Iter = ValueInterpreter(tuned1, seed: 99, maxRuns: 50)
        let values1 = try Array(collecting: &values1Iter)
        var values2Iter = ValueInterpreter(tuned2, seed: 99, maxRuns: 50)
        let values2 = try Array(collecting: &values2Iter)

        #expect(values1 == values2, "Same seed should produce identical tuned generators")
    }

    // MARK: - Convergence Early-Stopping

    @Test("Convergence early-stopping produces equivalent results with fewer samples")
    func convergenceEarlyStopping() throws {
        // A pick where one branch trivially satisfies and the other never does.
        // Convergence should stabilize quickly — a high sample cap shouldn't
        // change the weights compared to a moderate one.
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: 1 ... 50)),
            (1, Gen.choose(in: 501 ... 1000)),
        ])

        let predicate: (Int) -> Bool = { $0 <= 50 }

        // Moderate budget — should converge well within this
        let tunedModerate = try GeneratorTuning.tune(
            gen, samples: 100, seed: 42, predicate: predicate,
        )

        // Large budget — convergence should stop early, yielding similar weights
        let tunedLarge = try GeneratorTuning.tune(
            gen, samples: 2000, seed: 42, predicate: predicate,
        )

        guard case let .impure(.pick(moderateChoices), _) = tunedModerate,
              case let .impure(.pick(largeChoices), _) = tunedLarge
        else {
            Issue.record("Expected both tuned generators to be picks")
            return
        }

        // Both should have the first branch weighted higher than the second
        #expect(moderateChoices[0].weight > moderateChoices[1].weight,
                "Moderate: first branch should be favoured")
        #expect(largeChoices[0].weight > largeChoices[1].weight,
                "Large: first branch should be favoured")

        // Weight ratios should be similar — convergence means the large budget
        // didn't fundamentally change the distribution
        let moderateTotal = Double(moderateChoices[0].weight + moderateChoices[1].weight)
        let largeTotal = Double(largeChoices[0].weight + largeChoices[1].weight)

        guard moderateTotal > 0, largeTotal > 0 else {
            Issue.record("Expected non-zero total weights")
            return
        }

        let moderateRatio = Double(moderateChoices[0].weight) / moderateTotal
        let largeRatio = Double(largeChoices[0].weight) / largeTotal

        #expect(abs(moderateRatio - largeRatio) < 0.15,
                "Weight ratios should be similar (moderate: \(moderateRatio), large: \(largeRatio))")
    }

    // MARK: - Binary Search Tree

    @Test("BST: tuned generator structure has meaningful weight differences")
    func bstTunedStructure() throws {
        let naive = BST.arbitrary()

        let isValidBST: (BST) -> Bool = { $0.isValidBST() }

        let tuned = try GeneratorTuning.probeAndTune(
            naive,
            seed: 12345,
            predicate: isValidBST,
        )

        print("Tuned BST generator:\n\(tuned.debugDescription)")

        // The top-level should be a pick (leaf vs node)
        guard case let .impure(.pick(choices), _) = tuned else {
            Issue.record("Expected tuned generator to be a pick at top level")
            return
        }

        // Leaf branch (index 0) should have weight > 0 since all leaves are valid BSTs
        // Node branch (index 1) should also have weight > 0 since some nodes form valid BSTs
        #expect(choices.count == 2, "BST generator should have 2 branches (leaf and node)")

        let leafWeight = choices[0].weight
        let nodeWeight = choices[1].weight
        print("BST weights — leaf: \(leafWeight), node: \(nodeWeight)")

        #expect(leafWeight > 0, "Leaf branch should have positive weight")
        #expect(nodeWeight > 0, "Node branch should have positive weight")
    }
}
