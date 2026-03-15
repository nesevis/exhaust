/// Removes individual loose values not inside container groups, using adaptive batch sizing.
///
/// Target spans are pre-filtered by the scheduler to free-standing value spans at the appropriate depth.
public struct DeleteFreeStandingValuesEncoder: AdaptiveEncoder {
    public init() {}

    public let name = "deleteFreeStandingValues"
    public let phase = ReductionPhase.structuralDeletion


    public func estimatedCost(sequence: ChoiceSequence, bindIndex: BindSpanIndex?) -> Int? {
        let t = ChoiceSequence.extractFreeStandingValueSpans(from: sequence).count
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
