/// Speculatively deletes spans and relies on ``GuidedMaterializer`` fallback for repair.
///
/// Operates on a mixed target set using adaptive batch sizing.
public struct SpeculativeDeleteEncoder: AdaptiveEncoder {
    public init() {}

    public let name = "speculativeDelete"
    public let phase = ReductionPhase.structuralDeletion


    public func estimatedCost(sequence: ChoiceSequence, bindIndex: BindSpanIndex?) -> Int? {
        let t = ChoiceSequence.extractContainerSpans(from: sequence).count
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
