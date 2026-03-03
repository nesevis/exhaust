//
//  CGSBenchmark.swift
//  ExhaustTests
//
//  A/B benchmark: tune a BST generator then measure throughput over 20 seconds,
//  and time-to-N valid BSTs with maxRuns-aware budgeting.
//

import Foundation
import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

private enum BenchBST: Equatable, Hashable {
    case leaf
    indirect case node(left: BenchBST, value: UInt, right: BenchBST)

    static var arbitrary: ReflectiveGenerator<BenchBST> {
        bstGenerator(maxDepth: 5)
    }

    private static func bstGenerator(maxDepth: Int) -> ReflectiveGenerator<BenchBST> {
        if maxDepth <= 0 {
            return #gen(.just(.leaf))
        }
        let nodeBranch = #gen(bstGenerator(maxDepth: maxDepth - 1), .uint(in: 0 ... 9), bstGenerator(maxDepth: maxDepth - 1)).map { left, value, right in
            BenchBST.node(left: left, value: value, right: right)
        }
        return #gen(.oneOf(weighted: (1, .just(.leaf)), (3, nodeBranch)))
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
}

@Suite("CGS Benchmark", .disabled("Manual benchmark — run with --filter"))
struct CGSBenchmark {
    @Test("BST throughput — 20-second generation benchmark")
    func bstThroughput() throws {
        let naive = BenchBST.arbitrary
        let isValid: (BenchBST) -> Bool = { $0.height >= 1 && $0.isValidBST() }
        let duration: TimeInterval = 20

        // --- Phase 1: Tune ---
        let tuneStart = ContinuousClock.now
        let tuned = try GeneratorTuning.tune(
            naive,
            samples: 500,
            seed: 12345,
            predicate: isValid,
        )
        let tuneElapsed = ContinuousClock.now - tuneStart
        let tuneMs = Double(tuneElapsed.components.seconds) * 1000
            + Double(tuneElapsed.components.attoseconds) / 1e15

        print("=== BST CGS Benchmark (20s) ===")
        print("Tuning time: \(String(format: "%.0f", tuneMs)) ms")

        // --- Phase 2: Generate for 20 seconds ---
        var iterator = ValueInterpreter(tuned, seed: 42, maxRuns: .max)
        var total = 0
        var valid = 0
        var uniqueValid = Set<BenchBST>()
        var heightDist = [Int: Int]()

        let genStart = ContinuousClock.now
        while ContinuousClock.now - genStart < .seconds(duration) {
            guard let tree = iterator.next() else { break }
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

    @Test("BST time-to-100 — probeAndTune with maxRuns budget")
    func bstTimeToHundred() throws {
        let naive = BenchBST.arbitrary
        let isValid: (BenchBST) -> Bool = { $0.height >= 1 && $0.isValidBST() }
        let target = 100

        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }

        print("=== BST Time-to-\(target) Valid ===")

        // --- Baseline: no tuning, just rejection sampling ---
        let baseStart = ContinuousClock.now
        var baseIterator = ValueInterpreter(naive, seed: 42, maxRuns: .max)
        var baseTotal = 0
        var baseUnique = Set<BenchBST>()

        while let tree = baseIterator.next() {
            baseTotal += 1
            if isValid(tree) {
                baseUnique.insert(tree)
                if baseUnique.count >= target { break }
            }
        }

        let baseElapsed = ContinuousClock.now - baseStart
        let baseHeights = Dictionary(grouping: baseUnique, by: \.height).mapValues(\.count)
            .sorted { $0.key < $1.key }.map { "h\($0.key):\($0.value)" }.joined(separator: " ")
        print("Rejection:  \(String(format: "%.0f", ms(baseElapsed))) ms (\(baseTotal) gen → \(baseUnique.count) unique valid)  \(baseHeights)")

        // --- CGS sweep: vary maxRuns hint to show tuning budget vs quality trade-off ---
        for maxRunsHint: UInt64 in [100, 500, 1000, 5000] {
            let start = ContinuousClock.now

            let tuned = try GeneratorTuning.probeAndTune(
                naive,
                maxRuns: maxRunsHint,
                seed: 12345,
                predicate: isValid,
            )

            let tuneElapsed = ContinuousClock.now - start

            var iterator = ValueInterpreter(tuned, seed: 42, maxRuns: .max)
            var totalCount = 0
            var uniqueValid = Set<BenchBST>()

            while let tree = iterator.next() {
                totalCount += 1
                if isValid(tree) {
                    uniqueValid.insert(tree)
                    if uniqueValid.count >= target { break }
                }
            }

            let totalElapsed = ContinuousClock.now - start

            let heights = Dictionary(grouping: uniqueValid, by: \.height).mapValues(\.count)
                .sorted { $0.key < $1.key }.map { "h\($0.key):\($0.value)" }.joined(separator: " ")
            print("maxRuns=\(String(format: "%-5d", maxRunsHint)) tune: \(String(format: "%3.0f", ms(tuneElapsed)))ms  total: \(String(format: "%3.0f", ms(totalElapsed)))ms  (\(totalCount) gen → \(uniqueValid.count) unique valid)  \(heights)")
        }
        print("==================================")
    }
}
