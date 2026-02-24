//
//  CGSValueAndChoiceTreeInterpreterTests.swift
//  ExhaustTests
//
//  Tests for the online Choice Gradient Sampling interpreter.
//

import Foundation
import Testing
@testable import Exhaust

// MARK: - BST Definition

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
}

@Suite("Online CGS Interpreter")
struct CGSValueAndChoiceTreeInterpreterTests {

    // MARK: - BST Height Diversity

    @Test("BST: online CGS produces valid BSTs at heights >= 2")
    func bstHeightDiversity() throws {
        let gen = BST.arbitrary
        let isValidNonLeafBST: (BST) -> Bool = { $0 != .leaf && $0.isValidBST() }

        var iterator = CGSValueAndChoiceTreeInterpreter(
            gen,
            predicate: isValidNonLeafBST,
            sampleCount: 50,
            seed: 42,
            maxRuns: 500
        )

        var validTrees = [BST]()
        while let (value, _) = iterator.next() {
            if isValidNonLeafBST(value) {
                validTrees.append(value)
            }
        }

        let heights = Dictionary(grouping: validTrees, by: \.height).mapValues(\.count)
        let uniqueTrees = Set(validTrees)

        print("Online CGS BST: \(validTrees.count) valid, \(uniqueTrees.count) unique")
        print("Heights: \(heights.sorted(by: { $0.key < $1.key }))")

        // The key test: online CGS should produce trees at height >= 2
        let tallTreeCount = validTrees.count { $0.height >= 2 }
        #expect(tallTreeCount > 0, "Online CGS should produce BSTs at height >= 2, got heights: \(heights)")
        #expect(uniqueTrees.count > 20, "Should produce diverse valid BSTs, got \(uniqueTrees.count) unique")
    }

    // MARK: - Choice Tree Replay

