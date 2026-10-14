//
//  ScopedFloatSearchEncoder.swift
//  Exhaust
//

// MARK: - Float Search Encoder

/// Drives float leaves toward their semantic simplest values, one ``ScopedFloatSearch`` per scope.
///
/// Value edits apply to the graph in place, so the search keeps going after an acceptance, working from the accepted candidate. An acceptance that reshapes a bound subtree still ends the pass.
struct ScopedFloatSearchEncoder: ScopedEncoder {
    static let name: EncoderName = .floatSearch
    static let isValueDependent = true
    static let requiresGenerator = false
    static let isPathChanging = false

    func reducer(_ scope: FloatMinimizationScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            .floatSearch(ScopedFloatSearch(
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
