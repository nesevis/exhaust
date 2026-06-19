import ExhaustCore

/// Linearizability verdict used by the preemptive pipeline and ``PreemptiveBackend`` protocol.
///
/// Mirrors ``LinearizabilityChecker/Result`` from ExhaustCore so the pipeline does not depend on the generic checker's type parameter, and resolves the checker's positional witness into a renderable ``ResponseWitness``.
enum LinearizabilityResult {
    case linearizable
    case notLinearizable(witness: ResponseWitness?)
}

/// The concurrent command whose observed response no valid sequential ordering reproduces, addressed the way the failure renderer indexes lane commands: by ``ScheduleMarker/rawValue`` and per-lane execution offset.
struct ResponseWitness {
    let lane: UInt8
    let index: Int
}

/// Resolves a core checker result into a ``LinearizabilityResult``, mapping the checker's positional witness back to the originating lane's ``ScheduleMarker/rawValue``.
func makeLinearizabilityResult<Command>(
    _ coreResult: LinearizabilityChecker<Command>.Result,
    laneObservations: [[ObservedResponse<Command>]]
) -> LinearizabilityResult {
    switch coreResult {
        case .linearizable:
            return .linearizable
        case let .notLinearizable(witness):
            guard let witness,
                  witness.laneIndex < laneObservations.count,
                  witness.commandIndex < laneObservations[witness.laneIndex].count
            else {
                return .notLinearizable(witness: nil)
            }
            let response = laneObservations[witness.laneIndex][witness.commandIndex]
            return .notLinearizable(witness: ResponseWitness(lane: response.lane, index: witness.commandIndex))
    }
}
