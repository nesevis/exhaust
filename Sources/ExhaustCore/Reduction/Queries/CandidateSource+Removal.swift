//
//  CandidateSource+Removal.swift
//  Exhaust
//

// MARK: - Batched Cross-Sequence Removal Source

/// Attempts compatible sequences at their range minima first, then bisects the target list on rejection.
///
/// Tree traversal prefers outer sequences, prunes descendants inside deleted elements, and excludes targets invalidated by a changed bind inner. The initial all-sequence probe requires draining the selection cursor, but its compact plans share graph child storage and defer element-ID expansion until a scope is emitted.
///
/// A structural acceptance rebuilds the source collection. Advancing this cursor therefore means the previous scope did not accept, so its range can be bisected without explicit feedback.
///
/// Runs before the emptying builder — a successful first probe can eliminate more structure in one materialization than emptying sequences individually.
struct BatchedCrossSequenceRemovalSource {
    private let plans: [TreeDeletionSelection.Plan]
    /// Stack of index ranges to try. Continuing after an unsuccessful scope appends its two halves.
    private var pendingRanges: [(start: Int, end: Int)]
    /// The last emitted range, bisected if this cursor is advanced again.
    private var lastEmittedRange: (start: Int, end: Int)?
    private var exhausted: Bool
    private var cachedPriority: DispatchPriority?
    private(set) var prefersInitialDispatch: Bool

    init(graph: ChoiceGraph) {
        plans = Self.treePlans(graph: graph)
        let count = plans.count
        // Only useful when there are at least two independent sequences to batch.
        if count >= 2 {
            pendingRanges = [(start: 0, end: count)]
            lastEmittedRange = nil
            exhausted = false
        } else {
            pendingRanges = []
            lastEmittedRange = nil
            exhausted = true
        }
        cachedPriority = nil
        prefersInitialDispatch = count >= 2
        recomputePriority()
    }

    /// Drains lightweight plans for the initial all-sequence probe without expanding their element-ID arrays.
    private static func treePlans(graph: ChoiceGraph) -> [TreeDeletionSelection.Plan] {
        var cursor = TreeDeletionSelection.Cursor(graph: graph)
        var entries: [TreeDeletionSelection.Plan] = []
        while let plan = cursor.next() {
            entries.append(plan)
        }
        entries.sort { $0.yield > $1.yield }
        return entries
    }

    var peekPriority: DispatchPriority? {
        cachedPriority
    }

