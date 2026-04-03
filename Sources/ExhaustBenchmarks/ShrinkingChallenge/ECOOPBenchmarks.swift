// MARK: - ECOOP 2020 Methodology Benchmarks
//
// Independent generate-and-shrink runs matching MacIver & Donaldson (ECOOP 2020, Section 4.3)
// and the jlink/shrinking-challenge methodology.
//
// Each benchmark: N independent seeds, one failure per seed, reduce independently.
// Reports: mean size (with 95% CI), mean SUT invocations (with 95% CI), unique counterexamples.

import Benchmark
import Exhaust
import ExhaustCore
import Foundation

func registerECOOPBenchmarks() {
    let seedCount = 1000
    let baseSeed: UInt64 = 1337
    let config = Interpreters.BonsaiReducerConfiguration.slow

    registerECOOPChallenge(
        name: "Bound5",
        gen: bound5Gen,
        property: bound5Property,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed
    )
    registerECOOPChallenge(
        name: "BinaryHeap",
        gen: binaryHeapGen(depth: 10).unique(),
        property: binaryHeapProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed
    )
    registerECOOPChallenge(
        name: "Calculator",
        gen: #gen(calculatorExpressionGen(depth: 4)),
        property: calculatorProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed
    )
    registerECOOPChallenge(
        name: "Coupling",
        gen: couplingGen,
        property: couplingProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed
    )
    registerECOOPChallenge(
        name: "Deletion",
        gen: deletionGen,
        property: deletionProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed
    )
    registerECOOPChallenge(
        name: "Difference: Must Not Be Zero",
        gen: differenceMustNotBeZeroGen,
        property: differenceMustNotBeZeroProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed,
        maxGenerationRuns: 500_000
    )
    registerECOOPChallenge(
        name: "Difference: Must Not Be Small",
        gen: differenceMustNotBeSmallGen,
        property: differenceMustNotBeSmallProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed,
        maxGenerationRuns: 500_000
    )
    registerECOOPChallenge(
        name: "Difference: Must Not Be One",
        gen: differenceMustNotBeOneGen,
        property: differenceMustNotBeOneProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed,
        maxGenerationRuns: 500_000
    )
    registerECOOPChallenge(
        name: "Distinct",
        gen: distinctGen,
        property: distinctProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed
    )
    registerECOOPChallenge(
        name: "LargeUnionList",
        gen: largeUnionListGen,
        property: largeUnionListProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed
    )
    registerECOOPChallenge(
        name: "LengthList",
        gen: lengthListGen,
        property: lengthListProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed
    )
    registerECOOPChallenge(
        name: "NestedLists",
        gen: nestedListsGen,
        property: nestedListsProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed
    )
    registerECOOPChallenge(
        name: "Reverse",
        gen: reverseGen,
        property: reverseProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed
    )
    registerECOOPChallenge(
        name: "Replacement",
        gen: replacementGen,
        property: replacementProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed
    )
//    registerECOOPChallenge(
//        name: "Parser",
//        gen: parserLangGen,
//        property: parserProperty,
//        config: .slow,
//        seedCount: seedCount,
//        baseSeed: baseSeed,
//        sizeMetric: { parserSize($0) }
//    )
}

// MARK: - Per-Seed Result

private struct SeedResult {
    let seed: UInt64
    let generationIterations: Int
    let invocations: Int
    let generationMilliseconds: Double
    let reductionMilliseconds: Double
    let size: Int?
    let counterexampleDescription: String
}

// MARK: - Runner

private func registerECOOPChallenge<Output>(
    name: String,
    gen: ReflectiveGenerator<Output>,
    property: @Sendable @escaping (Output) -> Bool,
    config: Interpreters.BonsaiReducerConfiguration,
    seedCount: Int,
    baseSeed: UInt64,
    maxGenerationRuns: UInt64 = 10_000,
    sizeMetric: ((Output) -> Int)? = nil
) {
    benchmark("\(name) ECOOP") {
        var results: [SeedResult] = []

        for i in 0 ..< seedCount {
            let seed = baseSeed &+ UInt64(i)

            let genStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: maxGenerationRuns)
            var failingValue: Output?
            var failingTree: ChoiceTree?
            var generationIterations = 0
            do {
                while let (value, tree) = try iterator.next() {
                    generationIterations += 1
                    if property(value) == false {
                        failingValue = value
                        failingTree = tree
                        break
                    }
                }
            } catch {}
            let genEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard let value = failingValue, let tree = failingTree else { continue }
            let generationMs = Double(genEnd - genStart) / 1_000_000.0

            var invocationCount = 0
            let countingProperty: (Output) -> Bool = { candidate in
                invocationCount += 1
                return property(candidate)
            }
            let reduceStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let result = try? Interpreters.bonsaiReduce(
                gen: gen,
                tree: tree,
                output: value,
                config: config,
                property: countingProperty
            )
            let reduceEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let reductionMs = Double(reduceEnd - reduceStart) / 1_000_000.0

            let output = result?.1 ?? value
            results.append(SeedResult(
                seed: seed,
                generationIterations: generationIterations,
                invocations: invocationCount,
                generationMilliseconds: generationMs,
                reductionMilliseconds: reductionMs,
                size: sizeMetric?(output),
                counterexampleDescription: String(describing: output)
            ))
        }

        printECOOPReport(name: name, seedCount: seedCount, results: results)
    }
}

