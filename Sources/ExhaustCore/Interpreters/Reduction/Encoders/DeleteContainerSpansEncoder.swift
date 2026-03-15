/// Removes whole container subtrees (groups, sequences, binds) using adaptive batch sizing.
///
/// Uses ``FindIntegerStepper`` to binary-search for the largest contiguous batch of same-depth spans that can be deleted. Only full spans starting with an opener marker are eligible.
public struct DeleteContainerSpansEncoder: AdaptiveEncoder {
    public init() {}

    public let name = "deleteContainerSpans"
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
        let filtered = spans.filter { span in
            switch sequence[span.range.lowerBound] {
            case .sequence(true, isLengthExplicit: _), .group(true), .bind(true):
                return true
            default:
                return false
            }
        }
        driver.start(sequence: sequence, sortedSpans: filtered)
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        driver.nextProbe(lastAccepted: lastAccepted)
    }
}
