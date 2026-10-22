//
//  LiftedSearchTypes.swift
//  Exhaust
//

// MARK: - Lift Types

/// Keeps a candidate prefix and its reported mutation together without feeding acceptance back into proposal generation.
struct LiftProposal {
    let prefix: EditedChoiceSequence
    let mutation: ProjectedMutation
}

/// Retains the lifted sequence so factories can reject its length before building a graph.
struct LiftResult {
    let tree: ChoiceTree
    let sequence: ChoiceSequence
}

/// Describes why construction stopped after an attempted lift.
package enum DownstreamBuildFailure: String, Hashable, Sendable, CaseIterable {
    case materializationFailed
    case liftedTooLong
    case bindNotFound
    case noDownstreamLeaves
    /// The fixed value prefix already prevents an improving terminal assignment.
    case nonImprovingPrefix
    case sinkValueMismatch
}
