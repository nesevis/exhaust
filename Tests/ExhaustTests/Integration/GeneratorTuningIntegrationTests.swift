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
import ExhaustCore

@Suite("Choice Gradient Sampling Integration")
struct GeneratorTuningIntegrationTests {
    // MARK: - Pick Adaptation

    @Test("Pick adaptation produces only valid output via .probeSampling")
    func pickAdaptationWeightsByPredicate() throws {
        let gen = #gen(.oneOf(weighted:
            (1, .int(in: 1 ... 100)),
            (1, .int(in: 901 ... 1000)))).filter(.probeSampling) { $0 <= 100 }

        var valuesIter = ValueInterpreter(gen, seed: 123, maxRuns: 200)
        let values = try Array(collecting: &valuesIter)

        #expect(values.allSatisfy { $0 <= 100 })
        #expect(values.count == 200, "All runs should succeed with tuning")
    }

    @Test(".probeSampling produces more valid output than raw generation")
    func tuneOutperformsRawGeneration() throws {
        let gen = #gen(.oneOf(weighted:
            (1, .int(in: 1 ... 500)),
            (1, .int(in: 501 ... 1000))))
        let predicate: @Sendable (Int) -> Bool = { $0 <= 250 }

        // Raw generator: only ~25% of output satisfies the predicate
        var rawIter = ValueInterpreter(gen, seed: 99, maxRuns: 200)
        let rawValues = try Array(collecting: &rawIter)
        let rawValidCount = rawValues.count(where: predicate)

        // Tuned filter: all output satisfies the predicate
        var tunedIter = ValueInterpreter(gen.filter(.probeSampling, predicate), seed: 99, maxRuns: 200)
        let tunedValues = try Array(collecting: &tunedIter)

        #expect(tunedValues.allSatisfy(predicate))
        #expect(tunedValues.count > rawValidCount,
                "Tuned filter (\(tunedValues.count) valid) should exceed raw generation (\(rawValidCount) valid)")
    }

    // MARK: - ChooseBits Subdivision

    @Test("ChooseBits subdivision concentrates output in favoured subrange")
    func chooseBitsSubdivision() throws {
        let gen = #gen(.uint64(in: 1 ... 1000))
            .filter(.probeSampling) { $0 < 100 }

        var valuesIter = ValueInterpreter(gen, seed: 123, maxRuns: 200)
        let values = try Array(collecting: &valuesIter)

        #expect(values.allSatisfy { $0 < 100 })
        #expect(values.count == 200, "All runs should succeed with tuning")
    }

    // MARK: - Sequence Length Adaptation

    @Test("Sequence length adaptation favours short arrays")
    func sequenceLengthAdaptation() throws {
        let lengthGen = #gen(.uint64(in: 1 ... 50))
        let elementGen = #gen(.int(in: 1 ... 10))
        let gen = ReflectiveGenerator<[Int]>.impure(
            operation: .sequence(length: lengthGen, gen: elementGen.erase()),
        ) { result in
            .pure(result as! [Int])
        }.filter(.probeSampling) { $0.count <= 3 }

        var valuesIter = ValueInterpreter(gen, seed: 123, maxRuns: 100)
        let values = try Array(collecting: &valuesIter)

        #expect(values.allSatisfy { $0.count <= 3 })
        #expect(values.count == 100, "All runs should succeed with tuning")
    }

    // MARK: - Depth Budget

    @Test("Deeply nested generators do not explode in sample count")
    func depthBudget() throws {
        // Create a deeply nested pick structure
        var gen: ReflectiveGenerator<Int> = #gen(.int(in: 1 ... 10))
        for _ in 0 ..< 10 {
            gen = #gen(.oneOf(weighted:
                (1, gen),
                (1, .int(in: 1 ... 10))))
        }

        let filtered = gen.filter(.probeSampling) { $0 <= 5 }

        // This should complete in reasonable time without blowup
        var valuesIter = ValueInterpreter(filtered, seed: 123, maxRuns: 20)
        let values = try Array(collecting: &valuesIter)
        #expect(!values.isEmpty, "Deeply nested tuned generator should still produce values")
        #expect(values.allSatisfy { $0 <= 5 })
    }

    // MARK: - Binary Search Tree

    @Test("BST: .probeSampling produces more valid BSTs than raw generation")
    func bstProbeSamplingOutperformsRawGeneration() throws {
        let isValidNonLeafBST: @Sendable (BST) -> Bool = { tree in
            tree != .leaf && tree.isValidBST()
        }

        let sampleCount: UInt64 = 500

        // Raw generation: only a fraction of output satisfies the predicate
        var rawIter = ValueInterpreter(BST.arbitrary(), seed: 42, maxRuns: sampleCount)
        let rawValues = try Array(collecting: &rawIter)
        let rawValidCount = rawValues.count(where: isValidNonLeafBST)

        // Tuned filter: all output satisfies the predicate
        let tunedGen = BST.arbitrary().filter(.probeSampling, isValidNonLeafBST)
        var tunedIter = ValueInterpreter(tunedGen, seed: 42, maxRuns: sampleCount)
        let tunedValues = try Array(collecting: &tunedIter)

        #expect(tunedValues.allSatisfy(isValidNonLeafBST))
        #expect(tunedValues.count > rawValidCount,
                "Tuned filter (\(tunedValues.count) valid) should exceed raw generation (\(rawValidCount) valid)")
    }

    @Test("BST: timed benchmark — .probeSampling vs .rejectionSampling (paper comparison)", .disabled("Not required"))
    func bstTimedBenchmark() throws {
        let isValidBST: @Sendable (BST) -> Bool = { $0.height >= 1 && $0.isValidBST() }
        let duration: TimeInterval = 1

        // --- .rejectionSampling strategy ---
        let rejectGen = BST.arbitrary().filter(.rejectionSampling, isValidBST)
        var rejectIterator = ValueInterpreter(rejectGen, seed: 42, maxRuns: .max)
        var rejectValues = [BST]()

        let rejectStart = ContinuousClock.now
        while ContinuousClock.now - rejectStart < .seconds(duration) {
            guard let tree = try rejectIterator.next() else { break }
            rejectValues.append(tree)
        }

        let rejectUnique = Set(rejectValues)
        print("=== \(duration)-second BST benchmark ===")
        print(".rejectionSampling: \(rejectValues.count) valid (\(rejectUnique.count) unique)")

        // --- .probeSampling strategy ---
        let tuneGen = BST.arbitrary().filter(.probeSampling, isValidBST)
        var tuneIterator = ValueInterpreter(tuneGen, seed: 42, maxRuns: .max)
        var tuneValues = [BST]()

        let tuneStart = ContinuousClock.now
        while ContinuousClock.now - tuneStart < .seconds(duration) {
            guard let tree = try tuneIterator.next() else { break }
            tuneValues.append(tree)
        }

        let tuneUnique = Set(tuneValues)
        print(".probeSampling: \(tuneValues.count) valid (\(tuneUnique.count) unique)")
    }

    @Test("BST: .probeSampling produces valid non-leaf trees")
    func bstProbeSamplingNonLeaf() throws {
        let isValidNonLeafBST: @Sendable (BST) -> Bool = { tree in
            tree != .leaf && tree.isValidBST()
        }

        let tunedGen = BST.arbitrary().filter(.probeSampling, isValidNonLeafBST)
        var valuesIter = ValueInterpreter(tunedGen, seed: 99, maxRuns: 500)
        let values = try Array(collecting: &valuesIter)

        #expect(values.allSatisfy(isValidNonLeafBST))
        #expect(!values.isEmpty, "Should produce valid non-leaf BSTs")
    }
}
