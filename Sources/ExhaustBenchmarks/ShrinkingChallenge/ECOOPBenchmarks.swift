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
        name: "Bound5", gen: bound5Gen.gen, property: bound5Property,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "BinaryHeap", gen: #gen(.uint64(in: 0 ... 20)).bind { binaryHeapGen(depth: $0) }.unique().gen, property: binaryHeapProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "BinaryHeap (recursive)", gen: binaryHeapGenRecursive().gen, property: binaryHeapProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "Calculator", gen: calculatorExpressionGen(depth: 5).gen, property: calculatorProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "Coupling", gen: couplingGen.gen, property: couplingProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "Deletion", gen: deletionGen.gen, property: deletionProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "MixedCoupling", gen: mixedCouplingGen.gen, property: mixedCouplingProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "MixedCoupling (wide)", gen: wideMixedCouplingGen.gen, property: wideMixedCouplingProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "Difference: Must Not Be Zero",
        gen: differenceMustNotBeZeroGen.gen, property: differenceMustNotBeZeroProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed, maxGenerationRuns: 500_000
    )
    registerECOOPPair(
        name: "Difference: Must Not Be Small",
        gen: differenceMustNotBeSmallGen.gen, property: differenceMustNotBeSmallProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed, maxGenerationRuns: 500_000
    )
    registerECOOPPair(
        name: "Difference: Must Not Be One",
        gen: differenceMustNotBeOneGen.gen, property: differenceMustNotBeOneProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed, maxGenerationRuns: 500_000
    )
    registerECOOPPair(
        name: "RatioCoupling",
        gen: ratioCouplingGen.gen, property: ratioCouplingProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed, maxGenerationRuns: 500_000
    )
    registerECOOPPair(
        name: "Distinct", gen: distinctGen.gen, property: distinctProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "LargeUnionList", gen: largeUnionListGen.gen, property: largeUnionListProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "LengthList", gen: lengthListGen.gen, property: lengthListProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "NestedLists", gen: nestedListsGen.gen, property: nestedListsProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "Reverse", gen: reverseGen.gen, property: reverseProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
    registerECOOPPair(
        name: "Replacement", gen: replacementGen.gen, property: replacementProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )

    registerECOOPPair(
        name: "Parser", gen: parserLangGen.gen, property: parserProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed, sizeMetric: parserSize
    )
    registerECOOPPair(
        name: "GraphColoring", gen: graphColoringGen.gen, property: graphColoringProperty,
        config: config, seedCount: seedCount, baseSeed: baseSeed
    )
}

/// Registers a benchmark for a single challenge using the graph-based reducer.
///
/// One registration per `withStrategies` variant, all sharing the same base seed so per-seed results pair exactly. The first variant (the committed baseline) keeps the plain challenge name so its report blocks stay comparable across sessions; session variants are suffixed with the strategy name.
func registerECOOPPair<Output>(
    name: String,
    gen: Generator<Output>,
    property: @Sendable @escaping (Output) -> Bool,
    config: Interpreters.ReducerConfiguration,
    seedCount: Int,
    baseSeed: UInt64,
    maxGenerationRuns: UInt64 = 10000,
    sizeMetric: ((Output) -> Int)? = nil
) {
    for (strategyIndex, strategy) in withStrategies(config).enumerated() {
        registerECOOPChallenge(
            name: strategyIndex == 0 ? name : "\(name) [\(strategy.name)]",
            gen: gen,
            property: property,
            config: strategy.config,
            seedCount: seedCount,
            baseSeed: baseSeed,
            maxGenerationRuns: maxGenerationRuns,
            sizeMetric: sizeMetric
        )
    }
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
    let stepTimings: ReductionStats.StepTimings?
    let structuralFloorMotionEvents: Int
    let valueFloorMotionEvents: Int
    let valueFloorMotionNodeIDs: Set<Int>
    let redistributionAcceptanceNodeIDs: Set<Int>
    let couplingEdges: [CouplingEdge: Int]
    let floorMotionPartnerCounts: [Int: Int]
    let dispatchLog: [DispatchRecord]
}

