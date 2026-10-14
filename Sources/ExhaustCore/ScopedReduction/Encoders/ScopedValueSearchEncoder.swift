//
//  ScopedValueSearchEncoder.swift
//  Exhaust
//

// MARK: - Value Search Encoder

/// Drives integer or float leaves toward their semantic simplest values, one ``ScopedValueSearch`` per scope.
///
/// Value edits apply to the graph in place, so the search keeps going after an acceptance, working from the accepted candidate. An acceptance that reshapes a bound subtree still ends the pass.
struct ScopedValueSearchEncoder: ScopedEncoder {
    let name: EncoderName = .valueSearch
    let isValueDependent = true
    let tuning: ScopedReductionTuning

    func reducer(_ scope: ScopedValueSearch.Scope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            .valueSearch(ScopedValueSearch(
                scope: scope,
                sequence: input.baseSequence,
                graph: input.graph,
                warmStarts: input.warmStartRecords,
                tuning: tuning
            )),
            configuration: ScopedSearchConfiguration(
                acceptance: .continue,
                requiresExactDecoder: false,
                reportedMutation: nil
            )
        )
    }
}
