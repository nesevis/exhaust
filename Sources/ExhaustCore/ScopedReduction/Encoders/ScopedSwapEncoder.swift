//
//  ScopedSwapEncoder.swift
//  Exhaust
//

// MARK: - Swap Encoder

/// Swaps same-shaped siblings for shortlex improvement, then pushes the moved content further rightward.
///
/// The search keeps going after an acceptance, building its next probe on the recovered sequence.
struct ScopedSwapEncoder: ScopedEncoder {
    static let name: EncoderName = .siblingSwap
    static let isValueDependent = false
    static let requiresGenerator = false
    static let isPathChanging = false
    let tuning: ScopedReductionTuning

    func reducer(_ scope: PermutationScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            .swap(ScopedSwapSearch(scope: scope, sequence: input.baseSequence, graph: input.graph)),
            configuration: ScopedSearchConfiguration(acceptance: .rebuildAndContinue, requiresExactDecoder: false, reportedMutation: nil)
        )
    }
}
