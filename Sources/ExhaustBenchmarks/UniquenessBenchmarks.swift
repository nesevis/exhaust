// MARK: - Uniqueness Benchmarks

//
// Benchmarks generation strategies across sparse-validity problems from the CGS paper:
//   BST        — binary search tree, values 0...9, depth 5, predicate: valid ordering
//   SORTED(8)  — list of values 0...9, length 8, predicate: sorted
//   AVL        — AVL tree, values 0...9, depth 5, predicate: valid BST + balanced
//   BOUND-SUM  — Int16 list, predicate: wrapping sum below 256
//
// Each (problem × strategy) pair is its own `benchmark` entry, so the harness supplies the
// time-to-target measurement; the closure body prints the auxiliary stats (unique count,
// attempts, validity rate, quality distribution) that timing alone cannot show. Strategies
// with a tuning phase include it in the closure, matching the original total-time semantics.
//
// Ported from Tests/ExhaustCoreTests/Benchmarks/UniquenessBenchmarkTests.swift (2026-07-04).

import Benchmark
import ExhaustCore
import Foundation

func registerUniquenessBenchmarks() {
    registerProblem(bstProblem, strategies: UniquenessStrategy.allCases)
    registerProblem(bstRecursiveProblem, strategies: [.rejection, .cgsFitnessSharing])
    registerProblem(sortedProblem, strategies: UniquenessStrategy.allCases)
    registerProblem(avlProblem, strategies: UniquenessStrategy.allCases)
    registerProblem(boundedSumProblem, strategies: [.rejection, .adaptivelySmoothed, .cgsFitnessSharing])
}

private func registerProblem(
    _ problem: UniquenessProblem<some Hashable>,
    strategies: [UniquenessStrategy]
) {
    for strategy in strategies {
        benchmark("Uniqueness \(problem.name): \(strategy.rawValue) to \(uniquenessTargetUnique) unique") {
            do {
                let stats = try run(strategy, on: problem)
                printStats(stats, problem: problem, strategy: strategy)
            } catch {
                print("Uniqueness \(problem.name)/\(strategy.rawValue) failed: \(error)")
            }
        }
    }
}

// MARK: - Configuration

private let uniquenessTargetUnique = 200
private let uniquenessSeed: UInt64 = 42
private let uniquenessBudget: UInt64 = 500_000

// MARK: - Strategies

private enum UniquenessStrategy: String, CaseIterable {
    case rejection = "Rejection"
    case smoothed = "Smoothed"
    case adaptivelySmoothed = "Adaptive"
    case autoAdapted = "Auto"
    case cgsFitnessSharing = "CGS-Shared"
}

/// Builds the strategy's generator (including any tuning phase) and harvests unique valid values until the target or the budget runs out. The harness times this whole call.
private func run<Value: Hashable>(
    _ strategy: UniquenessStrategy,
    on problem: UniquenessProblem<Value>
) throws -> UniquenessStats {
    let generator: Generator<Value>
    switch strategy {
        case .rejection:
            generator = problem.generator
        case .smoothed:
            let tuned = try GeneratorTuning.tune(
                problem.generator,
                samples: 1000,
                seed: 12345,
                predicate: problem.predicate
            )
            generator = AdaptiveSmoothing.smooth(tuned)
        case .adaptivelySmoothed:
            let tuned = try GeneratorTuning.tune(
                problem.generator,
                samples: 1000,
                seed: 12345,
                predicate: problem.predicate
            )
            generator = GeneratorTuning.smoothAdaptively(
                tuned,
                epsilon: 1.0,
                baseTemperature: 1.0,
                maxTemperature: 4.0
            )
        case .autoAdapted:
            generator = try GeneratorTuning.probeAndTune(
                problem.generator,
                seed: 12345,
                predicate: problem.predicate
            )
        case .cgsFitnessSharing:
            generator = try ChoiceGradientTuner<Value>.tune(
                problem.generator,
                predicate: problem.predicate,
                warmupRuns: 400,
                sampleCount: 10,
                seed: 12345,
                weightingStrategy: .fitnessSharing
            )
    }

    var unique = Set<Value>()
    var total = 0
    var quality = [Int: Int]()
    var iterator = ValueAndChoiceTreeInterpreter(generator, seed: uniquenessSeed, maxRuns: uniquenessBudget)

    while unique.count < uniquenessTargetUnique, let (value, _) = try iterator.next() {
        total += 1
        if problem.predicate(value) {
            let (inserted, _) = unique.insert(value)
            if inserted {
                quality[problem.qualityBucket(value), default: 0] += 1
            }
        }
    }

    return UniquenessStats(uniqueCount: unique.count, totalGenerated: total, qualityDistribution: quality)
}

