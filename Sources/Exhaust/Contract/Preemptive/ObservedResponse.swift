import Foundation

/// A single command's observed result during a preemptive concurrent execution, recorded per-lane with a monotonic timestamp.
///
/// Per-lane arrays of these are collected during concurrent execution and merged by timestamp on failure to reconstruct the actual execution order. The timestamps also establish the partial order for linearizability checking: if one response's timestamp precedes another's, the first must precede the second in any valid linearization.
///
/// Marked `@unchecked Sendable` because `Outcome.returned` carries `Any`, which is not `Sendable`. The values are command return values produced and consumed on GCD threads within a single `execute()` call and never shared beyond the runner.
struct ObservedResponse<Command>: @unchecked Sendable {
    let lane: UInt8
    let command: Command
    let commandDescription: String
    let outcome: Outcome
    let timestamp: UInt64

    enum Outcome: @unchecked Sendable {
        case returned(Any)
        case returnedVoid
        case skipped
    }
}

extension ObservedResponse.Outcome {
    /// The return value for response comparison, or `nil` for void and skipped commands.
    var returnValue: Any? {
        switch self {
            case let .returned(value):
                return value
            case .returnedVoid, .skipped:
                return nil
        }
    }

    var isSkipped: Bool {
        switch self {
            case .skipped:
                return true
            case .returned, .returnedVoid:
                return false
        }
    }
}
