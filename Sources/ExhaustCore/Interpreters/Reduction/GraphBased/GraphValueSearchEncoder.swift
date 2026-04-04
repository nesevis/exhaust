//
//  GraphValueSearchEncoder.swift
//  Exhaust
//

// MARK: - Graph Value Search Encoder

/// Minimises leaf values in the ``ChoiceGraph`` via batch zeroing then per-leaf binary search.
///
/// ## Phase 1 (Batch Zero)
/// Sets all leaf values to their semantic simplest simultaneously. If the property still fails, all leaves are zeroed in one probe.
///
/// ## Phase 2 (Per-Leaf Binary Search)
/// For each leaf that was not zeroed, runs a bidirectional ``BinarySearchStepper`` (or ``MaxBinarySearchStepper``) toward the reduction target. A cross-zero phase follows for signed integers.
///
/// - SeeAlso: ``ZeroValueEncoder``, ``BinarySearchEncoder``
public struct GraphValueSearchEncoder: GraphEncoder {
    public let name: EncoderName = .graphValueSearch

    // MARK: - State

    private enum Phase {
        case batchZero
        case perLeaf
    }

    private var sequence = ChoiceSequence()
    private var phase = Phase.batchZero

    /// Per-leaf targets extracted from the graph.
    private var leaves: [LeafTarget] = []
    private var leafIndex = 0
    private var needsFirstProbe = true

    /// Binary search phase tracking for the current leaf.
    private var searchPhase = SearchPhase.binarySearch

    /// Saved entry for rollback on rejection.
    private var savedEntry: ChoiceSequenceValue?

    /// Whether the batch-zero probe was rejected (triggers zeroingDependency signals).
    private var batchRejected = false

    /// Leaves that were individually zeroed after batch rejection.
    private var individuallyAccepted: Set<Int> = []

    /// Convergence records accumulated during the probe loop.
    public private(set) var convergenceRecords: [Int: ConvergedOrigin] = [:]

    private var currentCycle: Int = 0

    private struct LeafTarget {
        let sequenceIndex: Int
        let typeTag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        let currentBitPattern: UInt64
        let targetBitPattern: UInt64
        var stepper: DirectionalStepper
        let isConvergedOrigined: Bool
        let convergedOriginBound: UInt64
    }

    private enum DirectionalStepper {
        case downward(BinarySearchStepper)
        case upward(MaxBinarySearchStepper)

        var bestAccepted: UInt64 {
            switch self {
            case let .downward(stepper): stepper.bestAccepted
            case let .upward(stepper): stepper.bestAccepted
            }
        }

        mutating func start() -> UInt64? {
            switch self {
            case var .downward(stepper):
                let value = stepper.start()
                self = .downward(stepper)
                return value
            case var .upward(stepper):
                let value = stepper.start()
                self = .upward(stepper)
                return value
            }
        }

        mutating func advance(lastAccepted: Bool) -> UInt64? {
            switch self {
            case var .downward(stepper):
                let value = stepper.advance(lastAccepted: lastAccepted)
                self = .downward(stepper)
                return value
            case var .upward(stepper):
                let value = stepper.advance(lastAccepted: lastAccepted)
                self = .upward(stepper)
                return value
            }
        }
    }

    private enum SearchPhase {
        case binarySearch
        case validatingFloor(floor: UInt64, targetBitPattern: UInt64)
        case crossZero(currentKey: UInt64, lowerBound: UInt64)
    }

    // MARK: - GraphEncoder

