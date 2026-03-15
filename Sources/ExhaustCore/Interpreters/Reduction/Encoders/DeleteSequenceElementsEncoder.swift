/// Removes element groups within arrays using adaptive batch sizing.
///
/// Target spans are pre-filtered by the scheduler to sequence element spans at the appropriate depth.
public struct DeleteSequenceElementsEncoder: AdaptiveEncoder {
    public init() {}

    public let name = "deleteSequenceElements"
    public let phase = ReductionPhase.structuralDeletion

    public var grade: ReductionGrade {
        ReductionGrade(approximation: .exact, maxMaterializations: 0)
    }

    public func estimatedCost(sequence: ChoiceSequence, bindIndex: BindSpanIndex?) -> Int? {
        let t = ChoiceSequence.extractSequenceElementSpans(from: sequence).count
        guard t > 0 else { return nil }
        return t * 10
    }

    private var driver = AdaptiveDeletionEncoder()

    public mutating func start(sequence: ChoiceSequence, targets: TargetSet) {
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
