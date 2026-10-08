//
//  GraphBinarySearchEncoder.swift
//  Exhaust
//

// MARK: - Graph Binary Search Encoder

/// Feedback-driven binary search over one leaf for depth collapse and terminal value searches. Lifted proposals use the fixed rejected ladder from ``LeafCandidates`` instead.
///
/// Reads the first leaf in a ``ValueMinimizationScope`` and searches between its current bit pattern and reduction target. ``BinarySearchStepper`` chooses the direction and narrows the interval using acceptance feedback. Unlike ``GraphValueEncoder``, this search has no linear-scan or cross-zero phases.
///
/// Each candidate preserves the leaf's type tag and range metadata. The emitted mutation has `mayReshape: false`; an enclosing composition supplies reshaping semantics when necessary.
///
/// - SeeAlso: ``BinarySearchStepper``, ``LeafCandidates``.
struct GraphBinarySearchEncoder: GraphEncoder {
    let name: EncoderName = .valueSearch

    private var leafNodeID: Int = -1
    private var sequenceIndex: Int = -1
    private var typeTag: TypeTag = .uint
    private var validRange: ClosedRange<UInt64>?
    private var isRangeExplicit: Bool = false
    private var stepper: BinarySearchStepper?
    private var baseSequence: ChoiceSequence = .init([])
    private var needsFirstProbe = true

    mutating func start(scope: EncoderInput) {
        leafNodeID = -1
        sequenceIndex = -1
        stepper = nil
        baseSequence = scope.baseSequence
        needsFirstProbe = true

        guard case let .minimize(.valueLeaves(integerScope)) = scope.transformation.operation,
              let entry = integerScope.leaves.first
        else { return }
        let graph = scope.graph
        guard entry.nodeID < graph.nodes.count,
              case let .chooseBits(metadata) = graph.nodes[entry.nodeID].kind,
              let range = graph.nodes[entry.nodeID].positionRange,
              range.lowerBound < scope.baseSequence.count,
              scope.baseSequence[range.lowerBound].value != nil
        else { return }

        let currentBitPattern = metadata.value.bitPattern64
        let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
        guard currentBitPattern != targetBitPattern else { return }

        leafNodeID = entry.nodeID
        sequenceIndex = range.lowerBound
        typeTag = metadata.typeTag
        validRange = metadata.validRange
        isRangeExplicit = metadata.isRangeExplicit
        if currentBitPattern > targetBitPattern {
            stepper = BinarySearchStepper(lo: targetBitPattern, hi: currentBitPattern, direction: .findSmallest)
        } else {
            stepper = BinarySearchStepper(lo: currentBitPattern, hi: targetBitPattern, direction: .findLargest)
        }
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard leafNodeID >= 0 else { return nil }

        let nextBitPattern: UInt64?
        if needsFirstProbe {
            needsFirstProbe = false
            nextBitPattern = stepper?.start()
        } else {
            nextBitPattern = stepper?.advance(lastAccepted: lastAccepted)
        }
        guard let bitPattern = nextBitPattern else { return nil }

        let newChoice = ChoiceValue(
            typeTag.makeConvertible(bitPattern64: bitPattern),
            tag: typeTag
        )
        candidate = baseSequence
        candidate[sequenceIndex] = .value(.init(
            choice: newChoice,
            validRange: validRange,
            isRangeExplicit: isRangeExplicit
        ))

        let change = LeafChange(
            leafNodeID: leafNodeID,
            newValue: newChoice,
            mayReshape: false
        )
        return .leafValues([change])
    }
}
