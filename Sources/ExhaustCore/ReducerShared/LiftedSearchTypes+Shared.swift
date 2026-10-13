//
//  LiftedSearchTypes+Shared.swift
//  Exhaust
//

// MARK: - Lift Types

/// Keeps a candidate prefix and its reported mutation together without feeding acceptance back into proposal generation.
struct LiftProposal {
    let prefix: ChoiceSequence
    let mutation: EncoderProbe
}

/// Retains the lifted sequence so factories can reject its length before building a graph.
struct LiftResult {
    let tree: ChoiceTree
    let sequence: ChoiceSequence
}

/// Describes why construction stopped after an attempted lift.
enum DownstreamBuildFailure {
    case materializationFailed
    case liftedTooLong
    case bindNotFound
    case noDownstreamLeaves
    case sinkValueMismatch
}