    public mutating func start(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        tree _: ChoiceTree
    ) {
        self.sequence = sequence
        phase = .batchZero
        leafIndex = 0
        needsFirstProbe = true
        searchPhase = .binarySearch
        savedEntry = nil
        batchRejected = false
        individuallyAccepted = []
        convergenceRecords = [:]
        currentCycle = 0

        let leafNodeIDs = graph.leafNodes
        leaves = []

        for nodeID in leafNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind,
                  let positionRange = node.positionRange
            else { continue }

            let sequenceIndex = positionRange.lowerBound
            let currentBitPattern = metadata.value.bitPattern64
            let isWithinRecordedRange = metadata.isRangeExplicit
                && metadata.value.fits(in: metadata.validRange)
            let targetBitPattern = isWithinRecordedRange
                ? metadata.value.reductionTarget(in: metadata.validRange)
                : metadata.value.semanticSimplest.bitPattern64

            guard currentBitPattern != targetBitPattern else { continue }

            // Skip floating-point values — they use a separate encoder.
            guard metadata.typeTag.isFloatingPoint == false else { continue }

            let stepper: DirectionalStepper
            if currentBitPattern > targetBitPattern {
                stepper = .downward(BinarySearchStepper(
                    lo: targetBitPattern,
                    hi: currentBitPattern
                ))
            } else {
                stepper = .upward(MaxBinarySearchStepper(
                    lo: currentBitPattern,
                    hi: targetBitPattern
                ))
            }

            leaves.append(LeafTarget(
                sequenceIndex: sequenceIndex,
                typeTag: metadata.typeTag,
                validRange: metadata.validRange,
                isRangeExplicit: metadata.isRangeExplicit,
                currentBitPattern: currentBitPattern,
                targetBitPattern: targetBitPattern,
                stepper: stepper,
                isConvergedOrigined: false,
                convergedOriginBound: targetBitPattern
            ))
        }
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard leaves.isEmpty == false else { return nil }

