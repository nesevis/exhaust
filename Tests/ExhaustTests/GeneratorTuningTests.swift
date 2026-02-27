//
//  GeneratorTuningTests.swift
//  ExhaustTests
//
//  Tests for the offline generator tuning algorithm.
//

import Foundation
import Testing
@testable import Exhaust

// MARK: - BST Definition (self-contained for test independence)

private enum BST: Equatable, Hashable {
    case leaf
    indirect case node(left: BST, value: UInt, right: BST)

    static var arbitrary: ReflectiveGenerator<BST> {
        bstGenerator(maxDepth: 5)
    }

    private static func bstGenerator(maxDepth: Int) -> ReflectiveGenerator<BST> {
        if maxDepth <= 0 {
            return Gen.just(.leaf)
        }
        return Gen.pick(choices: [
            (weight: 1, Gen.just(.leaf)),
            (weight: 3, Gen.zip(
                bstGenerator(maxDepth: maxDepth - 1),
                Gen.choose(in: UInt(0) ... 9),
                bstGenerator(maxDepth: maxDepth - 1),
            ).map { left, value, right in
                .node(left: left, value: value, right: right)
            }),
        ])
    }

    func isValidBST() -> Bool {
        isValidBST(min: nil, max: nil)
    }

    private func isValidBST(min: UInt?, max: UInt?) -> Bool {
        switch self {
        case .leaf:
            return true
        case let .node(left, value, right):
            if let min, value <= min { return false }
            if let max, value >= max { return false }
            return left.isValidBST(min: min, max: value) &&
                right.isValidBST(min: value, max: max)
        }
    }

    var height: Int {
        switch self {
        case .leaf: 0
        case let .node(left, _, right):
            1 + Swift.max(left.height, right.height)
        }
    }

    var nodeCount: Int {
        switch self {
        case .leaf: 0
        case let .node(left, _, right):
            1 + left.nodeCount + right.nodeCount
        }
    }
}

@Suite("Choice Gradient Sampling")
struct GeneratorTuningTests {
    // MARK: - Pick Adaptation

