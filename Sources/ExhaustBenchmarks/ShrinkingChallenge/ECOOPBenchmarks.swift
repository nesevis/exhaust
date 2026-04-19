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
    let seedCount = benchmarkSeedsToRun
    let baseSeed: UInt64 = 1337
    let config = reducerConfig

    registerECOOPPair(
        name: "Bound5", gen: bound5Gen, property: bound5Property,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "BinaryHeap", gen: binaryHeapGen(depth: 10).unique(), property: binaryHeapProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "Calculator", gen: #gen(calculatorExpressionGen(depth: 4)), property: calculatorProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "Coupling", gen: couplingGen, property: couplingProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "Deletion", gen: deletionGen, property: deletionProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "Difference: Must Not Be Zero",
        gen: differenceMustNotBeZeroGen, property: differenceMustNotBeZeroProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed, maxGenerationRuns: 500_000
    )
    registerECOOPPair(
        name: "Difference: Must Not Be Small",
        gen: differenceMustNotBeSmallGen, property: differenceMustNotBeSmallProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed, maxGenerationRuns: 500_000
    )
    registerECOOPPair(
        name: "Difference: Must Not Be One",
        gen: differenceMustNotBeOneGen, property: differenceMustNotBeOneProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed, maxGenerationRuns: 500_000
    )
    registerECOOPPair(
        name: "Distinct", gen: distinctGen, property: distinctProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "LargeUnionList", gen: largeUnionListGen, property: largeUnionListProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "LengthList", gen: lengthListGen, property: lengthListProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "NestedLists", gen: nestedListsGen, property: nestedListsProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "Reverse", gen: reverseGen, property: reverseProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "Replacement", gen: replacementGen, property: replacementProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    
    registerECOOPPair(
        name: "Parser", gen: parserLangGen, property: parserProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed, sizeMetric: parserSize
    )
    registerECOOPPair(
        name: "GraphColoring", gen: graphColoringGen, property: graphColoringProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
}

/// Registers a benchmark for a single challenge using the graph-based reducer.
func registerECOOPPair<Output>(
    name: String,
    gen: ReflectiveGenerator<Output>,
    property: @Sendable @escaping (Output) -> Bool,
    config: Interpreters.ReducerConfiguration,
    seedCount: Int,
    baseSeed: UInt64,
    maxGenerationRuns: UInt64 = 10000,
    sizeMetric: ((Output) -> Int)? = nil
) {
    registerECOOPChallenge(
        name: name,
        gen: gen,
        property: property,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed,
        maxGenerationRuns: maxGenerationRuns,
        sizeMetric: sizeMetric
    )
}

// MARK: - Per-Seed Result

private struct SeedResult {
    let seed: UInt64
    let generationIterations: Int
    let invocations: Int
    let materializations: Int
    let generationMilliseconds: Double
    let reductionMilliseconds: Double
    let size: Int?
    let counterexampleDescription: String
    let encoderProbes: [EncoderName: Int]
    let encoderProbesAccepted: [EncoderName: Int]
    let encoderProbesRejectedByCache: [EncoderName: Int]
    let encoderProbesRejectedByDecoder: [EncoderName: Int]
}

// MARK: - Runner

private func registerECOOPChallenge<Output>(
    name: String,
    gen: ReflectiveGenerator<Output>,
    property: @Sendable @escaping (Output) -> Bool,
    config: Interpreters.ReducerConfiguration,
    seedCount: Int,
    baseSeed: UInt64,
    maxGenerationRuns: UInt64 = 10000,
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
            // Use the *CollectingStats variants so we can pull
            // `stats.totalMaterializations` for the report. The reduced
            // tuple has the same shape as the plain `*Reduce` return.
            let reduceResult = try? Interpreters.choiceGraphReduceCollectingStats(
                gen: gen,
                tree: tree,
                output: value,
                config: config,
                property: countingProperty
            )
            let reduceEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let reductionMs = Double(reduceEnd - reduceStart) / 1_000_000.0

            let output = reduceResult?.reduced?.1 ?? value
            let materializationCount = reduceResult?.stats.totalMaterializations ?? 0
            results.append(SeedResult(
                seed: seed,
                generationIterations: generationIterations,
                invocations: invocationCount,
                materializations: materializationCount,
                generationMilliseconds: generationMs,
                reductionMilliseconds: reductionMs,
                size: sizeMetric?(output),
                counterexampleDescription: String(describing: output),
                encoderProbes: reduceResult?.stats.encoderProbes ?? [:],
                encoderProbesAccepted: reduceResult?.stats.encoderProbesAccepted ?? [:],
                encoderProbesRejectedByCache: reduceResult?.stats.encoderProbesRejectedByCache ?? [:],
                encoderProbesRejectedByDecoder: reduceResult?.stats.encoderProbesRejectedByDecoder ?? [:]
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
    let materializations = results.map { Double($0.materializations) }
    let genTimes = results.map(\.generationMilliseconds)
    let reduceTimes = results.map(\.reductionMilliseconds)
    let uniqueCEs = Set(results.map(\.counterexampleDescription))

    let genIterStats = summaryStats(genIterations)
    let invocStats = summaryStats(invocations)
    let matStats = summaryStats(materializations)
    let genStats = summaryStats(genTimes)
    let reduceStats = summaryStats(reduceTimes)

    let sizes = results.compactMap(\.size)
    var sizeReport = ""
    if sizes.isEmpty == false {
        let sizeStats = summaryStats(sizes.map { Double($0) })
        sizeReport = " mean_size=\(f2(sizeStats.mean)) (\(f2(sizeStats.ciLow))–\(f2(sizeStats.ciHigh)))"
    }

    print("[\(name) ECOOP] seeds=\(foundCount)/\(seedCount)\(sizeReport) iter_to_fail: mean=\(f1(genIterStats.mean)) median=\(f1(genIterStats.median)) | invocations: mean=\(f1(invocStats.mean)) (\(f1(invocStats.ciLow))–\(f1(invocStats.ciHigh))) median=\(f1(invocStats.median)) | mats: mean=\(f1(matStats.mean)) (\(f1(matStats.ciLow))–\(f1(matStats.ciHigh))) median=\(f1(matStats.median)) | gen(ms): mean=\(f2(genStats.mean)) median=\(f2(genStats.median)) | reduce(ms): mean=\(f2(reduceStats.mean)) (\(f2(reduceStats.ciLow))–\(f2(reduceStats.ciHigh))) median=\(f2(reduceStats.median)) | unique_CEs=\(uniqueCEs.count)")

    // Per-encoder probe breakdown (summed across all seeds).
    // Per-encoder rejection breakdown:
    // each `rejDec` is one materialization that did not reach the property.
    var totalEmitted: [EncoderName: Int] = [:]
    var totalAccepted: [EncoderName: Int] = [:]
    var totalCacheRej: [EncoderName: Int] = [:]
    var totalDecRej: [EncoderName: Int] = [:]
    for result in results {
        for (encoder, count) in result.encoderProbes {
            totalEmitted[encoder, default: 0] += count
        }
        for (encoder, count) in result.encoderProbesAccepted {
            totalAccepted[encoder, default: 0] += count
        }
        for (encoder, count) in result.encoderProbesRejectedByCache {
            totalCacheRej[encoder, default: 0] += count
        }
        for (encoder, count) in result.encoderProbesRejectedByDecoder {
            totalDecRej[encoder, default: 0] += count
        }
    }
    let allEncoders = Set(totalEmitted.keys)
        .union(totalAccepted.keys)
        .union(totalCacheRej.keys)
        .union(totalDecRej.keys)
    if allEncoders.isEmpty == false {
        let sortedEncoders = allEncoders.sorted { lhs, rhs in
            (totalDecRej[lhs] ?? 0) > (totalDecRej[rhs] ?? 0)
        }
        print("[\(name) ECOOP] encoder breakdown (summed across \(foundCount) seeds, sorted by rejDec descending):")
        for encoder in sortedEncoders {
            let emit = totalEmitted[encoder] ?? 0
            let acc = totalAccepted[encoder] ?? 0
            let cacheRej = totalCacheRej[encoder] ?? 0
            let decRej = totalDecRej[encoder] ?? 0
            print("  \(encoder.rawValue): emit=\(emit) acc=\(acc) rejCache=\(cacheRej) rejDec=\(decRej)")
        }
    }

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

private func f1(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private func f2(_ value: Double) -> String {
    String(format: "%.2f", value)
}
