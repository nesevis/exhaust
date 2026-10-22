//
//  LiftedSearchTypes.swift
//  Exhaust
//

// MARK: - Lift Types

/// Keeps a candidate prefix and its reported mutation together without feeding acceptance back into proposal generation.
struct LiftProposal {
    let basePrefix: ChoiceSequence
    let valueReplacement: ChoiceSequenceValueReplacement?
    let mutation: ProjectedMutation

    init(prefix: ChoiceSequence, mutation: ProjectedMutation, valueReplacement: ChoiceSequenceValueReplacement? = nil) {
        basePrefix = prefix
        self.mutation = mutation
        self.valueReplacement = valueReplacement
    }

    /// Materializes the edit only for consumers that need an owned, mutable candidate. Guided lifting reads the shared base and replacement directly.
    var prefix: ChoiceSequence {
        guard let valueReplacement else {
            return basePrefix
        }
        var result = basePrefix
        result[valueReplacement.index] = .value(valueReplacement.value)
        return result
    }

    func value(at index: Int) -> ChoiceSequenceValue.Value? {
        if let valueReplacement, valueReplacement.index == index {
            return valueReplacement.value
        }
        return basePrefix[index].value
    }
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
