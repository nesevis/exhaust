import ExhaustCore

/// A single command's observed result during a preemptive concurrent execution, recorded per-lane.
///
/// Per-lane arrays of these (one array per lane, in per-lane execution order) feed the linearizability checker, which enumerates the order-preserving interleavings of the lanes. The per-lane order is the only ordering constraint the checker needs, so no cross-lane timestamp is recorded.
///
/// Marked `@unchecked Sendable` because `Outcome.returned` carries `Any`, which is not `Sendable`. The values are command return values produced and consumed on GCD threads within a single `execute()` call and never shared beyond the runner.
struct ObservedResponse<Command>: @unchecked Sendable {
    let lane: UInt8
    let command: Command
    let commandDescription: String
    let outcome: Outcome

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

    /// A human-readable rendering of the return value for failure reports, or `nil` for void commands (which carry no response to show).
    var displayValue: String? {
        switch self {
            case let .returned(value):
                return "\(value)"
            case .skipped:
                return "skipped"
            case .returnedVoid:
                return nil
        }
    }
}

extension LinearizabilityChecker {
    /// Builds a checker from the per-lane responses captured during a preemptive run, mapping each ``ObservedResponse`` to a checker observation. Shared by the synchronous and asynchronous preemptive backends.
    init(laneResponses: [[ObservedResponse<Command>]]) {
        self.init(laneObservations: laneResponses.map { lane in
            lane.map { response in
                Observation(
                    command: response.command,
                    commandDescription: response.commandDescription,
                    returnValue: response.outcome.returnValue,
                    isSkipped: response.outcome.isSkipped
                )
            }
        })
    }
}
