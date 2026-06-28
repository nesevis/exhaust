// Shared types for the synchronous and async preemptive contract runners.
import ExhaustCore

/// Groups shared types for the synchronous and async preemptive contract runners.
enum Preemptive {
    /// Reports whether one preemptive concurrent execution passed, failed, or timed out.
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
}

/// Whether a replayed command result matches an observed response, using the same rule as ``LinearizabilityChecker``: skip flags must agree, and non-skipped return values must be structurally equal. Shared by the synchronous and async preemptive witness checks so the cheap realized-order replay and the full interleaving search never disagree on what "the same response" means.
func preemptiveResponseMatches(
    observed: ObservedResponse<some Any>.Outcome,
    replayValue: Any?,
    replaySkipped: Bool
) -> Bool {
    if observed.isSkipped != replaySkipped {
        return false
    }
    switch (observed.returnValue, replayValue) {
        case (nil, nil):
            return true
        case let (observedValue?, replayedValue?):
            return structurallyEqual(observedValue, replayedValue)
        default:
            return false
    }
}
