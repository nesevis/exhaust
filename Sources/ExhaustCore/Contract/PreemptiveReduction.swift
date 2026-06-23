/// Constants and reduction algorithm for preemptive concurrent contract testing.
///
/// The two preemptive backends (synchronous and async) differ only in how a single probe runs. The reduction algorithm and its result type are backend-independent and live here for whole-module optimization.
package enum PreemptiveReduction {
    /// Number of times each reduction probe re-executes the concurrent schedule to probabilistically confirm the race still reproduces. Runs once per candidate inside the reduction loop, so this is kept small.
    package static let confirmationRepetitions = 25

    /// Number of times the terminal confirmation re-executes the reported schedule to reproduce the race for evidence and final confirmation. This runs at most once per reported failure (not per reduction probe), so it can afford far more attempts than ``confirmationRepetitions``.
    package static let finalConfirmationRepetitions = 150

    /// Default command limit for `.threads` contracts.
    package static let defaultCommandLimit = 20

    /// Result of a preemptive reduction pass.
    package struct ReductionResult<Command> {
        package let output: [(ScheduleMarker, Command)]
        package let tree: ChoiceTree
        package let propertyInvocations: Int
        package let stats: ReductionStats

        package init(
            output: [(ScheduleMarker, Command)],
            tree: ChoiceTree,
            propertyInvocations: Int,
            stats: ReductionStats
        ) {
            self.output = output
            self.tree = tree
            self.propertyInvocations = propertyInvocations
            self.stats = stats
        }
    }

    /// Runs a single reduction pass with the given encoder set and property function.
    ///
    /// The `execute` closure receives the materialized commands and the ChoiceTree from which they were produced, so the linearizability checker can derive per-command observation hashes from the reduced tree rather than the stale original.
    package static func reduceSinglePass<Command>(
        generator: Generator<[(ScheduleMarker, Command)]>,
        tree: ChoiceTree,
        output: [(ScheduleMarker, Command)],
        encoders: Set<EncoderName>,
        maxStalls: Int,
        deadlineNanoseconds: UInt64,
        rematerialize: Bool,
        repetitions: Int,
        tuning: SchedulerTuning = .init(),
        execute: @escaping ([(ScheduleMarker, Command)], ChoiceTree) -> Bool
    ) -> ReductionResult<Command> {
        var propertyInvocations = 0
        let reductionProperty: ReductionProperty = .contract { output, probeTree in
            let taggedCommands = output as! [(ScheduleMarker, Command)] // swiftlint:disable:this force_cast
            for _ in 0 ..< repetitions {
                propertyInvocations += 1
                if execute(taggedCommands, probeTree) == false {
                    return false
                }
            }
            return true
        }

        var currentOutput = output
        var currentTree = tree
        var stats = ReductionStats()

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
            property: reductionProperty
        ) {
            stats.merge(result.stats)
            if case let .reduced(sequence, reducedTree, reduced) = result.outcome {
                currentOutput = reduced
                currentTree = reducedTree
                if rematerialize,
                   case let .success(value, tree, _) = Materializer.materialize(
                       generator,
                       prefix: sequence,
                       mode: .exact
                   )
                {
                    currentOutput = value
                    currentTree = tree
                }
            }
        }

        return ReductionResult(output: currentOutput, tree: currentTree, propertyInvocations: propertyInvocations, stats: stats)
    }
}
