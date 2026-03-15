/// Removes sequence boundary marker pairs using adaptive batch sizing, merging adjacent sequences.
///
/// Target spans are pre-filtered by the scheduler to boundary spans at the appropriate depth.
public struct DeleteSequenceBoundariesEncoder: AdaptiveEncoder {
    public init() {}

    public let name = "deleteSequenceBoundaries"
    public let phase = ReductionPhase.structuralDeletion


    public func estimatedCost(sequence: ChoiceSequence, bindIndex: BindSpanIndex?) -> Int? {
        let t = ChoiceSequence.extractSequenceBoundarySpans(from: sequence).count
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
