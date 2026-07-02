/// The observed result of a single command during a preemptive concurrent execution.
///
/// Extracted from ``ObservedResponse`` so the (non-generic) ``LinearizabilityChecker`` can store per-lane outcome arrays without carrying the command type parameter — commands stay with the caller, addressed by lane and per-lane offset.
///
/// Marked `@unchecked Sendable` because `returned` carries `Any`. The values are command return values produced and consumed on GCD threads within a single `execute()` call and never shared beyond the runner.
package enum ObservedOutcome: @unchecked Sendable {
    case returned(Any)
    case returnedVoid
    case skipped
}

package extension ObservedOutcome {
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
                return String(describing: value)
            case .skipped:
                return "skipped"
            case .returnedVoid:
                return nil
        }
    }
}

/// A single command's observed result during a preemptive concurrent execution, recorded per-lane.
///
/// Per-lane arrays of these (one array per lane, in per-lane execution order) feed the linearizability checker, which enumerates the order-preserving interleavings of the lanes. The per-lane order is the only ordering constraint the checker needs, so no cross-lane timestamp is recorded.
///
/// Marked `@unchecked Sendable` because ``Outcome`` carries `Any`; see ``ObservedOutcome``.
package struct ObservedResponse<Command>: @unchecked Sendable {
    /// Preserves the pre-extraction spelling `ObservedResponse<Command>.Outcome` at call sites.
    package typealias Outcome = ObservedOutcome

    package let lane: UInt8
    package let command: Command
    package let outcome: Outcome

    package init(lane: UInt8, command: Command, outcome: Outcome) {
        self.lane = lane
        self.command = command
        self.outcome = outcome
    }
}

package extension LinearizabilityChecker {
    /// Builds a checker directly from the per-lane responses captured during a preemptive run, keeping only the outcomes — the drivers replay commands by (lane, offset) coordinates. Shared by the synchronous and asynchronous preemptive backends.
    init(laneResponses: [[ObservedResponse<some Any>]]) {
        self.init(laneOutcomes: laneResponses.map { lane in lane.map(\.outcome) })
    }
}
