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
