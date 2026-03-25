/// Scans a bounded value range at a single coordinate by exhaustive enumeration.
///
/// Produced by the factory when ``ConvergenceSignal/nonMonotoneGap(remainingRange:)`` has a remaining range within the scan threshold (≤ 64). Scans values in order, stops early when a failure is found (for `.upward` direction) or when the range is exhausted. Runs in Phase 2 (value minimization) in place of ``BinarySearchEncoder`` for the flagged coordinate.
///
/// The scan produces ``ConvergenceSignal/scanComplete(foundLowerFloor:)`` at termination so the factory can revert to binary search on the next cycle.
struct LinearScanEncoder: ComposableEncoder {
    let name: EncoderName = .linearScan
    let phase = ReductionPhase.valueMinimization

    /// Which direction to scan the range.
    enum ScanDirection {
        /// Scan upward from the range's lower bound. First failure found is the new floor.
        case upward
        /// Scan from semantic simplest outward. First failure found is the new floor.
        case fromSimplest
    }

    /// The sequence position to scan.
    let targetPosition: Int

    /// The range of bit-pattern values to scan (inclusive).
    let scanRange: ClosedRange<UInt64>

    /// The direction to scan.
    let scanDirection: ScanDirection

    init(
        targetPosition: Int,
        scanRange: ClosedRange<UInt64>,
        scanDirection: ScanDirection
    ) {
        self.targetPosition = targetPosition
        self.scanRange = scanRange
        self.scanDirection = scanDirection
    }

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var choiceTag: TypeTag = .uint64
    private var validRange: ClosedRange<UInt64>?
    private var isRangeExplicit = false
    private var scanValues: [UInt64] = []
    private var scanIndex = 0
    private var foundLowerFloor = false
    private var bestBound: UInt64 = 0
    private var currentCycle: Int = 0
    private var started = false

    // MARK: - ComposableEncoder

    func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        let count = Int(clamping: scanRange.upperBound - scanRange.lowerBound + 1)
        return count > 0 ? count : nil
    }

    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        self.sequence = sequence
        currentCycle = context.cycle
        started = true
        foundLowerFloor = false
        bestBound = scanRange.upperBound + 1
        scanIndex = 0
        scanValues = []

        guard targetPosition < sequence.count,
              let value = sequence[targetPosition].value
        else { return }

        choiceTag = value.choice.tag
        validRange = value.validRange
        isRangeExplicit = value.isRangeExplicit

        // Build ordered scan values based on direction.
        let lower = scanRange.lowerBound
        let upper = scanRange.upperBound
        guard lower <= upper else { return }

        switch scanDirection {
        case .upward:
            var current = lower
            while current <= upper {
                scanValues.append(current)
                if current == UInt64.max {
                    break
                }
                current += 1
            }
        case .fromSimplest:
            // Semantic simplest for the tag, then expand outward.
            let zeroChoice = ChoiceValue(
                choiceTag.makeConvertible(bitPattern64: 0),
                tag: choiceTag
            )
            let simplest = zeroChoice.semanticSimplest.bitPattern64
            if lower <= simplest, simplest <= upper {
                scanValues.append(simplest)
            }
            var delta: UInt64 = 1
            while scanValues.count < Int(clamping: upper - lower + 1) {
                let below = simplest >= delta ? simplest - delta : nil
                let above = simplest <= UInt64.max - delta ? simplest + delta : nil
                if let below, below >= lower {
                    scanValues.append(below)
                }
                if let above, above <= upper, above != below {
                    scanValues.append(above)
                }
                if delta == UInt64.max {
                    break
                }
                delta += 1
            }
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard started else { return nil }

        // Track acceptance of previous probe.
        if lastAccepted, scanIndex > 0 {
            let acceptedValue = scanValues[scanIndex - 1]
            if foundLowerFloor == false || acceptedValue < bestBound {
                foundLowerFloor = true
                bestBound = acceptedValue
            }
            // Early stop: found a failure, and for upward scan the first
            // failure is the minimum — no need to scan further.
            if scanDirection == .upward {
                scanIndex = scanValues.count
                return nil
            }
        }

        guard scanIndex < scanValues.count else { return nil }

        let probeValue = scanValues[scanIndex]
        scanIndex += 1

        var candidate = sequence
        candidate[targetPosition] = .value(.init(
            choice: ChoiceValue(
                choiceTag.makeConvertible(bitPattern64: probeValue),
                tag: choiceTag
            ),
            validRange: validRange,
            isRangeExplicit: isRangeExplicit
        ))
        return candidate
    }

    var convergenceRecords: [Int: ConvergedOrigin] {
        guard started else { return [:] }
        let bound = foundLowerFloor ? bestBound : scanRange.upperBound + 1
        return [
            targetPosition: ConvergedOrigin(
                bound: bound,
                signal: .scanComplete(foundLowerFloor: foundLowerFloor),
                configuration: .linearScan,
                cycle: currentCycle
            )
        ]
    }
}
