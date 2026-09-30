//
//  GraphBinarySearchEncoder.swift
//  Exhaust
//

// MARK: - Graph Binary Search Encoder

/// Pure binary search over a single integer leaf in bit-pattern space, intended as the upstream slot of a ``GraphComposedEncoder``.
///
/// Operates on a one-leaf ``ValueMinimizationScope`` and emits a sequence of midpoint probes between the leaf's current bit pattern and its reduction target. On rejection, narrows the lower bound (`lo = lastProbe + 1`). On acceptance, narrows the upper bound (`hi = lastProbe`). Converges to the smallest accepted value, or to the original current value if every probe is rejected.
///
/// ## Why not ``GraphValueEncoder``?
///
/// ``GraphValueEncoder`` is designed for *standalone* integer minimization: after binary search converges short of the target, it falls into an inline linear scan (up to ``GraphValueEncoder/linearScanThreshold``) to look for non-monotone gaps, then a cross-zero phase for signed types. Both are appropriate when each probe is cheap. Inside a bound value composition, every upstream probe spawns one generator lift materialization plus a full downstream bound subtree search — so 10+ extra linear-scan upstream probes per dispatch is catastrophic. This encoder strips those phases down to plain binary search.
///
/// ## Lifecycle
///
/// 1. ``start(scope:)`` extracts the single leaf from the scope's ``ValueMinimizationScope``, reads its current and target bit patterns, and initializes a ``BinarySearchStepper``. Multi-leaf scopes are not supported and produce no probes.
/// 2. ``nextProbe(into:lastAccepted:)`` returns midpoint candidates until convergence. Each candidate writes the next bit pattern into the caller's inout buffer; the mutation is `.leafValues([LeafChange])` with `mayReshape: false` so the enclosing ``GraphComposedEncoder/wrap(downstreamMutation:candidate:upstreamProbe:)`` can flip the flag to `true` when wrapping the downstream probe.
///
/// - SeeAlso: ``GraphComposedEncoder``, ``BinarySearchStepper``
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
