//
//  ScopedLaneCollapseEncoder.swift
//  Exhaust
//

// MARK: - Lane Collapse Encoder

/// Moves commands from concurrent lanes into the sequential prefix, one lane marker at a time, front to back.
///
/// Every candidate reorders the command sequence so prefix commands stay contiguous at the front, which the graph cannot apply in place. Acceptance therefore ends the pass and the next scope is built against the rebuilt graph.
struct ScopedLaneCollapseEncoder: ScopedEncoder {
    let name: EncoderName = .laneCollapse
    let isValueDependent = true
    let tuning: ScopedReductionTuning

    func reducer(_ scope: ValueMinimizationScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            .laneCollapse(ScopedLaneCollapseSearch(
                leaves: scope.leaves,
                graph: input.graph,
                baseSequence: input.baseSequence
            )),
            configuration: ScopedSearchConfiguration(
                acceptance: .continue,
                requiresExactDecoder: false,
                reportedMutation: nil
            )
        )
    }
}
