//
//  ScopedSwapEncoder.swift
//  Exhaust
//

// MARK: - Swap Encoder

/// Swaps same-shaped siblings for shortlex improvement, then pushes the moved content further rightward.
///
/// The search keeps going after an acceptance, building its next probe on the recovered sequence.
struct ScopedSwapEncoder: ScopedEncoder {
    let name: EncoderName = .siblingSwap
    let isValueDependent = false
    let tuning: ScopedReductionTuning

    func reducer(_ scope: PermutationScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            .swap(ScopedSwapSearch(scope: scope, sequence: input.baseSequence, graph: input.graph)),
            configuration: ScopedSearchConfiguration(acceptance: .rebuildAndContinue, requiresExactDecoder: false, reportedMutation: nil)
        )
    }
}
