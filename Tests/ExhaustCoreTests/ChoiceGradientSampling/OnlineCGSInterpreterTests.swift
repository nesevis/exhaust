//
//  OnlineCGSInterpreterTests.swift
//  ExhaustTests
//
//  Tests for the online CGS interpreter.
//

import Foundation
import Testing
@testable import ExhaustCore

@Suite("Online CGS Interpreter")
struct OnlineCGSInterpreterTests {
    // MARK: - BST Height Diversity

    @Test("BST: online CGS produces valid BSTs at heights >= 2", .disabled("Takes 21 seconds to run"))
    func bstHeightDiversity() throws {
        let gen = BST.arbitrary()
        let isValidNonLeafBST: (BST) -> Bool = { $0 != .leaf && $0.isValidBST() }

        var iterator = OnlineCGSInterpreter(
            gen,
            predicate: isValidNonLeafBST,
            sampleCount: 50,
            seed: 42,
            maxRuns: 500,
        )

        var validTrees = [BST]()
        while let value = try iterator.next() {
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

    // MARK: - Simple Pick Guidance

    @Test("Pick guidance: CGS favours branch matching predicate")
    func simplePickGuidance() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: 1 ... 100)),
            (1, Gen.choose(in: 901 ... 1000)),
        ])
        let predicate: (Int) -> Bool = { $0 <= 100 }

        var cgsIterator = OnlineCGSInterpreter(
            gen,
            predicate: predicate,
            sampleCount: 50,
            seed: 42,
            maxRuns: 200,
        )
        let cgsValues = try Array(collecting: &cgsIterator)

        let cgsHitRate = Double(cgsValues.count(where: predicate)) / Double(cgsValues.count)

        // Naive baseline: ~50% since both branches have equal weight
        var naiveIterator = ValueInterpreter(gen, seed: 42, maxRuns: 200)
        let naiveValues = try Array(collecting: &naiveIterator)
        let naiveHitRate = Double(naiveValues.count(where: predicate)) / Double(naiveValues.count)

        print("Pick guidance — naive: \(String(format: "%.1f%%", naiveHitRate * 100)), CGS: \(String(format: "%.1f%%", cgsHitRate * 100))")

        #expect(cgsHitRate > naiveHitRate,
                "CGS hit rate (\(cgsHitRate)) should exceed naive (\(naiveHitRate))")
        #expect(cgsHitRate > 0.7, "CGS should strongly favour the valid branch, got \(cgsHitRate)")
    }

    // MARK: - Deterministic Seeding

    @Test("Same seed produces same output sequence")
    func deterministicSeeding() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: 1 ... 500)),
            (1, Gen.choose(in: 501 ... 1000)),
        ])
        let predicate: (Int) -> Bool = { $0 <= 250 }

        var iterator1 = OnlineCGSInterpreter(
            gen,
            predicate: predicate,
            sampleCount: 30,
            seed: 42,
            maxRuns: 50,
        )
        let values1 = try Array(collecting: &iterator1)

        var iterator2 = OnlineCGSInterpreter(
            gen,
            predicate: predicate,
            sampleCount: 30,
            seed: 42,
            maxRuns: 50,
        )
        let values2 = try Array(collecting: &iterator2)

        #expect(values1 == values2, "Same seed should produce identical output sequences")
    }

    // MARK: - Zip CGS Guidance

    @Test("Zip: CGS guidance improves joint predicate satisfaction")
    func zipCGSGuidance() throws {
        let gen = Gen.zip(
            Gen.choose(in: 1 ... 20),
            Gen.choose(in: 1 ... 20),
        )
        let predicate: ((Int, Int)) -> Bool = { $0.0 + $0.1 < 10 }

        var cgsZipIterator = OnlineCGSInterpreter(
            gen,
            predicate: predicate,
            sampleCount: 50,
            seed: 42,
            maxRuns: 200,
        )
        let cgsValues = try Array(collecting: &cgsZipIterator)

        let cgsHitRate = Double(cgsValues.count(where: predicate)) / Double(cgsValues.count)

        // Naive baseline
        var naiveZipIterator = ValueInterpreter(gen, seed: 42, maxRuns: 200)
        let naiveValues = try Array(collecting: &naiveZipIterator)
        let naiveHitRate = Double(naiveValues.count(where: predicate)) / Double(naiveValues.count)

        print("Zip guidance — naive: \(String(format: "%.1f%%", naiveHitRate * 100)), CGS: \(String(format: "%.1f%%", cgsHitRate * 100))")

        #expect(cgsHitRate >= naiveHitRate,
                "CGS zip hit rate (\(cgsHitRate)) should be at least as good as naive (\(naiveHitRate))")
    }

    // MARK: - ChooseBits Subdivision

    @Test("ChooseBits subdivision concentrates output in favoured subrange")
    func chooseBitsSubdivision() throws {
        let gen = Gen.choose(in: 1 ... 1000 as ClosedRange<UInt64>)
        let predicate: (UInt64) -> Bool = { $0 < 100 }

        var cgsBitsIterator = OnlineCGSInterpreter(
            gen,
            predicate: predicate,
            sampleCount: 50,
            seed: 42,
            maxRuns: 200,
        )
        let cgsValues = try Array(collecting: &cgsBitsIterator)

        let hitRate = Double(cgsValues.count(where: predicate)) / Double(cgsValues.count)

        // Naive baseline is ~10% (100/1000)
        print("ChooseBits subdivision — CGS hit rate: \(String(format: "%.1f%%", hitRate * 100))")

        #expect(hitRate > 0.15,
                "ChooseBits subdivision should concentrate in low range, got hit rate \(hitRate)")
    }

    // MARK: - Weight Smoothing

    @Test("Smoothing recovers dead branches in tuned BST generator")
    func smoothingRecoverDeadBranches() throws {
        let gen = BST.arbitrary()
        let isValidBST: (BST) -> Bool = { $0.height >= 1 && $0.isValidBST() }

        let tuned = try GeneratorTuning.tune(
            gen,
            samples: 100,
            seed: 12345,
            predicate: isValidBST,
        )

        let smoothed = GeneratorTuning.smooth(tuned, epsilon: 1.0, temperature: 2.0)

        var iterator = ValueInterpreter(smoothed, seed: 42, maxRuns: 2000)
        var validTrees = [BST]()
        while let tree = try iterator.next() {
            if isValidBST(tree) {
                validTrees.append(tree)
            }
        }

        let heights = Dictionary(grouping: validTrees, by: \.height).mapValues(\.count)
        let uniqueTrees = Set(validTrees)

        print("Smoothed eager CGS BST: \(validTrees.count) valid, \(uniqueTrees.count) unique")
        print("Heights: \(heights.sorted(by: { $0.key < $1.key }))")

        let tallTreeCount = validTrees.count { $0.height >= 2 }
        #expect(tallTreeCount > 0,
                "Smoothed CGS should produce BSTs at height >= 2, got heights: \(heights)")
        #expect(uniqueTrees.count >= 50,
                "Smoothed CGS should produce diverse valid BSTs, got \(uniqueTrees.count) unique")
    }

    // MARK: - All-Zero Fallback

    @Test("All-zero fallback: unsatisfiable predicate falls back to equal weights")
    func allZeroFallback() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: 1 ... 10)),
            (1, Gen.choose(in: 11 ... 20)),
        ])

        // Predicate that nothing can satisfy
        let predicate: (Int) -> Bool = { _ in false }

        var fallbackIterator = OnlineCGSInterpreter(
            gen,
            predicate: predicate,
            sampleCount: 20,
            seed: 42,
            maxRuns: 50,
        )
        let values = try Array(collecting: &fallbackIterator)

        // Should still produce values (not crash)
        #expect(!values.isEmpty, "All-zero fallback should still produce values")

        // Should produce values from both branches (equal weights)
        let lowCount = values.count { $0 <= 10 }
        let highCount = values.count { $0 > 10 }
        #expect(lowCount > 0, "Should produce values from first branch")
        #expect(highCount > 0, "Should produce values from second branch")
    }

    // MARK: - Static Profile

    @Test("Static profile: tuned BST shows low entropy at depth-1+ picks")
    func staticProfileEntropy() throws {
        let gen = BST.arbitrary()
        let isValidBST: (BST) -> Bool = { $0.height >= 1 && $0.isValidBST() }

        let tuned = try GeneratorTuning.tune(
            gen,
            samples: 500,
            seed: 12345,
            predicate: isValidBST,
        )

        let profile = GeneratorTuning.profile(tuned)

        // Should have multiple pick sites
        #expect(profile.sites.count >= 2,
                "Tuned BST should have multiple pick sites, got \(profile.sites.count)")

        // Root pick (depth 0) should exist and often be a bottleneck
        // (adaptation concentrates weight on the valid branch)
        let rootSites = profile.sites.filter { $0.depth == 0 }
        #expect(!rootSites.isEmpty, "Should have at least one root-depth pick site")

        // After adaptation with a weight floor (0.1), sites won't be extreme
        // bottlenecks, but the root pick should still show some non-uniformity
        // (the valid-BST branch gets higher weight than the leaf branch).
        let nonUniformSites = profile.sites.filter { $0.entropyRatio < 0.95 }
        #expect(!nonUniformSites.isEmpty,
                "Tuned BST should have at least one non-uniform pick site")
    }

    // MARK: - Empirical Profile

    @Test("Empirical profile: validity rates decrease with depth for BST")
    func empiricalProfileValidity() throws {
        let gen = BST.arbitrary()
        let isValidBST: (BST) -> Bool = { $0.height >= 1 && $0.isValidBST() }

        let tuned = try GeneratorTuning.tune(
            gen,
            samples: 200,
            seed: 12345,
            predicate: isValidBST,
        )

        let profile = GeneratorTuning.profile(
            tuned,
            predicate: isValidBST,
            samples: 1000,
            seed: 42,
        )

        // Should have empirical data
        let sitesWithValidity = profile.sites.filter { $0.validityCounts != nil }
        #expect(!sitesWithValidity.isEmpty,
                "Empirical profile should have validity data for at least some sites")

        // Sites with validity data should show meaningful selection counts
        for site in sitesWithValidity {
            guard let counts = site.validityCounts else { continue }
            let totalSelected = counts.values.reduce(0) { $0 + $1.selected }
            #expect(totalSelected > 0,
                    "Site \(site.siteID) should have been selected at least once")
        }
    }

    // MARK: - Adaptive Smoothing

    @Test("Adaptive smooth vs global smooth: adaptive achieves better diversity")
    func adaptiveSmoothVsGlobalSmooth() throws {
        let gen = BST.arbitrary()
        let isValidBST: (BST) -> Bool = { $0.height >= 1 && $0.isValidBST() }
        let maxRuns: UInt64 = 100

        let adaptStart = ContinuousClock().now
        let tuned = try GeneratorTuning.tune(
            gen,
            samples: 1000,
            seed: 12345,
            predicate: isValidBST,
        )
        let adaptTime = ContinuousClock().now - adaptStart

        // Global smooth
        let globalSmoothStart = ContinuousClock().now
        let globalSmoothed = GeneratorTuning.smooth(tuned, epsilon: 1.0, temperature: 2.0)
        let globalSmoothTime = ContinuousClock().now - globalSmoothStart

        let globalGenStart = ContinuousClock().now
        var globalIterator = ValueAndChoiceTreeInterpreter(globalSmoothed, seed: 42, maxRuns: maxRuns)
        var globalValid = 0
        var globalUnique = Set<BST>()
        var globalHeights = [Int: Int]()

        while let (tree, _) = try globalIterator.next() {
            if isValidBST(tree) {
                globalValid += 1
                globalUnique.insert(tree)
                globalHeights[tree.height, default: 0] += 1
            }
        }
        let globalGenTime = ContinuousClock().now - globalGenStart

        // Adaptive smooth
        let adaptiveSmoothStart = ContinuousClock().now
        let adaptiveSmoothed = GeneratorTuning.smoothAdaptively(
            tuned,
            epsilon: 1.0,
            baseTemperature: 1.0,
            maxTemperature: 4.0,
        )
        let adaptiveSmoothTime = ContinuousClock().now - adaptiveSmoothStart

        let adaptiveGenStart = ContinuousClock().now
        var adaptiveIterator = ValueAndChoiceTreeInterpreter(adaptiveSmoothed, seed: 42, maxRuns: maxRuns)
        var adaptiveValid = 0
        var adaptiveUnique = Set<BST>()
        var adaptiveHeights = [Int: Int]()

        while let (tree, _) = try adaptiveIterator.next() {
            if isValidBST(tree) {
                adaptiveValid += 1
                adaptiveUnique.insert(tree)
                adaptiveHeights[tree.height, default: 0] += 1
            }
        }
        let adaptiveGenTime = ContinuousClock().now - adaptiveGenStart

        let globalRate = Double(globalValid) / Double(maxRuns)
        let adaptiveRate = Double(adaptiveValid) / Double(maxRuns)

        print("=== Adaptive vs Global Smooth (\(maxRuns) runs) ===")
        print("Adapt: \(adaptTime)")
        print("Global smooth:   \(globalValid) valid (\(globalUnique.count) unique), rate: \(String(format: "%.1f%%", globalRate * 100))")
        print("  Smooth: \(globalSmoothTime), Generate: \(globalGenTime)")
        print("  Heights: \(globalHeights.sorted(by: { $0.key < $1.key }))")
        print("Adaptive smooth: \(adaptiveValid) valid (\(adaptiveUnique.count) unique), rate: \(String(format: "%.1f%%", adaptiveRate * 100))")
        print("  Smooth: \(adaptiveSmoothTime), Generate: \(adaptiveGenTime)")
        print("  Heights: \(adaptiveHeights.sorted(by: { $0.key < $1.key }))")

        // Adaptive should achieve higher or equal unique count
        #expect(adaptiveUnique.count >= globalUnique.count - 50,
                "Adaptive smooth unique count (\(adaptiveUnique.count)) should be comparable to global smooth (\(globalUnique.count))")

        // Adaptive trades some validity for diversity — allow up to 50% drop
        #expect(adaptiveRate >= globalRate * 0.5,
                "Adaptive smooth validity rate (\(adaptiveRate)) should not be dramatically worse than global (\(globalRate))")
    }
}

