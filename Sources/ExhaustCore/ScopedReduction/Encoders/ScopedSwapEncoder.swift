//
//  ScopedSwapEncoder.swift
//  Exhaust
//

// MARK: - Swap Encoder

/// Swaps same-shaped siblings for shortlex improvement, then pushes the moved content further rightward.
///
/// The search keeps going after an acceptance, building its next probe on the recovered sequence.
enum ScopedSwapEncoder: ScopedEncoder {
    static let name: EncoderName = .siblingSwap
    static let isValueDependent = false
    static let requiresGenerator = false
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger
    static let rebuildsAfterAcceptance = false

    static func reducer(_ scope: PermutationScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            ScopedSwapSearch(scope: scope, sequence: input.baseSequence, graph: input.graph),
            configuration: ScopedSearchConfiguration(
                acceptance: .rebuildAndContinue,
                requiresExactDecoder: false,
                reportedMutation: nil
            )
        )
    }
}

// MARK: - Dispatch Requirements

extension ScopedSwapEncoder {
    static func gate(_ _: PermutationScope) -> ScopedDispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: PermutationScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_ scope: PermutationScope, in graph: ChoiceGraph) -> Bool {
        scope.parentNodeID < graph.nodes.count
            && graph.nodes[scope.parentNodeID].positionRange != nil
    }

    /// Keyed by the values at the swapped positions, so a value change invalidates it by itself.
    static func rejectionKey(_ scope: PermutationScope) -> ScopedRejectionKey? {
        ScopedRejectionKey(
            discriminator: 0x9182_7364_5546_3728,
            isCoarse: false,
            affectedNodeIDs: scope.swappableGroups.flatMap(\.self)
        )
    }
}
