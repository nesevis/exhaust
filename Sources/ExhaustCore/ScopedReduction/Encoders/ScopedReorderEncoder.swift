//
//  ScopedReorderEncoder.swift
//  Exhaust
//

// MARK: - Reorder Encoder

/// Sorts type-homogeneous sibling groups into ascending numeric order, for presentation after reduction is complete.
///
/// A reordering need not precede the incumbent: the interpreter admits it under ``ReductionOrder/unordered``. The first accepted reordering requires a rebuild, which ends the pass.
struct ScopedReorderEncoder: ScopedEncoder {
    let name: EncoderName = .numericReorder
    let isValueDependent = false
    let tuning: ScopedReductionTuning

    func reducer(_ scope: ReorderingScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            .reorder(ScopedReorderSearch(scope: scope, baseSequence: input.baseSequence)),
            configuration: ScopedSearchConfiguration(acceptance: .continue, requiresExactDecoder: false, reportedMutation: nil)
        )
    }
}