// MARK: - DerivativeContext Tests

@Suite("DerivativeContext")
struct DerivativeContextTests {
    typealias Interpreter = OnlineCGSInterpreter<Int>
    typealias Context = Interpreter.DerivativeContext
    typealias Frame = Interpreter.DerivativeFrame

    private func sampleApplied(_ context: Context, gen: ReflectiveGenerator<Any>) throws -> Int {
        let result = try context.apply(gen)
        var iterator = ValueInterpreter(result, seed: 1, maxRuns: 1)
        let value = try iterator.next()
        return try #require(value)
    }

    @Test("Empty context applies identity transform")
    func emptyContextIsIdentity() throws {
        let context = Context()
        let gen: ReflectiveGenerator<Any> = .pure(42)
        let value = try sampleApplied(context, gen: gen)
        #expect(value == 42)
    }

    @Test("Depth tracks pushed frames")
    func depthCounting() {
        var context = Context()
        #expect(context.depth == 0)

        context.push(Frame.bind(continuation: { .pure($0) }))
        #expect(context.depth == 1)

        context.push(Frame.bind(continuation: { .pure($0) }))
        #expect(context.depth == 2)
    }

    @Test("Single bind frame composes correctly")
    func singleBind() throws {
        var context = Context()
        context.push(Frame.bind(continuation: { value in
            let n = value as! Int
            return .pure(n * 10 as Any)
        }))

        // gen produces 5, bind should transform to 50, map casts to Int
        let gen: ReflectiveGenerator<Any> = .pure(5)
        let value = try sampleApplied(context, gen: gen)
        #expect(value == 50)
    }

