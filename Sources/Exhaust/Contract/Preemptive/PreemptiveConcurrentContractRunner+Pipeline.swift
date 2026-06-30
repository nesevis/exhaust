import ExhaustCore

// MARK: - Shared Helpers

extension __ExhaustRuntime {
    /// Determines whether a failing outcome represents a confirmed linearizability violation. Returns `nil` when the execution passed or when linearizability holds despite the oracle flag.
    static func classifyFailure<Backend: PreemptiveBackend>(
        taggedCommands: [(ScheduleMarker, Backend.Spec.Command)],
        outcome: Preemptive.Outcome<Backend.Spec>,
        backend: Backend
    ) -> FailureEvidence<Backend.Spec>? {
        if outcome.passed {
            return nil
        }
        if outcome.timedOut {
            return .init(outcome: outcome, witness: nil, failureDescription: nil)
        }
        guard let laneResponses = outcome.laneResponses,
              let concurrentSpec = outcome.concurrentSpec
        else {
            return .init(outcome: outcome, witness: nil, failureDescription: nil)
        }
        guard case let .notLinearizable(witness, failure) = backend.checkLinearizability(
            taggedCommands: taggedCommands,
            laneResponses: laneResponses,
            concurrentSpec: concurrentSpec
        ) else {
            return nil
        }
        return .init(outcome: outcome, witness: witness, failureDescription: failure)
    }

    /// Extracts per-lane response display values from an outcome for trace annotation.
    static func laneResponseValues(
        from outcome: Preemptive.Outcome<some ContractSpecBase>?
    ) -> [UInt8: [String?]]? {
        guard let outcome, let typedResponses = outcome.laneResponses else { return nil }
        var values: [UInt8: [String?]] = [:]
        for laneArray in typedResponses {
            for response in laneArray {
                values[response.lane, default: []].append(response.outcome.displayValue)
            }
        }
        return values
    }

    /// Re-executes the reduced input to confirm the race is reproducible when no reduction probe cached evidence.
    static func confirmRealFailure<Backend: PreemptiveBackend>(
        backend: Backend,
        input: [(ScheduleMarker, Backend.Spec.Command)],
        discoveryIterations: Int
    ) -> FailureEvidence<Backend.Spec>? {
        let partition = LanePartition(input)
        for _ in 0 ..< PreemptiveReduction.finalConfirmationRepetitions(discoveryIterations: discoveryIterations) {
            if let confirmed = classifyFailure(
                taggedCommands: input,
                outcome: backend.execute(input, partition: partition),
                backend: backend
            ) {
                return confirmed
            }
        }
        return nil
    }

    /// Renders a preemptive failure message with the preemptive trace format.
    static func renderPreemptiveFailure(
        _ input: [(ScheduleMarker, some CustomStringConvertible)],
        context: FailureContext
    ) -> String {
        let trace = buildPreemptiveTrace(
            input,
            laneResponseValues: context.laneResponseValues,
            linearizabilityWitness: context.linearizabilityWitness
        )
        return renderFailure(input, trace: trace, context: context)
    }
}

// MARK: - Supporting Types

extension __ExhaustRuntime {
    /// Captures the outcome, response-level witness, and failure description from a single failing execution.
    struct FailureEvidence<Spec: ContractSpecBase> {
        let outcome: Preemptive.Outcome<Spec>
        let witness: ResponseWitness?
        let failureDescription: String?
    }
}
