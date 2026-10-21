//
//  SwapEncoder.swift
//  Exhaust
//

// MARK: - Swap Encoder

/// Swaps same-shaped siblings for shortlex improvement, then pushes the moved content further rightward.
///
/// The search keeps going after an acceptance, building its next probe on the recovered sequence.
enum SwapEncoder: ReductionEncoder {
    static let name: EncoderName = .siblingSwap
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger

    static func reduce(_ scope: PermutationScope, input: EncoderInput) -> Reduction {
        .search(
            SwapSearch(scope: scope, sequence: input.baseSequence, graph: input.graph),
            configuration: SearchConfiguration(graphUpdate: .rebuildAfterPass)
        )
    }
}

// MARK: - Dispatch Requirements

extension SwapEncoder {
    static func gate(_ _: PermutationScope) -> DispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: PermutationScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_ scope: PermutationScope, in graph: ChoiceGraph) -> Bool {
        scope.parentNodeID < graph.nodes.count
            && graph.nodes[scope.parentNodeID].positionRange != nil
    }
}
