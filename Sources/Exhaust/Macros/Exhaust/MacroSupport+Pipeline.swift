// Pipeline phases for `__exhaust`: screening and sampling orchestration.

import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

#if canImport(XCTest) && canImport(ObjectiveC)
    @preconcurrency @_weakLinked import XCTest
#elseif canImport(XCTest)
    @preconcurrency import XCTest
#endif

package extension __ExhaustRuntime {
    // MARK: - Pipeline Context

    /// Bundles parameters shared across screening, sampling, and reduction phases.
    struct PipelineContext<Output> {
        let gen: Generator<Output>
        let property: @Sendable (Output) -> Bool
        let samplingBudget: UInt64
        let reductionConfig: Interpreters.ReducerConfiguration
        let visualize: Bool
        let suppressIssueReporting: Bool
        let includeDiff: Bool
        let parallelLanes: UInt8
        let logFormat: LogFormat
        let fileID: StaticString
        let filePath: StaticString
        let line: UInt
        let column: UInt
        let statsAccumulator: OpenPBTStatsAccumulator?
        let skipCounter: SkipCounter?

        /// The skip count accumulated so far, for phase-delta accounting. Skips land on the shared counter from any lane, so a delta taken outside a concurrent section is exact.
        var skipCount: Int {
            skipCounter?.count ?? 0
        }
    }

    /// Represents the outcome of the screening phase: failure found, exhaustive pass, or proceed to sampling.
    enum ScreeningOutcome<Output> {
        case counterexample(Output)
        case exhaustivePass
        case proceed
    }

    /// Represents the outcome of the reduction phase: reduced counterexample, unreduced original, or error.
    enum ReduceOutcome<Output> {
        case reduced(Output)
        case unreduced(Output)
        case reductionError
    }

    // MARK: - Screening Phase

    /// Runs the structured covering-array phase, returning early on first failure.
    static func runScreeningPhase<Output>(
        context: PipelineContext<Output>,
        screeningBudget: UInt64,
        skipToRow: Int? = nil,
        report: inout ExhaustReport,
        ledger: inout RunLedger
    ) -> ScreeningOutcome<Output> {
        let skipsBefore = context.skipCount
        let screeningResult = ScreeningRunner.run(
            context.gen,
            screeningBudget: screeningBudget,
            skipToRow: skipToRow,
            property: context.property,
            onExample: context.statsAccumulator.map { accumulator in
                { value, tree, passed in
                    var representation = ""
                    customDump(value, to: &representation, maxDepth: 3)
                    accumulator.record(representation: representation, passed: passed, tree: tree, phase: .screening)
                }
            }
        )
        report.applyScreeningRows(screeningResult.summary)
        let screeningFailures = switch screeningResult {
            case .failure:
                1
            case .exhaustive, .partial, .notApplicable:
                0
        }
        ledger.record(
            .screening,
            invocations: screeningResult.summary.propertyInvocations,
            skips: context.skipCount - skipsBefore,
            failures: screeningFailures
        )
        switch screeningResult {
            case let .failure(value, tree, rowOrdinal, _, strength, rows, parameters, totalSpace, kind):
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "screening_failure",
                    metadata: [
                        "row_ordinal": "\(rowOrdinal)",
                        "strength": "\(strength)",
                        "covering_rows": "\(rows)",
                        "screening_rows": "\(report.screeningRows)",
                        "property_invocations": "\(report.screeningInvocations)",
                        "rejected_rows": "\(report.screeningRejectedRows)",
                        "parameters": "\(parameters)",
                        "total_space": "\(totalSpace)",
                        "kind": kind,
                    ]
                )
                let reductionTree = switch Materializer.materialize(
                    context.gen, prefix: ChoiceSequence.flatten(tree), mode: .exact, fallbackTree: tree, materializePicks: true
                ) {
                    case let .success(_, rematerialized, _):
                        rematerialized
                    case .rejected, .failed:
                        tree
                }
                let screeningReplaySeed = ReplaySeed.Resolved.screening(row: rowOrdinal - 1).encoded
                report.replaySeed = screeningReplaySeed
                let result = reduceAndReport(
                    context: context,
                    value: value,
                    tree: reductionTree,
                    seed: nil,
                    iteration: rowOrdinal,
                    phaseBudget: screeningBudget,
                    replayHint: "Reproduce: .replay(\"\(screeningReplaySeed)\")",
                    report: &report,
                    ledger: &ledger
                )
                switch result {
                    case let .reduced(counterexample):
                        return .counterexample(counterexample)
                    case let .unreduced(counterexample):
                        return .counterexample(counterexample)
                    case .reductionError:
                        return .proceed
                }

            case let .exhaustive(summary):
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "tway_coverage",
                    metadata: [
                        "exhaustive": "true",
                        "screening_rows": "\(summary.rowAttempts)",
                        "property_invocations": "\(summary.propertyInvocations)",
                        "rejected_rows": "\(summary.rejectedRows)",
                    ]
                )
                let passMetadata = [
                    "screening_rows": "\(summary.rowAttempts)",
                    "property_invocations": "\(summary.propertyInvocations)",
                    "rejected_rows": "\(summary.rejectedRows)",
                ]
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "property_passed",
                    metadata: passMetadata
                )
                return .exhaustivePass

            case let .partial(summary, strength, rows, parameters, totalSpace, kind):
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "tway_coverage",
                    metadata: [
                        "strength": "\(strength)",
                        "covering_rows": "\(rows)",
                        "screening_rows": "\(summary.rowAttempts)",
                        "property_invocations": "\(summary.propertyInvocations)",
                        "rejected_rows": "\(summary.rejectedRows)",
                        "total_space": "\(totalSpace)",
                        "parameters": "\(parameters)",
                        "exhaustive": "false",
                        "kind": kind,
                    ]
                )
                return .proceed

            case .notApplicable:
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "screening_not_applicable",
                    "Generator not analyzable for screening"
                )
                return .proceed
        }
    }

    // MARK: - Sampling Batch

    /// Outcome of a single sampling batch (sequential or one lane of a parallel run).
    struct BatchResult<Output> {
        var failure: (value: Output, tree: ChoiceTree, absoluteIteration: Int)?
        var iterations: Int = 0
        var filterObservations: [UInt64: FilterObservation] = [:]
        var statsLines: [OpenPBTStatsLine] = []
        var error: (any Error)?
        var uniqueExhaustionTruncatedRun = false
    }

    /// Runs a contiguous range of sampling iterations, returning the first failure (if any).
    ///
    /// Used by both the sequential and parallel sampling paths. Each call creates its own ``ValueAndChoiceTreeInterpreter`` covering indices `startIndex ..< startIndex + count`, with an independent PRNG derived from `baseSeed`.
    ///
    /// - Parameters:
    ///   - gen: The generator to sample from.
    ///   - property: The property to check each generated value against.
    ///   - baseSeed: Root seed for per-run PRNG derivation. All lanes share the same base seed.
    ///   - startIndex: Absolute run index for the first iteration in this batch.
    ///   - count: Number of iterations to run in this batch.
    ///   - lane: Batch index for stats attribution, or `nil` for sequential runs.
    ///   - statsPropertyName: Property name passed to the per-batch ``OpenPBTStatsAccumulator``, or `nil` to skip stats collection.
    ///   - canceled: Shared flag checked before each iteration. Set to `true` by the first lane to find a failure.
    private static func runSamplingBatch<Output>( // swiftlint:disable:this function_body_length
        gen: Generator<Output>,
        property: @Sendable (Output) -> Bool,
        baseSeed: UInt64,
        startIndex: UInt64,
        count: UInt64,
        lane: Int?,
        statsPropertyName: String?,
        canceled: some CancellationFlag
    ) -> BatchResult<Output> {
        var result = BatchResult<Output>()
        let statsAccumulator: OpenPBTStatsAccumulator? = statsPropertyName.map {
            OpenPBTStatsAccumulator(propertyName: $0, lane: lane)
        }
        var interpreter = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: statsAccumulator != nil,
            seed: baseSeed,
            maxRuns: startIndex + count,
            initialRunIndex: startIndex
        )
        do {
            if let statsAccumulator {
                var previousTotalAttempts = 0
                var previousTotalPasses = 0
                while canceled.isCancelled == false {
                    let generateStart = monotonicNanoseconds()
                    guard let (next, tree) = try interpreter.next() else { break }
                    let generateEnd = monotonicNanoseconds()
                    result.iterations += 1

                    var currentTotalAttempts = 0
                    var currentTotalPasses = 0
                    for (_, observation) in interpreter.filterObservations {
                        currentTotalAttempts += observation.attempts
                        currentTotalPasses += observation.passes
                    }
                    let deltaAttempts = currentTotalAttempts - previousTotalAttempts
                    let deltaPasses = currentTotalPasses - previousTotalPasses
                    previousTotalAttempts = currentTotalAttempts
                    previousTotalPasses = currentTotalPasses
                    var filterAttempts: Int?
                    var filterRejections: Int?
                    if deltaAttempts > 0 {
                        filterAttempts = deltaAttempts
                        filterRejections = deltaAttempts - deltaPasses
                    }

                    let testStart = monotonicNanoseconds()
                    let passed = property(next)
                    let testEnd = monotonicNanoseconds()

                    let generateSeconds = Double(generateEnd - generateStart) / 1_000_000_000
                    let testSeconds = Double(testEnd - testStart) / 1_000_000_000
                    var representation = ""
                    customDump(next, to: &representation, maxDepth: 3)
                    if let rejections = filterRejections, rejections > 0 {
                        statsAccumulator.recordDiscards(count: rejections, phase: .random)
                    }
                    statsAccumulator.record(
                        representation: representation,
                        passed: passed,
                        tree: tree,
                        phase: .random,
                        generateSeconds: generateSeconds,
                        testSeconds: testSeconds,
                        filterAttempts: filterAttempts,
                        filterRejections: filterRejections
                    )

                    if passed == false {
                        let absoluteIteration = Int(startIndex) + result.iterations
                        result.failure = (value: next, tree: tree, absoluteIteration: absoluteIteration)
                        canceled.isCancelled = true
                        break
                    }
                }
                result.statsLines = statsAccumulator.finalize()
            } else {
                while canceled.isCancelled == false {
                    guard let next = try interpreter.nextValueOnly() else { break }
                    result.iterations += 1

                    if property(next) == false {
                        let absoluteIteration = Int(startIndex) + result.iterations
                        let tree = try interpreter.reproduceFailureTree()
                        result.failure = (value: next, tree: tree, absoluteIteration: absoluteIteration)
                        canceled.isCancelled = true
                        break
                    }
                }
            }
        } catch {
            result.error = error
        }

        result.filterObservations = interpreter.filterObservations
        result.uniqueExhaustionTruncatedRun = interpreter.uniqueExhaustionTruncatedRun
        return result
    }

    // MARK: - Single-Lane Fast Path

    /// Tight generation loop for single-lane, no-stats runs.
    ///
    /// Bypasses the ``BatchResult`` / ``runSamplingBatch`` / merge machinery to avoid heap allocations and per-iteration indirection that are only needed for parallel or stats-collecting runs.
    private static func runSingleLaneSampling<Output>(
        context: PipelineContext<Output>,
        baseSeed: UInt64,
        replayIteration: Int?,
        generationPhaseStart: UInt64,
        report: inout ExhaustReport,
        ledger: inout RunLedger
    ) -> Output? {
        let startIndex = replayIteration.map { UInt64($0 - 1) } ?? 0
        let maxRuns = replayIteration.map { UInt64($0) } ?? context.samplingBudget
        var interpreter = ValueAndChoiceTreeInterpreter(
            context.gen,
            materializePicks: false,
            seed: baseSeed,
            maxRuns: maxRuns,
            initialRunIndex: startIndex
        )
        var iterations = 0
        let skipsBefore = context.skipCount

        do {
            while let next = try interpreter.nextValueOnly() {
                iterations += 1
                if context.property(next) == false {
                    // Sampling outcomes are recorded before reduction runs so reduction-phase skips stay out of the sampling delta.
                    ledger.record(
                        .sampling,
                        invocations: iterations,
                        skips: context.skipCount - skipsBefore,
                        failures: 1
                    )
                    let tree = try interpreter.reproduceFailureTree()
                    report.generationMilliseconds = Double(monotonicNanoseconds() - generationPhaseStart) / 1_000_000
                    emitFilterWarnings(interpreter.filterObservations, context: context)

                    let absoluteIteration = Int(startIndex) + iterations
                    let result = reduceAndReport(
                        context: context,
                        value: next,
                        tree: tree,
                        seed: baseSeed,
                        iteration: absoluteIteration,
                        phaseBudget: context.samplingBudget,
                        replayHint: nil,
                        report: &report,
                        ledger: &ledger
                    )
                    switch result {
                        case let .reduced(counterexample):
                            return counterexample
                        case let .unreduced(counterexample):
                            return counterexample
                        case .reductionError:
                            return next
                    }
                }
            }
        } catch {
            report.generationErrorOccurred = true
            reportError(
                localizedErrorMessage(error),
                fileID: context.fileID,
                filePath: context.filePath,
                line: context.line,
                column: context.column
            )
        }

        ledger.record(
            .sampling,
            invocations: iterations,
            skips: context.skipCount - skipsBefore
        )
        report.generationMilliseconds = Double(monotonicNanoseconds() - generationPhaseStart) / 1_000_000
        emitFilterWarnings(interpreter.filterObservations, context: context)
        if interpreter.uniqueExhaustionTruncatedRun {
            recordUniqueExhaustion(iterations: iterations, context: context, report: &report)
        }
        return nil
    }

    /// Records a unique-exhaustion truncation in the report and surfaces it as a warning.
    ///
    /// Exhaustion inside the interpreter only logs at warning level, which the default configuration never prints, so a run that executed a fraction of its budget would otherwise pass with no signal.
    private static func recordUniqueExhaustion(
        iterations: Int,
        context: PipelineContext<some Any>,
        report: inout ExhaustReport
    ) {
        report.runTruncatedByUniqueExhaustion = true
        let message = "A unique site exhausted its retry budget after \(iterations) of \(context.samplingBudget) sampling iterations. The remaining iterations did not run."
        report.uniqueExhaustionWarning = message
        if context.suppressIssueReporting == false {
            reportWarning(
                message,
                fileID: context.fileID,
                filePath: context.filePath,
                line: context.line,
                column: context.column
            )
        }
    }

    /// Emits filter validity warnings when the rejection rate exceeds 98%.
    private static func emitFilterWarnings(
        _ observations: [UInt64: FilterObservation],
        context: PipelineContext<some Any>
    ) {
        guard context.suppressIssueReporting == false else { return }
        for (_, observation) in observations where observation.attempts >= 20 {
            if observation.validityRate < 0.02, let location = observation.sourceLocation {
                reportWarning(
                    "Filter validity rate \(String(format: "%.1f", observation.validityRate * 100))% over \(observation.attempts) attempts. Generation is spending most of its time on rejection. Consider widening the input range or relaxing the predicate.",
                    fileID: location.fileID,
                    filePath: location.filePath,
                    line: location.line,
                    column: location.column
                )
            }
        }
    }

    // MARK: - Sampling Phase

    /// Runs the random sampling phase after screening completes.
    ///
    /// When `context.parallelLanes` is greater than one, splits the budget across multiple GCD threads (one per lane). Otherwise runs sequentially.
    static func runSamplingPhase<Output>( // swiftlint:disable:this function_body_length
        context: PipelineContext<Output>,
        seed: UInt64?,
        replayIteration: Int? = nil,
        report: inout ExhaustReport,
        ledger: inout RunLedger
    ) -> Output? {
        let generationPhaseStart = monotonicNanoseconds()

        let baseSeed = seed ?? Xoshiro256().seed
        report.seed = baseSeed

        let laneCount = seed == nil ? max(1, Int(context.parallelLanes)) : 1

        if laneCount <= 1, context.statsAccumulator == nil {
            return runSingleLaneSampling(
                context: context,
                baseSeed: baseSeed,
                replayIteration: replayIteration,
                generationPhaseStart: generationPhaseStart,
                report: &report,
                ledger: &ledger
            )
        }

        let baseIterationsPerLane = context.samplingBudget / UInt64(laneCount)
        let remainder = context.samplingBudget - baseIterationsPerLane * UInt64(laneCount)
        let statsPropertyName: String? = context.statsAccumulator != nil
            ? "\(context.fileID)"
            : nil

        let skipsBefore = context.skipCount
        let batchResults: [BatchResult<Output>]
        if laneCount <= 1 {
            let replayStartIndex = replayIteration.map { UInt64($0 - 1) } ?? 0
            let singleResult = runSamplingBatch(
                gen: context.gen,
                property: context.property,
                baseSeed: baseSeed,
                startIndex: replayStartIndex,
                count: context.samplingBudget,
                lane: nil,
                statsPropertyName: statsPropertyName,
                canceled: UnsafeSendableBox(false)
            )
            batchResults = [singleResult]
        } else {
            let canceled = SendableBox(false)
            nonisolated(unsafe) let unsafeContext = context

            let resultStorage = SendableBox<[BatchResult<Output>?]>(
                Array(repeating: nil, count: laneCount)
            )
            DispatchQueue.concurrentPerform(iterations: laneCount) { laneIndex in
                let startIndex = UInt64(laneIndex) * baseIterationsPerLane
                let iterationsForLane = baseIterationsPerLane + (laneIndex == laneCount - 1 ? remainder : 0)
                nonisolated(unsafe) let batchResult = runSamplingBatch(
                    gen: unsafeContext.gen,
                    property: unsafeContext.property,
                    baseSeed: baseSeed,
                    startIndex: startIndex,
                    count: iterationsForLane,
                    lane: laneIndex,
                    statsPropertyName: statsPropertyName,
                    canceled: canceled
                )
                resultStorage.withValue { $0[laneIndex] = batchResult }
            }
            batchResults = resultStorage.value.compactMap(\.self)
        }

        // Merge filter observations and emit warnings.
        var mergedFilterObservations: [UInt64: FilterObservation] = [:]
        for batch in batchResults {
            for (fingerprint, observation) in batch.filterObservations {
                mergedFilterObservations[fingerprint, default: FilterObservation()].merge(observation)
            }
        }
        if context.suppressIssueReporting == false {
            for (_, observation) in mergedFilterObservations where observation.attempts >= 20 {
                if observation.validityRate < 0.02, let location = observation.sourceLocation {
                    reportWarning(
                        "Filter validity rate \(String(format: "%.1f", observation.validityRate * 100))% over \(observation.attempts) attempts. Generation is spending most of its time on rejection. Consider widening the input range or relaxing the predicate.",
                        fileID: location.fileID,
                        filePath: location.filePath,
                        line: location.line,
                        column: location.column
                    )
                }
            }
        }

        // Merge stats lines into the parent accumulator.
        if let statsAccumulator = context.statsAccumulator {
            for batch in batchResults {
                statsAccumulator.appendLines(batch.statsLines)
            }
        }

        // Report first error from any batch.
        for batch in batchResults {
            if let error = batch.error {
                report.generationErrorOccurred = true
                reportError(
                    localizedErrorMessage(error),
                    fileID: context.fileID,
                    filePath: context.filePath,
                    line: context.line,
                    column: context.column
                )
            }
        }

        // Find the failure with the lowest absolute iteration (deterministic winner).
        // The skip delta is taken after all lanes have joined, so it is exact even though lanes share one counter. Each lane stops at its first failure, so failing invocations equal failing lanes.
        let totalIterations = batchResults.reduce(0) { $0 + $1.iterations }
        ledger.record(
            .sampling,
            invocations: totalIterations,
            skips: context.skipCount - skipsBefore,
            failures: batchResults.count(where: { $0.failure != nil })
        )
        let winningFailure = batchResults
            .compactMap(\.failure)
            .min(by: { $0.absoluteIteration < $1.absoluteIteration })

        guard let failure = winningFailure else {
            report.generationMilliseconds = Double(monotonicNanoseconds() - generationPhaseStart) / 1_000_000
            if batchResults.contains(where: \.uniqueExhaustionTruncatedRun) {
                recordUniqueExhaustion(iterations: totalIterations, context: context, report: &report)
            }
            return nil
        }

        report.generationMilliseconds = Double(monotonicNanoseconds() - generationPhaseStart) / 1_000_000
        let result = reduceAndReport(
            context: context,
            value: failure.value,
            tree: failure.tree,
            seed: baseSeed,
            iteration: failure.absoluteIteration,
            phaseBudget: context.samplingBudget,
            replayHint: nil,
            report: &report,
            ledger: &ledger
        )
        switch result {
            case let .reduced(counterexample):
                return counterexample
            case let .unreduced(counterexample):
                return counterexample
            case .reductionError:
                return failure.value
        }
    }
}
