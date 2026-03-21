//
//  DeleteSequenceElementsEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

/// Removes element groups within arrays using adaptive batch sizing.
///
/// Target spans are pre-filtered by the scheduler to sequence element spans at the appropriate depth.
public struct DeleteSequenceElementsEncoder: AdaptiveEncoder {
    public init() {}

    public let name: EncoderName = .deleteSequenceElements
    public let phase = ReductionPhase.structuralDeletion

    public func estimatedCost(sequence: ChoiceSequence, bindIndex _: BindSpanIndex?) -> Int? {
        let t = ChoiceSequence.extractSequenceElementSpans(from: sequence).count
        guard t > 0 else { return nil }
        // t element spans grouped by depth; FindIntegerStepper binary-searches the batch size within each group, converging in ~10 probes per group.
        return t * 10
    }

    private var driver = AdaptiveDeletionEncoder()

    public mutating func start(sequence: ChoiceSequence, targets: TargetSet, convergedOrigins _: [Int: ConvergedOrigin]?) {
        guard case let .spans(spans) = targets else {
            driver.start(sequence: sequence, sortedSpans: [])
            return
        }
        driver.start(sequence: sequence, sortedSpans: spans)
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        driver.nextProbe(lastAccepted: lastAccepted)
    }
}
