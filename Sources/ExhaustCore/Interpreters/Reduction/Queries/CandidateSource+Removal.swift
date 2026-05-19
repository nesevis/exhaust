//
//  CandidateSource+Removal.swift
//  Exhaust
//

// MARK: - Batched Cross-Sequence Removal Source

/// Emits a single scope that removes deletable elements from all antichain-independent sequences simultaneously, then bisects on rejection.
///
/// The deletion antichain identifies element nodes that are pairwise independent (no containment or dependency path). Grouping these by parent sequence yields a set of independent sequences. The first probe attempts to remove all deletable elements from every independent sequence at once. On rejection, the target list is bisected and each half is tried independently.
///
/// Runs before the emptying builder — a successful first probe can eliminate more structure in one materialization than emptying sequences individually.
struct BatchedCrossSequenceRemovalSource {
    /// Each entry represents one independent sequence with its deletable elements and yield.
    private let sequences: [(target: SequenceRemovalTarget, deletableCount: Int, yield: Int)]
    /// Queue of index ranges to try. Bisection appends two halves on rejection.
    private var pendingRanges: [(start: Int, end: Int)]
    /// The range most recently emitted as a probe, awaiting feedback.
    private var lastEmittedRange: (start: Int, end: Int)?
    private var exhausted: Bool
    private var cachedPriority: DispatchPriority?

    init(graph: ChoiceGraph) {
        // Group antichain members by parent sequence.
        var parentToElements: [Int: [Int]] = [:]
        for nodeID in graph.deletionAntichain {
            guard let parentID = graph.nodes[nodeID].parent else { continue }
            guard case .sequence = graph.nodes[parentID].kind else { continue }
            parentToElements[parentID, default: []].append(nodeID)
        }

        // For each independent sequence parent, gather ALL deletable elements (not just antichain members — the antichain tells us which sequences are independent, but within each sequence we want to remove as many elements as the length constraint permits).
        var entries: [(target: SequenceRemovalTarget, deletableCount: Int, yield: Int)] = []
        for (parentID, _) in parentToElements.sorted(by: { $0.key < $1.key }) {
            guard case let .sequence(metadata) = graph.nodes[parentID].kind else { continue }
            let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
            let deletable = metadata.elementCount - minLength
            guard deletable > 0 else { continue }

            // Collect children ordered by position, take the last `deletable` elements (tail-anchored removal is the default for batch deletion).
            let allChildren = graph.nodes[parentID].children
            var childrenWithPosition: [(nodeID: Int, lowerBound: Int)] = []
            for childID in allChildren {
                guard let range = graph.nodes[childID].positionRange else { continue }
                childrenWithPosition.append((nodeID: childID, lowerBound: range.lowerBound))
            }
            childrenWithPosition.sort { $0.lowerBound < $1.lowerBound }
            let deletableChildren = Array(childrenWithPosition.suffix(deletable))

            let yield = deletableChildren.reduce(0) { total, child in
                total + (graph.nodes[child.nodeID].positionRange?.count ?? 0)
            }

            entries.append((
                target: SequenceRemovalTarget(
                    sequenceNodeID: parentID,
                    elementNodeIDs: deletableChildren.map(\.nodeID)
                ),
                deletableCount: deletable,
                yield: yield
            ))
        }

        // Sort by yield descending so the bisection halves are balanced by impact.
        entries.sort { $0.yield > $1.yield }

        sequences = entries
        // Only useful when there are at least two independent sequences to batch.
        if entries.count >= 2 {
            pendingRanges = [(start: 0, end: entries.count)]
            lastEmittedRange = nil
            exhausted = false
        } else {
            pendingRanges = []
            lastEmittedRange = nil
            exhausted = true
        }
        cachedPriority = nil
        recomputePriority()
    }

    var peekPriority: DispatchPriority? { cachedPriority }

