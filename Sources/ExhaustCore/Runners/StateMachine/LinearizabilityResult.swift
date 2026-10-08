/// Linearizability verdict used by the preemptive pipeline and backend protocol.
///
/// Mirrors ``LinearizabilityChecker/Result``, resolving the checker's positional witness into a renderable ``ResponseWitness`` addressed by marker value rather than lane array position.
package enum LinearizabilityResult {
    case linearizable
    /// The search spent its replay budget before reaching a verdict. Passes the probe and counts against the run's abandonment tally; see ``LinearizabilityChecker/Result/abandoned``.
    case abandoned
    case notLinearizable(witness: ResponseWitness?, failureDescription: String?)
}

package extension LinearizabilityResult {
    /// Whether the verdict lets the probe stand; see ``LinearizabilityChecker/Result/passesTheProbe``.
    var passesTheProbe: Bool {
        switch self {
            case .linearizable, .abandoned:
                return true
            case .notLinearizable:
                return false
        }
    }

    /// Whether the search stopped for want of replay budget. Runners tally this so a run can warn about the probes it passed without judging.
    var isAbandoned: Bool {
        switch self {
            case .abandoned:
                return true
            case .linearizable, .notLinearizable:
                return false
        }
    }
}

/// The concurrent command whose observed response no valid sequential ordering reproduces, addressed the way the failure renderer indexes lane commands: by ``ScheduleMarker/rawValue`` and per-lane execution offset.
package struct ResponseWitness {
    package let lane: UInt8
    package let index: Int

    package init(lane: UInt8, index: Int) {
        self.lane = lane
        self.index = index
    }
}

/// Resolves a core checker result into a ``LinearizabilityResult``, mapping the checker's positional witness back to the originating lane's ``ScheduleMarker/rawValue``.
package func makeLinearizabilityResult(
    _ coreResult: LinearizabilityChecker.Result,
    laneObservations: [[ObservedResponse<some Any>]]
) -> LinearizabilityResult {
    switch coreResult {
        case .linearizable:
            return .linearizable
        case .abandoned:
            return .abandoned
        case let .notLinearizable(witness, failureDescription):
            guard let witness,
                  witness.laneIndex < laneObservations.count,
                  witness.commandIndex < laneObservations[witness.laneIndex].count
            else {
                return .notLinearizable(witness: nil, failureDescription: failureDescription)
            }
            let response = laneObservations[witness.laneIndex][witness.commandIndex]
            return .notLinearizable(witness: ResponseWitness(lane: response.lane, index: witness.commandIndex), failureDescription: failureDescription)
    }
}
