//
//  YieldCalibrationAnalysis.swift
//  Exhaust
//

import Foundation
import Testing
@testable import Exhaust
@testable import ExhaustCore

/// Empirical evaluation of whether ``TransformationYield``'s ranking predicts which dispatches actually accept.
///
/// Each test runs `seedCount` independent reductions of one ECOOP-style challenge with ``ExhaustSettings/onReport(_:)`` set, harvests the probe log, and prints three statistics:
///
/// 1. Per-encoder Spearman rank correlation between predicted structural yield and binary accept outcome, aggregated across seeds.
/// 2. Per-encoder yield-quartile acceptance rates (top quartile vs bottom).
/// 3. Per-seed wasted-tail count: dispatches issued after the last accept that produced no further progress.
///
/// Suite is disabled by default — runs are slow because each seed reduces a CE end-to-end. Enable manually via `swift test --filter YieldCalibrationAnalysis`.
@Suite("Yield Calibration Analysis", .disabled("Manual run only — long-running calibration analysis"))
struct YieldCalibrationAnalysis {
    /// Number of independent seeds per challenge. 30 is a noisy floor; raise to 100 for tighter intervals.
    static let seedCount = 30

    /// Base seed offset so the first run is `0x1337`.
    static let baseSeed: UInt64 = 0x1337

    @Test("Reverse")
    func reverse() {
        let gen = #gen(.uint()).array(length: 1 ... 1000)
        runAnalysis(name: "Reverse") { seed in
            var report: ExhaustReport?
            _ = #exhaust(
                gen,
                .suppress(.all),
                .replay(.numeric(seed)),
                .onReport { report = $0 }
            ) { arr in
                arr.elementsEqual(arr.reversed())
            }
            return report?.probeLog ?? []
        }
    }

    @Test("Calculator")
    func calculator() {
        let gen = #gen(CalculatorFixture.expression(depth: 5))
        runAnalysis(name: "Calculator") { seed in
            var report: ExhaustReport?
            _ = #exhaust(
                gen,
                .suppress(.all),
                .replay(.numeric(seed)),
                .budget(.exorbitant),
                .onReport { report = $0 }
            ) { expr in
                CalculatorFixture.property(expr)
            }
            return report?.probeLog ?? []
        }
    }

    @Test("LengthList")
    func lengthList() {
        // The "length" challenge: a list of int8s where length must equal first element.
        let gen = #gen(.int8()).array(length: 0 ... 100)
        runAnalysis(name: "LengthList") { seed in
            var report: ExhaustReport?
            _ = #exhaust(
                gen,
                .suppress(.all),
                .replay(.numeric(seed)),
                .onReport { report = $0 }
            ) { arr in
                guard arr.isEmpty == false else { return true }
                return Int(arr[0]) != arr.count - 1
            }
            return report?.probeLog ?? []
        }
    }

    @Test("Bound5")
    func bound5() {
        runAnalysis(name: "Bound5") { seed in
            var report: ExhaustReport?
            _ = #exhaust(
                Bound5Fixture.gen,
                .suppress(.all),
                .replay(.numeric(seed)),
                .onReport { report = $0 },
                property: Bound5Fixture.property
            )
            return report?.probeLog ?? []
        }
    }

    @Test("BinaryHeap")
    func binaryHeap() {
        let boundGen = #gen(.uint64(in: 0 ... 20)).bind { BinaryHeapFixture.heapGen(depth: $0) }
        runAnalysis(name: "BinaryHeap") { seed in
            var report: ExhaustReport?
            _ = #exhaust(
                boundGen,
                .suppress(.all),
                .replay(.numeric(seed)),
                .onReport { report = $0 },
                property: BinaryHeapFixture.property
            )
            return report?.probeLog ?? []
        }
    }

    @Test("Parser")
    func parser() {
        runAnalysis(name: "Parser") { seed in
            var report: ExhaustReport?
            _ = #exhaust(
                ParserFixture.langGen,
                .randomOnly,
                .suppress(.all),
                .replay(.numeric(seed)),
                .budget(.exorbitant),
                .onReport { report = $0 },
                property: ParserFixture.property
            )
            return report?.probeLog ?? []
        }
    }

    // MARK: - Runner

    private func runAnalysis(name: String, body: (UInt64) -> [ProbeLogEntry]) {
        var perSeedLogs: [(seed: UInt64, log: [ProbeLogEntry])] = []
        for index in 0 ..< Self.seedCount {
            let seed = Self.baseSeed &+ UInt64(index)
            let log = body(seed)
            if log.isEmpty == false {
                perSeedLogs.append((seed, log))
            }
        }
        let summary = analyzeCalibration(name: name, perSeedLogs: perSeedLogs)
        print(summary)
    }
}

