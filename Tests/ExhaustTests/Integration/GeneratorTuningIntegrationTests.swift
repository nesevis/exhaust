//
//  GeneratorTuningIntegrationTests.swift
//  ExhaustTests
//
//  Integration tests for the offline generator tuning algorithm that require
//  the Exhaust module (.filter, #gen macros, etc.).
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Choice Gradient Sampling Integration")
struct GeneratorTuningIntegrationTests {
    // MARK: - Pick Adaptation

    @Test("Pick adaptation produces only valid output via .probeSampling")
    func pickAdaptationWeightsByPredicate() {
        let gen = #gen(.oneOf(weighted:
            (1, .int(in: 1 ... 100)),
            (1, .int(in: 901 ... 1000)))).filter(.probeSampling) { $0 <= 100 }

        let values = #example(gen, count: 200, seed: 123)

        #expect(values.allSatisfy { $0 <= 100 })
        #expect(values.count == 200, "All runs should succeed with tuning")
    }

    @Test(".probeSampling produces more valid output than raw generation")
    func tuneOutperformsRawGeneration() {
        let gen = #gen(.oneOf(weighted:
            (1, .int(in: 1 ... 500)),
            (1, .int(in: 501 ... 1000))))
        let predicate: @Sendable (Int) -> Bool = { $0 <= 250 }

        // Raw generator: only ~25% of output satisfies the predicate
        let rawValues = #example(gen, count: 200, seed: 99)
        let rawValidCount = rawValues.count(where: predicate)

        // Tuned filter: all output satisfies the predicate
        let tunedValues = #example(gen.filter(.probeSampling, predicate), count: 200, seed: 99)

        #expect(tunedValues.allSatisfy(predicate))
        #expect(tunedValues.count > rawValidCount,
                "Tuned filter (\(tunedValues.count) valid) should exceed raw generation (\(rawValidCount) valid)")
    }

    // MARK: - ChooseBits Subdivision

    @Test("ChooseBits subdivision concentrates output in favoured subrange")
    func chooseBitsSubdivision() {
        let gen = #gen(.uint64(in: 1 ... 1000))
            .filter(.probeSampling) { $0 < 100 }

        let values = #example(gen, count: 200, seed: 123)

        #expect(values.allSatisfy { $0 < 100 })
        #expect(values.count == 200, "All runs should succeed with tuning")
    }

    // MARK: - Depth Budget

    @Test("Deeply nested generators do not explode in sample count")
    func depthBudget() {
        // Create a deeply nested pick structure
        var gen: ReflectiveGenerator<Int> = #gen(.int(in: 1 ... 10))
        for _ in 0 ..< 10 {
            gen = #gen(.oneOf(weighted:
                (1, gen),
                (1, .int(in: 1 ... 10))))
        }

        let filtered = gen.filter(.probeSampling) { $0 <= 5 }

        // This should complete in reasonable time without blowup
        let values = #example(filtered, count: 20, seed: 123)
        #expect(values.isEmpty == false, "Deeply nested tuned generator should still produce values")
        #expect(values.allSatisfy { $0 <= 5 })
    }

    // MARK: - Binary Search Tree

    @Test("BST: .probeSampling produces more valid BSTs than raw generation")
    func bstProbeSamplingOutperformsRawGeneration() {
        let isValidNonLeafBST: @Sendable (BST) -> Bool = { tree in
            tree != .leaf && tree.isValidBST()
        }

        let sampleCount: UInt64 = 500

        // Raw generation: only a fraction of output satisfies the predicate
        let rawValues = #example(BST.arbitrary(), count: sampleCount, seed: 42)
        let rawValidCount = rawValues.count(where: isValidNonLeafBST)

        // Tuned filter: all output satisfies the predicate
        let tunedGen = BST.arbitrary().filter(.probeSampling, isValidNonLeafBST)
        let tunedValues = #example(tunedGen, count: sampleCount, seed: 42)

        #expect(tunedValues.allSatisfy(isValidNonLeafBST))
        #expect(tunedValues.count > rawValidCount,
                "Tuned filter (\(tunedValues.count) valid) should exceed raw generation (\(rawValidCount) valid)")
    }

    @Test("BST: timed benchmark — .probeSampling vs .rejectionSampling (paper comparison)", .disabled("Not required"))
    func bstTimedBenchmark() {
        let isValidBST: @Sendable (BST) -> Bool = { $0.height >= 1 && $0.isValidBST() }
        let duration: TimeInterval = 1

        // --- .rejectionSampling strategy ---
        let rejectGen = BST.arbitrary().filter(.rejectionSampling, isValidBST)
        let rejectValues = #example(rejectGen, count: 10000, seed: 42)
        let rejectUnique = Set(rejectValues)
        print("=== \(duration)-second BST benchmark ===")
        print(".rejectionSampling: \(rejectValues.count) valid (\(rejectUnique.count) unique)")

        // --- .probeSampling strategy ---
        let tuneGen = BST.arbitrary().filter(.probeSampling, isValidBST)
        let tuneValues = #example(tuneGen, count: 10000, seed: 42)
        let tuneUnique = Set(tuneValues)
        print(".probeSampling: \(tuneValues.count) valid (\(tuneUnique.count) unique)")
    }

    @Test("BST: .probeSampling produces valid non-leaf trees")
    func bstProbeSamplingNonLeaf() {
        let isValidNonLeafBST: @Sendable (BST) -> Bool = { tree in
            tree != .leaf && tree.isValidBST()
        }

        let tunedGen = BST.arbitrary().filter(.probeSampling, isValidNonLeafBST)
        let values = #example(tunedGen, count: 500, seed: 99)

        #expect(values.allSatisfy(isValidNonLeafBST))
        #expect(values.isEmpty == false, "Should produce valid non-leaf BSTs")
    }
}
