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

/// The measured wall-clock span of a single command execution, in nanoseconds from a shared monotonic clock.
///
/// Timestamps are taken immediately before invoking the command and immediately after it returns, so the measured span contains the true span. The containment makes cross-lane precedence inference conservative: `returnTime < other.callTime` on measured values proves the true return preceded the true call, so every inferred returns-before edge is real, while some true edges may go undetected. The linearizability checker uses these edges to reject orderings that invert real-time precedence.
package struct ObservedInterval: Sendable {
    package let callTime: UInt64
    package let returnTime: UInt64

    package init(callTime: UInt64, returnTime: UInt64) {
        self.callTime = callTime
        self.returnTime = returnTime
    }
}

/// A single command's observed result during a preemptive concurrent execution, recorded per-lane.
///
/// Per-lane arrays of these (one array per lane, in per-lane execution order) feed the linearizability checker, which enumerates the order-preserving interleavings of the lanes. Each lane's internal order is one ordering constraint; the ``interval`` timestamps supply the cross-lane returns-before constraints, so commands that provably did not overlap are never reordered by the checker.
///
/// Marked `@unchecked Sendable` because ``Outcome`` carries `Any`; see ``ObservedOutcome``.
package struct ObservedResponse<Command>: @unchecked Sendable {
    /// Preserves the pre-extraction spelling `ObservedResponse<Command>.Outcome` at call sites.
    package typealias Outcome = ObservedOutcome

    package let lane: UInt8
    package let command: Command
    package let outcome: Outcome
    /// The command's measured execution span, or nil when the caller has no timing data (hand-built histories in tests). Without an interval the command is treated as overlapping everything, which can only weaken the check, never produce a spurious rejection.
    package let interval: ObservedInterval?

    package init(lane: UInt8, command: Command, outcome: Outcome, interval: ObservedInterval? = nil) {
        self.lane = lane
        self.command = command
        self.outcome = outcome
        self.interval = interval
    }
}

package extension LinearizabilityChecker {
    /// Builds a checker directly from the per-lane responses captured during a preemptive run, keeping the outcomes and the timing intervals; the drivers replay commands by (lane, offset) coordinates. Shared by the synchronous and asynchronous preemptive backends.
    init(laneResponses: [[ObservedResponse<some Any>]]) {
        self.init(
            laneOutcomes: laneResponses.map { lane in lane.map(\.outcome) },
            laneIntervals: laneResponses.map { lane in lane.map(\.interval) }
        )
    }
}
