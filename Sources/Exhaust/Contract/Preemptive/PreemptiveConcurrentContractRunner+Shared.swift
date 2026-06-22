// Shared types, reduction algorithm, and pipeline for the synchronous and async preemptive contract runners.
import ExhaustCore

/// Namespace for machinery shared by ``PreemptiveChecker`` (synchronous) and ``AsyncPreemptiveChecker``.
///
/// The two checkers differ only in how a single probe runs (direct GCD execution versus async bridged through a drain loop), so the outcome shape, single-pass reducer, and pipeline live here and are parameterised by each checker's `execute`.
enum Preemptive {
    /// Number of times each reduction probe re-executes the concurrent schedule to probabilistically confirm the race still reproduces. Runs once per candidate inside the reduction loop, so this is kept small.
    static let confirmationRepetitions = 25

    /// Number of times the terminal ``confirmRealFailure`` re-executes the reported schedule to reproduce the race for evidence and final confirmation. This runs at most once per reported failure (not per reduction probe), so it can afford far more attempts than ``confirmationRepetitions``: catching a timing-fragile race here is what attaches the actual-state line and witness to the report. For a race that reproduces with probability `p` per run, the chance of catching it scales as `1 - (1 - p)^n`.
    static let finalConfirmationRepetitions = 50

    /// Default command limit for `.threads` contracts. Lower than the cooperative runner's estimated/40 cap because each probe repeats `confirmationRepetitions` times.
    static let defaultCommandLimit = 20

    /// Outcome of one preemptive concurrent execution.
    ///
    /// `timedOut` distinguishes a hang (a wedged lane or a drain-loop idle bailout) from a genuine pass or property failure, so the runner reports the hang as a timeout rather than dressing it up as a confirmed race. A timed-out run always has `passed == false`.
    ///
    /// On failure, `laneResponses` carries the per-lane observed responses for linearizability confirmation. On pass or timeout, `laneResponses` is `nil` because responses are only worth preserving when the oracle flags a potential violation.
    struct Outcome<Spec: ContractSpecBase> {
        let passed: Bool
        let timedOut: Bool
        let laneResponses: [[ObservedResponse<Spec.Command>]]?
        let concurrentSpec: Spec?
    }

    /// Result of a preemptive reduction pass.
    struct ReductionResult<Command> {
        let output: [(ScheduleMarker, Command)]
        let tree: ChoiceTree
        let propertyInvocations: Int
        let stats: ReductionStats
    }

    /// Runs a single reduction pass with the given encoder set and property function.
    ///
    /// When `reductionTreeBox` is non-nil, the current tree is written to it before each property invocation and after rematerialization, so the `execute` closure can reconcile commands with their ChoiceSequence segments for cache fingerprinting.
    static func reduceSinglePass<Command>(
        generator: Generator<[(ScheduleMarker, Command)]>,
        tree: ChoiceTree,
        output: [(ScheduleMarker, Command)],
        encoders: Set<EncoderName>,
        maxStalls: Int,
        deadlineNanoseconds: UInt64,
        rematerialize: Bool,
        repetitions: Int,
        tuning: SchedulerTuning = .init(),
        reductionTreeBox: UnsafeSendableBox<ChoiceTree?>? = nil,
        execute: ([(ScheduleMarker, Command)]) -> Bool
    ) -> ReductionResult<Command> {
        var propertyInvocations = 0
        let property: ([(ScheduleMarker, Command)]) -> Bool = { taggedCommands in
            for _ in 0 ..< repetitions {
                propertyInvocations += 1
                if execute(taggedCommands) == false {
                    return false
                }
            }
            return true
        }

        var currentOutput = output
        var currentTree = tree
        var stats = ReductionStats()
        reductionTreeBox?.value = currentTree

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(
                maxStalls: maxStalls,
                wallClockDeadlineNanoseconds: deadlineNanoseconds,
                enabledEncoders: encoders,
                tuning: tuning
            ),
            property: property
        ) {
            stats.merge(result.stats)
            if case let .reduced(sequence, reducedTree, reduced) = result.outcome {
                currentOutput = reduced
                currentTree = reducedTree
                reductionTreeBox?.value = currentTree
                // Rebuild the tree from the reduced sequence so the next pass starts from a consistent (output, tree) pair, using the rematerialized value and tree together. Exact replay is sufficient: structural deletion runs first on the pruned tree (see reduceConfirmedFailure), before any rematerialize here, so no pass has to compute removal spans against this tree.
                if rematerialize,
                   case let .success(value, tree, _) = Materializer.materialize(
                       generator,
                       prefix: sequence,
                       mode: .exact
                   )
                {
                    currentOutput = value
                    currentTree = tree
                    reductionTreeBox?.value = currentTree
                }
            }
        }

        return ReductionResult(output: currentOutput, tree: currentTree, propertyInvocations: propertyInvocations, stats: stats)
    }
}
