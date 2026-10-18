//
//  RelationEncoder.swift
//  Exhaust
//

// MARK: - Relation Encoder

/// Reduces stall-converged leaf pairs jointly along the rational relation their current values suggest.
///
/// Value edits apply to the graph in place, so the search keeps going after an acceptance, working from the accepted candidate.
enum RelationEncoder: ReductionEncoder {
    static let name: EncoderName = .relationSearch
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger

    static func reduce(_ scope: RelationScope, input: EncoderInput) -> Reduction {
        .search(
            RelationSearch(
                scope: scope,
                sequence: input.baseSequence,
                graph: input.graph
            ),
            configuration: .standard
        )
    }
}

// MARK: - Dispatch Requirements

extension RelationEncoder {
    static func gate(_ _: RelationScope) -> DispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: RelationScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_: RelationScope, in _: ChoiceGraph) -> Bool {
        true
    }
}