// MARK: - Analysis

/// Aggregated calibration metrics for one challenge.
private struct CalibrationSummary {
    let name: String
    let seedsAnalyzed: Int
    let totalDispatches: Int
    let totalAcceptedDispatches: Int

    /// Per-encoder Spearman correlation distribution across seeds.
    let perEncoder: [EncoderName: PerEncoderStats]

    /// Per-seed wasted-tail counts (dispatches after the last accept).
    let wastedTailCounts: [Int]
}

private struct PerEncoderStats {
    /// Number of `(seed)` pairs that contributed a usable correlation (≥5 dispatches with mixed accept outcomes).
    let usableSeedCount: Int

    /// Mean Spearman correlation across usable seeds.
    let meanSpearman: Double

    /// Standard deviation of Spearman across usable seeds.
    let stddevSpearman: Double

    /// Acceptance rate in the top quartile of predicted yield (aggregated across all seeds).
    let topQuartileAcceptRate: Double

    /// Acceptance rate in the bottom quartile of predicted yield.
    let bottomQuartileAcceptRate: Double

    /// Total dispatches across all seeds for this encoder.
    let totalDispatches: Int

    /// Total accepted dispatches across all seeds for this encoder.
    let totalAccepted: Int
}

private func analyzeCalibration(
    name: String,
    perSeedLogs: [(seed: UInt64, log: [ProbeLogEntry])]
) -> String {
    var totalDispatches = 0
    var totalAccepted = 0
    var entriesByEncoder: [EncoderName: [(predictedYield: Int, accepted: Bool)]] = [:]
    var spearmanByEncoder: [EncoderName: [Double]] = [:]
    var wastedTailCounts: [Int] = []

    for (_, log) in perSeedLogs {
        totalDispatches += log.count
        totalAccepted += log.count(where: { $0.acceptCount > 0 })
        wastedTailCounts.append(wastedTailCount(log: log))

        // Per-seed per-encoder Spearman.
        var perEncoderInSeed: [EncoderName: [(yield: Int, accepted: Bool)]] = [:]
        for entry in log {
            perEncoderInSeed[entry.encoder, default: []].append((entry.predictedStructuralYield, entry.acceptCount > 0))
            entriesByEncoder[entry.encoder, default: []].append((entry.predictedStructuralYield, entry.acceptCount > 0))
        }
        for (encoder, pairs) in perEncoderInSeed {
            guard pairs.count >= 5 else { continue }
            let acceptedCount = pairs.count(where: \.accepted)
            guard acceptedCount > 0, acceptedCount < pairs.count else { continue }
            let correlation = spearmanRankCorrelation(pairs.map { Double($0.yield) }, pairs.map { $0.accepted ? 1.0 : 0.0 })
            spearmanByEncoder[encoder, default: []].append(correlation)
        }
    }

    var perEncoder: [EncoderName: PerEncoderStats] = [:]
    for (encoder, allPairs) in entriesByEncoder {
        let correlations = spearmanByEncoder[encoder] ?? []
        let mean = correlations.isEmpty ? 0 : correlations.reduce(0, +) / Double(correlations.count)
        let variance = correlations.count > 1
            ? correlations.map { pow($0 - mean, 2) }.reduce(0, +) / Double(correlations.count - 1)
            : 0
        let (top, bottom) = quartileAcceptRates(allPairs)
        perEncoder[encoder] = PerEncoderStats(
            usableSeedCount: correlations.count,
            meanSpearman: mean,
            stddevSpearman: sqrt(variance),
            topQuartileAcceptRate: top,
            bottomQuartileAcceptRate: bottom,
            totalDispatches: allPairs.count,
            totalAccepted: allPairs.count(where: \.accepted)
        )
    }

    let summary = CalibrationSummary(
        name: name,
        seedsAnalyzed: perSeedLogs.count,
        totalDispatches: totalDispatches,
        totalAcceptedDispatches: totalAccepted,
        perEncoder: perEncoder,
        wastedTailCounts: wastedTailCounts
    )
    return formatSummary(summary)
}

/// Counts dispatches issued after the last-accepted dispatch in the log. These are unambiguously wasted because no further progress was made.
private func wastedTailCount(log: [ProbeLogEntry]) -> Int {
    guard let lastAcceptIndex = log.lastIndex(where: { $0.acceptCount > 0 }) else {
        return log.count
    }
    return log.count - 1 - lastAcceptIndex
}