    @Test("Choice tree replay reproduces the same value")
    func choiceTreeReplay() throws {
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 100)),
            (weight: UInt64(1), generator: Gen.choose(in: 101 ... 200)),
        ])
        let predicate: (Int) -> Bool = { $0 <= 100 }

        var iterator = CGSValueAndChoiceTreeInterpreter(
            gen,
            predicate: predicate,
            sampleCount: 30,
            materializePicks: true,
            seed: 42,
            maxRuns: 10
        )

        for _ in 0 ..< 10 {
            guard let (value, tree) = iterator.next() else { break }
            let sequence = ChoiceSequence.flatten(tree)
            let replayed = try Interpreters.materialize(gen, with: tree, using: sequence)
            #expect(replayed == value, "Replayed value \(String(describing: replayed)) should match generated value \(value)")
        }
    }

    // MARK: - Shrinking Integration

    @Test("Shrinking integration: CGS counterexample can be reduced")
    func shrinkingIntegration() throws {
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 50)),
            (weight: UInt64(1), generator: Gen.choose(in: 51 ... 100)),
        ])

        // Property: all values should be <= 50 (branch 2 will fail)
        let property: (Int) -> Bool = { $0 <= 50 }

        var iterator = CGSValueAndChoiceTreeInterpreter(
            gen,
            predicate: { _ in true }, // Predicate for generation guidance (accept all)
            sampleCount: 20,
            materializePicks: true,
            seed: 42,
            maxRuns: 100
        )

        // Find a counterexample
        var counterexample: (value: Int, tree: ChoiceTree)?
        while let (value, tree) = iterator.next() {
            if !property(value) {
                counterexample = (value, tree)
                break
            }
        }

        let ce = try #require(counterexample, "Should find a counterexample")
        #expect(ce.value > 50)

        // Shrink the counterexample
        let reduced = try Interpreters.reduce(
            gen: gen,
            tree: ce.tree,
            config: .fast,
            property: property
        )

        let (_, shrunk) = try #require(reduced, "Shrinking should produce a result")
        #expect(shrunk == 51, "Minimal counterexample should be 51, got \(shrunk)")
    }

    // MARK: - Simple Pick Guidance

    @Test("Pick guidance: CGS favours branch matching predicate")
    func simplePickGuidance() throws {
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 100)),
            (weight: UInt64(1), generator: Gen.choose(in: 901 ... 1000)),
        ])
        let predicate: (Int) -> Bool = { $0 <= 100 }

        let cgsValues = Array(
            CGSValueAndChoiceTreeInterpreter(
                gen,
                predicate: predicate,
                sampleCount: 50,
                seed: 42,
                maxRuns: 200
            )
        ).map(\.value)

        let cgsHitRate = Double(cgsValues.count(where: predicate)) / Double(cgsValues.count)

        // Naive baseline: ~50% since both branches have equal weight
        let naiveValues = Array(ValueInterpreter(gen, seed: 42, maxRuns: 200))
        let naiveHitRate = Double(naiveValues.count(where: predicate)) / Double(naiveValues.count)

        print("Pick guidance — naive: \(String(format: "%.1f%%", naiveHitRate * 100)), CGS: \(String(format: "%.1f%%", cgsHitRate * 100))")

        #expect(cgsHitRate > naiveHitRate,
                "CGS hit rate (\(cgsHitRate)) should exceed naive (\(naiveHitRate))")
        #expect(cgsHitRate > 0.7, "CGS should strongly favour the valid branch, got \(cgsHitRate)")
    }

    // MARK: - Deterministic Seeding

    @Test("Same seed produces same output sequence")
    func deterministicSeeding() {
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 500)),
            (weight: UInt64(1), generator: Gen.choose(in: 501 ... 1000)),
        ])
        let predicate: (Int) -> Bool = { $0 <= 250 }

        let values1 = Array(
            CGSValueAndChoiceTreeInterpreter(
                gen,
                predicate: predicate,
                sampleCount: 30,
                seed: 42,
                maxRuns: 50
            )
        ).map(\.value)

        let values2 = Array(
            CGSValueAndChoiceTreeInterpreter(
                gen,
                predicate: predicate,
                sampleCount: 30,
                seed: 42,
                maxRuns: 50
            )
        ).map(\.value)

        #expect(values1 == values2, "Same seed should produce identical output sequences")
    }

    // MARK: - Zip CGS Guidance

    @Test("Zip: CGS guidance improves joint predicate satisfaction")
    func zipCGSGuidance() throws {
        let gen = Gen.zip(
            Gen.choose(in: 1 ... 20),
            Gen.choose(in: 1 ... 20)
        )
        let predicate: ((Int, Int)) -> Bool = { $0.0 + $0.1 < 10 }

        let cgsValues = Array(
            CGSValueAndChoiceTreeInterpreter(
                gen,
                predicate: predicate,
                sampleCount: 50,
                seed: 42,
                maxRuns: 200
            )
        ).map(\.value)

        let cgsHitRate = Double(cgsValues.count(where: predicate)) / Double(cgsValues.count)

        // Naive baseline
        let naiveValues = Array(ValueInterpreter(gen, seed: 42, maxRuns: 200))
        let naiveHitRate = Double(naiveValues.count(where: predicate)) / Double(naiveValues.count)

        print("Zip guidance — naive: \(String(format: "%.1f%%", naiveHitRate * 100)), CGS: \(String(format: "%.1f%%", cgsHitRate * 100))")

        #expect(cgsHitRate > naiveHitRate,
                "CGS zip hit rate (\(cgsHitRate)) should exceed naive (\(naiveHitRate))")
    }

    // MARK: - ChooseBits Subdivision

    @Test("ChooseBits subdivision concentrates output in favoured subrange")
    func chooseBitsSubdivision() {
        let gen = Gen.choose(in: UInt64(1) ... 1000)
        let predicate: (UInt64) -> Bool = { $0 < 100 }

        let cgsValues = Array(
            CGSValueAndChoiceTreeInterpreter(
                gen,
                predicate: predicate,
                sampleCount: 50,
                seed: 42,
                maxRuns: 200
            )
        ).map(\.value)

        let hitRate = Double(cgsValues.count(where: predicate)) / Double(cgsValues.count)

        // Naive baseline is ~10% (100/1000)
        print("ChooseBits subdivision — CGS hit rate: \(String(format: "%.1f%%", hitRate * 100))")

        #expect(hitRate > 0.15,
                "ChooseBits subdivision should concentrate in low range, got hit rate \(hitRate)")
    }

    // MARK: - Benchmark

    @Test("BST: 10 second benchmark — rejection vs eager CGS vs online CGS")
    func bstTenSecondBenchmark() throws {
        let naive = BST.arbitrary
        let isValidBST: (BST) -> Bool = { $0.height >= 1 && $0.isValidBST() }
        var maxRuns: UInt64 = 2000

        // --- Rejection sampling (generate naively, keep only valid) ---
        var rejectionIterator = ValueInterpreter(naive, seed: 42, maxRuns: maxRuns)
        var rejectionValid = 0
        var rejectionUnique = Set<BST>()
        var rejectionHeights = [Int: [BST]]()

        let rejectionStart = ContinuousClock.now
        while let tree = rejectionIterator.next() {
            if isValidBST(tree) {
                rejectionValid += 1
                rejectionUnique.insert(tree)
                rejectionHeights[tree.height, default: []].append(tree)
            }
        }
        let rejectionElapsed = ContinuousClock.now - rejectionStart

        // --- Eager CGS-adapted generation ---
        let eagerAdaptStart = ContinuousClock.now
        let adapted = try ChoiceGradientSampling.adapt(
            naive,
            samples: 1000,
            seed: 12345,
            predicate: isValidBST
        )
        let eagerAdaptTime = ContinuousClock.now - eagerAdaptStart

        var eagerIterator = ValueInterpreter(adapted, seed: 42, maxRuns: maxRuns)
        var eagerTotal = 0
        var eagerValid = 0
        var eagerUnique = Set<BST>()
        var eagerHeights = [Int: [BST]]()

        let eagerStart = ContinuousClock.now
        while let tree = eagerIterator.next() {
            eagerTotal += 1
            if isValidBST(tree) {
                eagerValid += 1
                eagerUnique.insert(tree)
                eagerHeights[tree.height, default: []].append(tree)
            }
        }
        let eagerElapsed = ContinuousClock.now - eagerStart

        // --- Online CGS generation ---
        let sampleCount: UInt64 = 3
        var onlineIterator = CGSValueAndChoiceTreeInterpreter(
            naive,
            predicate: isValidBST,
            sampleCount: sampleCount,
            seed: 42,
            maxRuns: maxRuns
        )
        var onlineTotal = 0
        var onlineValid = 0
        var onlineUnique = Set<BST>()
        var onlineHeights = [Int: [BST]]()

        let onlineStart = ContinuousClock.now
        while let (tree, _) = onlineIterator.next() {
            onlineTotal += 1
            if isValidBST(tree) {
                onlineValid += 1
                onlineUnique.insert(tree)
                onlineHeights[tree.height, default: []].append(tree)
            }
        }
        let onlineElapsed = ContinuousClock.now - onlineStart

        // --- Format results ---
        func formatHeights(_ heights: [Int: [BST]]) -> String {
            heights.sorted(by: { $0.key < $1.key })
                .map { "h\($0.key): \($0.value.count) (\(Set($0.value).count) unique)" }
                .joined(separator: ", ")
        }

        func formatDuration(_ d: Duration) -> String {
            let ms = Double(d.components.seconds) * 1000
                + Double(d.components.attoseconds) / 1e15
            if ms < 1000 {
                return String(format: "%.1fms", ms)
            } else {
                return String(format: "%.2fs", ms / 1000)
            }
        }

        let eagerAdaptMs = Double(eagerAdaptTime.components.seconds) * 1000
            + Double(eagerAdaptTime.components.attoseconds) / 1e15

        print("=== BST benchmark: \(maxRuns) maxRuns — rejection vs eager CGS vs online CGS ===")
        print("Paper reference (1 min, Haskell): Rejection 7,354 (109 unique) | CGS 22,107 (338 unique)")
        print()
        print("--- Time to exhaust \(maxRuns) candidates ---")
        print("Rejection:  \(formatDuration(rejectionElapsed))")
        print("Eager CGS:  \(formatDuration(eagerElapsed)) (+ \(String(format: "%.0f", eagerAdaptMs))ms adapt)")
        print("Online CGS: \(formatDuration(onlineElapsed)) (\(sampleCount) samples)")
        print()
        print("Rejection sampling: \(rejectionValid) valid (\(rejectionUnique.count) unique)")
        print("  \(formatHeights(rejectionHeights))")
        print()
        print("Eager CGS (adapt: \(String(format: "%.0f", eagerAdaptMs))ms):")
        print("  \(eagerTotal) total, \(eagerValid) valid (\(eagerUnique.count) unique)")
        print("  \(formatHeights(eagerHeights))")
        print()
        print("Online CGS: (\(sampleCount) samples)")
        print("  \(onlineTotal) total, \(onlineValid) valid (\(onlineUnique.count) unique)")
        print("  \(formatHeights(onlineHeights))")
        print()

        let onlineMaxHeight = onlineHeights.keys.max() ?? 0
        let eagerMaxHeight = eagerHeights.keys.max() ?? 0
        let eagerRate = Double(eagerValid) / Double(max(1, eagerTotal))
        let onlineRate = Double(onlineValid) / Double(max(1, onlineTotal))

        print("Max height — rejection: \(rejectionHeights.keys.max() ?? 0), eager: \(eagerMaxHeight), online: \(onlineMaxHeight)")
        print("Unique valid — rejection: \(rejectionUnique.count), eager: \(eagerUnique.count), online: \(onlineUnique.count)")
        print("Validity rate — eager: \(String(format: "%.1f%%", eagerRate * 100)), online: \(String(format: "%.1f%%", onlineRate * 100))")

        // Online CGS produces trees at heights >= 2, demonstrating depth diversity
        #expect(onlineMaxHeight >= 2,
                "Online CGS should produce BSTs at height >= 2, got max height \(onlineMaxHeight)")
        // Online CGS should achieve a meaningful validity rate
        #expect(onlineRate > 0.2,
                "Online CGS validity rate (\(onlineRate)) should exceed 20%")
    }

    // MARK: - All-Zero Fallback

    @Test("All-zero fallback: unsatisfiable predicate falls back to equal weights")
    func allZeroFallback() {
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: 1 ... 10)),
            (weight: UInt64(1), generator: Gen.choose(in: 11 ... 20)),
        ])

        // Predicate that nothing can satisfy
        let predicate: (Int) -> Bool = { _ in false }

        let values = Array(
            CGSValueAndChoiceTreeInterpreter(
                gen,
                predicate: predicate,
                sampleCount: 20,
                seed: 42,
                maxRuns: 50
            )
        ).map(\.value)

        // Should still produce values (not crash)
        #expect(!values.isEmpty, "All-zero fallback should still produce values")

        // Should produce values from both branches (equal weights)
        let lowCount = values.count { $0 <= 10 }
        let highCount = values.count { $0 > 10 }
        #expect(lowCount > 0, "Should produce values from first branch")
        #expect(highCount > 0, "Should produce values from second branch")
    }
}
