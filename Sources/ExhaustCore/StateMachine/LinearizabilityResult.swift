/// Linearizability verdict used by the preemptive pipeline and backend protocol.
///
/// Mirrors ``LinearizabilityChecker/Result``, resolving the checker's positional witness into a renderable ``ResponseWitness`` addressed by marker value rather than lane array position.
package enum LinearizabilityResult {
    case linearizable
    case notLinearizable(witness: ResponseWitness?, failureDescription: String?)
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
