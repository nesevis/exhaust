//
//  ScopeSource+Removal.swift
//  Exhaust
//

// MARK: - Batched Cross-Sequence Removal Source

/// Emits a single scope that removes deletable elements from all antichain-independent sequences simultaneously, then bisects on rejection.
///
/// The deletion antichain identifies element nodes that are pairwise independent (no containment or dependency path). Grouping these by parent sequence yields a set of independent sequences. The first probe attempts to remove all deletable elements from every independent sequence at once. On rejection, the target list is bisected and each half is tried independently.
///
/// Runs before ``SequenceEmptyingSource`` — a successful first probe can eliminate more structure in one materialization than emptying sequences individually.
struct BatchedCrossSequenceRemovalSource: ScopeSource {
    /// Each entry represents one independent sequence with its deletable elements and yield.
    private let sequences: [(target: SequenceRemovalTarget, deletableCount: Int, yield: Int)]
    /// Queue of index ranges to try. Bisection appends two halves on rejection.
    private var pendingRanges: [(start: Int, end: Int)]
    /// The range most recently emitted as a probe, awaiting feedback.
    private var lastEmittedRange: (start: Int, end: Int)?
    private var exhausted: Bool

    init(graph: ChoiceGraph) {
        // Group antichain members by parent sequence.
        var parentToElements: [Int: [Int]] = [:]
        for nodeID in graph.deletionAntichain {
            guard let parentID = graph.nodes[nodeID].parent else { continue }
            guard case .sequence = graph.nodes[parentID].kind else { continue }
            parentToElements[parentID, default: []].append(nodeID)
        }

        // For each independent sequence parent, gather ALL deletable elements
        // (not just antichain members — the antichain tells us which sequences
        // are independent, but within each sequence we want to remove as many
        // elements as the length constraint permits).
        var entries: [(target: SequenceRemovalTarget, deletableCount: Int, yield: Int)] = []
        for (parentID, _) in parentToElements.sorted(by: { $0.key < $1.key }) {
            guard case let .sequence(metadata) = graph.nodes[parentID].kind else { continue }
            let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
            let deletable = metadata.elementCount - minLength
            guard deletable > 0 else { continue }

            // Collect children ordered by position, take the last `deletable` elements
            // (tail-anchored removal is the default for batch deletion).
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
    }

    var peekYield: TransformationYield? {
        guard exhausted == false, let range = pendingRanges.last else { return nil }
        let totalYield = sequences[range.start ..< range.end].reduce(0) { $0 + $1.yield }
        return TransformationYield(
            structural: totalYield,
            value: 0,
            slack: .exact,
            estimatedProbes: 1
        )
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
            // If accepted, the structural mutation triggers a full source rebuild
            // from the scheduler, so no further action needed here.
        }

        guard let range = pendingRanges.popLast() else {
            exhausted = true
            return nil
        }
        lastEmittedRange = range

        let selectedSequences = sequences[range.start ..< range.end]
        let targets = selectedSequences.map(\.target)
        let totalYield = selectedSequences.reduce(0) { $0 + $1.yield }
        let maxElementYield = selectedSequences.map(\.yield).max() ?? 0
        let maxBatch = selectedSequences.reduce(0) { $0 + $1.deletableCount }

        let scope = ElementRemovalScope(
            targets: targets,
            maxBatch: maxBatch,
            maxElementYield: maxElementYield
        )

        return GraphTransformation(
            operation: .remove(.elements(scope)),
            yield: TransformationYield(
                structural: totalYield,
                value: 0,
                slack: .exact,
                estimatedProbes: 1
            ),
            precondition: .all(targets.map {
                .sequenceLengthAboveMinimum(sequenceNodeID: $0.sequenceNodeID)
            }),
            postcondition: TransformationPostcondition(
                isStructural: true,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
    }
}

// MARK: - Sequence Emptying Source

/// Emits "empty this sequence entirely" scopes in yield-descending order.
///
/// For each sequence that can be emptied (deletable count equals element count, or no minimum length constraint), produces one scope that removes all elements. Most drastic structural reduction — tried before batch removal and aligned windows.
struct SequenceEmptyingSource: ScopeSource {
    private var candidates: [(sequenceNodeID: Int, elementNodeIDs: [Int], yield: Int)]
    private var index = 0

    init(graph: ChoiceGraph) {
        var entries: [(sequenceNodeID: Int, elementNodeIDs: [Int], yield: Int)] = []
        for scope in RemovalScopeQuery.elementRemovalScopes(graph: graph) {
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
            entries.append((
                sequenceNodeID: target.sequenceNodeID,
                elementNodeIDs: target.elementNodeIDs,
                yield: totalYield
            ))
        }
        candidates = entries.sorted { $0.yield > $1.yield }
    }

    var peekYield: TransformationYield? {
        guard index < candidates.count else { return nil }
        return TransformationYield(
            structural: candidates[index].yield,
            value: 0,
            slack: .exact,
            estimatedProbes: 1
        )
    }

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard index < candidates.count else { return nil }
        let candidate = candidates[index]
        index += 1

        let scope = ElementRemovalScope(
            targets: [SequenceRemovalTarget(
                sequenceNodeID: candidate.sequenceNodeID,
                elementNodeIDs: candidate.elementNodeIDs
            )],
            maxBatch: candidate.elementNodeIDs.count,
            maxElementYield: candidate.yield
        )

        return GraphTransformation(
            operation: .remove(.elements(scope)),
            yield: TransformationYield(
                structural: candidate.yield,
                value: 0,
                slack: .exact,
                estimatedProbes: 1
            ),
            precondition: .sequenceLengthAboveMinimum(sequenceNodeID: candidate.sequenceNodeID),
            postcondition: TransformationPostcondition(
                isStructural: true,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
    }
}

// MARK: - Batch Removal Source

/// Emits per-parent removal scopes at geometrically decreasing batch sizes for a single sequence.
///
/// Starts at the maximum batch size (all deletable elements) and halves on rejection. Alternates head/tail anchors at each batch size. Each emitted scope fully specifies which positions to remove — the encoder applies it in one probe.
struct BatchRemovalSource: ScopeSource {
    private let sequenceNodeID: Int
    private let elements: [(nodeID: Int, positionRange: ClosedRange<Int>)]
    private let maxBatch: Int
    private var currentBatch: Int
    private var triedTail: Bool
    private var exhausted: Bool

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
        // Start below full emptying (SequenceEmptyingSource handles that).
        // Begin at half the max, or max-1 if max is small.
        let startBatch = deletable > 2 ? deletable / 2 : max(deletable - 1, 0)
        currentBatch = startBatch
        triedTail = false
        exhausted = startBatch <= 0
    }

    var peekYield: TransformationYield? {
        guard exhausted == false, currentBatch > 0 else { return nil }
        let batchYield = computeYield(batchSize: currentBatch, anchor: triedTail ? .head : .tail)
        return TransformationYield(
            structural: batchYield,
            value: 0,
            slack: .exact,
            estimatedProbes: 1
        )
    }

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
            return nil
        }

        let selectedElements = Array(elements[offset ..< offset + currentBatch])
        let batchYield = selectedElements.reduce(0) { $0 + $1.positionRange.count }

        let scope = ElementRemovalScope(
            targets: [SequenceRemovalTarget(
                sequenceNodeID: sequenceNodeID,
                elementNodeIDs: selectedElements.map(\.nodeID)
            )],
            maxBatch: currentBatch,
            maxElementYield: batchYield
        )

        let transformation = GraphTransformation(
            operation: .remove(.elements(scope)),
            yield: TransformationYield(
                structural: batchYield,
                value: 0,
                slack: .exact,
                estimatedProbes: 1
            ),
            precondition: .sequenceLengthAboveMinimum(sequenceNodeID: sequenceNodeID),
            postcondition: TransformationPostcondition(
                isStructural: true,
                invalidatesConvergence: [],
                enablesRemoval: []
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

        return transformation
    }

    private enum RemovalAnchor { case head, tail }

    private func computeYield(batchSize: Int, anchor: RemovalAnchor) -> Int {
        let offset = switch anchor {
        case .tail: elements.count - batchSize
        case .head: elements.count - maxBatch
        }
        guard offset >= 0, offset + batchSize <= elements.count else { return 0 }
        return elements[offset ..< offset + batchSize].reduce(0) { $0 + $1.positionRange.count }
    }
}

// MARK: - Per-Element Removal Source

/// Emits individual element removal scopes, one per deletable element.
///
/// Orders zero-valued elements first — removing a zero-valued element does not change sums, making it the cheapest deletion for sum-constrained generators. Remaining elements ordered by position.
struct PerElementRemovalSource: ScopeSource {
    private var elements: [(sequenceNodeID: Int, nodeID: Int, positionRange: ClosedRange<Int>, isZero: Bool)]
    private var index = 0

    init(graph: ChoiceGraph) {
        var entries: [(sequenceNodeID: Int, nodeID: Int, positionRange: ClosedRange<Int>, isZero: Bool)] = []
        for scope in RemovalScopeQuery.elementRemovalScopes(graph: graph) {
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
        elements = entries
    }

    var peekYield: TransformationYield? {
        guard index < elements.count else { return nil }
        return TransformationYield(
            structural: elements[index].positionRange.count,
            value: 0,
            slack: .exact,
            estimatedProbes: 1
        )
    }

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard index < elements.count else { return nil }
        let element = elements[index]
        index += 1

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
            yield: TransformationYield(
                structural: element.positionRange.count,
                value: 0,
                slack: .exact,
                estimatedProbes: 1
            ),
            precondition: .sequenceLengthAboveMinimum(sequenceNodeID: element.sequenceNodeID),
            postcondition: TransformationPostcondition(
                isStructural: true,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
    }
}

// MARK: - Aligned Removal Source

/// Emits covering-array-backed aligned removal scopes across sibling sequences under zip nodes.
///
/// Each scope carries a ``PullBasedCoveringArrayGenerator`` that the encoder pulls rows from on each probe. The source emits one transformation per zip node; the encoder is multi-shot.
struct AlignedRemovalSource: ScopeSource {
    private var scopes: [CoveringAlignedRemovalScope]
    private var index = 0

    init(graph: ChoiceGraph) {
        scopes = RemovalScopeQuery.coveringAlignedRemovalScopes(graph: graph)
            .sorted { scopeA, scopeB in
                scopeA.maxElementYield > scopeB.maxElementYield
            }
    }

    var peekYield: TransformationYield? {
        guard index < scopes.count else { return nil }
        return TransformationYield(
            structural: scopes[index].maxElementYield,
            value: 0,
            slack: .exact,
            estimatedProbes: scopes[index].handle.generator.totalRemaining
        )
    }

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard index < scopes.count else { return nil }
        let scope = scopes[index]
        index += 1

        return GraphTransformation(
            operation: .remove(.coveringAligned(scope)),
            yield: TransformationYield(
                structural: scope.maxElementYield,
                value: 0,
                slack: .exact,
                estimatedProbes: scope.handle.generator.totalRemaining
            ),
            precondition: .all(scope.siblings.map {
                .sequenceLengthAboveMinimum(sequenceNodeID: $0.sequenceNodeID)
            }),
            postcondition: TransformationPostcondition(
                isStructural: true,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
    }
}
