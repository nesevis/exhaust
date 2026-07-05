// MARK: - CGS Tuning Parameter Sweep

//
// Sweeps warmupRuns × sampleCount for the customCGS filter type and prints a table of
// time-to-N unique valid BSTs per configuration, sorted by total time.
//
// Ported from Tests/ExhaustCoreTests/ChoiceGradientSampling/CGSTuningParameterSweep.swift (2026-07-04).

import Benchmark
import ExhaustCore
import Foundation

func registerCGSTuningParameterSweepBenchmarks() {
    benchmark("CGS parameter sweep: shallow BST (values 0...9, height > 1)") {
        let isValidBST: (BenchmarkBST) -> Bool = { $0.isValidBST() && $0.height > 1 }
        runParameterSweep(
            generator: BenchmarkBST.arbitrary(),
            predicate: isValidBST,
            header: "CGS Parameter Sweep: time-to-\(sweepTarget) unique valid BSTs (height>1, seed=42) — sorted by total time"
        )
    }

    benchmark("CGS parameter sweep: deep BST (values 0...99, height >= 3)") {
        let deepBST = Gen.recursive(baseValue: BenchmarkBST.leaf, depthRange: 0 ... 5) { recurse, remaining in
            Gen.pick(choices: [
                (1, Gen.just(.leaf)),
                (Int(remaining), Gen.zip(
                    recurse(),
                    Gen.choose(in: 0 ... 99 as ClosedRange<UInt>),
                    recurse()
                ).map { left, value, right in BenchmarkBST.node(left: left, value: value, right: right) }),
            ])
        }
        let isDeepValidBST: (BenchmarkBST) -> Bool = { $0.isValidBST() && $0.height >= 3 }
        runParameterSweep(
            generator: deepBST,
            predicate: isDeepValidBST,
            header: "CGS Parameter Sweep: time-to-\(sweepTarget) unique valid BSTs (values 0...99, height>=3, seed=42) — sorted by total time"
        )
    }
}

// MARK: - Sweep Runner

private let sweepTarget = 200

private func runParameterSweep(
    generator: Generator<BenchmarkBST>,
    predicate: @escaping (BenchmarkBST) -> Bool,
    header: String
) {
    let warmupValues: [UInt64] = [50, 100, 200, 400, 800]
    let sampleCountValues: [UInt64] = [5, 10, 20, 40]

    struct Row {
        let label: String
        let tuneMs: Double
        let result: SweepGenerationResult
        var totalMs: Double {
            tuneMs + result.generationMs
        }
    }

    var rows: [Row] = []

    // Baseline: rejection sampling (no tuning)
    let baselineResult = measureBSTGeneration(generator: generator, predicate: predicate)
    rows.append(Row(label: "reject       —", tuneMs: 0, result: baselineResult))

    for warmup in warmupValues {
        for sampleCount in sampleCountValues {
            let filterType = FilterType.customCGS(
                warmupRuns: warmup,
                sampleCount: sampleCount,
                subdivisionThresholds: .default
            )

            let tuneTimer = BenchmarkTimer()
            let filtered = Gen.filter(
                generator,
                type: filterType,
                predicate: predicate,
                sourceLocation: FilterSourceLocation(
                    fileID: #fileID, filePath: #filePath,
                    line: #line, column: #column
                )
            )
            let tuneMs = tuneTimer.elapsedMs

            let result = measureBSTGeneration(generator: filtered, predicate: predicate)
            rows.append(Row(label: "\(pad(warmup, width: 6))  \(pad(sampleCount, width: 7))", tuneMs: tuneMs, result: result))
        }
    }

    rows.sort { $0.totalMs < $1.totalMs }

    print("")
    print(header)
    print(String(repeating: "─", count: 105))
    print("warmup  samples  tune(ms)  gen(ms)  total(ms)  attempts  unique  validity  heights")
    print(String(repeating: "─", count: 105))

    for row in rows {
        let tuneStr = row.tuneMs > 0 ? pad(row.tuneMs, width: 8) : "       —"
        print(
            "\(row.label)"
                + "  \(tuneStr)"
                + "  \(pad(row.result.generationMs, width: 7))"
                + "  \(pad(row.totalMs, width: 9))"
                + "  \(pad(row.result.attempts, width: 8))"
                + "  \(pad(row.result.uniqueCount, width: 6))"
                + "  \(pad(row.result.validityRate, width: 8))"
                + "  \(row.result.heightDistribution)"
        )
    }

    print(String(repeating: "─", count: 105))
}

// MARK: - Measurement

private struct SweepGenerationResult {
    let generationMs: Double
    let attempts: Int
    let uniqueCount: Int
    let validityRate: String
    let heightDistribution: String
}

private func measureBSTGeneration(
    generator: Generator<BenchmarkBST>,
    predicate: (BenchmarkBST) -> Bool
) -> SweepGenerationResult {
    var iterator = ValueInterpreter(generator, seed: 42, maxRuns: .max)
    var totalAttempts = 0
    var unique = Set<BenchmarkBST>()
    var heights = [Int: Int]()

    let genTimer = BenchmarkTimer()
    while unique.count < sweepTarget {
        guard let tree = try? iterator.next() else { break }
        totalAttempts += 1
        if predicate(tree) {
            let inserted = unique.insert(tree).inserted
            if inserted {
                heights[tree.height, default: 0] += 1
            }
        }
    }
    let genMs = genTimer.elapsedMs

    let rate = totalAttempts > 0
        ? String(format: "%.1f%%", Double(unique.count) / Double(totalAttempts) * 100)
        : "—"

    let dist = heights.sorted { $0.key < $1.key }
        .map { "h\($0.key):\($0.value)" }
        .joined(separator: " ")

    return SweepGenerationResult(
        generationMs: genMs,
        attempts: totalAttempts,
        uniqueCount: unique.count,
        validityRate: rate,
        heightDistribution: dist
    )
}

// MARK: - Formatting

private func pad(_ value: Double, width: Int) -> String {
    let formatted = String(format: "%.1f", value)
    return formatted.count >= width
        ? formatted
        : String(repeating: " ", count: width - formatted.count) + formatted
}

private func pad(_ value: UInt64, width: Int) -> String {
    let str = "\(value)"
    return str.count >= width ? str : String(repeating: " ", count: width - str.count) + str
}

private func pad(_ value: Int, width: Int) -> String {
    let str = "\(value)"
    return str.count >= width ? str : String(repeating: " ", count: width - str.count) + str
}

private func pad(_ value: String, width: Int) -> String {
    value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
}
