/// Binary-searches each target value toward its semantic simplest form (zero for numerics).
///
/// Processes targets sequentially, converging each via ``BinarySearchStepper`` before moving
/// to the next. After bit-pattern binary search converges, a **cross-zero probe** phase walks
/// down in shortlex key space to find simpler values that the bit-pattern search cannot reach.
/// This is essential for signed integers: bit-pattern search from positive values toward zero
/// stays on the positive side, missing negative values like -1 (shortlex key 1) which are
/// simpler than 1 (shortlex key 2) in zigzag encoding.
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

    private enum Phase {
        case binarySearch
        case crossZero(currentKey: UInt64, lowerBound: UInt64)
    }

    private var sequence = ChoiceSequence()
    private var targets: [TargetState] = []
    private var currentIndex = 0
    private var needsFirstProbe = true
    private var searchPhase = Phase.binarySearch

    // MARK: - AdaptiveEncoder

    public mutating func start(sequence: ChoiceSequence, targets: TargetSet) {
        self.sequence = sequence
        self.targets = []
        self.currentIndex = 0
        self.needsFirstProbe = true
        self.searchPhase = .binarySearch

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
            switch searchPhase {
            case .binarySearch:
                if let candidate = advanceBinarySearch(lastAccepted: lastAccepted) {
                    return candidate
                }
                // Binary search converged. Enter cross-zero phase.
                let state = targets[currentIndex]
                let currentChoice = sequence[state.seqIdx].value?.choice ?? ChoiceValue(
                    state.choiceTag.makeConvertible(bitPattern64: state.stepper.bestAccepted),
                    tag: state.choiceTag
                )
                let currentKey = currentChoice.shortlexKey
                if currentKey > 0 {
                    let maxProbes: UInt64 = 16
                    let lowerBound = currentKey > maxProbes ? currentKey - maxProbes : 0
                    searchPhase = .crossZero(currentKey: currentKey, lowerBound: lowerBound)
                    continue
                }
                // No cross-zero needed (already at key 0).
                advanceToNextTarget()

            case let .crossZero(currentKey, lowerBound):
                if lastAccepted {
                    // Update base sequence with the previously accepted cross-zero probe.
                    let state = targets[currentIndex]
                    let acceptedChoice = ChoiceValue.fromShortlexKey(currentKey, tag: state.choiceTag)
                    sequence[state.seqIdx] = .reduced(.init(
                        choice: acceptedChoice,
                        validRange: state.validRange,
                        isRangeExplicit: state.isRangeExplicit
                    ))
                }
                guard currentKey > lowerBound else {
                    advanceToNextTarget()
                    continue
                }
                let nextKey = currentKey - 1
                searchPhase = .crossZero(currentKey: nextKey, lowerBound: lowerBound)
                let state = targets[currentIndex]
                let probeChoice = ChoiceValue.fromShortlexKey(nextKey, tag: state.choiceTag)
                if state.isRangeExplicit, probeChoice.fits(in: state.validRange) == false {
                    continue
                }
                let probeEntry = ChoiceSequenceValue.reduced(.init(
                    choice: probeChoice,
                    validRange: state.validRange,
                    isRangeExplicit: state.isRangeExplicit
                ))
                guard probeEntry.shortLexCompare(sequence[state.seqIdx]) == .lt else {
                    continue
                }
                var candidate = sequence
                candidate[state.seqIdx] = probeEntry
                return candidate
            }
        }
        return nil
    }

    // MARK: - Helpers

    private mutating func advanceBinarySearch(lastAccepted: Bool) -> ChoiceSequence? {
        let probeValue: UInt64?

        if needsFirstProbe {
            needsFirstProbe = false
            probeValue = targets[currentIndex].stepper.start()
        } else {
            if lastAccepted {
                let state = targets[currentIndex]
                sequence[state.seqIdx] = .value(.init(
                    choice: ChoiceValue(state.choiceTag.makeConvertible(bitPattern64: state.stepper.bestAccepted), tag: state.choiceTag),
                    validRange: state.validRange,
                    isRangeExplicit: state.isRangeExplicit
                ))
            }
            probeValue = targets[currentIndex].stepper.advance(lastAccepted: lastAccepted)
        }

        guard let bp = probeValue else { return nil }
        let state = targets[currentIndex]
        var candidate = sequence
        candidate[state.seqIdx] = .value(.init(
            choice: ChoiceValue(state.choiceTag.makeConvertible(bitPattern64: bp), tag: state.choiceTag),
            validRange: state.validRange,
            isRangeExplicit: state.isRangeExplicit
        ))
        return candidate
    }

    private mutating func advanceToNextTarget() {
        currentIndex += 1
        needsFirstProbe = true
        searchPhase = .binarySearch
    }
}
