//
//  ReorderEncoder.swift
//  Exhaust
//

// MARK: - Reorder Encoder

/// Sorts type-homogeneous sibling groups into ascending numeric order, for presentation after reduction is complete.
///
/// A reordering need not precede the incumbent: the interpreter admits it under ``ReductionOrder/unordered``. The first accepted reordering requires a rebuild, which ends the pass.
///
/// Candidates decode exactly. The groups exclude bind-inner children, so a permutation never needs bound content regenerated, and guided decoding would let an unordered admission accept a larger term rebuilt around the permuted values.
enum ReorderEncoder: ReductionEncoder {
    static let name: EncoderName = .numericReorder
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .unordered

    static func reduce(_ scope: ReorderingScope, input: EncoderInput) -> Reduction {
        .search(
            ReorderSearch(scope: scope, baseSequence: input.baseSequence),
            configuration: SearchConfiguration(requiresExactDecoder: true)
        )
    }
}

// MARK: - Dispatch Requirements

extension ReorderEncoder {
    static func gate(_ _: ReorderingScope) -> DispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: ReorderingScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_: ReorderingScope, in _: ChoiceGraph) -> Bool {
        true
    }
}
