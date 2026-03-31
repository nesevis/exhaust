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
///
/// When ``bindInnerValueIndex`` is set, the encoder also decrements the bind-inner value that controls the sequence length so that the candidate is structurally consistent (n-k elements with bind-inner value n-k). Without this, element deletions in bind-controlled sequences are filled back in by the guided decoder because the bind-inner value still says n.
struct DeletionEncoder: ComposableEncoder {
    let spanCategory: DeletionSpanCategory
    let spans: [ChoiceSpan]

    /// Sequence index of the bind-inner value that controls the sequence length.
    /// When set, deleting k elements also decrements this value by k.
    var bindInnerValueIndex: Int?

    var name: EncoderName {
        switch spanCategory {
        case .containerSpans: .deleteContainerSpans
        case .sequenceElements: .deleteSequenceElements
        case .sequenceBoundaries: .deleteSequenceBoundaries
        case .freeStandingValues: .deleteFreeStandingValues
        case .mixed, .siblingGroups: .deleteContainerSpans
        }
    }

    let phase = ReductionPhase.structuralDeletion

    init(spanCategory: DeletionSpanCategory, spans: [ChoiceSpan]) {
        self.spanCategory = spanCategory
        self.spans = spans
    }

    // MARK: - State

    private var driver = AdaptiveDeletionEncoder()
    private var originalSequence = ChoiceSequence()

    // MARK: - ComposableEncoder

    func estimatedCost(
        sequence _: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) -> Int? {
        guard spans.isEmpty == false else { return nil }
        return spans.count * 10
    }

    mutating func start(
        sequence: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) {
        originalSequence = sequence
        driver.start(sequence: sequence, sortedSpans: spans)
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard var candidate = driver.nextProbe(lastAccepted: lastAccepted) else { return nil }

        guard let innerIndex = bindInnerValueIndex else { return candidate }

        // The bind-inner value controls the sequence length. After the driver
        // removed k element spans, decrement the bind-inner value by k so the
        // candidate is structurally consistent (n-k elements, bind-inner = n-k).
        let deletedCount = originalSequence.count - candidate.count
        guard deletedCount > 0,
              innerIndex < candidate.count,
              let innerEntry = candidate[innerIndex].value,
              let validRange = innerEntry.validRange
        else { return candidate }

        let currentBitPattern = innerEntry.choice.bitPattern64
        let offset = currentBitPattern - validRange.lowerBound
        // Underflow check: can't delete more elements than the offset allows.
        guard offset >= UInt64(deletedCount) else { return nil }

        let newBitPattern = currentBitPattern - UInt64(deletedCount)
        candidate[innerIndex] = .value(.init(
            choice: ChoiceValue(
                innerEntry.choice.tag.makeConvertible(bitPattern64: newBitPattern),
                tag: innerEntry.choice.tag
            ),
            validRange: validRange,
            isRangeExplicit: innerEntry.isRangeExplicit
        ))
        return candidate
    }
}
