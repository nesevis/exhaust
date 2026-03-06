//
//  UniquenessBenchmarkTests.swift
//  ExhaustTests
//
//  Benchmarks four strategies across three sparse-validity problems from the CGS paper:
//    BST    — binary search tree, values 0...9, depth 5, predicate: valid ordering
//    SORTED — list of values 0...9, length 20, predicate: sorted
//    AVL    — AVL tree, values 0...9, depth 5, predicate: valid BST + balanced
//

import Foundation
import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

// MARK: - Benchmark Problem

private struct BenchmarkProblem<Value: Hashable> {
    let name: String
    let generator: ReflectiveGenerator<Value>
    let predicate: (Value) -> Bool
    /// Maps a valid value to its quality bucket (e.g. height for trees, distinct count for lists).
    let qualityBucket: (Value) -> Int
    let bucketLabel: String
}

// MARK: - Benchmark Result

private struct BenchmarkResult {
    let strategyName: String
    let uniqueCount: Int
    let totalGenerated: Int
    let elapsed: Duration
    let qualityDistribution: [Int: Int]

    var reachedTarget: Bool {
        uniqueCount >= 100
    }
}

// MARK: - Benchmark

@Suite("Uniqueness Benchmark")
struct UniquenessBenchmarkTests {
    private static let targetUnique = 200
    private static let seed: UInt64 = 42
    private static let budget: UInt64 = 500_000

    // MARK: - Problems

    private static var bstProblem: BenchmarkProblem<BST> {
        BenchmarkProblem(
            name: "BST",
            generator: BST.arbitrary(),
            predicate: { $0.height >= 1 && $0.isValidBST() },
            qualityBucket: \.height,
            bucketLabel: "height",
        )
    }

    /// Length 20 with 10 values has validity ~10^-13 — intractable for any strategy.
    /// Length 8 gives ~1 in 4000 — sparse enough to differentiate strategies.
    private static let sortedLength: UInt64 = 8

    private static var sortedProblem: BenchmarkProblem<[UInt]> {
        BenchmarkProblem(
            name: "SORTED(\(sortedLength))",
            generator: #gen(.uint(in: 0 ... 9)).array(length: sortedLength),
            predicate: { list in
                guard list.count == sortedLength else { return false }
                return zip(list, list.dropFirst()).allSatisfy { $0 <= $1 }
            },
            qualityBucket: { Set($0).count },
            bucketLabel: "distinct",
        )
    }

    private static var avlProblem: BenchmarkProblem<BST> {
        BenchmarkProblem(
            name: "AVL",
            generator: BST.arbitrary(),
            predicate: { $0.height >= 1 && $0.isValidAVL() },
            qualityBucket: \.height,
            bucketLabel: "height",
        )
    }

