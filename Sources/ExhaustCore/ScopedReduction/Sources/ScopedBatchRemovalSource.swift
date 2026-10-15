//
//  ScopedBatchRemovalSource.swift
//  Exhaust
//

// MARK: - Batch Removal Source

/// Emits removal scopes for a single sequence at geometrically decreasing batch sizes, then interior windows that grow adaptively.
///
/// Starts below full emptying, which the emptying family covers, and halves after each head and tail pair. Alternates tail and head anchors at each batch size. Each emitted scope fully specifies which positions to remove, so the encoder applies it in one probe.
///
/// Once halving finishes, emits one ``RemovalScope/window(_:)`` seed per halving-grid offset (`count / 2`, `count / 4`, and so on). Window removal grows each seed rightward, reaching runs that neither anchor covers. Seeds whose window cannot hold two elements are skipped, because a one-element window duplicates the per-element removal scopes.
struct ScopedBatchRemovalSource {
    private enum RemovalAnchor {
        case head
        case tail
    }

    private let sequenceNodeID: Int
    private let elements: [(nodeID: Int, positionRange: ClosedRange<Int>)]
    private let maxBatch: Int
    private var currentBatch: Int
    private var triedTail: Bool
    private var exhausted: Bool
    private var cachedPriority: DispatchPriority?
    private let interiorSeeds: [PricedEncoderScope]
    private var interiorIndex = 0

    init(sequenceNodeID: Int, graph: ChoiceGraph) {
        self.sequenceNodeID = sequenceNodeID
        var elementList: [(nodeID: Int, positionRange: ClosedRange<Int>)] = []
        let node = graph.nodes[sequenceNodeID]
        guard case let .sequence(metadata) = node.kind else {
            elements = []
            maxBatch = 0
            currentBatch = 0
            triedTail = false
            exhausted = true
            cachedPriority = nil
            interiorSeeds = []
            return
        }
        let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
        let deletable = metadata.elementCount - minLength
        for childID in node.children {
            guard let range = graph.nodes[childID].positionRange else {
                continue
            }
            elementList.append((nodeID: childID, positionRange: range))
        }
        elementList.sort { $0.positionRange.lowerBound < $1.positionRange.lowerBound }

        var seeds: [PricedEncoderScope] = []
        var seedOffset = elementList.count / 2
        while seedOffset > 0 {
            let capacity = min(deletable, elementList.count - seedOffset)
            if capacity >= 2 {
                let window = elementList[seedOffset ..< seedOffset + capacity]
                seeds.append(PricedEncoderScope(
                    encoderScope: .removal(.window(WindowRemovalScope(
                        sequenceNodeID: sequenceNodeID,
                        elementNodeIDs: window.map(\.nodeID)
                    ))),
                    // The seed's first probe removes one element, so its priority reflects that element's yield rather than the window's capacity.
                    priority: DispatchPriority(
                        structuralBenefit: elementList[seedOffset].positionRange.count,
                        valueBenefit: 0,
                        reductionMagnitude: 0,
                        estimatedCost: 1
                    )
                ))
            }
            seedOffset /= 2
        }
        interiorSeeds = seeds

        elements = elementList
        maxBatch = deletable
        // Start below full emptying: half the maximum, or one less than the maximum when it is small.
        let startBatch = deletable > 2 ? deletable / 2 : max(deletable - 1, 0)
        currentBatch = startBatch
        triedTail = false
        exhausted = startBatch <= 0
        cachedPriority = nil
        recomputePriority()
    }

    var dispatchPriority: DispatchPriority? {
        cachedPriority
    }

    mutating func nextScope() -> PricedEncoderScope? {
        if let encoderScope = nextHalvingWindow() {
            return encoderScope
        }
        return nextInteriorSeed()
    }

    // MARK: - Helpers

    private var nextInteriorSeedPriority: DispatchPriority? {
        guard interiorIndex < interiorSeeds.count else {
            return nil
        }
        return interiorSeeds[interiorIndex].priority
    }

    private mutating func nextHalvingWindow() -> PricedEncoderScope? {
        guard exhausted == false, currentBatch > 0 else {
            return nil
        }

        let anchor: RemovalAnchor = triedTail ? .head : .tail

        // Build the scope with specific positions.
        let offset = switch anchor {
            case .tail:
                elements.count - currentBatch
            case .head:
                elements.count - maxBatch
        }
        guard offset >= 0, offset + currentBatch <= elements.count else {
            exhausted = true
            recomputePriority()
            return nil
        }

        let slice = elements[offset ..< offset + currentBatch]
        var batchYield = 0
        for element in slice {
            batchYield += element.positionRange.count
        }

        let scope = ElementRemovalScope(
            targets: [SequenceRemovalTarget(
                sequenceNodeID: sequenceNodeID,
                elementNodeIDs: slice.map { $0.nodeID }
            )],
            maxBatch: currentBatch,
            maxElementYield: batchYield
        )

        let encoderScope = PricedEncoderScope(
            encoderScope: .removal(.elements(scope)),
            priority: DispatchPriority(
                structuralBenefit: batchYield,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
        )

        // Advance state for the next call.
        if triedTail == false {
            // Just emitted tail. Next: try head at the same batch size.
            triedTail = true
        } else {
            // Just emitted head. Halve the batch size.
            triedTail = false
            currentBatch /= 2
            if currentBatch <= 0 {
                exhausted = true
            }
        }

        recomputePriority()
        return encoderScope
    }

    private mutating func nextInteriorSeed() -> PricedEncoderScope? {
        guard interiorIndex < interiorSeeds.count else {
            cachedPriority = nil
            return nil
        }
        let encoderScope = interiorSeeds[interiorIndex]
        interiorIndex += 1
        recomputePriority()
        return encoderScope
    }

    private mutating func recomputePriority() {
        guard exhausted == false, currentBatch > 0 else {
            cachedPriority = nextInteriorSeedPriority
            return
        }
        let anchor: RemovalAnchor = triedTail ? .head : .tail
        let offset = switch anchor {
            case .tail:
                elements.count - currentBatch
            case .head:
                elements.count - maxBatch
        }
        guard offset >= 0, offset + currentBatch <= elements.count else {
            cachedPriority = nextInteriorSeedPriority
            return
        }
        var batchYield = 0
        for element in elements[offset ..< offset + currentBatch] {
            batchYield += element.positionRange.count
        }
        cachedPriority = DispatchPriority(
            structuralBenefit: batchYield,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 1
        )
    }
}