// MARK: - Reporting

private func printECOOPReport(
    name: String,
    seedCount: Int,
    results: [SeedResult]
) {
    let foundCount = results.count
    guard foundCount > 0 else {
        print("[\(name) ECOOP] No failures found in \(seedCount) seeds")
        return
    }

    let genIterations = results.map { Double($0.generationIterations) }
    let invocations = results.map { Double($0.invocations) }
    let genTimes = results.map { $0.generationMilliseconds }
    let reduceTimes = results.map { $0.reductionMilliseconds }
    let uniqueCEs = Set(results.map(\.counterexampleDescription))

    let genIterStats = summaryStats(genIterations)
    let invocStats = summaryStats(invocations)
    let genStats = summaryStats(genTimes)
    let reduceStats = summaryStats(reduceTimes)

    let sizes = results.compactMap(\.size)
    var sizeReport = ""
    if sizes.isEmpty == false {
        let sizeStats = summaryStats(sizes.map { Double($0) })
        sizeReport = " mean_size=\(f2(sizeStats.mean)) (\(f2(sizeStats.ciLow))–\(f2(sizeStats.ciHigh)))"
    }

    print("[\(name) ECOOP] seeds=\(foundCount)/\(seedCount)\(sizeReport) iter_to_fail: mean=\(f1(genIterStats.mean)) median=\(f1(genIterStats.median)) | invocations: mean=\(f1(invocStats.mean)) (\(f1(invocStats.ciLow))–\(f1(invocStats.ciHigh))) median=\(f1(invocStats.median)) | gen(ms): mean=\(f1(genStats.mean)) median=\(f1(genStats.median)) | reduce(ms): mean=\(f1(reduceStats.mean)) (\(f1(reduceStats.ciLow))–\(f1(reduceStats.ciHigh))) median=\(f1(reduceStats.median)) | unique_CEs=\(uniqueCEs.count)")
    if enableCounterExamples {
        // Group seeds by counterexample for reproducibility.
        var seedsByCE: [String: [UInt64]] = [:]
        for result in results {
            seedsByCE[result.counterexampleDescription, default: []].append(result.seed)
        }
        let sortedCEs = seedsByCE.sorted { $0.value.count > $1.value.count }
        print("[\(name) ECOOP] unique counterexamples (\(uniqueCEs.count)):")
        for (counterexample, seeds) in sortedCEs {
            let percentage = String(format: "%.1f", Double(seeds.count) / Double(foundCount) * 100)
            let seedPreview = seeds.prefix(3).map { String($0) }.joined(separator: ", ")
            let suffix = seeds.count > 3 ? ", ... (\(seeds.count) total)" : " (\(seeds.count) total)"
            print("  \(percentage)% \(counterexample) — seeds: \(seedPreview)\(suffix)")
        }
    }
}

// MARK: - Statistics Helpers

private struct SummaryStats {
    let mean: Double
    let median: Double
    let ciLow: Double
    let ciHigh: Double
}

private func summaryStats(_ values: [Double]) -> SummaryStats {
    let count = values.count
    guard count > 1 else {
        let single = values.first ?? 0
        return SummaryStats(mean: single, median: single, ciLow: single, ciHigh: single)
    }
    let mean = values.reduce(0, +) / Double(count)
    let sorted = values.sorted()
    let median = count % 2 == 0
        ? (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        : sorted[count / 2]
    let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(count - 1)
    let stdError = sqrt(variance / Double(count))
    return SummaryStats(
        mean: mean,
        median: median,
        ciLow: mean - 1.96 * stdError,
        ciHigh: mean + 1.96 * stdError
    )
}

private func f1(_ value: Double) -> String { String(format: "%.1f", value) }
private func f2(_ value: Double) -> String { String(format: "%.2f", value) }