        switch phase {
        case .batchZero:
            phase = .perLeaf
            leafIndex = 0

            // Build the all-simplest candidate.
            var allSimplest = sequence
            for leaf in leaves {
                let target = ChoiceValue(
                    leaf.typeTag.makeConvertible(bitPattern64: leaf.targetBitPattern),
                    tag: leaf.typeTag
                )
                allSimplest[leaf.sequenceIndex] = .value(.init(
                    choice: target,
                    validRange: leaf.validRange,
                    isRangeExplicit: leaf.isRangeExplicit
                ))
            }
            return allSimplest

        case .perLeaf:
            // Process batch-zero feedback on first entry.
            if leafIndex == 0, needsFirstProbe {
                needsFirstProbe = false
                if lastAccepted {
                    // Batch accepted — update base sequence.
                    for leaf in leaves {
                        let target = ChoiceValue(
                            leaf.typeTag.makeConvertible(bitPattern64: leaf.targetBitPattern),
                            tag: leaf.typeTag
                        )
                        sequence[leaf.sequenceIndex] = .value(.init(
                            choice: target,
                            validRange: leaf.validRange,
                            isRangeExplicit: leaf.isRangeExplicit
                        ))
                    }
                    return nil
                }
                batchRejected = true
            }

            return advancePerLeaf(lastAccepted: lastAccepted)
        }
    }

    // MARK: - Per-Leaf Binary Search

    private mutating func advancePerLeaf(lastAccepted: Bool) -> ChoiceSequence? {
        while leafIndex < leaves.count {
            switch searchPhase {
            case .binarySearch:
                if let candidate = advanceBinarySearch(lastAccepted: lastAccepted) {
                    return candidate
                }
                let leaf = leaves[leafIndex]
                let bestAccepted = leaf.stepper.bestAccepted

                // Record convergence.
                let signal: ConvergenceSignal
                if bestAccepted > leaf.targetBitPattern {
                    let remaining = bestAccepted - leaf.targetBitPattern
                    if remaining <= 64 {
                        signal = .nonMonotoneGap(remainingRange: Int(remaining))
                    } else {
                        signal = .monotoneConvergence
                    }
                } else {
                    signal = .monotoneConvergence
                }
                convergenceRecords[leaf.sequenceIndex] = ConvergedOrigin(
                    bound: bestAccepted,
                    signal: signal,
                    configuration: .binarySearchSemanticSimplest,
                    cycle: currentCycle
                )

                // Validation probe for warm-started downward search.
                if leaf.isConvergedOrigined,
                   case .downward = leaf.stepper,
                   leaf.convergedOriginBound > leaf.targetBitPattern,
                   leaf.convergedOriginBound > 0,
                   leaf.convergedOriginBound < leaf.currentBitPattern
                {
                    searchPhase = .validatingFloor(
                        floor: leaf.convergedOriginBound,
                        targetBitPattern: leaf.targetBitPattern
                    )
                    savedEntry = sequence[leaf.sequenceIndex]
                    let probeBitPattern = leaf.convergedOriginBound - 1
                    sequence[leaf.sequenceIndex] = .value(.init(
                        choice: ChoiceValue(
                            leaf.typeTag.makeConvertible(bitPattern64: probeBitPattern),
                            tag: leaf.typeTag
                        ),
                        validRange: leaf.validRange,
                        isRangeExplicit: leaf.isRangeExplicit
                    ))
                    return sequence
                }
                // Try cross-zero for signed types.
                if tryCrossZeroEntry(for: leaf) {
                    continue
                }
                advanceToNextLeaf()

            case let .validatingFloor(floor, targetBitPattern):
                if lastAccepted {
                    if let saved = savedEntry {
                        sequence[leaves[leafIndex].sequenceIndex] = saved
                        savedEntry = nil
                    }
                    let leaf = leaves[leafIndex]
                    leaves[leafIndex] = LeafTarget(
                        sequenceIndex: leaf.sequenceIndex,
                        typeTag: leaf.typeTag,
                        validRange: leaf.validRange,
                        isRangeExplicit: leaf.isRangeExplicit,
                        currentBitPattern: leaf.currentBitPattern,
                        targetBitPattern: leaf.targetBitPattern,
                        stepper: .downward(BinarySearchStepper(lo: targetBitPattern, hi: floor - 1)),
                        isConvergedOrigined: false,
                        convergedOriginBound: targetBitPattern
                    )
                    needsFirstProbe = true
                    searchPhase = .binarySearch
                    continue
                }
                if let saved = savedEntry {
                    sequence[leaves[leafIndex].sequenceIndex] = saved
                    savedEntry = nil
                }
                let leaf = leaves[leafIndex]
                if tryCrossZeroEntry(for: leaf) {
                    continue
                }
                advanceToNextLeaf()

            case let .crossZero(currentKey, lowerBound):
                if let saved = savedEntry {
                    if lastAccepted {
                        let leaf = leaves[leafIndex]
                        let acceptedChoice = ChoiceValue.fromShortlexKey(
                            currentKey,
                            tag: leaf.typeTag
                        )
                        sequence[leaf.sequenceIndex] = .reduced(.init(
                            choice: acceptedChoice,
                            validRange: leaf.validRange,
                            isRangeExplicit: leaf.isRangeExplicit
                        ))
                    } else {
                        sequence[leaves[leafIndex].sequenceIndex] = saved
                    }
                    savedEntry = nil
                }
                guard currentKey > lowerBound else {
                    advanceToNextLeaf()
                    continue
                }
                let nextKey = currentKey - 1
                searchPhase = .crossZero(currentKey: nextKey, lowerBound: lowerBound)
                let leaf = leaves[leafIndex]
                let probeChoice = ChoiceValue.fromShortlexKey(nextKey, tag: leaf.typeTag)
                if leaf.isRangeExplicit, probeChoice.fits(in: leaf.validRange) == false {
                    continue
                }
                let probeEntry = ChoiceSequenceValue.reduced(.init(
                    choice: probeChoice,
                    validRange: leaf.validRange,
                    isRangeExplicit: leaf.isRangeExplicit
                ))
                guard probeEntry.shortLexCompare(sequence[leaf.sequenceIndex]) == .lt else {
                    continue
                }
                savedEntry = sequence[leaf.sequenceIndex]
                sequence[leaf.sequenceIndex] = probeEntry
                return sequence
            }
        }
        return nil
    }

    // MARK: - Binary Search Helpers

    private mutating func advanceBinarySearch(lastAccepted: Bool) -> ChoiceSequence? {
        let probeValue: UInt64?

        if needsFirstProbe {
            needsFirstProbe = false
            probeValue = leaves[leafIndex].stepper.start()
        } else {
            let leaf = leaves[leafIndex]
            if lastAccepted {
                individuallyAccepted.insert(leaf.sequenceIndex)
                sequence[leaf.sequenceIndex] = .value(.init(
                    choice: ChoiceValue(
                        leaf.typeTag.makeConvertible(bitPattern64: leaf.stepper.bestAccepted),
                        tag: leaf.typeTag
                    ),
                    validRange: leaf.validRange,
                    isRangeExplicit: leaf.isRangeExplicit
                ))
            } else if let saved = savedEntry {
                sequence[leaf.sequenceIndex] = saved
            }
            savedEntry = nil
            probeValue = leaves[leafIndex].stepper.advance(lastAccepted: lastAccepted)
        }

        guard let bitPattern = probeValue else { return nil }
        let leaf = leaves[leafIndex]
        if let current = sequence[leaf.sequenceIndex].value,
           bitPattern == current.choice.bitPattern64
        {
            return nil
        }
        savedEntry = sequence[leaf.sequenceIndex]
        sequence[leaf.sequenceIndex] = .value(.init(
            choice: ChoiceValue(
                leaf.typeTag.makeConvertible(bitPattern64: bitPattern),
                tag: leaf.typeTag
            ),
            validRange: leaf.validRange,
            isRangeExplicit: leaf.isRangeExplicit
        ))
        return sequence
    }

    /// Attempts to enter the cross-zero phase for a signed leaf. Returns true if entered (caller should `continue`).
    private mutating func tryCrossZeroEntry(for leaf: LeafTarget) -> Bool {
        guard leaf.typeTag.isSigned else { return false }
        if leaf.isConvergedOrigined {
            let currentBitPattern = sequence[leaf.sequenceIndex].value?.choice.bitPattern64 ?? 0
            if currentBitPattern == leaf.convergedOriginBound {
                return false
            }
        }
        let currentChoice = sequence[leaf.sequenceIndex].value?.choice ?? ChoiceValue(
            leaf.typeTag.makeConvertible(bitPattern64: leaf.stepper.bestAccepted),
            tag: leaf.typeTag
        )
        let currentKey = currentChoice.shortlexKey
        guard currentKey > 0 else { return false }
        let maxProbes: UInt64 = 16
        let lowerBound = currentKey > maxProbes ? currentKey - maxProbes : 0
        searchPhase = .crossZero(currentKey: currentKey, lowerBound: lowerBound)
        return true
    }

    private mutating func advanceToNextLeaf() {
        leafIndex += 1
        needsFirstProbe = true
        searchPhase = .binarySearch
    }
}

// MARK: - Zeroing Dependency Convergence

extension GraphValueSearchEncoder {
    /// Returns convergence records flagged with ``ConvergenceSignal/zeroingDependency`` for leaves that were individually zeroed after a batch rejection.
    var zeroingDependencyRecords: [Int: ConvergedOrigin] {
        guard batchRejected, individuallyAccepted.isEmpty == false else { return [:] }
        var records: [Int: ConvergedOrigin] = [:]
        for leaf in leaves where individuallyAccepted.contains(leaf.sequenceIndex) {
            records[leaf.sequenceIndex] = ConvergedOrigin(
                bound: leaf.targetBitPattern,
                signal: .zeroingDependency,
                configuration: .zeroValue,
                cycle: currentCycle
            )
        }
        return records
    }
}