    private static var boundedSumProblem: BenchmarkProblem<[Int16]> {
        let gen = #gen(.int16(scaling: .linear).array(length: 0 ... 10))
            .filter { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
        return BenchmarkProblem(
            name: "BOUND-SUM",
            generator: gen,
            predicate: { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 },
            qualityBucket: \.count,
            bucketLabel: "length",
        )
    }

    // MARK: - Structural Probe

    @Test("Structural probe detects picks vs chooseBits-only generators")
    func structuralProbe() {
        #expect(probeContainsPicks(Self.bstProblem.generator), "BST should contain picks")
        #expect(probeContainsPicks(Self.avlProblem.generator), "AVL should contain picks")
        #expect(!probeContainsPicks(Self.sortedProblem.generator), "SORTED should not contain picks")
    }

    /// Runs the generator a handful of times and returns true as soon as any tree contains a pick site.
    private func probeContainsPicks(_ generator: ReflectiveGenerator<some Any>) -> Bool {
        var iterator = ValueAndChoiceTreeInterpreter(generator, seed: Self.seed, maxRuns: 10)
        while let (_, tree) = iterator.next() {
            if tree.containsPicks { return true }
        }
        return false
    }

    // MARK: - Main Benchmark

    // Kolbu
    @Test("Time to 500 BST", .disabled())
    func bstBenchmark() throws {
//        let onlineCGS = measureOnlineCGS(Self.bstProblem)
        let rejection = measureRejection(Self.bstProblem)
        let adaptive = try measureAdaptivelySmoothed(Self.bstProblem)
//        let cgsTuned = try measureOnlineInformedTuning(Self.bstProblem)
        let cgsShared = try measureCGSFitnessSharing(Self.bstProblem)
//        let cgsUCB = try measureCGSUCB(Self.bstProblem)
        printProblemResults(Self.bstProblem, results: [rejection, adaptive, cgsShared])
    }
    
    @Test("Time to 100 AVL", .disabled())
    func avlBenchmark() throws {
        let adaptive = try measureAdaptivelySmoothed(Self.avlProblem)
        let cgsShared = try measureCGSFitnessSharing(Self.avlProblem)
        let cgsUCB = try measureCGSUCB(Self.avlProblem)
        printProblemResults(Self.avlProblem, results: [adaptive, cgsShared, cgsUCB])
    }

    @Test("Bounded sum: Adaptive vs CGS-Tuned", .disabled("Benchmark"))
    func boundedSumBenchmark() throws {
        let rejection = measureRejection(Self.boundedSumProblem)
        let adaptive = try measureAdaptivelySmoothed(Self.boundedSumProblem)
        let cgsTuned = try measureOnlineInformedTuning(Self.boundedSumProblem)
        printProblemResults(Self.boundedSumProblem, results: [rejection, adaptive, cgsTuned])
    }

    @Test("Time to 100 unique valid values: BST / SORTED / AVL x 4 strategies", .disabled())
    func fullBenchmark() throws {
        let bstResults = try runAllStrategies(Self.bstProblem)
        let sortedResults = try runAllStrategies(Self.sortedProblem)
        let avlResults = try runAllStrategies(Self.avlProblem)

        printProblemResults(Self.bstProblem, results: bstResults)
        printProblemResults(Self.sortedProblem, results: sortedResults)
        printProblemResults(Self.avlProblem, results: avlResults)

        // At least one strategy should reach the target for each problem
        for (problem, results) in [("BST", bstResults), ("SORTED", sortedResults), ("AVL", avlResults)] {
            let anyReached = results.contains { $0.reachedTarget }
            #expect(anyReached, "At least one strategy should reach \(Self.targetUnique) unique valid values for \(problem)")
        }
    }

    // MARK: - Strategy Runner

    private func runAllStrategies(
        _ problem: BenchmarkProblem<some Hashable>,
    ) throws -> [BenchmarkResult] {
        let rejection = measureRejection(problem)
        let smoothed = try measureSmoothed(problem)
//        let onlineCGS = measureOnlineCGS(problem)
        let adaptive = try measureAdaptivelySmoothed(problem)
        let auto = try measureAutoAdapted(problem)
        let cgsTuned = try measureOnlineInformedTuning(problem, weightingStrategy: .totalFitness)
        let cgsTunedValidity = try measureOnlineInformedTuning(problem, weightingStrategy: .validityRate)
        let cgsShared = try measureCGSFitnessSharing(problem)
        let cgsUCB = try measureCGSUCB(problem)
        return [rejection, smoothed, adaptive, auto, cgsTuned, cgsTunedValidity, cgsShared, cgsUCB]
    }

    // MARK: - Strategy Implementations

    private func measureRejection<Value: Hashable>(
        _ problem: BenchmarkProblem<Value>,
    ) -> BenchmarkResult {
        var unique = Set<Value>()
        var total = 0
        var quality = [Int: Int]()
        var iterator = ValueAndChoiceTreeInterpreter(problem.generator, seed: Self.seed, maxRuns: Self.budget)

        let start = ContinuousClock.now
        while unique.count < Self.targetUnique, let (value, _) = iterator.next() {
            total += 1
            if problem.predicate(value) {
                let (inserted, _) = unique.insert(value)
                if inserted {
                    quality[problem.qualityBucket(value), default: 0] += 1
                }
            }
        }
        let elapsed = ContinuousClock.now - start

        return BenchmarkResult(
            strategyName: "Rejection",
            uniqueCount: unique.count,
            totalGenerated: total,
            elapsed: elapsed,
            qualityDistribution: quality,
        )
    }

    private func measureOnlineCGS<Value: Hashable>(
        _ problem: BenchmarkProblem<Value>,
    ) -> BenchmarkResult {
        var unique = Set<Value>()
        var total = 0
        var quality = [Int: Int]()
        var iterator = OnlineCGSInterpreter(
            problem.generator,
            predicate: problem.predicate,
            sampleCount: 3,
            seed: Self.seed,
            maxRuns: Self.budget,
        )

        let start = ContinuousClock.now
        while unique.count < Self.targetUnique, let value = iterator.next() {
            total += 1
            if problem.predicate(value) {
                let (inserted, _) = unique.insert(value)
                if inserted {
                    quality[problem.qualityBucket(value), default: 0] += 1
                }
            }
        }
        let elapsed = ContinuousClock.now - start

        return BenchmarkResult(
            strategyName: "Online CGS",
            uniqueCount: unique.count,
            totalGenerated: total,
            elapsed: elapsed,
            qualityDistribution: quality,
        )
    }

    private func measureSmoothed<Value: Hashable>(
        _ problem: BenchmarkProblem<Value>,
    ) throws -> BenchmarkResult {
        let start = ContinuousClock.now

        let tuned = try GeneratorTuning.tune(
            problem.generator,
            samples: 1000,
            seed: 12345,
            predicate: problem.predicate,
        )
        let smoothed = GeneratorTuning.smooth(tuned, epsilon: 1.0, temperature: 2.0)

        var unique = Set<Value>()
        var total = 0
        var quality = [Int: Int]()
        var iterator = ValueAndChoiceTreeInterpreter(smoothed, seed: Self.seed, maxRuns: Self.budget)

        while unique.count < Self.targetUnique, let (value, _) = iterator.next() {
            total += 1
            if problem.predicate(value) {
                let (inserted, _) = unique.insert(value)
                if inserted {
                    quality[problem.qualityBucket(value), default: 0] += 1
                }
            }
        }
        let elapsed = ContinuousClock.now - start

        return BenchmarkResult(
            strategyName: "Smoothed",
            uniqueCount: unique.count,
            totalGenerated: total,
            elapsed: elapsed,
            qualityDistribution: quality,
        )
    }

    private func measureAdaptivelySmoothed<Value: Hashable>(
        _ problem: BenchmarkProblem<Value>,
    ) throws -> BenchmarkResult {
        let start = ContinuousClock.now

        let tuned = try GeneratorTuning.tune(
            problem.generator,
            samples: 1000,
            seed: 12345,
            predicate: problem.predicate,
        )
        let adaptive = GeneratorTuning.smoothAdaptively(
            tuned,
            epsilon: 1.0,
            baseTemperature: 1.0,
            maxTemperature: 4.0,
        )

        var unique = Set<Value>()
        var total = 0
        var quality = [Int: Int]()
        var iterator = ValueAndChoiceTreeInterpreter(adaptive, seed: Self.seed, maxRuns: Self.budget)

        while unique.count < Self.targetUnique, let (value, _) = iterator.next() {
            total += 1
            if problem.predicate(value) {
                let (inserted, _) = unique.insert(value)
                if inserted {
                    quality[problem.qualityBucket(value), default: 0] += 1
                }
            }
        }
        let elapsed = ContinuousClock.now - start

        return BenchmarkResult(
            strategyName: "Adaptive",
            uniqueCount: unique.count,
            totalGenerated: total,
            elapsed: elapsed,
            qualityDistribution: quality,
        )
    }

    private func measureAutoAdapted<Value: Hashable>(
        _ problem: BenchmarkProblem<Value>,
    ) throws -> BenchmarkResult {
        let start = ContinuousClock.now

        let generator = try GeneratorTuning.probeAndTune(
            problem.generator,
            seed: 12345,
            predicate: problem.predicate,
        )

        var unique = Set<Value>()
        var total = 0
        var quality = [Int: Int]()
        var iterator = ValueAndChoiceTreeInterpreter(generator, seed: Self.seed, maxRuns: Self.budget)

        while unique.count < Self.targetUnique, let (value, _) = iterator.next() {
            total += 1
            if problem.predicate(value) {
                let (inserted, _) = unique.insert(value)
                if inserted {
                    quality[problem.qualityBucket(value), default: 0] += 1
                }
            }
        }
        let elapsed = ContinuousClock.now - start

        return BenchmarkResult(
            strategyName: "Auto",
            uniqueCount: unique.count,
            totalGenerated: total,
            elapsed: elapsed,
            qualityDistribution: quality,
        )
    }

    // Kolbu
    private func measureOnlineInformedTuning<Value: Hashable>(
        _ problem: BenchmarkProblem<Value>,
        weightingStrategy: ChoiceGradientTuner<Value>.WeightingStrategy = .totalFitness,
    ) throws -> BenchmarkResult {
        let strategyName = switch weightingStrategy {
        case .totalFitness: "CGS-Tuned"
        case .validityRate: "CGS-Rate"
        case .fitnessSharing: "CGS-Shared"
        case .ucb: "CGS-UCB"
        }

        let start = ContinuousClock.now

        let tuned = try ChoiceGradientTuner.tune(
            problem.generator,
            predicate: problem.predicate,
            warmupRuns: 200,
            sampleCount: 5,
            seed: 12345,
            weightingStrategy: weightingStrategy,
        )

        let warmupElapsed = ContinuousClock.now - start
        let genStart = ContinuousClock.now

        var unique = Set<Value>()
        var total = 0
        var quality = [Int: Int]()
        var iterator = ValueAndChoiceTreeInterpreter(tuned, seed: Self.seed, maxRuns: Self.budget)

        while unique.count < Self.targetUnique, let (value, _) = iterator.next() {
            total += 1
            if problem.predicate(value) {
                let (inserted, _) = unique.insert(value)
                if inserted {
                    quality[problem.qualityBucket(value), default: 0] += 1
                }
            }
        }
        let genElapsed = ContinuousClock.now - genStart
        let elapsed = ContinuousClock.now - start

        print("  \(strategyName): warmup \(warmupElapsed), generation \(genElapsed), total generated \(total)")

        return BenchmarkResult(
            strategyName: strategyName,
            uniqueCount: unique.count,
            totalGenerated: total,
            elapsed: elapsed,
            qualityDistribution: quality,
        )
    }

    private func measureCGSFitnessSharing<Value: Hashable>(
        _ problem: BenchmarkProblem<Value>,
    ) throws -> BenchmarkResult {
        let start = ContinuousClock.now

        let tuned: ReflectiveGenerator<Value> = try ChoiceGradientTuner<Value>.tune(
            problem.generator,
            predicate: problem.predicate,
            warmupRuns: 400,
            sampleCount: 10,
            seed: 12345,
            weightingStrategy: .fitnessSharing,
        )

        let warmupElapsed = ContinuousClock.now - start
        let genStart = ContinuousClock.now

        var unique = Set<Value>()
        var total = 0
        var quality = [Int: Int]()
        var iterator = ValueAndChoiceTreeInterpreter(tuned, seed: Self.seed, maxRuns: Self.budget)

        while unique.count < Self.targetUnique, let (value, _) = iterator.next() {
            total += 1
            if problem.predicate(value) {
                let (inserted, _) = unique.insert(value)
                if inserted {
                    quality[problem.qualityBucket(value), default: 0] += 1
                }
            }
        }
        let genElapsed = ContinuousClock.now - genStart
        let elapsed = ContinuousClock.now - start

        print("  CGS-Shared: warmup \(warmupElapsed), generation \(genElapsed), total generated \(total)")

        return BenchmarkResult(
            strategyName: "CGS-Shared",
            uniqueCount: unique.count,
            totalGenerated: total,
            elapsed: elapsed,
            qualityDistribution: quality,
        )
    }

    private func measureCGSUCB<Value: Hashable>(
        _ problem: BenchmarkProblem<Value>,
    ) throws -> BenchmarkResult {
        let start = ContinuousClock.now

        let tuned: ReflectiveGenerator<Value> = try ChoiceGradientTuner<Value>.tune(
            problem.generator,
            predicate: problem.predicate,
            warmupRuns: 200,
            sampleCount: 5,
            seed: 12345,
            weightingStrategy: .ucb(explorationConstant: 1.4),
        )

        let warmupElapsed = ContinuousClock.now - start
        let genStart = ContinuousClock.now

        var unique = Set<Value>()
        var total = 0
        var quality = [Int: Int]()
        var iterator = ValueAndChoiceTreeInterpreter(tuned, seed: Self.seed, maxRuns: Self.budget)

        while unique.count < Self.targetUnique, let (value, _) = iterator.next() {
            total += 1
            if problem.predicate(value) {
                let (inserted, _) = unique.insert(value)
                if inserted {
                    quality[problem.qualityBucket(value), default: 0] += 1
                }
            }
        }
        let genElapsed = ContinuousClock.now - genStart
        let elapsed = ContinuousClock.now - start

        print("  CGS-UCB: warmup \(warmupElapsed), generation \(genElapsed), total generated \(total)")

        return BenchmarkResult(
            strategyName: "CGS-UCB",
            uniqueCount: unique.count,
            totalGenerated: total,
            elapsed: elapsed,
            qualityDistribution: quality,
        )
    }

    // MARK: - Formatting

    private func printProblemResults(_ problem: some Any, results: [BenchmarkResult]) {
        let p = problem as! (any BenchmarkProblemInfo)
        let name = p.problemName
        let label = p.problemBucketLabel

        print()
        print("┌───────────────────────────────────────────────────────────────────────────────────────────┐")
        print("│  \(name.padding(toLength: 12, withPad: " ", startingAt: 0))Time to \(Self.targetUnique) unique valid values\(String(repeating: " ", count: 40))│")
        print("├──────────────┬────────┬──────────┬────────┬────────────────────────────────────────────────┤")
        print("│ Strategy     │ Unique │ Time     │ Rate   │ \(label.padding(toLength: 8, withPad: " ", startingAt: 0)) distribution\(String(repeating: " ", count: 27))│")
        print("├──────────────┼────────┼──────────┼────────┼────────────────────────────────────────────────┤")

        for result in results {
            let status = result.reachedTarget ? "✓" : "✗"
            let dist = result.qualityDistribution.sorted(by: { $0.key < $1.key })
                .map { "\($0.key):\($0.value)" }
                .joined(separator: " ")
            let uniqueStr = String(result.uniqueCount).padding(toLength: 4, withPad: " ", startingAt: 0)
            let timeStr = formatDuration(result.elapsed).padding(toLength: 8, withPad: " ", startingAt: 0)
            let rate = result.totalGenerated > 0
                ? String(format: "%.2f%%", Double(result.uniqueCount) / Double(result.totalGenerated) * 100)
                : "N/A"
            let rateStr = rate.padding(toLength: 6, withPad: " ", startingAt: 0)
            let distStr = String(dist.prefix(46)).padding(toLength: 46, withPad: " ", startingAt: 0)
            print("│ \(status) \(result.strategyName.padding(toLength: 11, withPad: " ", startingAt: 0))│ \(uniqueStr)   │ \(timeStr) │ \(rateStr) │ \(distStr) │")
        }

        print("└──────────────┴────────┴──────────┴────────┴────────────────────────────────────────────────┘")

        // Bar chart
        let allBuckets = Set(results.flatMap(\.qualityDistribution.keys)).sorted()
        guard !allBuckets.isEmpty else { return }

//        print()
//        print("  \(name) \(label) distribution:")
//        for result in results {
//            print("    \(result.strategyName.padding(toLength: 11, withPad: " ", startingAt: 0)): ", terminator: "")
//            for bucket in allBuckets {
//                let count = result.qualityDistribution[bucket, default: 0]
//                let bar = String(repeating: "█", count: Swift.min(count, 40))
//                print("\(label[label.startIndex])\(bucket):\(String(count).padding(toLength: 3, withPad: " ", startingAt: 0))\(bar) ", terminator: "")
//            }
//            print()
//        }
    }

    private func formatDuration(_ d: Duration) -> String {
        let ms = Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
        if ms < 1000 {
            return String(format: "%.0fms", ms)
        } else {
            return String(format: "%.2fs", ms / 1000)
        }
    }
}

/// Helper protocol so printProblemResults can access name/label without generic parameter
private protocol BenchmarkProblemInfo {
    var problemName: String { get }
    var problemBucketLabel: String { get }
}

extension BenchmarkProblem: BenchmarkProblemInfo {
    var problemName: String {
        name
    }

    var problemBucketLabel: String {
        bucketLabel
    }
}
