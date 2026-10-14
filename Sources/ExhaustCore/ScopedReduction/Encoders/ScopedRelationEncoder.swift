//
//  ScopedRelationEncoder.swift
//  Exhaust
//

// MARK: - Relation Encoder

/// Reduces stall-converged leaf pairs jointly along the rational relation their current values suggest.
///
/// Value edits apply to the graph in place, so the search keeps going after an acceptance, working from the accepted candidate.
struct ScopedRelationEncoder: ScopedEncoder {
    static let name: EncoderName = .relationSearch
    static let isValueDependent = true
    static let requiresGenerator = false
    static let isPathChanging = false
    let tuning: ScopedReductionTuning

    func reducer(_ scope: RelationScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            .relation(ScopedRelationSearch(
                scope: scope,
                sequence: input.baseSequence,
                graph: input.graph
            )),
            configuration: ScopedSearchConfiguration(
                acceptance: .continue,
                requiresExactDecoder: false,
                reportedMutation: nil
            )
        )
    }
}