/// Computes the acceptance rate in the top and bottom quartile of predicted yield. Returns `(top, bottom)`. Quartiles are computed over the input pairs, ordered by yield descending.
private func quartileAcceptRates(_ pairs: [(predictedYield: Int, accepted: Bool)]) -> (top: Double, bottom: Double) {
    guard pairs.count >= 4 else { return (0, 0) }
    let sortedDescending = pairs.sorted { $0.predictedYield > $1.predictedYield }
    let quartileSize = sortedDescending.count / 4
    let top = sortedDescending.prefix(quartileSize)
    let bottom = sortedDescending.suffix(quartileSize)
    let topRate = Double(top.count(where: \.accepted)) / Double(top.count)
    let bottomRate = Double(bottom.count(where: \.accepted)) / Double(bottom.count)
    return (topRate, bottomRate)
}

private func spearmanRankCorrelation(_ xs: [Double], _ ys: [Double]) -> Double {
    let xRanks = ranks(xs)
    let yRanks = ranks(ys)
    return pearsonCorrelation(xRanks, yRanks)
}

/// Average ranks (handles ties by assigning the mean of the tied positions).
private func ranks(_ values: [Double]) -> [Double] {
    let indexed = values.enumerated().sorted { $0.element < $1.element }
    var result = [Double](repeating: 0, count: values.count)
    var index = 0
    while index < indexed.count {
        var sameValueEnd = index
        while sameValueEnd + 1 < indexed.count, indexed[sameValueEnd + 1].element == indexed[index].element {
            sameValueEnd += 1
        }
        let averageRank = Double(index + sameValueEnd) / 2.0 + 1.0
        for tiedIndex in index ... sameValueEnd {
            result[indexed[tiedIndex].offset] = averageRank
        }
        index = sameValueEnd + 1
    }
    return result
}

private func pearsonCorrelation(_ xs: [Double], _ ys: [Double]) -> Double {
    let count = Double(xs.count)
    guard count > 1 else { return 0 }
    let xMean = xs.reduce(0, +) / count
    let yMean = ys.reduce(0, +) / count
    var numerator = 0.0
    var xVariance = 0.0
    var yVariance = 0.0
    for index in xs.indices {
        let xDelta = xs[index] - xMean
        let yDelta = ys[index] - yMean
        numerator += xDelta * yDelta
        xVariance += xDelta * xDelta
        yVariance += yDelta * yDelta
    }
    let denominator = sqrt(xVariance * yVariance)
    return denominator == 0 ? 0 : numerator / denominator
}

// MARK: - Formatting

private func formatSummary(_ summary: CalibrationSummary) -> String {
    var lines: [String] = []
    lines.append("")
    lines.append("=== \(summary.name) — yield calibration ===")
    lines.append("seeds=\(summary.seedsAnalyzed) total_dispatches=\(summary.totalDispatches) accepted_dispatches=\(summary.totalAcceptedDispatches) (\(percent(Double(summary.totalAcceptedDispatches), Double(summary.totalDispatches))))")
    let wastedTotal = summary.wastedTailCounts.reduce(0, +)
    lines.append("wasted_tail: total=\(wastedTotal) mean_per_seed=\(String(format: "%.1f", summary.wastedTailCounts.isEmpty ? 0 : Double(wastedTotal) / Double(summary.wastedTailCounts.count)))")
    lines.append("per-encoder calibration (sorted by total dispatches):")
    let sortedEncoders = summary.perEncoder.keys.sorted { lhs, rhs in
        (summary.perEncoder[lhs]?.totalDispatches ?? 0) > (summary.perEncoder[rhs]?.totalDispatches ?? 0)
    }
    for encoder in sortedEncoders {
        guard let stats = summary.perEncoder[encoder] else { continue }
        let spearmanLabel = stats.usableSeedCount > 0
            ? "spearman=\(format2(stats.meanSpearman))±\(format2(stats.stddevSpearman)) (n=\(stats.usableSeedCount))"
            : "spearman=n/a (no seeds with mixed outcomes ≥5 dispatches)"
        lines.append("  \(encoder.rawValue): dispatches=\(stats.totalDispatches) accepted=\(stats.totalAccepted) (\(percent(Double(stats.totalAccepted), Double(stats.totalDispatches)))) | \(spearmanLabel) | top_quartile_accept=\(percent(stats.topQuartileAcceptRate, 1.0)) bottom_quartile_accept=\(percent(stats.bottomQuartileAcceptRate, 1.0))")
    }
    return lines.joined(separator: "\n")
}

private func percent(_ value: Double, _ total: Double) -> String {
    guard total > 0 else { return "n/a" }
    return String(format: "%.1f%%", value / total * 100)
}

private func format2(_ value: Double) -> String {
    String(format: "%.2f", value)
}
