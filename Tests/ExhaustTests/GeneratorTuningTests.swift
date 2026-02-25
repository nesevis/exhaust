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
                bstGenerator(maxDepth: maxDepth - 1)
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
        case .leaf: return 0
        case let .node(left, _, right):
            return 1 + Swift.max(left.height, right.height)
        }
    }

    var nodeCount: Int {
        switch self {
        case .leaf: return 0
        case let .node(left, _, right):
            return 1 + left.nodeCount + right.nodeCount
        }
    }
}

@Suite("Choice Gradient Sampling")
struct GeneratorTuningTests {

    // MARK: - Pick Adaptation

    @Test("Pick adaptation weights branches by predicate satisfaction")
    func pickAdaptationWeightsByPredicate() throws {
        // Generator with two branches: small numbers and large numbers
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 100)),
            (weight: UInt64(1), generator: Gen.choose(in: 901 ... 1000)),
        ])

        // Predicate that favours small numbers
        let predicate: (Int) -> Bool = { $0 <= 100 }

        let tuned = try GeneratorTuning.tune(
            gen,
            samples: 50,
            seed: 42,
            predicate: predicate
        )

        // Generate values from tuned generator and measure hit rate
        let values = Array(ValueInterpreter(tuned, seed: 123, maxRuns: 200))
        let hitRate = Double(values.count(where: predicate)) / Double(values.count)
        print()

        // Tuned generator should strongly favour the small-number branch
        #expect(hitRate > 0.7, "Expected tuned hit rate > 0.7, got \(hitRate)")
    }

    @Test("Pick adaptation increases hit rate versus untuned generator")
    func pickAdaptationIncreasesHitRate() throws {
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 500)),
            (weight: UInt64(1), generator: Gen.choose(in: 501 ... 1000)),
        ])

        let predicate: (Int) -> Bool = { $0 <= 250 }

        // Untuned baseline
        let baselineValues = Array(ValueInterpreter(gen, seed: 99, maxRuns: 200))
        let baselineRate = Double(baselineValues.count(where: predicate)) / Double(baselineValues.count)

        // Tuned
        let tuned = try GeneratorTuning.tune(
            gen,
            samples: 80,
            seed: 42,
            predicate: predicate
        )
        let tunedValues = Array(ValueInterpreter(tuned, seed: 99, maxRuns: 200))
        let tunedRate = Double(tunedValues.count(where: predicate)) / Double(tunedValues.count)

        #expect(tunedRate > baselineRate,
                "Tuned rate (\(tunedRate)) should exceed baseline (\(baselineRate))")
    }

    // MARK: - ChooseBits Subdivision

    @Test("ChooseBits subdivision concentrates output in favoured subrange")
    func chooseBitsSubdivision() throws {
        let gen = Gen.choose(in: UInt64(1) ... 1000)
        let predicate: (UInt64) -> Bool = { $0 < 100 }

        let tuned = try GeneratorTuning.tune(
            gen,
            samples: 80,
            seed: 42,
            predicate: predicate
        )

        let values = Array(ValueInterpreter(tuned, seed: 123, maxRuns: 200))
        let hitRate = Double(values.count(where: predicate)) / Double(values.count)

        #expect(hitRate > 0.3,
                "Expected chooseBits adaptation to concentrate in low range, got hit rate \(hitRate)")
    }

    // MARK: - Sequence Length Adaptation

    @Test("Sequence length adaptation favours short arrays")
    func sequenceLengthAdaptation() throws {
        let lengthGen: ReflectiveGenerator<UInt64> = Gen.choose(in: 1 ... 50)
        let elementGen = Gen.choose(in: 1 ... 10)
        let gen: ReflectiveGenerator<[Int]> = .impure(
            operation: .sequence(length: lengthGen, gen: elementGen.erase())
        ) { result in
            .pure(result as! [Int])
        }

        let predicate: ([Int]) -> Bool = { $0.count <= 3 }

        let tuned = try GeneratorTuning.tune(
            gen,
            samples: 50,
            seed: 42,
            predicate: predicate
        )

        let values = Array(ValueInterpreter(tuned, seed: 123, maxRuns: 100))
        let hitRate = Double(values.count(where: predicate)) / Double(values.count)

        // Baseline for count <= 3 in range 1...50 is ~6%; adaptation should significantly improve this.
        // The weight floor (0.1) limits how aggressively tuning can concentrate on short lengths.
        #expect(hitRate > 0.10,
                "Expected sequence adaptation to improve short array rate, got hit rate \(hitRate)")
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
            predicate: { (_: Int) in true }
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
            predicate: predicate
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
            predicate: predicate
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
            gen, samples: 50, seed: 42, predicate: predicate
        )
        let tuned2 = try GeneratorTuning.tune(
            gen, samples: 50, seed: 42, predicate: predicate
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
            gen, samples: 100, seed: 42, predicate: predicate
        )

        // Large budget — convergence should stop early, yielding similar weights
        let tunedLarge = try GeneratorTuning.tune(
            gen, samples: 2000, seed: 42, predicate: predicate
        )

        guard case let .impure(.pick(moderateChoices), _) = tunedModerate,
              case let .impure(.pick(largeChoices), _) = tunedLarge else {
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
    func depthBudget() throws {
        // Create a deeply nested pick structure
        var gen: ReflectiveGenerator<Int> = Gen.choose(in: 1 ... 10)
        for _ in 0 ..< 10 {
            gen = Gen.pick(choices: [
                (weight: UInt64(1), generator: gen),
                (weight: UInt64(1), generator: Gen.choose(in: 1 ... 10)),
            ])
        }

        let predicate: (Int) -> Bool = { $0 <= 5 }

        // This should complete in reasonable time without blowup
        let tuned = try GeneratorTuning.tune(
            gen,
            samples: 50,
            seed: 42,
            predicate: predicate
        )

        // Verify it produces values
        let values = Array(ValueInterpreter(tuned, seed: 123, maxRuns: 20))
        #expect(values.isEmpty == false, "Deeply nested tuned generator should still produce values")
    }

    // MARK: - Binary Search Tree

    @Test("BST: CGS adaptation improves valid BST rate over naive generation")
    func bstAdaptationImprovesValidityRate() throws {
        let naive = BST.arbitrary

        let isValidNonLeafBST: (BST) -> Bool = { tree in
            tree != .leaf && tree.isValidBST()
        }

        let sampleCount: UInt64 = 500

        // Measure naive baseline
        let naiveValues = Array(ValueInterpreter(naive, seed: 42, maxRuns: sampleCount))
        let naiveValid = naiveValues.filter(isValidNonLeafBST)
        let naiveRate = Double(naiveValid.count) / Double(naiveValues.count)

        // Adapt with CGS
        let tuned = try GeneratorTuning.tune(
            naive,
            samples: 100,
            seed: 12345,
            predicate: isValidNonLeafBST
        )

        // Measure tuned
        let tunedValues = Array(ValueInterpreter(tuned, seed: 42, maxRuns: sampleCount))
        let tunedValid = tunedValues.filter(isValidNonLeafBST)
        let tunedRate = Double(tunedValid.count) / Double(tunedValues.count)

        // Uniqueness and diversity
        let naiveUnique = Set(naiveValid)
        let tunedUnique = Set(tunedValid)
        let naiveHeights = Dictionary(grouping: naiveValid, by: \.height).mapValues(\.count)
        let tunedHeights = Dictionary(grouping: tunedValid, by: \.height).mapValues(\.count)

        print("BST validity — naive: \(naiveValid.count)/\(naiveValues.count) (\(String(format: "%.1f%%", naiveRate * 100))), tuned: \(tunedValid.count)/\(tunedValues.count) (\(String(format: "%.1f%%", tunedRate * 100)))")
        print("BST unique valid — naive: \(naiveUnique.count), tuned: \(tunedUnique.count)")
        print("BST heights — naive: \(naiveHeights.sorted(by: { $0.key < $1.key })), tuned: \(tunedHeights.sorted(by: { $0.key < $1.key }))")

        #expect(tunedRate > naiveRate,
                "Tuned rate (\(tunedRate)) should exceed naive rate (\(naiveRate))")
    }

    @Test("BST: timed benchmark — CGS vs rejection sampling (paper comparison)", .disabled("Not required"))
    func bstTimedBenchmark() throws {
        let naive = BST.arbitrary
        let isValidBST: (BST) -> Bool = { $0.height >= 1 && $0.isValidBST() }
        let duration: TimeInterval = 1

        // --- Rejection sampling baseline (run once) ---
        var rejectionIterator = ValueInterpreter(naive, seed: 42, maxRuns: .max)
        var rejectionTotal = 0
        var rejectionUnique = Set<BST>()
        var rejectionHeights = [Int: [BST]]()

        let rejectionStart = ContinuousClock.now
        while ContinuousClock.now - rejectionStart < .seconds(duration) {
            guard let tree = rejectionIterator.next() else { break }
            if isValidBST(tree) {
                rejectionTotal += 1
                rejectionUnique.insert(tree)
                rejectionHeights[tree.height, default: []].append(tree)
            }
        }

        let rUHeights = rejectionHeights
            .sorted(by: { $0.key < $1.key })
            .map { ($0.key, Set($0.value).count) }

        print("=== \(duration)-second BST benchmark — sampleCount sweep ===")
        print("Rejection sampling: \(rejectionTotal) valid (\(rejectionUnique.count) unique)")
        print("  Heights unique: \(rUHeights)")
        print()

        // --- CGS sweep across sample counts × tuning seeds ---
        let sampleCounts: [UInt64] = [500, 750, 1000, 1250, 1500, 2000, 3000, 5000]
        let tuningSeeds: [UInt64] = [12345, 99999, 271828, 314159]

        for seed in tuningSeeds {
            print("--- seed=\(seed) ---")
            for sampleCount in sampleCounts {
                let start = ContinuousClock.now
                let tuned = try GeneratorTuning.tune(
                    naive,
                    samples: sampleCount,
                    seed: seed,
                    predicate: isValidBST
                )
                let adaptTime = ContinuousClock.now - start

                var cgsIterator = ValueInterpreter(tuned, seed: 42, maxRuns: .max)
                var cgsTotal = 0
                var cgsValid = 0
                var cgsUnique = Set<BST>()
                var cgsHeights = [Int: Set<BST>]()

                while ContinuousClock.now - start < .seconds(duration) {
                    guard let tree = cgsIterator.next() else { break }
                    cgsTotal += 1
                    if isValidBST(tree) {
                        cgsValid += 1
                        cgsUnique.insert(tree)
                        cgsHeights[tree.height, default: []].insert(tree)
                    }
                }

                let heights = cgsHeights
                    .sorted(by: { $0.key < $1.key })
                    .map { "h\($0.key):\($0.value.count)" }
                    .joined(separator: " ")

                let adaptMs = Double(adaptTime.components.seconds) * 1000 + Double(adaptTime.components.attoseconds) / 1e15
                let validPct = cgsTotal > 0 ? Double(cgsValid) / Double(cgsTotal) * 100 : 0
                print("  s=\(String(format: "%4d", sampleCount)) | \(String(format: "%4.0f", adaptMs))ms | \(String(format: "%5d", cgsUnique.count)) unique | \(String(format: "%5.1f", validPct))% valid | \(heights)")
            }
        }

        print()
        print("Rejection baseline: \(rejectionUnique.count) unique")
    }

    @Test("BST: tuned generator produces valid non-leaf trees")
    func bstTunedNonLeaf() throws {
        let naive = BST.arbitrary

        // Require non-leaf valid BSTs — this is the hard predicate from the paper
        let isValidNonLeafBST: (BST) -> Bool = { tree in
            tree != .leaf && tree.isValidBST()
        }

        let tuned = try GeneratorTuning.tune(
            naive,
            samples: 100,
            seed: 12345,
            predicate: isValidNonLeafBST
        )

        // Measure naive baseline for non-leaf valid BSTs
        let naiveValues = Array(ValueInterpreter(naive, seed: 99, maxRuns: 500))
        let naiveValidCount = naiveValues.count(where: isValidNonLeafBST)

        let tunedValues = Array(ValueInterpreter(tuned, seed: 99, maxRuns: 500))
        let tunedValidCount = tunedValues.count(where: isValidNonLeafBST)

        let naiveRate = Double(naiveValidCount) / Double(naiveValues.count)
        let tunedRate = Double(tunedValidCount) / Double(tunedValues.count)

        print("BST non-leaf validity — naive: \(naiveValidCount)/\(naiveValues.count) (\(String(format: "%.1f%%", naiveRate * 100))), tuned: \(tunedValidCount)/\(tunedValues.count) (\(String(format: "%.1f%%", tunedRate * 100)))")

        // Tuned should improve over naive
        #expect(tunedRate > naiveRate,
                "Tuned non-leaf BST rate (\(tunedRate)) should exceed naive (\(naiveRate))")
        #expect(!tunedValues.filter(isValidNonLeafBST).isEmpty,
                "Should produce at least some valid non-leaf BSTs")
    }

    @Test("BST: tuned generator structure has meaningful weight differences")
    func bstTunedStructure() throws {
        let naive = BST.arbitrary

        let isValidBST: (BST) -> Bool = { $0.isValidBST() }

        let tuned = try GeneratorTuning.probeAndTune(
            naive,
            seed: 12345,
            predicate: isValidBST
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
