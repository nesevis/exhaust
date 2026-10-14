//
//  ScopedLockstepEncoder.swift
//  Exhaust
//

// MARK: - Lockstep Encoder

/// Moves groups of same-typed sibling values by the same delta at once, so properties that relate siblings keep holding while they shrink together.
///
/// Value edits apply to the graph in place, so the search keeps going after an acceptance, working from the accepted candidate.
struct ScopedLockstepEncoder: ScopedEncoder {
    static let name: EncoderName = .lockstep
    static let isValueDependent = true
    static let requiresGenerator = false
    static let isPathChanging = false
    let tuning: ScopedReductionTuning

    func reducer(_ scope: TandemScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            .lockstep(ScopedLockstepSearch(
                scope: scope,
                sequence: input.baseSequence,
                graph: input.graph,
                maxSuffixWindows: tuning.lockstepMaxSuffixWindows
            )),
            configuration: ScopedSearchConfiguration(
                acceptance: .continue,
                requiresExactDecoder: false,
                reportedMutation: nil
            )
        )
    }
}
