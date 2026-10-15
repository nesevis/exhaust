//
//  ScopedRelationEncoder.swift
//  Exhaust
//

// MARK: - Relation Encoder

/// Reduces stall-converged leaf pairs jointly along the rational relation their current values suggest.
///
/// Value edits apply to the graph in place, so the search keeps going after an acceptance, working from the accepted candidate.
enum ScopedRelationEncoder: ScopedEncoder {
    static let name: EncoderName = .relationSearch
    static let isValueDependent = true
    static let requiresGenerator = false
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger
    static let rebuildsAfterAcceptance = false

    static func reducer(_ scope: RelationScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            .relation(ScopedRelationSearch(
                scope: scope,
                sequence: input.baseSequence,
                graph: input.graph
            )),
            configuration: .standard
        )
    }
}

// MARK: - Dispatch Requirements

extension ScopedRelationEncoder {
    static func gate(_ _: RelationScope) -> ScopedDispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: RelationScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_: RelationScope, in _: ChoiceGraph) -> Bool {
        true
    }

    /// A search, whose outcome the scope does not determine.
    static func rejectionKey(_: RelationScope) -> ScopedRejectionKey? {
        nil
    }
}
