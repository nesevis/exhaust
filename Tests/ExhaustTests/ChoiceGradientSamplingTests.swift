//
//  ChoiceGradientSamplingTests.swift
//  ExhaustTests
//
//  Tests for the Choice Gradient Sampling adaptation interpreter.
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
struct ChoiceGradientSamplingTests {

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

        let adapted = try ChoiceGradientSampling.adapt(
            gen,
            samples: 50,
            seed: 42,
            predicate: predicate
        )

        // Generate values from adapted generator and measure hit rate
        let values = Array(ValueInterpreter(adapted, seed: 123, maxRuns: 200))
        let hitRate = Double(values.count(where: predicate)) / Double(values.count)
        print()

        // Adapted generator should strongly favour the small-number branch
        #expect(hitRate > 0.7, "Expected adapted hit rate > 0.7, got \(hitRate)")
    }

    @Test("Pick adaptation increases hit rate versus unadapted generator")
    func pickAdaptationIncreasesHitRate() throws {
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 500)),
            (weight: UInt64(1), generator: Gen.choose(in: 501 ... 1000)),
        ])

        let predicate: (Int) -> Bool = { $0 <= 250 }

        // Unadapted baseline
        let baselineValues = Array(ValueInterpreter(gen, seed: 99, maxRuns: 200))
        let baselineRate = Double(baselineValues.count(where: predicate)) / Double(baselineValues.count)

        // Adapted
        let adapted = try ChoiceGradientSampling.adapt(
            gen,
            samples: 80,
            seed: 42,
            predicate: predicate
        )
        let adaptedValues = Array(ValueInterpreter(adapted, seed: 99, maxRuns: 200))
        let adaptedRate = Double(adaptedValues.count(where: predicate)) / Double(adaptedValues.count)

        #expect(adaptedRate > baselineRate,
                "Adapted rate (\(adaptedRate)) should exceed baseline (\(baselineRate))")
    }

    // MARK: - ChooseBits Subdivision

    @Test("ChooseBits subdivision concentrates output in favoured subrange")
    func chooseBitsSubdivision() throws {
        let gen = Gen.choose(in: UInt64(1) ... 1000)
        let predicate: (UInt64) -> Bool = { $0 < 100 }

        let adapted = try ChoiceGradientSampling.adapt(
            gen,
            samples: 80,
            seed: 42,
            predicate: predicate
        )

        let values = Array(ValueInterpreter(adapted, seed: 123, maxRuns: 200))
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

        let adapted = try ChoiceGradientSampling.adapt(
            gen,
            samples: 50,
            seed: 42,
            predicate: predicate
        )

        let values = Array(ValueInterpreter(adapted, seed: 123, maxRuns: 100))
        let hitRate = Double(values.count(where: predicate)) / Double(values.count)

        // Baseline for count <= 3 in range 1...50 is ~6%; adaptation should significantly improve this
        #expect(hitRate > 0.15,
                "Expected sequence adaptation to improve short array rate, got hit rate \(hitRate)")
    }

    // MARK: - Filter Integration

    @Test("Filter adaptation uses the filter's own predicate to adapt inner generator")
    func filterAdaptation() throws {
        let innerGen = Gen.choose(in: 1 ... 1000)
        let gen = innerGen.filter { ($0 as! Int) < 200 }

        // The outer predicate is irrelevant — filter's predicate should drive adaptation
        let adapted = try ChoiceGradientSampling.adapt(
            gen,
            samples: 50,
            seed: 42,
            predicate: { (_: Int) in true }
        )

        // Verify that the adapted generator structure contains a filter with an adapted inner gen
        guard case let .impure(.filter(adaptedInner, _, _), _) = adapted else {
            Issue.record("Expected adapted generator to be a filter")
            return
        }

        // The inner generator should now be a pick (from chooseBits subdivision)
        // rather than the original chooseBits, because CGS adapted it using the filter predicate
        guard case let .impure(.pick(choices), _) = adaptedInner else {
            Issue.record("Expected inner generator to be adapted into a pick, got \(adaptedInner)")
            return
        }

        // The low-range subrange should have higher weight since the filter predicate favours < 200
        let firstWeight = choices.first?.weight ?? 0
        let lastWeight = choices.last?.weight ?? 0
        #expect(firstWeight >= lastWeight,
                "Low subrange should have equal or higher weight than high subrange")
    }

    // MARK: - Zero-weight Branches

    @Test("Zero-weight branches are preserved in adapted structure")
    func zeroWeightBranchesPreserved() throws {
        // One branch always satisfies, one never does
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 10)),
            (weight: UInt64(1), generator: Gen.choose(in: 901 ... 1000)),
        ])

        let predicate: (Int) -> Bool = { $0 <= 10 }

        let adapted = try ChoiceGradientSampling.adapt(
            gen,
            samples: 50,
            seed: 42,
            predicate: predicate
        )

        // Inspect the adapted structure: should have 2 branches still
        guard case let .impure(.pick(choices), _) = adapted else {
            Issue.record("Expected adapted generator to be a pick")
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

        let adapted = try ChoiceGradientSampling.adapt(
            gen,
            samples: 20,
            seed: 42,
            predicate: predicate
        )

        guard case let .impure(.pick(choices), _) = adapted else {
            Issue.record("Expected adapted generator to be a pick")
            return
        }

        // All weights should be restored to 1
        #expect(choices.allSatisfy { $0.weight == 1 },
                "All-zero fallback should restore weights to 1, got \(choices.map(\.weight))")
    }

    // MARK: - Deterministic Seeding

    @Test("Same seed produces same adapted structure")
    func deterministicSeeding() throws {
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 500)),
            (weight: UInt64(1), generator: Gen.choose(in: 501 ... 1000)),
        ])
        let predicate: (Int) -> Bool = { $0 <= 250 }

        let adapted1 = try ChoiceGradientSampling.adapt(
            gen, samples: 50, seed: 42, predicate: predicate
        )
        let adapted2 = try ChoiceGradientSampling.adapt(
            gen, samples: 50, seed: 42, predicate: predicate
        )

        // Generate from both and verify identical output
        let values1 = Array(ValueInterpreter(adapted1, seed: 99, maxRuns: 50))
        let values2 = Array(ValueInterpreter(adapted2, seed: 99, maxRuns: 50))

        #expect(values1 == values2, "Same seed should produce identical adapted generators")
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
        let adapted = try ChoiceGradientSampling.adapt(
            gen,
            samples: 50,
            seed: 42,
            predicate: predicate
        )

        // Verify it produces values
        let values = Array(ValueInterpreter(adapted, seed: 123, maxRuns: 20))
        #expect(values.isEmpty == false, "Deeply nested adapted generator should still produce values")
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
        let adapted = try ChoiceGradientSampling.adapt(
            naive,
            samples: 100,
            seed: 12345,
            predicate: isValidNonLeafBST
        )

        // Measure adapted
        let adaptedValues = Array(ValueInterpreter(adapted, seed: 42, maxRuns: sampleCount))
        let adaptedValid = adaptedValues.filter(isValidNonLeafBST)
        let adaptedRate = Double(adaptedValid.count) / Double(adaptedValues.count)

        // Uniqueness and diversity
        let naiveUnique = Set(naiveValid)
        let adaptedUnique = Set(adaptedValid)
        let naiveHeights = Dictionary(grouping: naiveValid, by: \.height).mapValues(\.count)
        let adaptedHeights = Dictionary(grouping: adaptedValid, by: \.height).mapValues(\.count)

        print("BST validity — naive: \(naiveValid.count)/\(naiveValues.count) (\(String(format: "%.1f%%", naiveRate * 100))), adapted: \(adaptedValid.count)/\(adaptedValues.count) (\(String(format: "%.1f%%", adaptedRate * 100)))")
        print("BST unique valid — naive: \(naiveUnique.count), adapted: \(adaptedUnique.count)")
        print("BST heights — naive: \(naiveHeights.sorted(by: { $0.key < $1.key })), adapted: \(adaptedHeights.sorted(by: { $0.key < $1.key }))")

        #expect(adaptedRate > naiveRate,
                "Adapted rate (\(adaptedRate)) should exceed naive rate (\(naiveRate))")
    }

    @Test("BST: 10 second benchmark — CGS vs rejection sampling (paper comparison)")
    func bstTenSecondBenchmark() throws {
        let naive = BST.arbitrary
        let isValidBST: (BST) -> Bool = { $0.height >= 1 && $0.isValidBST() }
        let duration: TimeInterval = 10

        // --- Rejection sampling (generate naively, keep only valid) ---
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

        // --- CGS-adapted generation ---
        let adaptStart = ContinuousClock.now
        let adapted = try ChoiceGradientSampling.adapt(
            naive,
            samples: 1000,
            seed: 12345,
            predicate: isValidBST
        )
        let adaptTime = ContinuousClock.now - adaptStart

        var cgsIterator = ValueInterpreter(adapted, seed: 42, maxRuns: .max)
        var cgsTotal = 0
        var cgsValid = 0
        var cgsUnique = Set<BST>()
        var cgsHeights = [Int: [BST]]()

        let cgsStart = ContinuousClock.now
        let cgsGenerationBudget = Duration.seconds(duration) - adaptTime
        while ContinuousClock.now - cgsStart < cgsGenerationBudget {
            guard let tree = cgsIterator.next() else { break }
            cgsTotal += 1
            if isValidBST(tree) {
                cgsValid += 1
                cgsUnique.insert(tree)
                cgsHeights[tree.height, default: []].append(tree)
            }
        }
        let rHeights = rejectionHeights
            .sorted(by: { $0.key < $1.key })
            .map { ($0.key, $0.value.count) }
        let rUHeights = rejectionHeights
            .sorted(by: { $0.key < $1.key })
            .map { ($0.key, Set($0.value).count) }
        
        let cHeights = cgsHeights
            .sorted(by: { $0.key < $1.key })
            .map { ($0.key, $0.value.count) }
        let cUHeights = cgsHeights
            .sorted(by: { $0.key < $1.key })
            .map { ($0.key, Set($0.value).count) }

        print("=== 1-minute BST benchmark (paper comparison) ===")
        print("Paper reference:    Rejection 7,354 (109 unique) | CGS 22,107 (338 unique)")
        print()
        print("Rejection sampling: \(rejectionTotal) valid (\(rejectionUnique.count) unique)")
        print("  Heights: \(rHeights)")
        print("  Heights unique: \(rUHeights)")
        print()
        let adaptMs = Double(adaptTime.components.seconds) * 1000 + Double(adaptTime.components.attoseconds) / 1e15
        print("CGS (adapt: \(String(format: "%.0f", adaptMs))ms):")
        print("  Generated: \(cgsTotal) total, \(cgsValid) valid (\(cgsUnique.count) unique)")
        print("  Heights: \(cHeights)")
        print("  Heights unique: \(cUHeights)")
        print()
        print("Unique valid ratio: CGS/Rejection = \(String(format: "%.1fx", Double(cgsUnique.count) / Double(max(1, rejectionUnique.count))))")

        #expect(cgsUnique.count > rejectionUnique.count,
                "CGS unique (\(cgsUnique.count)) should exceed rejection unique (\(rejectionUnique.count))")
    }

    @Test("BST: adapted generator produces valid non-leaf trees")
    func bstAdaptedNonLeaf() throws {
        let naive = BST.arbitrary

        // Require non-leaf valid BSTs — this is the hard predicate from the paper
        let isValidNonLeafBST: (BST) -> Bool = { tree in
            tree != .leaf && tree.isValidBST()
        }

        let adapted = try ChoiceGradientSampling.adapt(
            naive,
            samples: 100,
            seed: 12345,
            predicate: isValidNonLeafBST
        )

        // Measure naive baseline for non-leaf valid BSTs
        let naiveValues = Array(ValueInterpreter(naive, seed: 99, maxRuns: 500))
        let naiveValidCount = naiveValues.count(where: isValidNonLeafBST)

        let adaptedValues = Array(ValueInterpreter(adapted, seed: 99, maxRuns: 500))
        let adaptedValidCount = adaptedValues.count(where: isValidNonLeafBST)

        let naiveRate = Double(naiveValidCount) / Double(naiveValues.count)
        let adaptedRate = Double(adaptedValidCount) / Double(adaptedValues.count)

        print("BST non-leaf validity — naive: \(naiveValidCount)/\(naiveValues.count) (\(String(format: "%.1f%%", naiveRate * 100))), adapted: \(adaptedValidCount)/\(adaptedValues.count) (\(String(format: "%.1f%%", adaptedRate * 100)))")

        // Adapted should improve over naive
        #expect(adaptedRate > naiveRate,
                "Adapted non-leaf BST rate (\(adaptedRate)) should exceed naive (\(naiveRate))")
        #expect(!adaptedValues.filter(isValidNonLeafBST).isEmpty,
                "Should produce at least some valid non-leaf BSTs")
    }

    @Test("BST: adapted generator structure has meaningful weight differences")
    func bstAdaptedStructure() throws {
        let naive = BST.arbitrary

        let isValidBST: (BST) -> Bool = { $0.isValidBST() }

        let adapted = try ChoiceGradientSampling.adapt(
            naive,
            samples: 100,
            seed: 12345,
            predicate: isValidBST
        )

        print("Adapted BST generator:\n\(adapted.debugDescription)")

        // The top-level should be a pick (leaf vs node)
        guard case let .impure(.pick(choices), _) = adapted else {
            Issue.record("Expected adapted generator to be a pick at top level")
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
