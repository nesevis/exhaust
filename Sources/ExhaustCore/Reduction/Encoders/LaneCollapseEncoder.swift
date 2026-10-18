//
//  LaneCollapseEncoder.swift
//  Exhaust
//

// MARK: - Lane Collapse Encoder

/// Moves commands from concurrent lanes into the sequential prefix, one lane marker at a time, front to back.
///
/// Every candidate reorders the command sequence so prefix commands stay contiguous at the front, which the graph cannot apply in place. Acceptance therefore ends the pass and the next scope is built against the rebuilt graph.
enum LaneCollapseEncoder: ReductionEncoder {
    static let name: EncoderName = .laneCollapse
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger

    static func reduce(_ scope: ValueMinimizationScope, input: EncoderInput) -> Reduction {
        .search(
            LaneCollapseSearch(
                leaves: scope.leaves,
                graph: input.graph,
                baseSequence: input.baseSequence
            ),
            configuration: .standard
        )
    }
}

// MARK: - Dispatch Requirements

extension LaneCollapseEncoder {
    static func gate(_ _: ValueMinimizationScope) -> DispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: ValueMinimizationScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_: ValueMinimizationScope, in _: ChoiceGraph) -> Bool {
        true
    }
}