    private mutating func recomputePriority() {
        guard exhausted == false else {
            cachedPriority = nil
            return
        }
        // Active pending range — the normal case where the next ``next(lastAccepted:)`` call will pop ``pendingRanges.last`` and emit a probe for that range.
        if let range = pendingRanges.last {
            var totalYield = 0
            for index in range.start ..< range.end {
                totalYield += sequences[index].yield
            }
            cachedPriority = DispatchPriority(
                structuralBenefit: totalYield,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
            return
        }
        // Deferred bisection — the previous ``next(lastAccepted:)`` call emitted a probe whose rejection feedback has not yet been consumed. The next call will bisect ``lastEmittedRange`` into two halves and pop the higher-yield half (``[emitted.start, mid)``) first. Report that half's yield so the scheduler sees non-nil yield and dispatches ``next`` to actually perform the bisection. Without this branch, the scheduler drops the source from its merge the moment ``pendingRanges`` drains post-root, and the bisection code in ``next`` is never reached — making the halving tree functionally dead code in the current architecture.
        if let emitted = lastEmittedRange {
            let count = emitted.end - emitted.start
            guard count >= 2 else {
                cachedPriority = nil
                return
            }
            let mid = emitted.start + count / 2
            var firstHalfYield = 0
            for index in emitted.start ..< mid {
                firstHalfYield += sequences[index].yield
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

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
        guard exhausted == false else { return nil }

        // Handle feedback from the previous probe.
        if let emitted = lastEmittedRange {
            lastEmittedRange = nil
            if lastAccepted == false {
                // Bisect the rejected range.
                let count = emitted.end - emitted.start
                if count >= 2 {
                    let mid = emitted.start + count / 2
                    // Append both halves (larger half first so it's tried first).
                    pendingRanges.append((start: mid, end: emitted.end))
                    pendingRanges.append((start: emitted.start, end: mid))
                }
                // count == 1: single sequence rejected, drop it (existing sources handle it).
            }
            // If accepted, the structural mutation triggers a full source rebuild from the scheduler, so no further action needed here.
        }

        guard let range = pendingRanges.popLast() else {
            exhausted = true
            cachedPriority = nil
            return nil
        }
        lastEmittedRange = range

        let slice = sequences[range.start ..< range.end]
        let targets = slice.map(\.target)
        var totalYield = 0
        var maxElementYield = 0
        var maxBatch = 0
        for entry in slice {
            totalYield += entry.yield
            if entry.yield > maxElementYield {
                maxElementYield = entry.yield
            }
            maxBatch += entry.deletableCount
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

/// Emits per-parent removal scopes at geometrically decreasing batch sizes for a single sequence.
///
/// Starts at the maximum batch size (all deletable elements) and halves on rejection. Alternates head/tail anchors at each batch size. Each emitted scope fully specifies which positions to remove — the encoder applies it in one probe.
struct BatchRemovalSource {
    private let sequenceNodeID: Int
    private let elements: [(nodeID: Int, positionRange: ClosedRange<Int>)]
    private let maxBatch: Int
    private var currentBatch: Int
    private var triedTail: Bool
    private var exhausted: Bool
    private var cachedPriority: DispatchPriority?

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
            return
        }
        let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
        let deletable = metadata.elementCount - minLength
        for childID in node.children {
            guard let range = graph.nodes[childID].positionRange else { continue }
            elementList.append((nodeID: childID, positionRange: range))
        }
        elementList.sort { $0.positionRange.lowerBound < $1.positionRange.lowerBound }

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

    var peekPriority: DispatchPriority? { cachedPriority }

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard exhausted == false, currentBatch > 0 else { return nil }

        let anchor: RemovalAnchor = triedTail ? .head : .tail

        // Build the scope with specific positions.
        let offset = switch anchor {
        case .tail: elements.count - currentBatch
        case .head: elements.count - maxBatch
        }
        guard offset >= 0, offset + currentBatch <= elements.count else {
            exhausted = true
            cachedPriority = nil
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
                elementNodeIDs: slice.map(\.nodeID)
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

    private enum RemovalAnchor { case head, tail }

    private mutating func recomputePriority() {
        guard exhausted == false, currentBatch > 0 else {
            cachedPriority = nil
            return
        }
        let anchor: RemovalAnchor = triedTail ? .head : .tail
        let offset = switch anchor {
        case .tail: elements.count - currentBatch
        case .head: elements.count - maxBatch
        }
        guard offset >= 0, offset + currentBatch <= elements.count else {
            cachedPriority = nil
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

// MARK: - Builder Functions

extension CandidateSourceBuilder {
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