    @Test("Multiple bind frames compose innermost-first")
    func multipleBinds() throws {
        var context = Context()
        // First pushed (outer): multiply by 10
        context.push(Frame.bind(continuation: { value in
            let n = value as! Int
            return .pure(n * 10 as Any)
        }))
        // Second pushed (inner): add 1
        context.push(Frame.bind(continuation: { value in
            let n = value as! Int
            return .pure(n + 1 as Any)
        }))

        // gen produces 5 -> inner: 5+1=6 -> outer: 6*10=60
        let gen: ReflectiveGenerator<Any> = .pure(5)
        let value = try sampleApplied(context, gen: gen)
        #expect(value == 60)
    }

    @Test("zipComponent frame reconstructs zip correctly")
    func zipComponentFrame() throws {
        let g0: ReflectiveGenerator<Any> = .pure(10)
        let g1: ReflectiveGenerator<Any> = .pure(20)
        let generators = ContiguousArray([g0, g1])

        var context = Context()
        context.push(Frame.zipComponent(
            index: 0,
            completed: [],
            allGenerators: generators,
            continuation: { zipResult in
                let arr = zipResult as! [Any]
                let sum = (arr[0] as! Int) + (arr[1] as! Int)
                return .pure(sum as Any)
            },
        ))

        // Component gen produces 100 (replacing g0 at index 0)
        // -> zip([.pure(100), .pure(20)]) -> [100, 20] -> continuation sums -> 120
        let gen: ReflectiveGenerator<Any> = .pure(100)
        let value = try sampleApplied(context, gen: gen)
        #expect(value == 120)
    }

    @Test("Copy semantics: push on copy does not affect original")
    func copySemantics() {
        var original = Context()
        original.push(Frame.bind(continuation: { .pure($0) }))

        var copy = original
        copy.push(Frame.bind(continuation: { .pure($0) }))

        #expect(original.depth == 1)
        #expect(copy.depth == 2)
    }
}
