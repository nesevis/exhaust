//
//  SubstitutionEncoder.swift
//  Exhaust
//

// MARK: - Substitution Encoder

/// Replaces a recursive subtree with a smaller one of the same pick family: a smaller self-similar subtree, or a descendant promoted over its ancestor.
///
/// The scope fully determines the probe. A candidate that does not precede the base sequence is not probed and is reported as an unresolved replacement, which a relax round can try without the ordering.
enum SubstitutionEncoder: ReductionEncoder {
    /// A replacement within one pick family.
    enum Scope {
        case selfSimilar(targetNodeID: Int, donorNodeID: Int)
        case descendantPromotion(ancestorPickNodeID: Int, descendantPickNodeID: Int)
    }

    static let name: EncoderName = .substitution
    static let isPathChanging = true
    static let admissionOrder: ReductionOrder = .notLarger

    static func reduce(_ scope: Scope, input: EncoderInput) -> Reduction {
        let sequence = input.baseSequence
        let built: ChoiceSequence?
        let mutation: ProjectedMutation
        switch scope {
            case let .selfSimilar(targetNodeID, donorNodeID):
                built = StructuralCandidates.selfSimilarReplacement(
                    targetNodeID: targetNodeID,
                    donorNodeID: donorNodeID,
                    sequence: sequence,
                    graph: input.graph
                )
                mutation = .selfSimilarReplaced(targetNodeID: targetNodeID, donorNodeID: donorNodeID)
            case let .descendantPromotion(ancestorPickNodeID, descendantPickNodeID):
                built = StructuralCandidates.descendantPromotion(
                    ancestorPickNodeID: ancestorPickNodeID,
                    descendantPickNodeID: descendantPickNodeID,
                    sequence: sequence,
                    graph: input.graph
                )
                mutation = .descendantPromoted(ancestorPickNodeID: ancestorPickNodeID, descendantPickNodeID: descendantPickNodeID)
        }
        return .search(
            SingleCandidateSearch.replacement(built, mutation: mutation, base: sequence),
            configuration: .standard
        )
    }
}

// MARK: - Dispatch Requirements

extension SubstitutionEncoder {
    static func gate(_ _: Scope) -> DispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: Scope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_ scope: Scope, in graph: ChoiceGraph) -> Bool {
        switch scope {
            case let .selfSimilar(targetNodeID, donorNodeID):
                targetNodeID < graph.nodes.count
                    && graph.nodes[targetNodeID].positionRange != nil
                    && donorNodeID < graph.nodes.count
                    && graph.nodes[donorNodeID].positionRange != nil
            case let .descendantPromotion(ancestorPickNodeID, descendantPickNodeID):
                ancestorPickNodeID < graph.nodes.count
                    && graph.nodes[ancestorPickNodeID].positionRange != nil
                    && descendantPickNodeID < graph.nodes.count
                    && graph.nodes[descendantPickNodeID].positionRange != nil
        }
    }
}
