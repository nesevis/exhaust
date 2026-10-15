//
//  ScopedDepthCollapseEncoder.swift
//  Exhaust
//

// MARK: - Depth Collapse Encoder

/// Binary searches a ``TypeTag/depthControl`` leaf toward its range floor.
///
/// A depth leaf is an ordinary bounded integer, so finding the smallest failing layer count is a binary search over its value. Every candidate is a reshape: the leaf is the inner of a `._bound`, and accepting a lower value rebuilds the subtree that bind governs rather than editing an entry in place. Acceptance therefore ends the pass, and the next scope is built against the rebuilt graph.
struct ScopedDepthCollapseEncoder: ScopedEncoder {
    static let name: EncoderName = .depthCollapse
    static let isValueDependent = true
    static let requiresGenerator = false
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger
    static let rebuildsAfterAcceptance = false
    let tuning: ScopedReductionTuning

    func reducer(_ scope: ValueMinimizationScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            .binarySearch(ScopedBinarySearch(
                leaves: scope.leaves,
                graph: input.graph,
                baseSequence: input.baseSequence,
                mayReshape: true
            )),
            configuration: .standard
        )
    }
}

// MARK: - Dispatch Requirements

extension ScopedDepthCollapseEncoder {
    static func gate(_ _: ValueMinimizationScope) -> ScopedDispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: ValueMinimizationScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_: ValueMinimizationScope, in _: ChoiceGraph) -> Bool {
        true
    }

    /// A search, whose outcome the scope does not determine.
    static func rejectionKey(_: ValueMinimizationScope) -> ScopedRejectionKey? {
        nil
    }
}
