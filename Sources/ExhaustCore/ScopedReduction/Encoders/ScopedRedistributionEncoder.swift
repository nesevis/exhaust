//
//  ScopedRedistributionEncoder.swift
//  Exhaust
//

// MARK: - Redistribution Encoder

/// Moves magnitude between type-compatible leaf pairs, preserving their sum, so that later searches can reduce the sequence further.
///
/// Value edits apply to the graph in place, so the search keeps going after an acceptance, working from the accepted candidate.
struct ScopedRedistributionEncoder: ScopedEncoder {
    static let name: EncoderName = .redistribution
    static let isValueDependent = true
    static let requiresGenerator = false
    static let isPathChanging = false
    let tuning: ScopedReductionTuning

    func reducer(_ scope: RedistributionScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            .redistribution(ScopedRedistributionSearch(
                scope: scope,
                sequence: input.baseSequence,
                graph: input.graph,
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
