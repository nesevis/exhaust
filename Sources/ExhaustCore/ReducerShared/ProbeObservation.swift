/// Observes session decisions without retaining traces in the reducer. Choice sequences are copy-on-write snapshots; the session emits them only when an observer is installed.
enum ProbeObservation {
    case emitted(probeID: Int, sequence: ChoiceSequence, mutation: ProjectedMutation)
    case decoderSelected(probeID: Int, preferExact: Bool, materializePicks: Bool)
    case decoded(probeID: Int, sequence: ChoiceSequence)
    case terminated(probeID: Int, disposition: ProbeDisposition, materializationAttempts: Int)
}

/// Keeps the session's commit decision distinct from a property failure or a decoder rejection.
enum ProbeDisposition: Equatable {
    case cacheRejected
    case materializationRejected
    case propertyPassed
    case propertyFailedNotAdmitted(ProbeAdmissionRejection)
    case accepted
    case interrupted
}

/// Identifies only rejection information available to the session, without inferring why a decoder returned no reduction.
enum ProbeAdmissionRejection: Equatable {
    case decoderReturnedNoReduction
    case enlargingCommit
}