    @Test("Pick adaptation produces only valid output via .tune")
    func pickAdaptationWeightsByPredicate() {
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 100)),
            (weight: UInt64(1), generator: Gen.choose(in: 901 ... 1000)),
        ]).filter(.tune) { $0 <= 100 }

        let values = Array(ValueInterpreter(gen, seed: 123, maxRuns: 200))

        #expect(values.allSatisfy { $0 <= 100 })
        #expect(values.count == 200, "All runs should succeed with tuning")
    }

    @Test(".tune produces more valid output than raw generation")
    func tuneOutperformsRawGeneration() {
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 500)),
            (weight: UInt64(1), generator: Gen.choose(in: 501 ... 1000)),
        ])
        let predicate: (Int) -> Bool = { $0 <= 250 }

        // Raw generator: only ~25% of output satisfies the predicate
        let rawValues = Array(ValueInterpreter(gen, seed: 99, maxRuns: 200))
        let rawValidCount = rawValues.count(where: predicate)

        // Tuned filter: all output satisfies the predicate
        let tunedValues = Array(ValueInterpreter(gen.filter(.tune, predicate), seed: 99, maxRuns: 200))

        #expect(tunedValues.allSatisfy(predicate))
        #expect(tunedValues.count > rawValidCount,
                "Tuned filter (\(tunedValues.count) valid) should exceed raw generation (\(rawValidCount) valid)")
    }

    // MARK: - ChooseBits Subdivision

    @Test("ChooseBits subdivision concentrates output in favoured subrange")
    func chooseBitsSubdivision() {
        let gen = Gen.choose(in: UInt64(1) ... 1000)
            .filter(.tune) { $0 < 100 }

        let values = Array(ValueInterpreter(gen, seed: 123, maxRuns: 200))

        #expect(values.allSatisfy { $0 < 100 })
        #expect(values.count == 200, "All runs should succeed with tuning")
    }

    // MARK: - Sequence Length Adaptation

    @Test("Sequence length adaptation favours short arrays")
    func sequenceLengthAdaptation() {
        let lengthGen: ReflectiveGenerator<UInt64> = Gen.choose(in: 1 ... 50)
        let elementGen = Gen.choose(in: 1 ... 10)
        let gen = ReflectiveGenerator<[Int]>.impure(
            operation: .sequence(length: lengthGen, gen: elementGen.erase()),
        ) { result in
            .pure(result as! [Int])
        }.filter(.tune) { $0.count <= 3 }

        let values = Array(ValueInterpreter(gen, seed: 123, maxRuns: 100))

        #expect(values.allSatisfy { $0.count <= 3 })
        #expect(values.count == 100, "All runs should succeed with tuning")
    }

    // MARK: - Filter Integration

    @Test("Filter adaptation uses the filter's own predicate to adapt inner generator")
    func filterAdaptation() throws {
        let innerGen = Gen.choose(in: 1 ... 1000)
        let gen = innerGen.filter { ($0 as! Int) < 200 }

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
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 10)),
            (weight: UInt64(1), generator: Gen.choose(in: 901 ... 1000)),
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
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 10)),
            (weight: UInt64(1), generator: Gen.choose(in: 11 ... 20)),
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
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 500)),
            (weight: UInt64(1), generator: Gen.choose(in: 501 ... 1000)),
        ])
        let predicate: (Int) -> Bool = { $0 <= 250 }

        let tuned1 = try GeneratorTuning.tune(
            gen, samples: 50, seed: 42, predicate: predicate,
        )
        let tuned2 = try GeneratorTuning.tune(
            gen, samples: 50, seed: 42, predicate: predicate,
        )

        // Generate from both and verify identical output
        let values1 = Array(ValueInterpreter(tuned1, seed: 99, maxRuns: 50))
        let values2 = Array(ValueInterpreter(tuned2, seed: 99, maxRuns: 50))

        #expect(values1 == values2, "Same seed should produce identical tuned generators")
    }

    // MARK: - Convergence Early-Stopping

    @Test("Convergence early-stopping produces equivalent results with fewer samples")
    func convergenceEarlyStopping() throws {
        // A pick where one branch trivially satisfies and the other never does.
        // Convergence should stabilize quickly — a high sample cap shouldn't
        // change the weights compared to a moderate one.
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 50)),
            (weight: UInt64(1), generator: Gen.choose(in: 501 ... 1000)),
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

    // MARK: - Depth Budget

    @Test("Deeply nested generators do not explode in sample count")
    func depthBudget() {
        // Create a deeply nested pick structure
        var gen: ReflectiveGenerator<Int> = Gen.choose(in: 1 ... 10)
        for _ in 0 ..< 10 {
            gen = Gen.pick(choices: [
                (weight: UInt64(1), generator: gen),
                (weight: UInt64(1), generator: Gen.choose(in: 1 ... 10)),
            ])
        }

        let filtered = gen.filter(.tune) { $0 <= 5 }

        // This should complete in reasonable time without blowup
        let values = Array(ValueInterpreter(filtered, seed: 123, maxRuns: 20))
        #expect(!values.isEmpty, "Deeply nested tuned generator should still produce values")
        #expect(values.allSatisfy { $0 <= 5 })
    }

    // MARK: - Binary Search Tree

    @Test("BST: .tune produces more valid BSTs than raw generation")
    func bstTuneOutperformsRawGeneration() {
        let isValidNonLeafBST: (BST) -> Bool = { tree in
            tree != .leaf && tree.isValidBST()
        }

        let sampleCount: UInt64 = 500

        // Raw generation: only a fraction of output satisfies the predicate
        let rawValues = Array(ValueInterpreter(BST.arbitrary, seed: 42, maxRuns: sampleCount))
        let rawValidCount = rawValues.count(where: isValidNonLeafBST)

        // Tuned filter: all output satisfies the predicate
        let tunedGen = BST.arbitrary.filter(.tune, isValidNonLeafBST)
        let tunedValues = Array(ValueInterpreter(tunedGen, seed: 42, maxRuns: sampleCount))

        #expect(tunedValues.allSatisfy(isValidNonLeafBST))
        #expect(tunedValues.count > rawValidCount,
                "Tuned filter (\(tunedValues.count) valid) should exceed raw generation (\(rawValidCount) valid)")
    }

    @Test("BST: timed benchmark — .tune vs .reject (paper comparison)", .disabled("Not required"))
    func bstTimedBenchmark() {
        let isValidBST: (BST) -> Bool = { $0.height >= 1 && $0.isValidBST() }
        let duration: TimeInterval = 1

        // --- .reject strategy ---
        let rejectGen = BST.arbitrary.filter(.reject, isValidBST)
        var rejectIterator = ValueInterpreter(rejectGen, seed: 42, maxRuns: .max)
        var rejectValues = [BST]()

        let rejectStart = ContinuousClock.now
        while ContinuousClock.now - rejectStart < .seconds(duration) {
            guard let tree = rejectIterator.next() else { break }
            rejectValues.append(tree)
        }

        let rejectUnique = Set(rejectValues)
        print("=== \(duration)-second BST benchmark ===")
        print(".reject: \(rejectValues.count) valid (\(rejectUnique.count) unique)")

        // --- .tune strategy ---
        let tuneGen = BST.arbitrary.filter(.tune, isValidBST)
        var tuneIterator = ValueInterpreter(tuneGen, seed: 42, maxRuns: .max)
        var tuneValues = [BST]()

        let tuneStart = ContinuousClock.now
        while ContinuousClock.now - tuneStart < .seconds(duration) {
            guard let tree = tuneIterator.next() else { break }
            tuneValues.append(tree)
        }

        let tuneUnique = Set(tuneValues)
        print(".tune: \(tuneValues.count) valid (\(tuneUnique.count) unique)")
    }

    @Test("BST: .tune produces valid non-leaf trees")
    func bstTunedNonLeaf() {
        let isValidNonLeafBST: (BST) -> Bool = { tree in
            tree != .leaf && tree.isValidBST()
        }

        let tunedGen = BST.arbitrary.filter(.tune, isValidNonLeafBST)
        let values = Array(ValueInterpreter(tunedGen, seed: 99, maxRuns: 500))

        #expect(values.allSatisfy(isValidNonLeafBST))
        #expect(!values.isEmpty, "Should produce valid non-leaf BSTs")
    }

    @Test("BST: tuned generator structure has meaningful weight differences")
    func bstTunedStructure() throws {
        let naive = BST.arbitrary

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
