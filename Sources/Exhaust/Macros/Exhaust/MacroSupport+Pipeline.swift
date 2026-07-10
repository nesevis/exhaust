// Pipeline phases for `__exhaust`: screening, sampling, shared reduction, and async/detection bridge helpers.

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
    }

    /// Represents the outcome of the screening phase: failure found, exhaustive pass, or proceed to sampling.
    enum ScreeningOutcome<Output> {
        case counterexample(Output)
        case exhaustivePass(iterations: Int)
        case proceed(screeningIterations: Int)
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
        report: inout ExhaustReport
    ) -> ScreeningOutcome<Output> {
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
        switch screeningResult {
            case let .failure(value, tree, iteration, strength, rows, parameters, totalSpace, kind):
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "screening_failure",
                    metadata: [
                        "iteration": "\(iteration)",
                        "strength": "\(strength)",
                        "covering_rows": "\(rows)",
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
                let screeningReplaySeed = ReplaySeed.Resolved.screening(row: iteration - 1).encoded
                report.replaySeed = screeningReplaySeed
                let result = reduceAndReport(
                    context: context,
                    value: value,
                    tree: reductionTree,
                    seed: nil,
                    iteration: iteration,
                    phaseBudget: screeningBudget,
                    screeningIterations: iteration,
                    randomSamplingIterations: 0,
                    replayHint: "Reproduce: .replay(\"\(screeningReplaySeed)\")",
                    report: &report
                )
                switch result {
                    case let .reduced(counterexample):
                        return .counterexample(counterexample)
                    case let .unreduced(counterexample):
                        return .counterexample(counterexample)
                    case .reductionError:
                        return .proceed(screeningIterations: iteration)
                }

            case let .exhaustive(iterations):
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "tway_coverage",
                    metadata: [
                        "exhaustive": "true",
                        "iterations": "\(iterations)",
                    ]
                )
                let passMetadata = [
                    "iterations": "\(iterations)",
                    "property_invocations": "\(iterations)",
                ]
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "property_passed",
                    metadata: passMetadata
                )
                report.setInvocations(
                    screening: iterations,
                    randomSampling: 0,
                    reduction: 0
                )
                return .exhaustivePass(iterations: iterations)

            case let .partial(iterations, strength, rows, parameters, totalSpace, kind):
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "tway_coverage",
                    metadata: [
                        "strength": "\(strength)",
                        "covering_rows": "\(rows)",
                        "iterations": "\(iterations)",
                        "total_space": "\(totalSpace)",
                        "parameters": "\(parameters)",
                        "exhaustive": "false",
                        "kind": kind,
                    ]
                )
                return .proceed(screeningIterations: iterations)

            case .notApplicable:
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "screening_not_applicable",
                    "Generator not analyzable for screening"
                )
                return .proceed(screeningIterations: 0)
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
    ///   - cancelled: Shared flag checked before each iteration. Set to `true` by the first lane to find a failure.
    private static func runSamplingBatch<Output>( // swiftlint:disable:this function_body_length
        gen: Generator<Output>,
        property: @Sendable (Output) -> Bool,
        baseSeed: UInt64,
        startIndex: UInt64,
        count: UInt64,
        lane: Int?,
        statsPropertyName: String?,
        cancelled: some CancellationFlag
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
                while cancelled.isCancelled == false {
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
                        cancelled.isCancelled = true
                        break
                    }
                }
                result.statsLines = statsAccumulator.finalize()
            } else {
                while cancelled.isCancelled == false {
                    guard let next = try interpreter.nextValueOnly() else { break }
                    result.iterations += 1

                    if property(next) == false {
                        let absoluteIteration = Int(startIndex) + result.iterations
                        let tree = try interpreter.reproduceFailureTree()
                        result.failure = (value: next, tree: tree, absoluteIteration: absoluteIteration)
                        cancelled.isCancelled = true
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
        screeningIterations: Int,
        report: inout ExhaustReport
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

        do {
            while let next = try interpreter.nextValueOnly() {
                iterations += 1
                if context.property(next) == false {
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
                        screeningIterations: screeningIterations,
                        randomSamplingIterations: iterations,
                        replayHint: nil,
                        report: &report
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

        report.generationMilliseconds = Double(monotonicNanoseconds() - generationPhaseStart) / 1_000_000
        emitFilterWarnings(interpreter.filterObservations, context: context)
        if interpreter.uniqueExhaustionTruncatedRun {
            recordUniqueExhaustion(iterations: iterations, context: context, report: &report)
        }
        report.setInvocations(
            screening: screeningIterations,
            randomSampling: iterations,
            reduction: 0
        )
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
        screeningIterations: Int,
        report: inout ExhaustReport
    ) -> Output? {
        let generationPhaseStart = monotonicNanoseconds()

        let baseSeed: UInt64
        if let seed {
            baseSeed = seed
        } else {
            baseSeed = Xoshiro256().seed
        }
        report.seed = baseSeed

        let laneCount = seed == nil ? max(1, Int(context.parallelLanes)) : 1

        if laneCount <= 1, context.statsAccumulator == nil {
            return runSingleLaneSampling(
                context: context,
                baseSeed: baseSeed,
                replayIteration: replayIteration,
                generationPhaseStart: generationPhaseStart,
                screeningIterations: screeningIterations,
                report: &report
            )
        }

        let baseIterationsPerLane = context.samplingBudget / UInt64(laneCount)
        let remainder = context.samplingBudget - baseIterationsPerLane * UInt64(laneCount)
        let statsPropertyName: String? = context.statsAccumulator != nil
            ? "\(context.fileID)"
            : nil

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
                cancelled: UnsafeSendableBox(false)
            )
            batchResults = [singleResult]
        } else {
            let cancelled = SendableBox(false)
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
                    cancelled: cancelled
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
        let totalIterations = batchResults.reduce(0) { $0 + $1.iterations }
        let winningFailure = batchResults
            .compactMap(\.failure)
            .min(by: { $0.absoluteIteration < $1.absoluteIteration })

        guard let failure = winningFailure else {
            report.generationMilliseconds = Double(monotonicNanoseconds() - generationPhaseStart) / 1_000_000
            if batchResults.contains(where: \.uniqueExhaustionTruncatedRun) {
                recordUniqueExhaustion(iterations: totalIterations, context: context, report: &report)
            }
            report.setInvocations(
                screening: screeningIterations,
                randomSampling: totalIterations,
                reduction: 0
            )
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
            screeningIterations: screeningIterations,
            randomSamplingIterations: totalIterations,
            replayHint: nil,
            report: &report
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

    // MARK: - Shared Reduction

    /// Reduces a failing counterexample and reports the result.
    static func reduceAndReport<Output>( // swiftlint:disable:this function_parameter_count
        context: PipelineContext<Output>,
        value: Output,
        tree: ChoiceTree,
        seed: UInt64?,
        iteration: Int,
        phaseBudget: UInt64,
        screeningIterations: Int,
        randomSamplingIterations: Int,
        replayHint: String?,
        report: inout ExhaustReport
    ) -> ReduceOutcome<Output> {
        var propertyInvocationCount = 0
        let countingProperty: (Output) -> Bool = { value in
            propertyInvocationCount += 1
            return context.property(value)
        }
        let reductionStart = monotonicNanoseconds()
        do {
            var reducerConfig = context.reductionConfig
            reducerConfig.visualize = context.visualize
            let reduceResult = try Interpreters.choiceGraphReduceCollectingStats(
                gen: context.gen,
                tree: tree,
                output: value,
                config: reducerConfig,
                property: countingProperty
            )
            report.applyReductionStats(reduceResult.stats)
            report.reductionMilliseconds = Double(monotonicNanoseconds() - reductionStart) / 1_000_000
            if case let .reduced(reducedSequence, _, reducedValue) = reduceResult.outcome {
                let totalInvocations = screeningIterations + randomSamplingIterations + propertyInvocationCount
                var failure = PropertyTestFailure(
                    counterexample: reducedValue,
                    original: value,

                    seed: seed,
                    iteration: iteration,
                    phaseBudget: phaseBudget,
                    blueprint: reducedSequence.shortString,
                    propertyInvocations: totalInvocations,
                    reducedSequence: reducedSequence
                )
                failure.replayHint = replayHint
                failure.reductionWasCapped = report.reductionWasCapped
                failure.includeDiff = context.includeDiff
                let rendered = failure.render(format: context.logFormat)
                report.renderedFailure = rendered
                report.replaySeed = failure.encodedReplaySeed
                ExhaustLog.debug(
                    category: .propertyTest,
                    event: "reduced_blueprint",
                    "\(reducedSequence.shortString)"
                )
                report.setInvocations(
                    screening: screeningIterations,
                    randomSampling: randomSamplingIterations,
                    reduction: propertyInvocationCount
                )
                if let statsAccumulator = context.statsAccumulator {
                    var representation = ""
                    customDump(reducedValue, to: &representation, maxDepth: 3)
                    statsAccumulator.recordReduced(
                        representation: representation,
                        tree: .just,
                        reductionSeconds: report.reductionMilliseconds / 1000
                    )
                }
                if context.suppressIssueReporting == false {
                    reportError(
                        rendered,
                        fileID: context.fileID,
                        filePath: context.filePath,
                        line: context.line,
                        column: context.column
                    )
                }
                return .reduced(reducedValue)
            }
        } catch {
            reportError(
                localizedErrorMessage(error),
                fileID: context.fileID,
                filePath: context.filePath,
                line: context.line,
                column: context.column
            )
            report.setInvocations(
                screening: screeningIterations,
                randomSampling: randomSamplingIterations,
                reduction: propertyInvocationCount
            )
            return .reductionError
        }

        // Reduction ran but could not improve
        let totalInvocationsUnreduced = screeningIterations + randomSamplingIterations + propertyInvocationCount
        var failure = PropertyTestFailure(
            counterexample: value,
            original: nil as Output?,
            seed: seed,
            iteration: iteration,
            phaseBudget: phaseBudget,
            blueprint: nil,
            propertyInvocations: totalInvocationsUnreduced
        )
        failure.replayHint = replayHint
        failure.reductionProducedNoImprovement = true
        // Reflected inputs (the other no-improvement site) deliberately do not set this: a user-supplied example is often already minimal, and warning "may not be minimal" there would be noise.
        failure.reductionStalled = report.reductionStalled
        let rendered = failure.render(format: context.logFormat)
        report.renderedFailure = rendered
        report.replaySeed = failure.encodedReplaySeed
        if context.suppressIssueReporting == false {
            reportError(
                rendered,
                fileID: context.fileID,
                filePath: context.filePath,
                line: context.line,
                column: context.column
            )
        }
        report.setInvocations(
            screening: screeningIterations,
            randomSampling: randomSamplingIterations,
            reduction: propertyInvocationCount
        )
        return .unreduced(value)
    }

    // MARK: - Reflecting

    // swiftlint:disable:next function_parameter_count
    /// Reduces a counterexample using reflection to seed the reducer.
    static func __reduceReflected<Output>(
        _ gen: Generator<Output>,
        value: Output,
        reductionConfig: Interpreters.ReducerConfiguration,
        visualize: Bool,
        suppressIssueReporting: Bool,
        includeDiff: Bool,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        property: @Sendable (Output) -> Bool,
        report: inout ExhaustReport
    ) throws -> Output? {
        let reflectStart = monotonicNanoseconds()

        guard property(value) == false else {
            let message = "reflecting: value passes the property — reduction requires a failing value"
            if suppressIssueReporting == false {
                reportError(
                    message,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
            report.setInvocations(screening: 0, randomSampling: 0, reduction: 1)
            return nil
        }

        guard let tree = try Interpreters.reflect(gen, with: value) else {
            let message = "reflecting: could not reflect value into choice tree"
            if suppressIssueReporting == false {
                reportError(
                    message,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
            report.setInvocations(screening: 0, randomSampling: 0, reduction: 1)
            return nil
        }

        let reflectionEnd = monotonicNanoseconds()

        var propertyInvocationCount = 0
        let countingProperty: (Output) -> Bool = { value in
            propertyInvocationCount += 1
            return property(value)
        }
        var reducerConfig = reductionConfig
        reducerConfig.visualize = visualize
        let reduceResult = try Interpreters.choiceGraphReduceCollectingStats(
            gen: gen,
            tree: tree,
            output: value,
            config: reducerConfig,
            property: countingProperty
        )
        report.applyReductionStats(reduceResult.stats)

        if case let .reduced(reducedSequence, _, reducedValue) = reduceResult.outcome {
            var failure = PropertyTestFailure(
                counterexample: reducedValue,
                original: value,
                seed: nil,
                iteration: 1,
                phaseBudget: 1,
                blueprint: reducedSequence.shortString,
                propertyInvocations: propertyInvocationCount
            )
            failure.replayHint = "No replay seed — counterexample found via reflection."
            failure.includeDiff = includeDiff
            let rendered = failure.render(format: ExhaustLog.configuration.format)
            report.renderedFailure = rendered
            let reductionEnd = monotonicNanoseconds()
            let reflectionMs = Double(reflectionEnd - reflectStart) / 1_000_000
            let reductionMs = Double(reductionEnd - reflectionEnd) / 1_000_000
            let totalMs = Double(reductionEnd - reflectStart) / 1_000_000
            ExhaustLog.notice(
                category: .propertyTest,
                event: "phase_timing",
                metadata: [
                    "reflection_ms": String(format: "%.1f", reflectionMs),
                    "reduction_ms": String(format: "%.1f", reductionMs),
                    "total_ms": String(format: "%.1f", totalMs),
                ]
            )
            report.reflectionMilliseconds = reflectionMs
            report.reductionMilliseconds = reductionMs
            report.totalMilliseconds = totalMs
            report.setInvocations(
                screening: 0,
                randomSampling: 0,
                reduction: 1 + propertyInvocationCount
            )
            if suppressIssueReporting == false {
                reportError(
                    rendered,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
            return reducedValue
        }

        // Reflection succeeded but reduction could not improve — return original
        var failure = PropertyTestFailure(
            counterexample: value,
            original: nil as Output?,
            seed: nil,
            iteration: 1,
            phaseBudget: 1,
            blueprint: nil,
            propertyInvocations: propertyInvocationCount
        )
        failure.replayHint = "No replay seed — counterexample found via reflection."
        failure.reductionProducedNoImprovement = true
        let rendered = failure.render(format: ExhaustLog.configuration.format)
        report.renderedFailure = rendered
        let reductionEnd = monotonicNanoseconds()
        let reflectionMs = Double(reflectionEnd - reflectStart) / 1_000_000
        let reductionMs = Double(reductionEnd - reflectionEnd) / 1_000_000
        let totalMs = Double(reductionEnd - reflectStart) / 1_000_000
        ExhaustLog.notice(
            category: .propertyTest,
            event: "phase_timing",
            metadata: [
                "reflection_ms": String(format: "%.1f", reflectionMs),
                "reduction_ms": String(format: "%.1f", reductionMs),
                "total_ms": String(format: "%.1f", totalMs),
            ]
        )
        report.reflectionMilliseconds = reflectionMs
        report.reductionMilliseconds = reductionMs
        report.totalMilliseconds = totalMs
        report.setInvocations(
            screening: 0,
            randomSampling: 0,
            reduction: 1 + propertyInvocationCount
        )
        if suppressIssueReporting == false {
            reportError(
                rendered,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
        return value
    }

    // MARK: - Detection and Async Bridges

    /// Returns whether an error thrown from a property closure is a skip marker rather than a failure.
    static func isSkipError(_ error: any Error) -> Bool {
        if error is PropertySkip { return true }
        #if canImport(XCTest)
            if error is XCTSkip { return true }
        #endif
        return false
    }

    /// Wraps a throwing `Void`-returning closure into `(Output) -> Bool` via try/catch.
    ///
    /// A thrown skip marker (``PropertySkip`` or `XCTSkip`) counts as a pass and is tallied into `skipCounter`, so the run can warn on a high skip rate and fail when every invocation was skipped.
    static func wrapDetectionProperty<Output>(
        _ detection: @escaping @Sendable (Output) throws -> Void,
        countingSkipsInto skipCounter: SkipCounter? = nil
    ) -> @Sendable (Output) -> Bool {
        { value in
            do {
                try detection(value)
                return true
            } catch {
                if isSkipError(error) {
                    skipCounter?.increment()
                    return true
                }
                return false
            }
        }
    }

    /// Bridges an async Bool-returning property to a synchronous one via ``blockingAwait(_:)``.
    static func bridgeAsyncProperty<Output>(
        _ property: @escaping @Sendable (Output) async throws -> Bool,
        countingSkipsInto skipCounter: SkipCounter? = nil
    ) -> @Sendable (Output) -> Bool {
        { value in
            let valueBox = UnsafeSendableBox(value)
            return blockingAwait {
                do {
                    return try await property(valueBox.value)
                } catch {
                    if isSkipError(error) {
                        skipCounter?.increment()
                        return true
                    }
                    return false
                }
            }
        }
    }

    /// Bridges an async Void-returning detection closure to a synchronous Bool via ``blockingAwait(_:)``.
    static func bridgeAsyncDetection<Output>(
        _ detection: @escaping @Sendable (Output) async throws -> Void,
        countingSkipsInto skipCounter: SkipCounter? = nil
    ) -> @Sendable (Output) -> Bool {
        { value in
            let valueBox = UnsafeSendableBox(value)
            return blockingAwait {
                do {
                    try await detection(valueBox.value)
                } catch {
                    if isSkipError(error) {
                        skipCounter?.increment()
                        return true
                    }
                    return false
                }
                return true
            }
        }
    }
}