    private mutating func recomputePriority() {
        guard exhausted == false else {
            cachedPriority = nil
            return
        }
        if let range = pendingRanges.last {
            var totalYield = 0
            for index in range.start ..< range.end {
                totalYield += plans[index].yield
            }
            cachedPriority = DispatchPriority(
                structuralBenefit: totalYield,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
            return
        }
        // Advertise the first half of the deferred bisection even when the stack is empty, so the scheduler continues enumeration rather than dropping the source after its root scope.
        if let emitted = lastEmittedRange {
            let count = emitted.end - emitted.start
            guard count >= 2 else {
                cachedPriority = nil
                return
            }
            let mid = emitted.start + count / 2
            var firstHalfYield = 0
            for index in emitted.start ..< mid {
                firstHalfYield += plans[index].yield
            }
            cachedPriority = DispatchPriority(
                structuralBenefit: firstHalfYield,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
            return
        }
        cachedPriority = nil
    }

    /// Continuing the same graph snapshot bisects the previous unsuccessful scope; accepted structural edits discard this cursor.
    mutating func next() -> GraphTransformation? {
        prefersInitialDispatch = false
        guard exhausted == false else {
            return nil
        }
        if let emitted = lastEmittedRange {
            lastEmittedRange = nil
            let count = emitted.end - emitted.start
            if count >= 2 {
                let mid = emitted.start + count / 2
                // The first half contains the highest-yield sequences and is popped first.
                pendingRanges.append((start: mid, end: emitted.end))
                pendingRanges.append((start: emitted.start, end: mid))
            }
        }

        guard let range = pendingRanges.popLast() else {
            exhausted = true
            cachedPriority = nil
            return nil
        }
        lastEmittedRange = range

        let indices = range.start ..< range.end
        let targets = plans[indices].map { $0.target }
        var totalYield = 0
        var maxElementYield = 0
        var maxBatch = 0
        for index in indices {
            let entryYield = plans[index].yield
            totalYield += entryYield
            if entryYield > maxElementYield {
                maxElementYield = entryYield
            }
            maxBatch += plans[index].deletableCount
        }

        let scope = ElementRemovalScope(
            targets: targets,
            maxBatch: maxBatch,
            maxElementYield: maxElementYield
        )

        recomputePriority()

        return GraphTransformation(
            operation: .remove(.elements(scope)),
            priority: DispatchPriority(
                structuralBenefit: totalYield,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
        )
    }
}

// MARK: - Batch Removal Source

/// Emits per-parent removal scopes at geometrically decreasing batch sizes for a single sequence, then interior windows that grow adaptively.
///
/// Starts at the maximum batch size (all deletable elements) and halves on rejection. Alternates head/tail anchors at each batch size. Each emitted scope fully specifies which positions to remove — the encoder applies it in one probe.
///
/// Once halving finishes, emits one ``RemovalScope/window(_:)`` seed per halving-grid offset (`count / 2`, `count / 4`, and so on). ``GraphWindowRemovalEncoder`` grows each seed rightward with ``FindIntegerStepper``, reaching runs that neither anchor covers. Seeds whose window cannot hold two elements are skipped, because a one-element window duplicates the per-element removal candidates.
struct BatchRemovalSource {
    private let sequenceNodeID: Int
    private let elements: [(nodeID: Int, positionRange: ClosedRange<Int>)]
    private let maxBatch: Int
    private var currentBatch: Int
    private var triedTail: Bool
    private var exhausted: Bool
    private var cachedPriority: DispatchPriority?
    private let interiorSeeds: [GraphTransformation]
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
            guard let range = graph.nodes[childID].positionRange else { continue }
            elementList.append((nodeID: childID, positionRange: range))
        }
        elementList.sort { $0.positionRange.lowerBound < $1.positionRange.lowerBound }

        var seeds: [GraphTransformation] = []
        var seedOffset = elementList.count / 2
        while seedOffset > 0 {
            let capacity = min(deletable, elementList.count - seedOffset)
            if capacity >= 2 {
                let window = elementList[seedOffset ..< seedOffset + capacity]
                seeds.append(GraphTransformation(
                    operation: .remove(.window(WindowRemovalScope(
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
        // Start below full emptying (emptying builder handles that).
        // Begin at half the max, or max-1 if max is small.
        let startBatch = deletable > 2 ? deletable / 2 : max(deletable - 1, 0)
        currentBatch = startBatch
        triedTail = false
        exhausted = startBatch <= 0
        cachedPriority = nil
        recomputePriority()
    }

    var peekPriority: DispatchPriority? {
        cachedPriority
    }

    mutating func next() -> GraphTransformation? {
        if let transformation = nextHalvingWindow() {
            return transformation
        }
        return nextInteriorSeed()
    }

    private mutating func nextHalvingWindow() -> GraphTransformation? {
        guard exhausted == false, currentBatch > 0 else { return nil }

        let anchor: RemovalAnchor = triedTail ? .head : .tail

        // Build the scope with specific positions.
        let offset = switch anchor {
            case .tail: elements.count - currentBatch
            case .head: elements.count - maxBatch
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

        let transformation = GraphTransformation(
            operation: .remove(.elements(scope)),
            priority: DispatchPriority(
                structuralBenefit: batchYield,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
        )

        // Advance state for next call.
        if triedTail == false {
            // Just emitted tail. Next: try head at same batch size.
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
        return transformation
    }

    private mutating func nextInteriorSeed() -> GraphTransformation? {
        guard interiorIndex < interiorSeeds.count else {
            cachedPriority = nil
            return nil
        }
        let transformation = interiorSeeds[interiorIndex]
        interiorIndex += 1
        recomputePriority()
        return transformation
    }

    private enum RemovalAnchor { case head, tail }

    private var nextInteriorSeedPriority: DispatchPriority? {
        guard interiorIndex < interiorSeeds.count else {
            return nil
        }
        return interiorSeeds[interiorIndex].priority
    }

    private mutating func recomputePriority() {
        guard exhausted == false, currentBatch > 0 else {
            cachedPriority = nextInteriorSeedPriority
            return
        }
        let anchor: RemovalAnchor = triedTail ? .head : .tail
        let offset = switch anchor {
            case .tail: elements.count - currentBatch
            case .head: elements.count - maxBatch
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

extension BatchedCrossSequenceRemovalSource: CandidateSource {
    var isValueDependent: Bool {
        false
    }

    var isPermutationSource: Bool {
        false
    }
}

extension BatchRemovalSource: CandidateSource {
    var isValueDependent: Bool {
        false
    }

    var isPermutationSource: Bool {
        false
    }
}

// MARK: - Builder Functions

extension CandidateSourceBuilder {
    /// Seeds center-out deletion with the largest centered window allowed by each sequence's minimum length.
    ///
    /// Keeping the window's parity equal to the sequence's makes the first probe remove its middle element or middle pair. Its dispatch priority reflects only that first probe; subsequent growth is driven by acceptance feedback.
    static func buildCenteredCandidates(graph: ChoiceGraph, elementScopes: [ElementRemovalScope]) -> [GraphTransformation] {
        var results: [GraphTransformation] = []
        for scope in elementScopes {
            guard scope.targets.count == 1, let target = scope.targets.first else { continue }
            let elements = target.elementNodeIDs
            var capacity = min(scope.maxBatch, elements.count)
            if capacity % 2 != elements.count % 2 {
                capacity -= 1
            }
            guard capacity > 0 else { continue }
            let start = (elements.count - capacity) / 2
            let window = WindowRemovalScope(
                sequenceNodeID: target.sequenceNodeID,
                elementNodeIDs: Array(elements[start ..< start + capacity]),
                growth: .outward
            )
            guard let initialNodeIDs = window.removalNodeIDs(step: 1) else { continue }
            let initialYield = initialNodeIDs.reduce(0) { total, nodeID in
                total + (graph.nodes[nodeID].positionRange?.count ?? 0)
            }
            results.append(GraphTransformation(
                operation: .remove(.window(window)),
                priority: DispatchPriority(
                    structuralBenefit: initialYield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ))
        }
        results.sort { $0.priority > $1.priority }
        return results
    }

    /// Seeds equal prefix and suffix deletions within each sequence's minimum-length budget.
    ///
    /// The first probe removes both edge elements together. Increasing the search step grows both arms inward; the retained middle is omitted from the scope so it cannot be deleted or counted twice. Priority reflects only the first pair's yield.
    static func buildSymmetricCandidates(graph: ChoiceGraph, elementScopes: [ElementRemovalScope]) -> [GraphTransformation] {
        var results: [GraphTransformation] = []
        for scope in elementScopes {
            guard scope.targets.count == 1, let target = scope.targets.first else { continue }
            let elements = target.elementNodeIDs
            let pairCapacity = min(scope.maxBatch / 2, elements.count / 2)
            guard pairCapacity > 0 else { continue }
            let window = WindowRemovalScope(
                sequenceNodeID: target.sequenceNodeID,
                elementNodeIDs: Array(elements.prefix(pairCapacity)) + Array(elements.suffix(pairCapacity)),
                growth: .symmetric
            )
            let initialYield = (graph.nodes[elements[0]].positionRange?.count ?? 0)
                + (graph.nodes[elements[elements.count - 1]].positionRange?.count ?? 0)
            results.append(GraphTransformation(
                operation: .remove(.window(window)),
                priority: DispatchPriority(
                    structuralBenefit: initialYield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ))
        }
        results.sort { $0.priority > $1.priority }
        return results
    }

    /// Constructs emptying removal candidates for sequences whose minimum length constraint is zero. Each candidate removes all elements from a single sequence, producing the maximal structural reduction per sequence. Sorted by yield descending.
    static func buildEmptyingCandidates(graph: ChoiceGraph, elementScopes: [ElementRemovalScope]) -> [GraphTransformation] {
        var results: [GraphTransformation] = []
        for scope in elementScopes {
            // Only consider single-target (per-parent) scopes for emptying.
            guard scope.targets.count == 1, let target = scope.targets.first else { continue }
            guard case let .sequence(metadata) = graph.nodes[target.sequenceNodeID].kind else {
                continue
            }
            let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
            guard metadata.elementCount > minLength else { continue }
            guard minLength == 0 else { continue }
            let totalYield = target.elementNodeIDs.reduce(0) { total, nodeID in
                total + (graph.nodes[nodeID].positionRange?.count ?? 0)
            }

            let emptyingScope = ElementRemovalScope(
                targets: [SequenceRemovalTarget(
                    sequenceNodeID: target.sequenceNodeID,
                    elementNodeIDs: target.elementNodeIDs
                )],
                maxBatch: target.elementNodeIDs.count,
                maxElementYield: totalYield
            )

            results.append(GraphTransformation(
                operation: .remove(.elements(emptyingScope)),
                priority: DispatchPriority(
                    structuralBenefit: totalYield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ))
        }
        results.sort { $0.priority > $1.priority }
        return results
    }

    /// Constructs per-element removal candidates that delete one element at a time from each deletable sequence. Zero-valued elements are prioritized (removing an already-minimal element is more likely to preserve the property failure) and remaining elements are ordered by position.
    static func buildPerElementCandidates(graph: ChoiceGraph, elementScopes: [ElementRemovalScope]) -> [GraphTransformation] {
        var entries: [(sequenceNodeID: Int, nodeID: Int, positionRange: ClosedRange<Int>, isZero: Bool)] = []
        for scope in elementScopes {
            // Per-element source only handles single-target scopes.
            guard scope.targets.count == 1, let target = scope.targets.first else { continue }
            for elementNodeID in target.elementNodeIDs {
                guard let range = graph.nodes[elementNodeID].positionRange else { continue }
                let isZero: Bool
                if case let .chooseBits(metadata) = graph.nodes[elementNodeID].kind {
                    let reductionTarget = metadata.value.reductionTarget(in: metadata.validRange)
                    isZero = metadata.value.bitPattern64 == reductionTarget
                } else {
                    isZero = false
                }
                entries.append((
                    sequenceNodeID: target.sequenceNodeID,
                    nodeID: elementNodeID,
                    positionRange: range,
                    isZero: isZero
                ))
            }
        }
        // Zero-valued elements first, then by position.
        entries.sort { entryA, entryB in
            if entryA.isZero != entryB.isZero {
                return entryA.isZero
            }
            return entryA.positionRange.lowerBound < entryB.positionRange.lowerBound
        }

        return entries.map { element in
            let scope = ElementRemovalScope(
                targets: [SequenceRemovalTarget(
                    sequenceNodeID: element.sequenceNodeID,
                    elementNodeIDs: [element.nodeID]
                )],
                maxBatch: 1,
                maxElementYield: element.positionRange.count
            )
            return GraphTransformation(
                operation: .remove(.elements(scope)),
                priority: DispatchPriority(
                    structuralBenefit: element.positionRange.count,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            )
        }
    }

    /// Constructs covering-aligned removal candidates that delete elements at corresponding positions across multiple same-length sequences simultaneously. Sorted by maximum element yield descending so higher-impact aligned deletions are tried first.
    static func buildAlignedCandidates(graph: ChoiceGraph) -> [GraphTransformation] {
        let scopes = RemovalQuery.coveringAlignedRemovalScopes(graph: graph)
            .sorted { $0.maxElementYield > $1.maxElementYield }

        return scopes.map { scope in
            GraphTransformation(
                operation: .remove(.coveringAligned(scope)),
                priority: DispatchPriority(
                    structuralBenefit: scope.maxElementYield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: scope.generator.totalRemaining
                )
            )
        }
    }
}
