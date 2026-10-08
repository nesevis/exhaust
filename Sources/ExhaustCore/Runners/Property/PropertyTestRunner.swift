//
//  PropertyTestRunner.swift
//  Exhaust
//

import Foundation

// MARK: - Property Test Runner

/// Runs a `#exhaust` property test: screening, then sampling, then reduction of the first failure.
///
/// The runner records what happened and leaves every judgement about the test framework to its caller. Issues it would otherwise report (generation errors, filter validity, unique exhaustion, a screening replay that never reached its row) come back in ``Run/diagnostics`` in the order they occurred, and a failure comes back unrendered in ``Run/failure``. The caller reports diagnostics first and the failure last, which is the order the phases produce them in.
package enum PropertyTestRunner {
    /// Everything the phases share for one run.
    package struct Context<Output> {
        package let gen: Generator<Output>
        package let property: @Sendable (Output) -> Bool
        package let samplingBudget: UInt64
        /// The reducer configuration, including ``Interpreters/ReducerConfiguration/visualize``.
        package let reductionConfig: Interpreters.ReducerConfiguration
        package let parallelLanes: UInt8
        package let statsAccumulator: OpenPBTStatsAccumulator?
        /// The OpenPBT property name each parallel sampling lane records under.
        package let laneStatsPropertyName: String
        package let skipCounter: SkipCounter?
        /// Binds the caller's issue scope on each parallel sampling lane, or nil to run lanes bare.
        package let laneScope: (any SamplingLaneScope)?
        /// Renders a value for OpenPBT statistics.
        package let representation: (Output) -> String
        /// The absolute monotonic deadline resolved from `.deadline`, or nil for the usual iteration budget.
        package let deadlineNanoseconds: UInt64?

        package init(
            gen: Generator<Output>,
            property: @escaping @Sendable (Output) -> Bool,
            samplingBudget: UInt64,
            reductionConfig: Interpreters.ReducerConfiguration,
            parallelLanes: UInt8,
            statsAccumulator: OpenPBTStatsAccumulator?,
            laneStatsPropertyName: String,
            skipCounter: SkipCounter?,
            laneScope: (any SamplingLaneScope)?,
            representation: @escaping (Output) -> String,
            deadlineNanoseconds: UInt64?
        ) {
            self.gen = gen
            self.property = property
            self.samplingBudget = samplingBudget
            self.reductionConfig = reductionConfig
            self.parallelLanes = parallelLanes
            self.statsAccumulator = statsAccumulator
            self.laneStatsPropertyName = laneStatsPropertyName
            self.skipCounter = skipCounter
            self.laneScope = laneScope
            self.representation = representation
            self.deadlineNanoseconds = deadlineNanoseconds
        }

        package var hasExceededDeadline: Bool {
            deadlineNanoseconds.map { monotonicNanoseconds() >= $0 } ?? false
        }

        /// The skip count accumulated so far, for phase-delta accounting. Skips land on the shared counter from any lane, so a delta taken outside a concurrent section is exact.
        package var skipCount: Int {
            skipCounter?.count ?? 0
        }
    }

    /// Where the run stopped.
    package enum Ending: Equatable {
        /// A screening replay tested its addressed row, whatever the outcome.
        case screeningReplay
        /// Screening found a counterexample.
        case screeningFailure
        /// Screening exhausted the domain without a counterexample, so sampling did not run.
        case screeningExhaustive
        /// Sampling ran. `passedWithinDeadline` is true when it found no counterexample and the deadline had not passed when it returned.
        case sampling(passedWithinDeadline: Bool)
    }

    /// Something the caller reports to the test framework, in the order the phases produced it.
    package enum Diagnostic {
        /// Generation threw.
        case generationError(any Error)
        /// Filter observations to check for validity warnings.
        case filterObservations([UInt64: FilterObservation])
        /// A unique site exhausted its retry budget after this many sampling iterations.
        case uniqueExhaustion(iterations: Int)
        /// A screening replay ended before reaching this zero-based row.
        case screeningReplayRowNotTested(row: Int)
    }

    /// A failure after reduction, with what the caller needs to render it.
    package struct Failure<Output> {
        package let counterexample: Output
        package let original: Output
        /// Whether reduction produced a different counterexample.
        package let improved: Bool
        /// The reduced sequence, when ``improved``.
        package let reducedSequence: ChoiceSequence?
        /// The sampling seed, or nil for a screening failure.
        package let seed: UInt64?
        package let iteration: Int
        package let phaseBudget: UInt64
        /// The encoded screening replay seed, for a screening failure.
        package let screeningReplaySeed: String?
    }

    /// The record of one run.
    package struct Run<Output> {
        package var ending: Ending = .sampling(passedWithinDeadline: false)
        package var failure: Failure<Output>?
        package var diagnostics: [Diagnostic] = []
        package var ledger: RunLedger
        package var screeningSummary: ScreeningPhase.Summary?
        /// The sampling seed, once sampling has started.
        package var seed: UInt64?
        /// Reducer statistics, or nil when reduction did not run or never started.
        package var reductionStats: ReductionStats?
        /// True when a failure's reduction never started because the deadline had passed.
        package var reductionWasCapped = false
        package var screeningMilliseconds: Double = 0
        package var generationMilliseconds: Double = 0
        package var reductionMilliseconds: Double = 0
        package var totalMilliseconds: Double = 0
    }

    // MARK: - Run

    /// Runs screening and sampling and reduces the first failure.
    ///
    /// - Parameters:
    ///   - context: The phases' shared configuration.
    ///   - screeningBudget: The screening row budget. Zero skips screening.
    ///   - screeningReplayRow: The zero-based row a screening replay tests, or nil. A replay screens under `replayScreeningBudget` and never samples.
    ///   - replayScreeningBudget: The budget a screening replay rebuilds its covering array with: the budget the failure was discovered under.
    ///   - coveringSeed: The covering array seed.
    ///   - seed: The sampling seed, or nil to draw one.
    ///   - replayIteration: The one-based sampling iteration a sampling replay reruns, or nil.
    ///   - ledger: The run's ledger so far.
    package static func run<Output>(
        context: Context<Output>,
        screeningBudget: UInt64,
        screeningReplayRow: Int?,
        replayScreeningBudget: UInt64,
        coveringSeed: UInt64,
        seed: UInt64?,
        replayIteration: Int?,
        ledger: RunLedger
    ) -> Run<Output> {
        var run = Run<Output>(ledger: ledger)
        let phaseTimingStart = monotonicNanoseconds()
        if let screeningReplayRow {
            let outcome = runScreening(
                context: context,
                screeningBudget: replayScreeningBudget,
                coveringSeed: coveringSeed,
                skipToRow: screeningReplayRow,
                run: &run
            )
            let screeningEnd = monotonicNanoseconds()
            run.screeningMilliseconds = Double(screeningEnd - phaseTimingStart) / 1_000_000
            run.totalMilliseconds = run.screeningMilliseconds
            run.ending = .screeningReplay
            if case let .counterexample(failure) = outcome {
                run.failure = failure
            }
            return run
        } else if screeningBudget == 0 {
            ExhaustLog.notice(category: .propertyTest, event: "screening_skipped", "Screening phase skipped")
        } else {
            let outcome = runScreening(
                context: context,
                screeningBudget: screeningBudget,
                coveringSeed: coveringSeed,
                run: &run
            )
            switch outcome {
                case let .counterexample(failure):
                    let screeningEnd = monotonicNanoseconds()
                    run.screeningMilliseconds = Double(screeningEnd - phaseTimingStart) / 1_000_000
                    run.totalMilliseconds = run.screeningMilliseconds
                    run.ending = .screeningFailure
                    run.failure = failure
                    return run
                case .exhaustivePass:
                    let screeningEnd = monotonicNanoseconds()
                    run.screeningMilliseconds = Double(screeningEnd - phaseTimingStart) / 1_000_000
                    run.totalMilliseconds = run.screeningMilliseconds
                    run.ending = .screeningExhaustive
                    return run
                case .proceed:
                    break
            }
        }
        let screeningPhaseEndTime = monotonicNanoseconds()

        let baseSeed = seed ?? Xoshiro256().seed
        run.seed = baseSeed
        let sampled = SamplingPhase.run(
            context: context,
            baseSeed: baseSeed,
            singleLane: seed != nil,
            replayIteration: replayIteration,
            run: &run
        )
        var samplingResult: Output?
        if let sampled {
            let failure = reduce(
                context: context,
                value: sampled.value,
                tree: sampled.tree,
                seed: baseSeed,
                iteration: sampled.absoluteIteration,
                phaseBudget: context.samplingBudget,
                screeningReplaySeed: nil,
                run: &run
            )
            run.failure = failure
            samplingResult = failure.counterexample
        }

        let endTime = monotonicNanoseconds()
        run.screeningMilliseconds = Double(screeningPhaseEndTime - phaseTimingStart) / 1_000_000
        run.totalMilliseconds = Double(endTime - phaseTimingStart) / 1_000_000

        let passedWithinDeadline = samplingResult == nil && context.hasExceededDeadline == false
        if passedWithinDeadline {
            run.generationMilliseconds = Double(endTime - screeningPhaseEndTime) / 1_000_000
        }
        run.ending = .sampling(passedWithinDeadline: passedWithinDeadline)

        ExhaustLog.notice(
            category: .propertyTest,
            event: "phase_timing",
            metadata: [
                "screening_ms": String(format: "%.1f", run.screeningMilliseconds),
                "generation_ms": String(format: "%.1f", run.generationMilliseconds),
                "reduction_ms": String(format: "%.1f", run.reductionMilliseconds),
                "total_ms": String(format: "%.1f", run.totalMilliseconds),
            ]
        )
        return run
    }

    // MARK: - Screening

    /// The outcome of the screening phase: failure found, exhaustive pass, or proceed to sampling.
    private enum ScreeningOutcome<Output> {
        case counterexample(Failure<Output>)
        case exhaustivePass
        case proceed
    }

    /// Runs the structured covering array phase, returning early on first failure.
    private static func runScreening<Output>(
        context: Context<Output>,
        screeningBudget: UInt64,
        coveringSeed: UInt64,
        skipToRow: Int? = nil,
        run: inout Run<Output>
    ) -> ScreeningOutcome<Output> {
        let skipsBefore = context.skipCount
        let screeningResult = ScreeningPhase.run(
            context.gen,
            screeningBudget: screeningBudget,
            coveringSeed: coveringSeed,
            skipToRow: skipToRow,
            deadlineNanoseconds: context.deadlineNanoseconds,
            property: context.property,
            onExample: context.statsAccumulator.map { accumulator in
                { value, tree, passed in
                    accumulator.record(representation: context.representation(value), passed: passed, tree: tree, phase: .screening)
                }
            }
        )
        run.screeningSummary = screeningResult.summary
        let screeningFailures = switch screeningResult {
            case .failure:
                1
            case .exhaustive, .partial, .notApplicable:
                0
        }
        run.ledger.record(
            .screening,
            invocations: screeningResult.summary.propertyInvocations,
            skips: context.skipCount - skipsBefore,
            failures: screeningFailures
        )
        // A replay that never tested its addressed row would otherwise complete as a quiet pass, which reads as "fixed" when it means "not reproduced". The value covering array is budget-coupled, so a budget change since discovery can end the row stream before the row.
        if let skipToRow, screeningFailures == 0, screeningResult.summary.propertyInvocations == 0 {
            run.diagnostics.append(.screeningReplayRowNotTested(row: skipToRow))
        }
        switch screeningResult {
            case let .failure(value, tree, rowOrdinal, _, _, _, _, _, _):
                let screeningReplaySeed = ReplaySeed.Resolved.valueScreening(seed: coveringSeed, row: rowOrdinal - 1).encoded
                return .counterexample(reduce(
                    context: context,
                    value: value,
                    tree: tree,
                    seed: nil,
                    iteration: rowOrdinal,
                    phaseBudget: screeningBudget,
                    screeningReplaySeed: screeningReplaySeed,
                    run: &run
                ))

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

    // MARK: - Reduction

    /// Reduces a failure under the run's deadline and records the reduction's outcomes in the ledger.
    private static func reduce<Output>(
        context: Context<Output>,
        value: Output,
        tree: ChoiceTree,
        seed: UInt64?,
        iteration: Int,
        phaseBudget: UInt64,
        screeningReplaySeed: String?,
        run: inout Run<Output>
    ) -> Failure<Output> {
        let reductionSkipsBefore = context.skipCount
        let reductionStart = monotonicNanoseconds()
        let reduction = ReductionRunner.reduce(
            context.gen,
            tree: tree,
            value: value,
            configuration: context.reductionConfig,
            runDeadlineNanoseconds: context.deadlineNanoseconds,
            property: context.property
        )
        if reduction.started {
            run.reductionStats = reduction.stats
        } else {
            run.reductionWasCapped = true
        }
        run.reductionMilliseconds = Double(monotonicNanoseconds() - reductionStart) / 1_000_000
        run.ledger.record(
            .reduction,
            invocations: reduction.propertyInvocations,
            skips: context.skipCount - reductionSkipsBefore,
            failures: reduction.propertyFailures
        )
        guard reduction.improved else {
            return Failure(
                counterexample: value,
                original: value,
                improved: false,
                reducedSequence: nil,
                seed: seed,
                iteration: iteration,
                phaseBudget: phaseBudget,
                screeningReplaySeed: screeningReplaySeed
            )
        }
        ExhaustLog.debug(
            category: .propertyTest,
            event: "reduced_blueprint",
            "\(reduction.sequence.shortString)"
        )
        if let statsAccumulator = context.statsAccumulator {
            statsAccumulator.recordReduced(
                representation: context.representation(reduction.value),
                tree: .just,
                reductionSeconds: run.reductionMilliseconds / 1000
            )
        }
        return Failure(
            counterexample: reduction.value,
            original: value,
            improved: true,
            reducedSequence: reduction.sequence,
            seed: seed,
            iteration: iteration,
            phaseBudget: phaseBudget,
            screeningReplaySeed: screeningReplaySeed
        )
    }
}
