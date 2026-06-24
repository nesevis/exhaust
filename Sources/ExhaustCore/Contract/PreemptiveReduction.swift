/// Constants and reduction algorithm for preemptive concurrent contract testing.
///
/// The two preemptive backends (synchronous and async) differ only in how a single probe runs. The reduction algorithm and its result type are backend-independent and live here for whole-module optimization.
package enum PreemptiveReduction {
    /// Maximum confirmation repetitions, used for failures discovered within 1,000 iterations.
    package static let confirmationRepetitionsCeiling = 100

    /// Minimum confirmation repetitions, used for failures discovered at or beyond 10,000 iterations.
    package static let confirmationRepetitionsFloor = 25

    /// Computes the number of confirmation repetitions per reduction probe, scaled by how quickly the failure was discovered.
    ///
    /// Failures found within 1,000 total iterations (coverage + sampling) get ``confirmationRepetitionsCeiling`` repetitions. The count scales linearly down to ``confirmationRepetitionsFloor`` by 10,000 iterations, then stays at the floor. Races that reproduce easily (low iteration count) get more attempts per probe, so the reducer can confidently strip commands. Races that took many iterations to surface are inherently harder to reproduce, and additional repetitions beyond the floor yield diminishing returns against the per-probe cost.
    package static func confirmationRepetitions(discoveryIterations: Int) -> Int {
        if discoveryIterations <= 1000 {
            return confirmationRepetitionsCeiling
        }
        if discoveryIterations >= 10000 {
            return confirmationRepetitionsFloor
        }
        let range = confirmationRepetitionsCeiling - confirmationRepetitionsFloor
        let scaled = range * (discoveryIterations - 1000) / (10000 - 1000)
        return confirmationRepetitionsCeiling - scaled
    }

    /// Computes the number of terminal confirmation repetitions, scaled by how quickly the failure was discovered.
    ///
    /// The terminal confirmation runs once per reported failure (not per reduction probe), so it can afford more attempts than the per-probe count. Uses 3x the per-probe count, floored at 150 — easy races get up to 300 attempts to attach the actual-state evidence line, while hard races stay at 150 (where more attempts would be wasted anyway).
    package static func finalConfirmationRepetitions(discoveryIterations: Int) -> Int {
        max(150, confirmationRepetitions(discoveryIterations: discoveryIterations) * 3)
    }

    /// Default command limit for `.threads` contracts.
    package static let defaultCommandLimit = 20

    /// Result of a preemptive reduction pass.
    package struct ReductionResult<Command, FailureOutcome> {
        package let output: [(ScheduleMarker, Command)]
        package let tree: ChoiceTree
        package let propertyInvocations: Int
        package let stats: ReductionStats
        package let witness: ResponseWitness?
        package let failureDescription: String?
        package let failureOutcome: FailureOutcome?

        package init(
            output: [(ScheduleMarker, Command)],
            tree: ChoiceTree,
            propertyInvocations: Int,
            stats: ReductionStats,
            witness: ResponseWitness?,
            failureDescription: String?,
            failureOutcome: FailureOutcome?
        ) {
            self.output = output
            self.tree = tree
            self.propertyInvocations = propertyInvocations
            self.stats = stats
            self.witness = witness
            self.failureDescription = failureDescription
            self.failureOutcome = failureOutcome
        }
    }

    /// Runs a single reduction pass with the given encoder set and property function.
    package static func reduceSinglePass<Command, FailureOutcome>(
        generator: Generator<[(ScheduleMarker, Command)]>,
        tree: ChoiceTree,
        output: [(ScheduleMarker, Command)],
        encoders: Set<EncoderName>,
        maxStalls: Int,
        deadlineNanoseconds: UInt64,
        rematerialize: Bool,
        repetitions: Int,
        tuning: SchedulerTuning = .init(),
        execute: @escaping ([(ScheduleMarker, Command)], ChoiceTree) -> (Bool, ResponseWitness?, String?, FailureOutcome?)
    ) -> ReductionResult<Command, FailureOutcome> {
        var propertyInvocations = 0
        var lastFailure: (ResponseWitness?, String?, FailureOutcome?)?
        let reductionProperty: ReductionProperty = .contract { output, probeTree in
            let taggedCommands = output as! [(ScheduleMarker, Command)] // swiftlint:disable:this force_cast
            for _ in 0 ..< repetitions {
                propertyInvocations += 1
                let (pass, witness, failureDescription, outcome) = execute(taggedCommands, probeTree)
                if pass == false {
                    lastFailure = (witness, failureDescription, outcome)
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

        return ReductionResult(
            output: currentOutput,
            tree: currentTree,
            propertyInvocations: propertyInvocations,
            stats: stats,
            witness: lastFailure?.0,
            failureDescription: lastFailure?.1,
            failureOutcome: lastFailure?.2
        )
    }
}
