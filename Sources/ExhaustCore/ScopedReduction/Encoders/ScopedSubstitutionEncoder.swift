//
//  ScopedSubstitutionEncoder.swift
//  Exhaust
//

// MARK: - Substitution Encoder

/// Replaces a recursive subtree with a smaller one of the same pick family: a smaller self-similar subtree, or a descendant promoted over its ancestor.
///
/// The scope fully determines the probe. A candidate that does not precede the base sequence is not probed and is reported as an unresolved replacement, which a relax round can try without the ordering.
struct ScopedSubstitutionEncoder: ScopedEncoder {
    /// A replacement within one pick family.
    enum Scope {
        case selfSimilar(targetNodeID: Int, donorNodeID: Int)
        case descendantPromotion(ancestorPickNodeID: Int, descendantPickNodeID: Int)
    }

    let name: EncoderName = .substitution
    let isValueDependent = false
    let tuning: ScopedReductionTuning

    func reducer(_ scope: Scope, input: ScopedEncoderInput) -> ScopedReducer {
        let sequence = input.baseSequence
        let built: ChoiceSequence?
        let mutation: EncoderProbe
        switch scope {
            case let .selfSimilar(targetNodeID, donorNodeID):
                built = ScopedStructuralCandidates.selfSimilarReplacement(
                    targetNodeID: targetNodeID,
                    donorNodeID: donorNodeID,
                    sequence: sequence,
                    graph: input.graph
                )
                mutation = .selfSimilarReplaced(targetNodeID: targetNodeID, donorNodeID: donorNodeID)
            case let .descendantPromotion(ancestorPickNodeID, descendantPickNodeID):
                built = ScopedStructuralCandidates.descendantPromotion(
                    ancestorPickNodeID: ancestorPickNodeID,
                    descendantPickNodeID: descendantPickNodeID,
                    sequence: sequence,
                    graph: input.graph
                )
                mutation = .descendantPromoted(ancestorPickNodeID: ancestorPickNodeID, descendantPickNodeID: descendantPickNodeID)
        }
        return .search(
            .singleCandidate(ScopedSingleCandidateSearch.replacement(built, mutation: mutation, base: sequence)),
            configuration: ScopedSearchConfiguration(acceptance: .continue, requiresExactDecoder: false, reportedMutation: nil)
        )
    }
}
