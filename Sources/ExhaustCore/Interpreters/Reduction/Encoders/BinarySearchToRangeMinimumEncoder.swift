/// Binary-searches each target value toward a specific reduction target.
///
/// The reduction target for each value is determined by its recorded valid range (see ``ChoiceValue/reductionTarget(in:)``). Processes targets sequentially, converging each via ``BinarySearchStepper`` before moving to the next.
public struct BinarySearchToRangeMinimumEncoder: AdaptiveEncoder {
    public init() {}

    public let name: EncoderName = .binarySearchToRangeMinimum
    public let phase = ReductionPhase.valueMinimization

    public func estimatedCost(sequence: ChoiceSequence, bindIndex _: BindSpanIndex?) -> Int? {
        let t = ChoiceSequence.extractAllValueSpans(from: sequence).count
        guard t > 0 else { return nil }
        // t targets × ~64: BinarySearchStepper over [reductionTarget, currentBP] converges in O(log(range)) steps, bounded by the reduction target rather than zero.
        return t * 64
    }

    // MARK: - State

    private struct TargetState {
        let seqIdx: Int
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        let choiceTag: TypeTag
        var stepper: BinarySearchStepper
    }

    private var sequence = ChoiceSequence()
    private var targets: [TargetState] = []
    private var currentIndex = 0
    private var needsFirstProbe = true
    /// Saved entry for in-place mutation restore on rejection.
    private var savedEntry: ChoiceSequenceValue?

    // MARK: - AdaptiveEncoder

    public mutating func start(sequence: ChoiceSequence, targets: TargetSet) {
        self.sequence = sequence
        self.targets = []
        currentIndex = 0
        needsFirstProbe = true
        savedEntry = nil

        guard case let .spans(spans) = targets else { return }

        var i = 0
        while i < spans.count {
            let seqIdx = spans[i].range.lowerBound
            guard let v = sequence[seqIdx].value else { i += 1; continue }
            // Skip float targets — bit-pattern ordering diverges from shortlex ordering
            // near integral values (for example 999.0000000000001 has a lower bit pattern than
            // 1000.0 but a higher shortlex key). Float reduction is handled by
            // ReduceFloatEncoder and BinarySearchToSemanticSimplestEncoder.
            if v.choice.tag == .float || v.choice.tag == .double { i += 1; continue }
            let currentBP = v.choice.bitPattern64
            let isWithinRecordedRange = v.isRangeExplicit && v.choice.fits(in: v.validRange)
            let targetBP = isWithinRecordedRange
                ? v.choice.reductionTarget(in: v.validRange)
                : v.choice.semanticSimplest.bitPattern64
            guard currentBP != targetBP else { i += 1; continue }
            self.targets.append(TargetState(
                seqIdx: seqIdx,
                validRange: v.validRange,
                isRangeExplicit: v.isRangeExplicit,
                choiceTag: v.choice.tag,
                stepper: BinarySearchStepper(lo: targetBP, hi: currentBP)
            ))
            i += 1
        }
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        while currentIndex < targets.count {
            let probeValue: UInt64?

            if needsFirstProbe {
                needsFirstProbe = false
                probeValue = targets[currentIndex].stepper.start()
            } else {
                let state = targets[currentIndex]
                if lastAccepted {
                    sequence[state.seqIdx] = .value(.init(
                        choice: ChoiceValue(state.choiceTag.makeConvertible(bitPattern64: state.stepper.bestAccepted), tag: state.choiceTag),
                        validRange: state.validRange,
                        isRangeExplicit: state.isRangeExplicit
                    ))
                } else if let saved = savedEntry {
                    sequence[state.seqIdx] = saved
                }
                savedEntry = nil
                probeValue = targets[currentIndex].stepper.advance(lastAccepted: lastAccepted)
            }

            if let bp = probeValue {
                let state = targets[currentIndex]
                // In-place mutation: save entry before mutating, restore on rejection.
                // Avoids full ChoiceSequence copy per probe (COW copy deferred to caller).
                savedEntry = sequence[state.seqIdx]
                sequence[state.seqIdx] = .value(.init(
                    choice: ChoiceValue(state.choiceTag.makeConvertible(bitPattern64: bp), tag: state.choiceTag),
                    validRange: state.validRange,
                    isRangeExplicit: state.isRangeExplicit
                ))
                return sequence
            }

            // Moving to next target — restore if needed.
            if let saved = savedEntry {
                sequence[targets[currentIndex].seqIdx] = saved
                savedEntry = nil
            }
            currentIndex += 1
            needsFirstProbe = true
        }
        return nil
    }
}
