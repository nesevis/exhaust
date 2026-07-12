// Paired A/B analysis of two benchmark JSONL files — the Swift port of the former Benchmarks/analyze.py, kept semantically identical: records pair by (fixture, seed), every comparison is per-seed first and aggregates second, censored discovery runs count as strictly worse than any completed one, and ties drop from the sign test.

import ArgumentParser
import Foundation

extension ExploreBenchmark {
    struct Analyze: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "analyze",
            abstract: "Paired A/B analysis of two benchmark JSONL files.",
            discussion: """
            Records are paired by (fixture, seed); every comparison is per-seed first, aggregates second. For each metric the command prints the per-seed table, then per-fixture medians, IQRs, median deltas, and two-sided paired sign-test verdicts, plus a pooled block when more than one fixture is present. Ties are dropped from the sign test.

            --discovery defines an attempts-to-discovery metric: the minimum firstSeenAttempt over clusters whose canonicalDescription contains every semicolon-separated marker. A run that never found a matching cluster is censored: it counts as strictly worse than any run that did, and censored-in-both pairs are dropped.
            """
        )

        @Argument(help: "Baseline JSONL path.")
        var baseline: String

        @Argument(help: "Candidate JSONL path.")
        var candidate: String

        @Option(help: "Comma-separated metrics. Known: any numeric record field, plus clusterCount and reducedTotal.")
        var metrics: String = "attemptsPerSecond,coveredEdges,clusterCount,reducedTotal"

        @Option(help: "label=marker[;marker...] — attempts-to-discovery of the cluster matching all markers. Repeatable.")
        var discovery: [String] = []

        mutating func run() throws {
            var resolved: [Metric] = []
            for name in metrics.split(separator: ",").map(String.init) {
                guard let metric = Self.recordMetrics[name] else {
                    throw ValidationError("unknown metric '\(name)'. Known metrics: \(Self.recordMetrics.keys.sorted().joined(separator: ", ")).")
                }
                resolved.append(metric)
            }
            for spec in discovery {
                let parts = spec.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, parts[1].isEmpty == false else {
                    throw ValidationError("--discovery '\(spec)' must be label=marker[;marker...]")
                }
                let markers = parts[1].split(separator: ";").map(String.init)
                resolved.append(Metric(name: String(parts[0]), kind: .integer) { record in
                    let attempts = record.clusters
                        .filter { cluster in markers.allSatisfy { cluster.canonicalDescription.contains($0) } }
                        .map(\.firstSeenAttempt)
                    return attempts.min().map(Double.init)
                })
            }

            let baselineRecords = try Self.load(baseline)
            let candidateRecords = try Self.load(candidate)
            let shared = Set(baselineRecords.keys).intersection(candidateRecords.keys).sorted()
            let unpaired = Set(baselineRecords.keys).symmetricDifference(candidateRecords.keys).sorted()
            if unpaired.isEmpty == false {
                let preview = unpaired.prefix(6).map { "(\($0.fixture), \($0.seed))" }.joined(separator: ", ")
                warn("warning: \(unpaired.count) unpaired records skipped: \(preview)\(unpaired.count > 6 ? "..." : "")")
            }
            guard shared.isEmpty == false else {
                warn("no paired (fixture, seed) records between the two files")
                throw ExitCode(1)
            }
            print("\(shared.count) paired runs: \(baseline) vs \(candidate)")
            for metric in resolved {
                Self.analyzeMetric(metric, keys: shared, baseline: baselineRecords, candidate: candidateRecords)
            }
        }

        // MARK: - Metrics

        /// The numeric record surface. `handleSkipFraction` reads as censored (`notfound`) on records without it rather than erroring, matching its optional schema.
        static let recordMetrics: [String: Metric] = {
            var table: [String: Metric] = [:]
            func add(_ name: String, _ kind: MetricKind, decimals: Int = 1, _ value: @escaping @Sendable (BenchmarkRecord) -> Double?) {
                table[name] = Metric(name: name, kind: kind, decimals: decimals, value: value)
            }
            add("seed", .integer) { Double($0.seed) }
            add("screeningAttempts", .integer) { Double($0.screeningAttempts) }
            add("samplingAttempts", .integer) { Double($0.samplingAttempts) }
            add("sprawlAttempts", .integer) { Double($0.sprawlAttempts) }
            add("totalAttempts", .integer) { Double($0.totalAttempts) }
            add("discardedAttempts", .integer) { Double($0.discardedAttempts) }
            add("coveredEdges", .integer) { Double($0.coveredEdges) }
            add("instrumentedEdges", .integer) { Double($0.instrumentedEdges) }
            add("edgeSingletons", .integer) { Double($0.edgeSingletons) }
            add("edgeDoubletons", .integer) { Double($0.edgeDoubletons) }
            add("corpusEntries", .integer) { Double($0.corpusEntries) }
            add("clusterCount", .integer) { Double($0.clusters.count) }
            add("reducedTotal", .integer) { Double($0.clusters.reduce(0) { $0 + $1.reduced }) }
            add("budgetSeconds", .fractional) { $0.budgetSeconds }
            add("elapsedSeconds", .fractional) { $0.elapsedSeconds }
            add("attemptsPerSecond", .fractional) { $0.attemptsPerSecond }
            add("overheadFraction", .fractional, decimals: 4) { $0.overheadFraction }
            add("estimatedNextEdgeProbability", .fractional, decimals: 4) { $0.estimatedNextEdgeProbability }
            add("estimatedReachableEdges", .fractional) { $0.estimatedReachableEdges }
            add("handleSkipFraction", .fractional, decimals: 4) { $0.handleSkipFraction }
            return table
        }()

        // MARK: - Loading

        static func load(_ path: String) throws -> [PairKey: BenchmarkRecord] {
            let decoder = JSONDecoder()
            var records: [PairKey: BenchmarkRecord] = [:]
            let content = try String(contentsOfFile: path, encoding: .utf8)
            for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    continue
                }
                let record = try decoder.decode(BenchmarkRecord.self, from: Data(line.utf8))
                let key = PairKey(fixture: record.fixture, seed: record.seed)
                if records[key] != nil {
                    warn("warning: duplicate record for (\(key.fixture), \(key.seed)) in \(path); keeping the last one")
                }
                records[key] = record
            }
            return records
        }

        // MARK: - Analysis

        static func analyzeMetric(
            _ metric: Metric,
            keys: [PairKey],
            baseline: [PairKey: BenchmarkRecord],
            candidate: [PairKey: BenchmarkRecord]
        ) {
            print("\n=== \(metric.name) ===")
            print("\(pad("fixture", 18)) \(padLeft("seed", 5)) \(padLeft("baseline", 12)) \(padLeft("candidate", 12)) \(padLeft("delta", 12))")
            var byFixture: [String: Accumulator] = [:]
            var fixtureOrder: [String] = []
            for key in keys {
                guard let baseRecord = baseline[key], let candidateRecord = candidate[key] else {
                    continue
                }
                if byFixture[key.fixture] == nil {
                    byFixture[key.fixture] = Accumulator()
                    fixtureOrder.append(key.fixture)
                }
                let baseValue = metric.value(baseRecord)
                let candidateValue = metric.value(candidateRecord)
                let row = { (baseText: String, candidateText: String, deltaText: String) in
                    print("\(pad(key.fixture, 18)) \(padLeft("\(key.seed)", 5)) \(padLeft(baseText, 12)) \(padLeft(candidateText, 12)) \(padLeft(deltaText, 12))")
                }
                switch (baseValue, candidateValue) {
                    case (nil, nil):
                        row("notfound", "notfound", "dropped")
                    case let (nil, .some(found)):
                        // The candidate found what the baseline never did: an improvement for the sign test.
                        byFixture[key.fixture]?.deltas.append(-1)
                        row("notfound", fmt(found, metric), "improved")
                    case let (.some(found), nil):
                        byFixture[key.fixture]?.deltas.append(1)
                        row(fmt(found, metric), "notfound", "regressed")
                    case let (.some(base), .some(cand)):
                        byFixture[key.fixture]?.deltas.append(cand - base)
                        byFixture[key.fixture]?.baselineValues.append(base)
                        byFixture[key.fixture]?.candidateValues.append(cand)
                        row(fmt(base, metric), fmt(cand, metric), fmt(cand - base, metric))
                }
            }

            // Gates read per-fixture verdicts (per-class no-regression); the pooled block stays for single-fixture runs and quick overall reads.
            for fixture in fixtureOrder.sorted() {
                guard let accumulator = byFixture[fixture] else {
                    continue
                }
                summarize("[\(fixture)]", accumulator, metric: metric)
            }
            if fixtureOrder.count > 1 {
                var pooled = Accumulator()
                for accumulator in byFixture.values {
                    pooled.deltas.append(contentsOf: accumulator.deltas)
                    pooled.baselineValues.append(contentsOf: accumulator.baselineValues)
                    pooled.candidateValues.append(contentsOf: accumulator.candidateValues)
                }
                summarize("[all fixtures]", pooled, metric: metric)
            }
        }

        private static func summarize(_ label: String, _ accumulator: Accumulator, metric: Metric) {
            guard accumulator.deltas.isEmpty == false else {
                print("\(label): no comparable pairs")
                return
            }
            print(label)
            if accumulator.baselineValues.isEmpty == false {
                let (baseLow, baseHigh) = iqr(accumulator.baselineValues)
                let (candidateLow, candidateHigh) = iqr(accumulator.candidateValues)
                print("  baseline : median \(fmtMedian(accumulator.baselineValues, metric))  IQR [\(fmtFractional(baseLow, metric.decimals)), \(fmtFractional(baseHigh, metric.decimals))]")
                print("  candidate: median \(fmtMedian(accumulator.candidateValues, metric))  IQR [\(fmtFractional(candidateLow, metric.decimals)), \(fmtFractional(candidateHigh, metric.decimals))]")
                let numericDeltas = zip(accumulator.baselineValues, accumulator.candidateValues).map { $1 - $0 }
                print("  delta    : median \(fmtMedian(numericDeltas, metric))")
            }
            let (positive, negative, pValue) = signTest(accumulator.deltas)
            let ties = accumulator.deltas.count - positive - negative
            let verdict = pValue < 0.05 ? "significant at 0.05" : "not significant"
            print("  sign test: \(positive) up, \(negative) down, \(ties) ties dropped; p = \(String(format: "%.4f", pValue)) (\(verdict))")
        }

        // MARK: - Statistics

        /// Two-sided paired sign test at p = 1/2, ties already excluded by construction. The binomial tail accumulates iteratively in probability space; the smallest term, 0.5^n, stays representable far past any realistic pair count.
        static func signTest(_ deltas: [Double]) -> (positive: Int, negative: Int, pValue: Double) {
            let positive = deltas.count(where: { $0 > 0 })
            let negative = deltas.count(where: { $0 < 0 })
            let n = positive + negative
            if n == 0 {
                return (positive, negative, 1.0)
            }
            let k = min(positive, negative)
            var probabilityMass = pow(0.5, Double(n))
            var tail = probabilityMass
            for i in 0 ..< k {
                probabilityMass = probabilityMass * Double(n - i) / Double(i + 1)
                tail += probabilityMass
            }
            return (positive, negative, min(1.0, 2 * tail))
        }

        /// The true median: the middle element, or the mean of the two middles for even counts.
        static func median(_ values: [Double]) -> Double {
            let ordered = values.sorted()
            let count = ordered.count
            if count % 2 == 1 {
                return ordered[count / 2]
            }
            return (ordered[count / 2 - 1] + ordered[count / 2]) / 2
        }

        /// Linearly interpolated quartiles, matching the former script's quantile convention.
        static func iqr(_ values: [Double]) -> (low: Double, high: Double) {
            let ordered = values.sorted()
            func quantile(_ fraction: Double) -> Double {
                let position = Double(ordered.count - 1) * fraction
                let low = Int(position.rounded(.down))
                let high = Int(position.rounded(.up))
                return ordered[low] + (ordered[high] - ordered[low]) * (position - Double(low))
            }
            return (low: quantile(0.25), high: quantile(0.75))
        }

        // MARK: - Formatting

        /// Integer metrics print whole values plainly and averaged values (medians of even counts) with one decimal; fractional metrics print at the metric's declared precision.
        private static func fmt(_ value: Double, _ metric: Metric) -> String {
            if metric.kind == .integer, value == value.rounded() {
                return String(Int(value))
            }
            return String(format: "%.\(metric.decimals)f", value)
        }

        /// Interpolated quantiles always print fractionally, at the metric's declared precision.
        private static func fmtFractional(_ value: Double, _ decimals: Int = 1) -> String {
            String(format: "%.\(decimals)f", value)
        }

        /// An even-count median averages the two middles and therefore prints fractionally even for integer metrics; an odd-count median is an element and follows the metric kind.
        private static func fmtMedian(_ values: [Double], _ metric: Metric) -> String {
            values.count % 2 == 0 ? fmtFractional(median(values), metric.decimals) : fmt(median(values), metric)
        }

        private static func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }

        private static func padLeft(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
        }
    }

    // MARK: - Analysis Types

    enum MetricKind {
        case integer
        case fractional
    }

    struct Metric: Sendable {
        let name: String
        let kind: MetricKind
        /// Display decimals for fractional values. Fraction-scale observables (skip fraction, overhead) need more than the default one, or a 0.025-scale signal prints as 0.0.
        var decimals: Int = 1
        let value: @Sendable (BenchmarkRecord) -> Double?
    }

    struct PairKey: Hashable, Comparable {
        let fixture: String
        let seed: UInt64

        static func < (lhs: PairKey, rhs: PairKey) -> Bool {
            lhs.fixture == rhs.fixture ? lhs.seed < rhs.seed : lhs.fixture < rhs.fixture
        }
    }

    /// Per-fixture accumulation for one metric: sign-test deltas (including the ±1 censoring sentinels) and the numeric value pairs.
    private struct Accumulator {
        var deltas: [Double] = []
        var baselineValues: [Double] = []
        var candidateValues: [Double] = []
    }
}

private func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