// MARK: - Runner

private func registerECOOPChallenge<Output>(
    name: String,
    gen: Generator<Output>,
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

            let genStart = monotonicNanoseconds()
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
            let genEnd = monotonicNanoseconds()
            guard let value = failingValue, let tree = failingTree else { continue }
            let generationMs = Double(genEnd - genStart) / 1_000_000.0

            var invocationCount = 0
            let countingProperty: (Output) -> Bool = { candidate in
                invocationCount += 1
                return property(candidate)
            }
            let reduceStart = monotonicNanoseconds()
            // Use the *CollectingStats variants so we can pull
            // `stats.totalMaterializations` for the report. The reduced tuple has the same shape as the plain `*Reduce` return.
            let reduceResult = try? Interpreters.choiceGraphReduceCollectingStats(
                gen: gen,
                tree: tree,
                output: value,
                config: config,
                property: countingProperty
            )
            let reduceEnd = monotonicNanoseconds()
            let reductionMs = Double(reduceEnd - reduceStart) / 1_000_000.0

            let output = reduceResult?.outcome.counterexample?.1 ?? value
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
                encoderProbesRejectedByDecoder: reduceResult?.stats.encoderProbesRejectedByDecoder ?? [:],
                stepTimings: reduceResult?.stats.stepTimings,
                structuralFloorMotionEvents: reduceResult?.stats.structuralFloorMotionEvents ?? 0,
                valueFloorMotionEvents: reduceResult?.stats.valueFloorMotionEvents ?? 0,
                valueFloorMotionNodeIDs: reduceResult?.stats.valueFloorMotionNodeIDs ?? [],
                redistributionAcceptanceNodeIDs: reduceResult?.stats.redistributionAcceptanceNodeIDs ?? [],
                couplingEdges: reduceResult?.stats.couplingEdges ?? [:],
                floorMotionPartnerCounts: reduceResult?.stats.floorMotionPartnerCounts ?? [:],
                dispatchLog: reduceResult?.stats.dispatchLog ?? []
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

    let totalStructuralMotion = results.map(\.structuralFloorMotionEvents).reduce(0, +)
    let totalValueMotion = results.map(\.valueFloorMotionEvents).reduce(0, +)
    if totalStructuralMotion + totalValueMotion > 0 {
        let structStats = summaryStats(results.map { Double($0.structuralFloorMotionEvents) })
        let valueStats = summaryStats(results.map { Double($0.valueFloorMotionEvents) })
        print("[\(name) ECOOP] floor_motion: structural=\(totalStructuralMotion) (mean=\(f1(structStats.mean))) value=\(totalValueMotion) (mean=\(f1(valueStats.mean)))")
    }

    let seedsWithValueMotion = results.filter { $0.valueFloorMotionNodeIDs.isEmpty == false }
    if seedsWithValueMotion.isEmpty == false {
        var overlapCount = 0
        var motionOnlyCount = 0
        var redistOnlyCount = 0
        for result in seedsWithValueMotion {
            let overlap = result.valueFloorMotionNodeIDs.intersection(result.redistributionAcceptanceNodeIDs)
            let motionOnly = result.valueFloorMotionNodeIDs.subtracting(result.redistributionAcceptanceNodeIDs)
            let redistOnly = result.redistributionAcceptanceNodeIDs.subtracting(result.valueFloorMotionNodeIDs)
            overlapCount += overlap.count
            motionOnlyCount += motionOnly.count
            redistOnlyCount += redistOnly.count
        }
        let seedsWithRedist = seedsWithValueMotion.count(where: { $0.redistributionAcceptanceNodeIDs.isEmpty == false })
        print("[\(name) ECOOP] coupling_correlation: seeds_with_value_motion=\(seedsWithValueMotion.count) seeds_also_with_redist=\(seedsWithRedist) | nodes: overlap=\(overlapCount) motion_only=\(motionOnlyCount) redist_only=\(redistOnlyCount)")
    }

    var aggregatedEdges: [CouplingEdge: Int] = [:]
    for result in results {
        for (edge, count) in result.couplingEdges {
            aggregatedEdges[edge, default: 0] += count
        }
    }
    if aggregatedEdges.isEmpty == false {
        let sortedEdges = aggregatedEdges.sorted { $0.value > $1.value }
        let uniqueNodes = Set(sortedEdges.flatMap { [$0.key.motionNodeID, $0.key.changedNodeID] })
        print("[\(name) ECOOP] coupling_graph: \(sortedEdges.count) edges, \(uniqueNodes.count) nodes")
        for (edge, count) in sortedEdges {
            print("  \(edge.changedNodeID) -> \(edge.motionNodeID): \(count)")
        }
    }

    var aggregatedPartnerCounts: [Int: Int] = [:]
    for result in results {
        for (partnerCount, events) in result.floorMotionPartnerCounts {
            aggregatedPartnerCounts[partnerCount, default: 0] += events
        }
    }
    if aggregatedPartnerCounts.isEmpty == false {
        let sorted = aggregatedPartnerCounts.sorted { $0.key < $1.key }
        let total = sorted.map(\.value).reduce(0, +)
        let components = sorted.map { "\($0.key):\($0.value)" }.joined(separator: " ")
        print("[\(name) ECOOP] partner_count_distribution (partners:events, total=\(total)): \(components)")
    }

    // Per-encoder probe breakdown (summed across all seeds).
    // Per-encoder rejection breakdown:
    // Per-dispatch aggregation: the reservation-value table (R17) and the indexability signal (R14). A dispatch is one completed encoder pass; "prior accept" means an earlier pass in the same cycle of the same seed accepted at least one probe.
    let allDispatchLogs = results.map(\.dispatchLog).filter { $0.isEmpty == false }
    if allDispatchLogs.isEmpty == false {
        struct DispatchAggregate {
            var dispatches = 0
            var acceptingDispatches = 0
            var totalProbes = 0
            var totalLengthDeltaGivenAccept = 0
            var totalDistanceDeltaGivenAccept: Double = 0
            var probesGivenReject = 0
            var acceptsWithPrior = 0
            var dispatchesWithPrior = 0
            var acceptsWithoutPrior = 0
            var dispatchesWithoutPrior = 0
            var decoderRejectsWithPrior = 0
            var decoderRejectsWithoutPrior = 0
        }
        var aggregates: [EncoderName: DispatchAggregate] = [:]
        for log in allDispatchLogs {
            var cyclesWithAccept: Set<Int> = []
            for record in log {
                var aggregate = aggregates[record.encoderName, default: DispatchAggregate()]
                aggregate.dispatches += 1
                aggregate.totalProbes += record.probeCount
                let accepted = record.acceptCount > 0
                if accepted {
                    aggregate.acceptingDispatches += 1
                    aggregate.totalLengthDeltaGivenAccept += record.sequenceLengthDelta
                    aggregate.totalDistanceDeltaGivenAccept += record.targetDistanceDelta
                } else {
                    aggregate.probesGivenReject += record.probeCount
                }
                if cyclesWithAccept.contains(record.cycle) {
                    aggregate.dispatchesWithPrior += 1
                    aggregate.decoderRejectsWithPrior += record.decoderRejectCount
                    if accepted {
                        aggregate.acceptsWithPrior += 1
                    }
                } else {
                    aggregate.dispatchesWithoutPrior += 1
                    aggregate.decoderRejectsWithoutPrior += record.decoderRejectCount
                    if accepted {
                        aggregate.acceptsWithoutPrior += 1
                    }
                }
                aggregates[record.encoderName] = aggregate
                if accepted {
                    cyclesWithAccept.insert(record.cycle)
                }
            }
        }
        let rate: (Int, Int) -> String = { numerator, denominator in
            denominator == 0 ? "-" : String(format: "%.1f%%", 100.0 * Double(numerator) / Double(denominator))
        }
        let mean: (Int, Int) -> String = { total, count in
            count == 0 ? "-" : String(format: "%.1f", Double(total) / Double(count))
        }
        print("[\(name) ECOOP] dispatch_stats (per encoder: dispatches, accept rate, mean probes; given accept: mean len/dist improvement; given reject: mean probes):")
        for encoder in aggregates.keys.sorted(by: { (aggregates[$0]?.dispatches ?? 0) > (aggregates[$1]?.dispatches ?? 0) }) {
            guard let aggregate = aggregates[encoder] else {
                continue
            }
            let meanDistance = aggregate.acceptingDispatches == 0
                ? "-"
                : String(format: "%.4g", aggregate.totalDistanceDeltaGivenAccept / Double(aggregate.acceptingDispatches))
            let rejectingDispatches = aggregate.dispatches - aggregate.acceptingDispatches
            print("  \(encoder.rawValue): n=\(aggregate.dispatches) acc_rate=\(rate(aggregate.acceptingDispatches, aggregate.dispatches)) probes=\(mean(aggregate.totalProbes, aggregate.dispatches)) | acc_len=\(mean(aggregate.totalLengthDeltaGivenAccept, aggregate.acceptingDispatches)) acc_dist=\(meanDistance) | rej_probes=\(mean(aggregate.probesGivenReject, rejectingDispatches))")
        }
        print("[\(name) ECOOP] indexability (accept rate and decoder rejects with vs without a prior accept in the same cycle):")
        for encoder in aggregates.keys.sorted(by: { (aggregates[$0]?.dispatches ?? 0) > (aggregates[$1]?.dispatches ?? 0) }) {
            guard let aggregate = aggregates[encoder] else {
                continue
            }
            print("  \(encoder.rawValue): prior=\(rate(aggregate.acceptsWithPrior, aggregate.dispatchesWithPrior)) (n=\(aggregate.dispatchesWithPrior), rejDec=\(aggregate.decoderRejectsWithPrior)) none=\(rate(aggregate.acceptsWithoutPrior, aggregate.dispatchesWithoutPrior)) (n=\(aggregate.dispatchesWithoutPrior), rejDec=\(aggregate.decoderRejectsWithoutPrior))")
        }

        // Composed-spend attribution: whether the composed encoder's probes are many distinct binds each paying once (classification cost) or few binds re-paying within a seed (a gate defect). Groups composed dispatches by bind fingerprint within each seed; the redispatch distribution's key is dispatches per (seed, bind) pair.
        var composedDispatches = 0
        var composedAcceptingDispatches = 0
        var composedUpstreamLifts = 0
        var composedProbes = 0
        var composedCacheHits = 0
        var composedDecoderRejects = 0
        var seedsWithComposed = 0
        var distinctBindsPerSeedTotal = 0
        var allComposedFingerprints: Set<UInt64> = []
        var redispatchDistribution: [Int: Int] = [:]
        var verdictCounts: [String: Int] = [:]
        for log in allDispatchLogs {
            var dispatchesPerFingerprint: [UInt64: Int] = [:]
            for record in log where record.encoderName == .composed {
                composedDispatches += 1
                composedProbes += record.probeCount
                composedCacheHits += record.cacheHitCount
                composedDecoderRejects += record.decoderRejectCount
                composedUpstreamLifts += record.composedUpstreamLifts ?? 0
                if record.acceptCount > 0 {
                    composedAcceptingDispatches += 1
                }
                let verdict = record.bindClassification.map { "\($0.topology)/\($0.liftability)" } ?? "-"
                verdictCounts[verdict, default: 0] += 1
                if let fingerprint = record.boundValueFingerprint {
                    dispatchesPerFingerprint[fingerprint, default: 0] += 1
                    allComposedFingerprints.insert(fingerprint)
                }
            }
            if dispatchesPerFingerprint.isEmpty == false {
                seedsWithComposed += 1
                distinctBindsPerSeedTotal += dispatchesPerFingerprint.count
                for (_, dispatchCount) in dispatchesPerFingerprint {
                    redispatchDistribution[dispatchCount, default: 0] += 1
                }
            }
        }
        if composedDispatches > 0 {
            let redispatchComponents = redispatchDistribution.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            let verdictComponents = verdictCounts.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            print("[\(name) ECOOP] composed_spend (n=\(composedDispatches) accepting=\(composedAcceptingDispatches) lifts=\(composedUpstreamLifts) probes=\(composedProbes) cacheHits=\(composedCacheHits) rejDec=\(composedDecoderRejects)):")
            print("  seeds_with_composed=\(seedsWithComposed) distinct_binds_per_seed=\(mean(distinctBindsPerSeedTotal, seedsWithComposed)) distinct_binds_total=\(allComposedFingerprints.count) redispatch_per_bind (dispatches:seed-bind pairs): \(redispatchComponents) verdicts: \(verdictComponents)")
        }
    }

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

    // Per-step timing breakdown (summed across all seeds).
    let timingResults = results.compactMap(\.stepTimings)
    if timingResults.isEmpty == false {
        var totalSrc: UInt64 = 0
        var totalDisp: UInt64 = 0
        var totalEnc: UInt64 = 0
        var totalDec: UInt64 = 0
        var totalReb: UInt64 = 0
        var totalCC: UInt64 = 0
        var totalRlx: UInt64 = 0
        var totalRel: UInt64 = 0
        var totalReord: UInt64 = 0
        for timing in timingResults {
            totalSrc += timing.buildSources
            totalDisp += timing.dispatch
            totalEnc += timing.encode
            totalDec += timing.decode
            totalReb += timing.rebuild
            totalCC += timing.convergenceConfirmation
            totalRlx += timing.relaxRound
            totalRel += timing.relationPass
            totalReord += timing.reorder
        }
        var totalRebGraph: UInt64 = 0
        var totalRebSource: UInt64 = 0
        for timing in timingResults {
            totalRebGraph += timing.rebuildGraphNanoseconds
            totalRebSource += timing.rebuildSourceNanoseconds
        }
        let toMs: (UInt64) -> String = { String(format: "%.2f", Double($0) / 1_000_000) }
        let totalNs = totalSrc + totalDisp + totalEnc + totalDec + totalReb + totalCC + totalRlx + totalRel + totalReord
        print("[\(name) ECOOP] reducer timing (summed across \(timingResults.count) seeds): total=\(toMs(totalNs))ms src=\(toMs(totalSrc)) disp=\(toMs(totalDisp)) enc=\(toMs(totalEnc)) dec=\(toMs(totalDec)) reb=\(toMs(totalReb))(graph=\(toMs(totalRebGraph))/src=\(toMs(totalRebSource))) cc=\(toMs(totalCC)) rlx=\(toMs(totalRlx)) rel=\(toMs(totalRel)) reord=\(toMs(totalReord))")
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

    // Top seeds by materialization count.
    let worstSeeds = results.sorted { $0.materializations > $1.materializations }.prefix(5)
    if let worst = worstSeeds.first, worst.materializations > Int(matStats.mean * 2) {
        print("[\(name) ECOOP] highest-mat seeds:")
        for result in worstSeeds {
            print("  seed \(result.seed): mats=\(result.materializations) invocations=\(result.invocations) reduce=\(f2(result.reductionMilliseconds))ms CE=\(result.counterexampleDescription)")
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
