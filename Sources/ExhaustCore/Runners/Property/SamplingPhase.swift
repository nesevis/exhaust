//
//  SamplingPhase.swift
//  Exhaust
//

import Foundation

// MARK: - Sampling Lane Scope

/// Binds a caller's issue scope around each parallel sampling lane.
///
/// A lane runs on a `concurrentPerform` worker, which inherits no task-locals from the thread that started the run, so a scope bound around the whole run does not reach it. The runner calls ``run(_:)`` once per lane on the lane's worker and ``lanesJoined()`` once on the starting thread after every lane has returned. Sequential sampling runs on the starting thread and never calls either.
package protocol SamplingLaneScope: Sendable {
    /// Runs one lane's work inside the scope, on the lane's worker thread.
    func run<Result>(_ body: () -> Result) -> Result

    /// Called on the starting thread once every lane has returned.
    func lanesJoined()
}

// MARK: - Sampling Phase

/// Random sampling after screening: generates values from the generator and checks each against the property until the first failure or the end of the budget.
package enum SamplingPhase {
    /// A failure sampling found, before reduction.
    struct Found<Output> {
        let value: Output
        let tree: ChoiceTree
        let absoluteIteration: Int
    }

    /// Outcome of a single sampling batch (sequential or one lane of a parallel run).
    struct BatchResult<Output> {
        var failure: (value: Output, tree: ChoiceTree, absoluteIteration: Int)?
        var iterations: Int = 0
        var filterObservations: [UInt64: FilterObservation] = [:]
        var statsLines: [OpenPBTStatsLine] = []
        var error: (any Error)?
        var uniqueExhaustionTruncatedRun = false
    }

    /// Runs the random sampling phase after screening completes, returning the first failure found.
    ///
    /// When `context.parallelLanes` is greater than one, splits the budget across multiple GCD threads (one per lane). Otherwise runs sequentially.
    ///
    /// - Parameter singleLane: Forces sequential sampling, as a replay or fixed-seed run requires for deterministic reproduction.
    static func run<Output>( // swiftlint:disable:this function_body_length
        context: PropertyTestRunner.Context<Output>,
        baseSeed: UInt64,
        singleLane: Bool,
        replayIteration: Int?,
        run: inout PropertyTestRunner.Run<Output>
    ) -> Found<Output>? {
        let generationPhaseStart = monotonicNanoseconds()

        let laneCount = singleLane ? 1 : max(1, Int(context.parallelLanes))

        if laneCount <= 1, context.statsAccumulator == nil {
            return runSingleLane(
                context: context,
                baseSeed: baseSeed,
                replayIteration: replayIteration,
                generationPhaseStart: generationPhaseStart,
                run: &run
            )
        }

        let baseIterationsPerLane = context.samplingBudget / UInt64(laneCount)
        let remainder = context.samplingBudget - baseIterationsPerLane * UInt64(laneCount)
        let statsPropertyName: String? = context.statsAccumulator != nil
            ? context.laneStatsPropertyName
            : nil

        let skipsBefore = context.skipCount
        let batchResults: [BatchResult<Output>]
        if laneCount <= 1 {
            let replayStartIndex = replayIteration.map { UInt64($0 - 1) } ?? 0
            let singleResult = runBatch(
                gen: context.gen,
                property: context.property,
                representation: context.representation,
                baseSeed: baseSeed,
                startIndex: replayStartIndex,
                count: context.samplingBudget,
                lane: nil,
                statsPropertyName: statsPropertyName,
                canceled: UnsafeSendableBox(false),
                deadlineNanoseconds: context.deadlineNanoseconds
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
                let body = {
                    runBatch(
                        gen: unsafeContext.gen,
                        property: unsafeContext.property,
                        representation: unsafeContext.representation,
                        baseSeed: baseSeed,
                        startIndex: startIndex,
                        count: iterationsForLane,
                        lane: laneIndex,
                        statsPropertyName: statsPropertyName,
                        canceled: canceled,
                        deadlineNanoseconds: unsafeContext.deadlineNanoseconds
                    )
                }
                nonisolated(unsafe) let batchResult = unsafeContext.laneScope.map { $0.run(body) } ?? body()
                resultStorage.withValue { $0[laneIndex] = batchResult }
            }
            context.laneScope?.lanesJoined()
            batchResults = resultStorage.value.compactMap(\.self)
        }

        // Merge filter observations.
        var mergedFilterObservations: [UInt64: FilterObservation] = [:]
        for batch in batchResults {
            for (fingerprint, observation) in batch.filterObservations {
                mergedFilterObservations[fingerprint, default: FilterObservation()].merge(observation)
            }
        }
        run.diagnostics.append(.filterObservations(mergedFilterObservations))

        // Merge stats lines into the parent accumulator.
        if let statsAccumulator = context.statsAccumulator {
            for batch in batchResults {
                statsAccumulator.appendLines(batch.statsLines)
            }
        }

        // Report every batch's error.
        for batch in batchResults {
            if let error = batch.error {
                run.diagnostics.append(.generationError(error))
            }
        }

        // Find the failure with the lowest absolute iteration (deterministic winner).
        // The skip delta is taken after all lanes have joined, so it is exact even though lanes share one counter. Each lane stops at its first failure, so failing invocations equal failing lanes.
        let totalIterations = batchResults.reduce(0) { $0 + $1.iterations }
        run.ledger.record(
            .sampling,
            invocations: totalIterations,
            skips: context.skipCount - skipsBefore,
            failures: batchResults.count(where: { $0.failure != nil })
        )
        let winningFailure = batchResults
            .compactMap(\.failure)
            .min(by: { $0.absoluteIteration < $1.absoluteIteration })

        run.generationMilliseconds = Double(monotonicNanoseconds() - generationPhaseStart) / 1_000_000
        guard let failure = winningFailure else {
            if batchResults.contains(where: \.uniqueExhaustionTruncatedRun) {
                run.diagnostics.append(.uniqueExhaustion(iterations: totalIterations))
            }
            return nil
        }
        return Found(value: failure.value, tree: failure.tree, absoluteIteration: failure.absoluteIteration)
    }

    // MARK: - Single-Lane Fast Path

    /// Tight generation loop for single-lane, no-stats runs.
    ///
    /// Bypasses the ``BatchResult`` / ``runBatch`` / merge machinery to avoid heap allocations and per-iteration indirection that are only needed for parallel or stats-collecting runs.
    private static func runSingleLane<Output>(
        context: PropertyTestRunner.Context<Output>,
        baseSeed: UInt64,
        replayIteration: Int?,
        generationPhaseStart: UInt64,
        run: inout PropertyTestRunner.Run<Output>
    ) -> Found<Output>? {
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
            while context.hasExceededDeadline == false, let next = try interpreter.nextValueOnly() {
                guard context.hasExceededDeadline == false else {
                    break
                }
                iterations += 1
                if context.property(next) == false {
                    // Sampling outcomes are recorded before reduction runs so reduction-phase skips stay out of the sampling delta.
                    run.ledger.record(
                        .sampling,
                        invocations: iterations,
                        skips: context.skipCount - skipsBefore,
                        failures: 1
                    )
                    let tree = try interpreter.reproduceFailureTree()
                    run.generationMilliseconds = Double(monotonicNanoseconds() - generationPhaseStart) / 1_000_000
                    run.diagnostics.append(.filterObservations(interpreter.filterObservations))

                    let absoluteIteration = Int(startIndex) + iterations
                    return Found(value: next, tree: tree, absoluteIteration: absoluteIteration)
                }
            }
        } catch {
            run.diagnostics.append(.generationError(error))
        }

        run.ledger.record(
            .sampling,
            invocations: iterations,
            skips: context.skipCount - skipsBefore
        )
        run.generationMilliseconds = Double(monotonicNanoseconds() - generationPhaseStart) / 1_000_000
        run.diagnostics.append(.filterObservations(interpreter.filterObservations))
        if interpreter.uniqueExhaustionTruncatedRun {
            run.diagnostics.append(.uniqueExhaustion(iterations: iterations))
        }
        return nil
    }

    // MARK: - Sampling Batch

    /// Runs a contiguous range of sampling iterations, returning the first failure (if any).
    ///
    /// Used by both the sequential and parallel sampling paths. Each call creates its own ``ValueAndChoiceTreeInterpreter`` covering indices `startIndex ..< startIndex + count`, with an independent PRNG derived from `baseSeed`.
    ///
    /// - Parameters:
    ///   - gen: The generator to sample from.
    ///   - property: The property to check each generated value against.
    ///   - representation: Renders a value for OpenPBT statistics.
    ///   - baseSeed: Root seed for per-run PRNG derivation. All lanes share the same base seed.
    ///   - startIndex: Absolute run index for the first iteration in this batch.
    ///   - count: Number of iterations to run in this batch.
    ///   - lane: Batch index for stats attribution, or `nil` for sequential runs.
    ///   - statsPropertyName: Property name passed to the per-batch ``OpenPBTStatsAccumulator``, or `nil` to skip stats collection.
    ///   - canceled: Shared flag checked before each iteration. Set to `true` by the first lane to find a failure.
    ///   - deadlineNanoseconds: Absolute monotonic deadline shared by the run's lanes, or nil for no time limit.
    private static func runBatch<Output>( // swiftlint:disable:this function_body_length function_parameter_count
        gen: Generator<Output>,
        property: @Sendable (Output) -> Bool,
        representation: (Output) -> String,
        baseSeed: UInt64,
        startIndex: UInt64,
        count: UInt64,
        lane: Int?,
        statsPropertyName: String?,
        canceled: some CancellationFlag,
        deadlineNanoseconds: UInt64?
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
                while canceled.isCancelled == false,
                      deadlineNanoseconds.map({ monotonicNanoseconds() < $0 }) ?? true
                {
                    let generateStart = monotonicNanoseconds()
                    guard let (next, tree) = try interpreter.next() else { break }
                    guard deadlineNanoseconds.map({ monotonicNanoseconds() < $0 }) ?? true else {
                        break
                    }
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
                    if let rejections = filterRejections, rejections > 0 {
                        statsAccumulator.recordDiscards(count: rejections, phase: .random)
                    }
                    statsAccumulator.record(
                        representation: representation(next),
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
                while canceled.isCancelled == false,
                      deadlineNanoseconds.map({ monotonicNanoseconds() < $0 }) ?? true
                {
                    guard let next = try interpreter.nextValueOnly() else { break }
                    guard deadlineNanoseconds.map({ monotonicNanoseconds() < $0 }) ?? true else {
                        break
                    }
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
}
