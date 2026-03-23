//
//  DeletionEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 23/3/2026.
//

/// Adaptive batch deletion of spans from the choice sequence.
///
/// Replaces the four boilerplate deletion encoders (``DeleteContainerSpansEncoder``,
/// ``DeleteSequenceElementsEncoder``, ``DeleteSequenceBoundariesEncoder``,
/// ``DeleteFreeStandingValuesEncoder``) and the random repair variant with a single
/// composable encoder parameterised by ``DeletionSpanCategory``.
///
/// Spans are provided at construction time (pre-extracted by the caller from the span cache).
/// The caller restarts the deletion loop after any acceptance to get fresh spans.
struct DeletionEncoder: ComposableEncoder {
    let spanCategory: DeletionSpanCategory
    let spans: [ChoiceSpan]

    var name: EncoderName {
        switch spanCategory {
        case .containerSpans: .deleteContainerSpans
        case .sequenceElements: .deleteSequenceElements
        case .sequenceBoundaries: .deleteSequenceBoundaries
        case .freeStandingValues: .deleteFreeStandingValues
        case .mixed: .deleteContainerSpansWithRandomRepair
        case .siblingGroups: .deleteContainerSpans
        }
    }

    let phase = ReductionPhase.structuralDeletion

    init(spanCategory: DeletionSpanCategory, spans: [ChoiceSpan]) {
        self.spanCategory = spanCategory
        self.spans = spans
    }

    // MARK: - State

    private var driver = AdaptiveDeletionEncoder()

    // MARK: - ComposableEncoder

    func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        guard spans.isEmpty == false else { return nil }
        return spans.count * 10
    }

    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        driver.start(sequence: sequence, sortedSpans: spans)
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        driver.nextProbe(lastAccepted: lastAccepted)
    }
}
