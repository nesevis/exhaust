/// Binary-searches each target value toward its semantic simplest form (zero for numerics).
///
/// Processes targets sequentially, converging each via ``BinarySearchStepper`` before moving to the next. The scheduler provides acceptance feedback via ``nextProbe(lastAccepted:)``.
public struct BinarySearchToZeroEncoder: AdaptiveEncoder {
    public init() {}

    public let name = "binarySearchToZero"
    public let phase = ReductionPhase.valueMinimization

    public var grade: ReductionGrade {
        ReductionGrade(approximation: .exact, maxMaterializations: 0)
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

    // MARK: - AdaptiveEncoder

    public mutating func start(sequence: ChoiceSequence, targets: TargetSet) {
        self.sequence = sequence
        self.targets = []
        self.currentIndex = 0
        self.needsFirstProbe = true

        guard case let .spans(spans) = targets else { return }

        var i = 0
        while i < spans.count {
            let seqIdx = spans[i].range.lowerBound
            guard let v = sequence[seqIdx].value else { i += 1; continue }
            let simplified = v.choice.semanticSimplest
            guard simplified != v.choice else { i += 1; continue }
            guard v.isRangeExplicit == false || simplified.fits(in: v.validRange) else { i += 1; continue }
            let targetBP = simplified.bitPattern64
            let currentBP = v.choice.bitPattern64
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
                if lastAccepted {
                    // Update the base sequence with the accepted value.
                    let state = targets[currentIndex]
                    sequence[state.seqIdx] = .value(.init(
                        choice: ChoiceValue(state.choiceTag.makeConvertible(bitPattern64: state.stepper.bestAccepted), tag: state.choiceTag),
                        validRange: state.validRange,
                        isRangeExplicit: state.isRangeExplicit
                    ))
                }
                probeValue = targets[currentIndex].stepper.advance(lastAccepted: lastAccepted)
            }

            if let bp = probeValue {
                let state = targets[currentIndex]
                var candidate = sequence
                candidate[state.seqIdx] = .value(.init(
                    choice: ChoiceValue(state.choiceTag.makeConvertible(bitPattern64: bp), tag: state.choiceTag),
                    validRange: state.validRange,
                    isRangeExplicit: state.isRangeExplicit
                ))
                return candidate
            }

            // Current target converged — move to next.
            currentIndex += 1
            needsFirstProbe = true
        }
        return nil
    }
}
