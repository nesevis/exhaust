// MARK: - CGS BST Throughput Benchmarks

//
// A/B benchmark: tune a BST generator then measure throughput over 20 seconds,
// and time-to-N valid BSTs with maxRuns-aware budgeting.
//
// Ported from Tests/ExhaustCoreTests/ChoiceGradientSampling/CGSBenchmark.swift (2026-07-04).

import Benchmark
import ExhaustCore
import Foundation

func registerCGSBSTThroughputBenchmarks() {
    // The tune phase is its own entry so the harness supplies its timing distribution.
    benchmark("CGS BST tune — 500 samples") {
        do {
            let naive = BenchmarkBST.arbitrary()
            let isValid: (BenchmarkBST) -> Bool = { $0.height >= 1 && $0.isValidBST() }
            _ = try GeneratorTuning.tune(
                naive,
                samples: 500,
                seed: 12345,
                predicate: isValid
            )
        } catch {
            print("CGS BST tune benchmark failed: \(error)")
        }
    }

    benchmark("CGS BST throughput — 20-second generation") {
        do {
            try runBSTThroughput()
        } catch {
            print("CGS BST throughput benchmark failed: \(error)")
        }
    }

    benchmark("CGS BST time-to-100 — probeAndTune with maxRuns budget") {
        do {
            try runBSTTimeToHundred()
        } catch {
            print("CGS BST time-to-100 benchmark failed: \(error)")
        }
    }
}

private func runBSTThroughput() throws {
    let naive = BenchmarkBST.arbitrary()
    let isValid: (BenchmarkBST) -> Bool = { $0.height >= 1 && $0.isValidBST() }
    let duration: TimeInterval = 20

    let tuned = try GeneratorTuning.tune(
        naive,
        samples: 500,
        seed: 12345,
        predicate: isValid
    )

    print("=== BST CGS Benchmark (20s) ===")

    // Generate for a fixed 20 seconds; the timer here is loop control, not a measurement — the
    // reported numbers are throughput counts, and the harness times the closure as a whole.
    var iterator = ValueInterpreter(tuned, seed: 42, maxRuns: .max)
    var total = 0
    var valid = 0
    var uniqueValid = Set<BenchmarkBST>()
    var heightDist = [Int: Int]()

    let genTimer = BenchmarkTimer()
    while genTimer.elapsedSeconds < duration {
        guard let tree = try iterator.next() else { break }
        total += 1
        if isValid(tree) {
            valid += 1
            uniqueValid.insert(tree)
            heightDist[tree.height, default: 0] += 1
        }
    }

    let validPct = total > 0 ? Double(valid) / Double(total) * 100 : 0
    let heights = heightDist
        .sorted { $0.key < $1.key }
        .map { "h\($0.key):\($0.value)" }
        .joined(separator: " ")

    print("Total generated: \(total)")
    print("Valid:           \(valid) (\(String(format: "%.1f", validPct))%)")
    print("Unique valid:    \(uniqueValid.count)")
    print("Heights:         \(heights)")
    print("================================")
}

private func runBSTTimeToHundred() throws {
    let naive = BenchmarkBST.arbitrary()
    let isValid: (BenchmarkBST) -> Bool = { $0.height >= 1 && $0.isValidBST() }
    let target = 100

    print("=== BST Time-to-\(target) Valid ===")

    // --- Baseline: no tuning, just rejection sampling ---
    let baseTimer = BenchmarkTimer()
    var baseIterator = ValueInterpreter(naive, seed: 42, maxRuns: .max)
    var baseTotal = 0
    var baseUnique = Set<BenchmarkBST>()

    while let tree = try baseIterator.next() {
        baseTotal += 1
        if isValid(tree) {
            baseUnique.insert(tree)
            if baseUnique.count >= target { break }
        }
    }

    let baseElapsedMs = baseTimer.elapsedMs
    let baseHeights = Dictionary(grouping: baseUnique, by: \.height).mapValues(\.count)
        .sorted { $0.key < $1.key }.map { "h\($0.key):\($0.value)" }.joined(separator: " ")
    print("Rejection:  \(String(format: "%.0f", baseElapsedMs)) ms (\(baseTotal) gen → \(baseUnique.count) unique valid)  \(baseHeights)")

    // --- CGS sweep: vary maxRuns hint to show tuning budget vs quality trade-off ---
    for maxRunsHint: UInt64 in [100, 500, 1000, 5000] {
        let timer = BenchmarkTimer()

        let tuned = try GeneratorTuning.probeAndTune(
            naive,
            maxRuns: maxRunsHint,
            seed: 12345,
            predicate: isValid
        )

        let tuneElapsedMs = timer.elapsedMs

        var iterator = ValueInterpreter(tuned, seed: 42, maxRuns: .max)
        var totalCount = 0
        var uniqueValid = Set<BenchmarkBST>()

        while let tree = try iterator.next() {
            totalCount += 1
            if isValid(tree) {
                uniqueValid.insert(tree)
                if uniqueValid.count >= target { break }
            }
        }

        let totalElapsedMs = timer.elapsedMs

        let heights = Dictionary(grouping: uniqueValid, by: \.height).mapValues(\.count)
            .sorted { $0.key < $1.key }.map { "h\($0.key):\($0.value)" }.joined(separator: " ")
        print("maxRuns=\(String(format: "%-5d", maxRunsHint)) tune: \(String(format: "%3.0f", tuneElapsedMs))ms  total: \(String(format: "%3.0f", totalElapsedMs))ms  (\(totalCount) gen → \(uniqueValid.count) unique valid)  \(heights)")
    }
    print("==================================")
}
