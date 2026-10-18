//
//  BinarySearch.swift
//  Exhaust
//

// MARK: - Binary Search

/// Feedback-driven binary search over one leaf, between its current bit pattern and its reduction target.
///
/// ``BinarySearchStepper`` chooses the direction and narrows the interval using acceptance feedback. Each candidate preserves the leaf's type tag and range metadata.
struct BinarySearch: ReductionSearch {
    private var leafNodeID: Int = -1
    private var sequenceIndex: Int = -1
    private var typeTag: TypeTag = .uint
    private var validRange: ClosedRange<UInt64>?
    private var isRangeExplicit: Bool = false
    private var stepper: BinarySearchStepper?
    private let baseSequence: ChoiceSequence
    private let mayReshape: Bool
    private var needsFirstProbe = true

    /// Searches the first of `leaves`. The search is empty when that leaf has no position, no value entry, or already sits at its target.
    ///
    /// - Parameter mayReshape: Whether each candidate's mutation marks the leaf as reshaping. A leaf that controls a bind rebuilds the subtree it governs when accepted, so its mutation has to say so; inside a composition the enclosing encoder's reduction reports the mutation instead.
    init(leaves: [LeafEntry], graph: ChoiceGraph, baseSequence: ChoiceSequence, mayReshape: Bool = false) {
        self.baseSequence = baseSequence
        self.mayReshape = mayReshape

        guard let entry = leaves.first else {
            return
        }
        guard entry.nodeID < graph.nodes.count,
              case let .chooseBits(metadata) = graph.nodes[entry.nodeID].kind,
              let range = graph.nodes[entry.nodeID].positionRange,
              range.lowerBound < baseSequence.count,
              baseSequence[range.lowerBound].value != nil
        else {
            return
        }

        let currentBitPattern = metadata.value.bitPattern64
        let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
        guard currentBitPattern != targetBitPattern else {
            return
        }

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

    mutating func next(_ feedback: SearchFeedback, into buffer: inout ChoiceSequence) -> ReductionCandidate? {
        guard leafNodeID >= 0 else {
            return nil
        }

        let nextBitPattern: UInt64?
        if needsFirstProbe {
            needsFirstProbe = false
            nextBitPattern = stepper?.start()
        } else {
            nextBitPattern = stepper?.advance(lastAccepted: feedback.isAccepted)
        }
        guard let bitPattern = nextBitPattern else {
            return nil
        }

        let newChoice = ChoiceValue(
            typeTag.makeConvertible(bitPattern64: bitPattern),
            tag: typeTag
        )
        buffer = baseSequence
        buffer[sequenceIndex] = .value(.init(
            choice: newChoice,
            validRange: validRange,
            isRangeExplicit: isRangeExplicit
        ))

        let change = LeafChange(
            leafNodeID: leafNodeID,
            newValue: newChoice,
            mayReshape: mayReshape
        )
        return .written(mutation: .leafValues([change]), admission: .standard)
    }
}