// MARK: - Problems

private var bstProblem: UniquenessProblem<BenchmarkBST> {
    UniquenessProblem(
        name: "BST",
        generator: BenchmarkBST.arbitrary(),
        predicate: { $0.height >= 1 && $0.isValidBST() },
        qualityBucket: \.height,
        bucketLabel: "height"
    )
}

/// Length 20 with 10 values has validity ~10^-13 — intractable for any strategy.
/// Length 8 gives ~1 in 4000 — sparse enough to differentiate strategies.
private let sortedLength: UInt64 = 8

private var sortedProblem: UniquenessProblem<[UInt]> {
    UniquenessProblem(
        name: "SORTED(\(sortedLength))",
        generator: Gen.arrayOf(Gen.choose(in: 0 ... 9 as ClosedRange<UInt>), exactly: sortedLength),
        predicate: { list in
            guard list.count == sortedLength else { return false }
            return zip(list, list.dropFirst()).allSatisfy { $0 <= $1 }
        },
        qualityBucket: { Set($0).count },
        bucketLabel: "distinct"
    )
}

private var bstRecursiveProblem: UniquenessProblem<BenchmarkBST> {
    UniquenessProblem(
        name: "BST-Recursive",
        generator: BenchmarkBST.arbitraryRecursive(),
        predicate: { $0.height >= 1 && $0.isValidBST() },
        qualityBucket: \.height,
        bucketLabel: "height"
    )
}

private var avlProblem: UniquenessProblem<BenchmarkBST> {
    UniquenessProblem(
        name: "AVL",
        generator: BenchmarkBST.arbitrary(),
        predicate: { $0.height >= 1 && $0.isValidAVL() },
        qualityBucket: \.height,
        bucketLabel: "height"
    )
}

private var boundedSumProblem: UniquenessProblem<[Int16]> {
    let gen: Generator<[Int16]> = Gen.arrayOf(Gen.choose(in: Int16.min ... Int16.max), within: 0 ... 10)
    return UniquenessProblem(
        name: "BOUND-SUM",
        generator: gen,
        predicate: { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 },
        qualityBucket: \.count,
        bucketLabel: "length"
    )
}

// MARK: - Reporting

private func printStats(
    _ stats: UniquenessStats,
    problem: UniquenessProblem<some Hashable>,
    strategy: UniquenessStrategy
) {
    let status = stats.uniqueCount >= uniquenessTargetUnique ? "reached" : "FELL SHORT of"
    let rate = stats.totalGenerated > 0
        ? String(format: "%.2f%%", Double(stats.uniqueCount) / Double(stats.totalGenerated) * 100)
        : "N/A"
    let dist = stats.qualityDistribution.sorted(by: { $0.key < $1.key })
        .map { "\($0.key):\($0.value)" }
        .joined(separator: " ")
    print("  \(problem.name)/\(strategy.rawValue): \(status) target — \(stats.uniqueCount) unique / \(stats.totalGenerated) generated (\(rate)), \(problem.bucketLabel) distribution: \(dist)")
}

// MARK: - Types

private struct UniquenessProblem<Value: Hashable> {
    let name: String
    let generator: Generator<Value>
    let predicate: (Value) -> Bool
    /// Maps a valid value to its quality bucket (for example height for trees, distinct count for lists).
    let qualityBucket: (Value) -> Int
    let bucketLabel: String
}

private struct UniquenessStats {
    let uniqueCount: Int
    let totalGenerated: Int
    let qualityDistribution: [Int: Int]
}
