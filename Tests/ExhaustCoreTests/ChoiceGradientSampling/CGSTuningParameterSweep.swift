import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

private enum SweepBST: Equatable, Hashable {
    case leaf
    indirect case node(left: SweepBST, value: UInt, right: SweepBST)

    static var arbitrary: Generator<SweepBST> {
        bstGenerator(maxDepth: 5)
    }

    private static func bstGenerator(maxDepth: Int) -> Generator<SweepBST> {
        if maxDepth <= 0 {
            return Gen.just(.leaf)
        }
        let nodeBranch = Gen.zip(
            bstGenerator(maxDepth: maxDepth - 1),
            Gen.choose(in: 0 ... 9 as ClosedRange<UInt>),
            bstGenerator(maxDepth: maxDepth - 1)
        ).map { left, value, right in
            SweepBST.node(left: left, value: value, right: right)
        }
        return Gen.pick(choices: [(1, Gen.just(.leaf)), (3, nodeBranch)])
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

// MARK: - Test Suite

@Suite("CGS Tuning Parameter Sweep", .disabled())
struct CGSTuningParameterSweep {
    private let target = 200

    @Test("Sweep warmupRuns × sampleCount for time-to-200 valid BSTs")
    func parameterSweep() {
        let isValidBST: (SweepBST) -> Bool = { $0.isValidBST() && $0.height > 1 }
        let warmupValues: [UInt64] = [50, 100, 200, 400, 800]
        let sampleCountValues: [UInt64] = [5, 10, 20, 40]

        struct Row {
            let label: String
            let tuneMs: Double
            let result: GenerationResult
            var totalMs: Double { tuneMs + result.generationMs }
        }

        var rows: [Row] = []

        // Baseline: rejection sampling (no tuning)
        let baselineResult = measureBSTGeneration(
            generator: SweepBST.arbitrary,
            predicate: isValidBST
        )
        rows.append(Row(label: "reject       —", tuneMs: 0, result: baselineResult))

        for warmup in warmupValues {
            for sampleCount in sampleCountValues {
                let filterType = FilterType.customCGS(
                    warmupRuns: warmup,
                    sampleCount: sampleCount,
                    subdivisionThresholds: .default
                )

                let tuneStart = ContinuousClock.now
                let filtered = Gen.filter(
                    SweepBST.arbitrary,
                    type: filterType,
                    predicate: isValidBST,
                    sourceLocation: FilterSourceLocation(
                        fileID: #fileID, filePath: #filePath,
                        line: #line, column: #column
                    )
                )
                let tuneMs = ms(ContinuousClock.now - tuneStart)

                let result = measureBSTGeneration(generator: filtered, predicate: isValidBST)
                rows.append(Row(label: "\(pad(warmup, width: 6))  \(pad(sampleCount, width: 7))", tuneMs: tuneMs, result: result))
            }
        }

        rows.sort { $0.totalMs < $1.totalMs }

        print("")
        print("CGS Parameter Sweep: time-to-\(target) unique valid BSTs (height>1, seed=42) — sorted by total time")
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

    @Test("Sweep warmupRuns × sampleCount for deep BST with wide value range")
    func deepBSTParameterSweep() {
        let deepBST = Gen.recursive(base: SweepBST.leaf, depthRange: 0 ... 5) { recurse, remaining in
            Gen.pick(choices: [
                (1, Gen.just(.leaf)),
                (Int(remaining), Gen.zip(
                    recurse(),
                    Gen.choose(in: 0 ... 99 as ClosedRange<UInt>),
                    recurse()
                ).map { left, value, right in SweepBST.node(left: left, value: value, right: right) })
            ])
        }
        let isDeepValidBST: (SweepBST) -> Bool = { $0.isValidBST() && $0.height >= 3 }
        let warmupValues: [UInt64] = [50, 100, 200, 400, 800]
        let sampleCountValues: [UInt64] = [5, 10, 20, 40]

        struct Row {
            let label: String
            let tuneMs: Double
            let result: GenerationResult
            var totalMs: Double { tuneMs + result.generationMs }
        }

        var rows: [Row] = []

        let baselineResult = measureBSTGeneration(
            generator: deepBST,
            predicate: isDeepValidBST
        )
        rows.append(Row(label: "reject       —", tuneMs: 0, result: baselineResult))

        for warmup in warmupValues {
            for sampleCount in sampleCountValues {
                let filterType = FilterType.customCGS(
                    warmupRuns: warmup,
                    sampleCount: sampleCount,
                    subdivisionThresholds: .default
                )

                let tuneStart = ContinuousClock.now
                let filtered = Gen.filter(
                    deepBST,
                    type: filterType,
                    predicate: isDeepValidBST,
                    sourceLocation: FilterSourceLocation(
                        fileID: #fileID, filePath: #filePath,
                        line: #line, column: #column
                    )
                )
                let tuneMs = ms(ContinuousClock.now - tuneStart)

                let result = measureBSTGeneration(generator: filtered, predicate: isDeepValidBST)
                rows.append(Row(label: "\(pad(warmup, width: 6))  \(pad(sampleCount, width: 7))", tuneMs: tuneMs, result: result))
            }
        }

        rows.sort { $0.totalMs < $1.totalMs }

        print("")
        print("CGS Parameter Sweep: time-to-\(target) unique valid BSTs (values 0...99, height>=3, seed=42) — sorted by total time")
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

    // MARK: - Helpers

    private struct GenerationResult {
        let generationMs: Double
        let attempts: Int
        let uniqueCount: Int
        let validityRate: String
        let heightDistribution: String
    }

    private func measureBSTGeneration(
        generator: Generator<SweepBST>,
        predicate: (SweepBST) -> Bool
    ) -> GenerationResult {
        var iterator = ValueInterpreter(generator, seed: 42, maxRuns: .max)
        var totalAttempts = 0
        var unique = Set<SweepBST>()
        var heights = [Int: Int]()

        let genStart = ContinuousClock.now
        while unique.count < target {
            guard let tree = try? iterator.next() else { break }
            totalAttempts += 1
            if predicate(tree) {
                let inserted = unique.insert(tree).inserted
                if inserted {
                    heights[tree.height, default: 0] += 1
                }
            }
        }
        let genMs = ms(ContinuousClock.now - genStart)

        let rate = totalAttempts > 0
            ? String(format: "%.1f%%", Double(unique.count) / Double(totalAttempts) * 100)
            : "—"

        let dist = heights.sorted { $0.key < $1.key }
            .map { "h\($0.key):\($0.value)" }
            .joined(separator: " ")

        return GenerationResult(
            generationMs: genMs,
            attempts: totalAttempts,
            uniqueCount: unique.count,
            validityRate: rate,
            heightDistribution: dist
        )
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

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
}
