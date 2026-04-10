//
//  ScopeSource.swift
//  Exhaust
//

// MARK: - Scope Source Protocol

/// A pull-based iterator that lazily produces scopes in yield-descending order.
///
/// Each source represents one structural search space (a sequence to empty, a batch removal range, an aligned sibling set, a replacement candidate). It emits one fully specified scope at a time via ``next(lastAccepted:)``. The scheduler merges sources by ``peekYield``, pulling from whichever has the highest-yield next scope.
///
/// This is a graph-aware variant of the pull-based density algorithm used by ``PullBasedCoveringArrayGenerator``. The same pattern — lazy, greedy, demand-driven — applies to scope generation, with graph-specific advantages: heterogeneous unit sizes weighted by exact yield, independence structure from the antichain, constraint-aware pruning via length constraints, and hierarchical decomposition from the containment tree.
///
/// On structural acceptance, all sources are rebuilt from the new graph. On rejection, only the dispatched source advances.
protocol ScopeSource {
    /// The yield of the scope that would be returned by the next call to ``next(lastAccepted:)``. Nil when exhausted.
    var peekYield: TransformationYield? { get }

    /// Produces the next scope, incorporating feedback from the prior probe.
    mutating func next(lastAccepted: Bool) -> GraphTransformation?
}

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
        for (parentID, _) in parentToElements {
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

        self.sequences = entries
        // Only useful when there are at least two independent sequences to batch.
        if entries.count >= 2 {
            self.pendingRanges = [(start: 0, end: entries.count)]
            self.lastEmittedRange = nil
            self.exhausted = false
        } else {
            self.pendingRanges = []
            self.lastEmittedRange = nil
            self.exhausted = true
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
        for scope in graph.elementRemovalScopes() {
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

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
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
            self.elements = []
            self.maxBatch = 0
            self.currentBatch = 0
            self.triedTail = false
            self.exhausted = true
            return
        }
        let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
        let deletable = metadata.elementCount - minLength
        for childID in node.children {
            guard let range = graph.nodes[childID].positionRange else { continue }
            elementList.append((nodeID: childID, positionRange: range))
        }
        elementList.sort { $0.positionRange.lowerBound < $1.positionRange.lowerBound }

        self.elements = elementList
        self.maxBatch = deletable
        // Start below full emptying (SequenceEmptyingSource handles that).
        // Begin at half the max, or max-1 if max is small.
        let startBatch = deletable > 2 ? deletable / 2 : max(deletable - 1, 0)
        self.currentBatch = startBatch
        self.triedTail = false
        self.exhausted = startBatch <= 0
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

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
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
        for scope in graph.elementRemovalScopes() {
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

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
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

/// Emits multi-target element removal scopes across sibling subsets in yield-descending order.
///
/// Uses the aligned element scopes from ``ChoiceGraph/elementRemovalScopes()`` (multi-target scopes only). Each scope fully specifies which positions to remove across all participating sequences. One probe per scope.
struct AlignedRemovalSource: ScopeSource {
    private var scopes: [ElementRemovalScope]
    private var index = 0

    init(graph: ChoiceGraph) {
        // Filter to multi-target scopes only (aligned across siblings).
        self.scopes = graph.elementRemovalScopes()
            .filter { $0.targets.count >= 2 }
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
            estimatedProbes: 1
        )
    }

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
        guard index < scopes.count else { return nil }
        let scope = scopes[index]
        index += 1

        return GraphTransformation(
            operation: .remove(.elements(scope)),
            yield: TransformationYield(
                structural: scope.maxElementYield,
                value: 0,
                slack: .exact,
                estimatedProbes: 1
            ),
            precondition: .all(scope.targets.map {
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

// MARK: - Replacement Source

/// Emits replacement scopes in size-delta-descending order.
///
/// Includes self-similar substitutions, branch pivots, and descendant promotions. Each scope fully specifies the donor and target. One probe per scope.
struct ReplacementSource: ScopeSource {
    private var candidates: [(scope: ReplacementScope, yield: TransformationYield)]
    private var index = 0

    init(graph: ChoiceGraph) {
        var entries: [(scope: ReplacementScope, yield: TransformationYield)] = []

        for scope in graph.replacementScopes() {
            let structuralYield: Int
            let nodeID: Int
            switch scope {
            case let .selfSimilar(selfSimilar):
                structuralYield = max(0, selfSimilar.sizeDelta)
                nodeID = selfSimilar.targetNodeID
            case let .branchPivot(pivot):
                structuralYield = graph.nodes[pivot.pickNodeID].positionRange?.count ?? 0
                nodeID = pivot.pickNodeID
            case let .descendantPromotion(promotion):
                structuralYield = promotion.sizeDelta
                nodeID = promotion.ancestorPickNodeID
            }
            entries.append((
                scope: scope,
                yield: TransformationYield(
                    structural: structuralYield,
                    value: 0,
                    slack: .exact,
                    estimatedProbes: 1
                )
            ))
        }
        candidates = entries.sorted { $0.yield < $1.yield }
    }

    var peekYield: TransformationYield? {
        guard index < candidates.count else { return nil }
        return candidates[index].yield
    }

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
        guard index < candidates.count else { return nil }
        let entry = candidates[index]
        index += 1

        let precondition: TransformationPrecondition
        switch entry.scope {
        case let .selfSimilar(selfSimilar):
            precondition = .all([
                .nodeActive(selfSimilar.targetNodeID),
                .nodeActive(selfSimilar.donorNodeID),
            ])
        case let .branchPivot(pivot):
            precondition = .nodeActive(pivot.pickNodeID)
        case let .descendantPromotion(promotion):
            precondition = .all([
                .nodeActive(promotion.ancestorPickNodeID),
                .nodeActive(promotion.descendantPickNodeID),
            ])
        }

        return GraphTransformation(
            operation: .replace(entry.scope),
            yield: entry.yield,
            precondition: precondition,
            postcondition: TransformationPostcondition(
                isStructural: true,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
    }
}

// MARK: - Permutation Source

/// Emits sibling swap scopes ordered by zip position (earlier = more shortlex impact).
///
/// Each scope specifies exactly which two children to swap. One probe per scope.
struct PermutationSource: ScopeSource {
    private var candidates: [(zipNodeID: Int, nodeA: Int, nodeB: Int)]
    private var index = 0

    init(graph: ChoiceGraph) {
        var entries: [(zipNodeID: Int, nodeA: Int, nodeB: Int)] = []
        for scope in graph.permutationScopes() {
            guard case let .siblingPermutation(permScope) = scope else { continue }
            for group in permScope.swappableGroups {
                for indexA in 0 ..< group.count {
                    for indexB in (indexA + 1) ..< group.count {
                        entries.append((
                            zipNodeID: permScope.zipNodeID,
                            nodeA: group[indexA],
                            nodeB: group[indexB]
                        ))
                    }
                }
            }
        }
        // Order by position of the earlier child (earlier = more shortlex impact).
        entries.sort { entryA, entryB in
            let positionA = min(entryA.nodeA, entryA.nodeB)
            let positionB = min(entryB.nodeA, entryB.nodeB)
            return positionA < positionB
        }
        candidates = entries
    }

    var peekYield: TransformationYield? {
        guard index < candidates.count else { return nil }
        return TransformationYield(
            structural: 0,
            value: 0,
            slack: .exact,
            estimatedProbes: 1
        )
    }

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
        guard index < candidates.count else { return nil }
        let entry = candidates[index]
        index += 1

        let scope = SiblingPermutationScope(
            zipNodeID: entry.zipNodeID,
            swappableGroups: [[entry.nodeA, entry.nodeB]]
        )

        return GraphTransformation(
            operation: .permute(.siblingPermutation(scope)),
            yield: TransformationYield(
                structural: 0,
                value: 0,
                slack: .exact,
                estimatedProbes: 1
            ),
            precondition: .nodeActive(entry.zipNodeID),
            postcondition: TransformationPostcondition(
                isStructural: false,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
    }
}

// MARK: - Minimization Source

/// Emits minimization scopes for value search. These are search-based — the encoder handles multi-probe internally.
///
/// Produces one scope per leaf type (integer, float) and one per Kleisli fibre edge, ordered by value yield descending.
struct MinimizationSource: ScopeSource {
    private var scopes: [(scope: MinimizationScope, yield: TransformationYield)]
    private var index = 0

    init(graph: ChoiceGraph) {
        let innerChildToBind = Self.buildInnerChildToBind(from: graph)
        var entries: [(scope: MinimizationScope, yield: TransformationYield)] = []

        for scope in graph.minimizationScopes() {
            let valueYield: Int
            switch scope {
            case let .integerLeaves(integerScope):
                valueYield = integerScope.leafNodeIDs.reduce(0) { maxSoFar, nodeID in
                    max(maxSoFar, Self.computeValueYield(leafNodeID: nodeID, graph: graph, innerChildToBind: innerChildToBind))
                }
            case let .floatLeaves(floatScope):
                valueYield = floatScope.leafNodeIDs.reduce(0) { maxSoFar, nodeID in
                    max(maxSoFar, Self.computeValueYield(leafNodeID: nodeID, graph: graph, innerChildToBind: innerChildToBind))
                }
            case let .kleisliFibre(fibreScope):
                valueYield = fibreScope.boundSubtreeSize
            }

            let estimatedProbes: Int
            switch scope {
            case let .integerLeaves(integerScope):
                estimatedProbes = 1 + integerScope.leafNodeIDs.count * 16
            case let .floatLeaves(floatScope):
                estimatedProbes = floatScope.leafNodeIDs.count * 15
            case let .kleisliFibre(fibreScope):
                estimatedProbes = 15 + min(128, fibreScope.boundSubtreeSize)
            }

            entries.append((
                scope: scope,
                yield: TransformationYield(
                    structural: 0,
                    value: valueYield,
                    slack: .exact,
                    estimatedProbes: estimatedProbes
                )
            ))
        }
        scopes = entries.sorted { $0.yield < $1.yield }
    }

    var peekYield: TransformationYield? {
        guard index < scopes.count else { return nil }
        return scopes[index].yield
    }

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
        guard index < scopes.count else { return nil }
        let entry = scopes[index]
        index += 1

        return GraphTransformation(
            operation: .minimize(entry.scope),
            yield: entry.yield,
            precondition: .unconditional,
            postcondition: TransformationPostcondition(
                isStructural: false,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
    }

    private static func buildInnerChildToBind(from graph: ChoiceGraph) -> [Int: Int] {
        var index: [Int: Int] = [:]
        for node in graph.nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            index[innerChildID] = node.id
        }
        return index
    }

    private static func computeValueYield(leafNodeID: Int, graph: ChoiceGraph, innerChildToBind: [Int: Int]) -> Int {
        guard let bindNodeID = innerChildToBind[leafNodeID] else { return 0 }
        guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else { return 0 }
        guard metadata.isStructurallyConstant == false else { return 0 }
        guard graph.nodes[bindNodeID].children.count >= 2 else { return 0 }
        let boundChildID = graph.nodes[bindNodeID].children[metadata.boundChildIndex]
        return graph.nodes[boundChildID].positionRange?.count ?? 0
    }
}

// MARK: - Exchange Source

/// Emits exchange scopes for value redistribution and tandem reduction.
///
/// Search-based — the encoder handles multi-probe magnitude search internally.
struct ExchangeSource: ScopeSource {
    private var scopes: [(scope: ExchangeScope, yield: TransformationYield)]
    private var index = 0

    init(graph: ChoiceGraph) {
        var entries: [(scope: ExchangeScope, yield: TransformationYield)] = []
        for scope in graph.exchangeScopes() {
            let estimatedProbes: Int
            let slack: AffineSlack
            switch scope {
            case let .redistribution(redistScope):
                estimatedProbes = min(24, redistScope.pairs.count)
                let maxDistance = redistScope.pairs.reduce(0) { maxSoFar, pair in
                    guard case let .chooseBits(metadata) = graph.nodes[pair.sourceNodeID].kind else {
                        return maxSoFar
                    }
                    let target = metadata.value.reductionTarget(in: metadata.validRange)
                    let distance = metadata.value.bitPattern64 > target
                        ? metadata.value.bitPattern64 - target
                        : target - metadata.value.bitPattern64
                    return max(maxSoFar, Int(min(distance, UInt64(Int.max))))
                }
                slack = AffineSlack(multiplicative: 1, additive: maxDistance)
            case let .tandem(tandemScope):
                estimatedProbes = tandemScope.groups.count * 8
                slack = AffineSlack(multiplicative: 1, additive: 1)
            }

            entries.append((
                scope: scope,
                yield: TransformationYield(
                    structural: 0,
                    value: 0,
                    slack: slack,
                    estimatedProbes: estimatedProbes
                )
            ))
        }
        scopes = entries.sorted { $0.yield < $1.yield }
    }

    var peekYield: TransformationYield? {
        guard index < scopes.count else { return nil }
        return scopes[index].yield
    }

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
        guard index < scopes.count else { return nil }
        let entry = scopes[index]
        index += 1

        return GraphTransformation(
            operation: .exchange(entry.scope),
            yield: entry.yield,
            precondition: .unconditional,
            postcondition: TransformationPostcondition(
                isStructural: false,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
    }
}

// MARK: - Source Collection Builder

/// Builds the collection of scope sources from a graph.
///
/// Creates one source per search space. The scheduler merges them by ``ScopeSource/peekYield``.
enum ScopeSourceBuilder {
    /// Builds all scope sources from the current graph.
    static func buildSources(from graph: ChoiceGraph) -> [any ScopeSource] {
        var sources: [any ScopeSource] = []

        // Batched cross-sequence removal — most drastic structural reduction.
        let batchedSource = BatchedCrossSequenceRemovalSource(graph: graph)
        if batchedSource.peekYield != nil {
            sources.append(batchedSource)
        }

        // Batch removal — one source per sequence with deletable elements.
        // Geometric halving within each sequence (half → quarter → eighth).
        for scope in graph.elementRemovalScopes() {
            guard scope.targets.count == 1, let target = scope.targets.first else { continue }
            let source = BatchRemovalSource(
                sequenceNodeID: target.sequenceNodeID,
                graph: graph
            )
            if source.peekYield != nil {
                sources.append(source)
            }
        }

        // Per-element removal.
        let perElementSource = PerElementRemovalSource(graph: graph)
        if perElementSource.peekYield != nil {
            sources.append(perElementSource)
        }

        // Aligned removal — only if at least one participating sibling is dirty.
        let alignedSource = AlignedRemovalSource(graph: graph)
        if alignedSource.peekYield != nil {
            sources.append(alignedSource)
        }

        // Replacement.
        let replacementSource = ReplacementSource(graph: graph)
        if replacementSource.peekYield != nil {
            sources.append(replacementSource)
        }

        // Permutation.
        let permutationSource = PermutationSource(graph: graph)
        if permutationSource.peekYield != nil {
            sources.append(permutationSource)
        }

        // Minimization (search-based).
        let minimizationSource = MinimizationSource(graph: graph)
        if minimizationSource.peekYield != nil {
            sources.append(minimizationSource)
        }

        // Migration — move elements between antichain-independent sequences.
        let migrationSource = MigrationSource(graph: graph)
        if migrationSource.peekYield != nil {
            sources.append(migrationSource)
        }

        // Exchange (search-based).
        let exchangeSource = ExchangeSource(graph: graph)
        if exchangeSource.peekYield != nil {
            sources.append(exchangeSource)
        }

        return sources
    }
}

// MARK: - Migration Source

/// Emits element migration scopes from earlier sequences to later sequences.
///
/// For each pair of antichain-independent sequences where the source is at an earlier position, emits scopes at geometrically decreasing element counts. Moving elements rightward improves shortlex at earlier positions.
struct MigrationSource: ScopeSource {
    private var candidates: [(sourceSeqID: Int, receiverSeqID: Int, elementNodeIDs: [Int], elementRanges: [ClosedRange<Int>], receiverRange: ClosedRange<Int>, yield: Int)]
    private var index = 0

    init(graph: ChoiceGraph) {
        var entries: [(sourceSeqID: Int, receiverSeqID: Int, elementNodeIDs: [Int], elementRanges: [ClosedRange<Int>], receiverRange: ClosedRange<Int>, yield: Int)] = []

        // Find all sequence node pairs where source is earlier than receiver.
        // Lengths use UInt64 throughout to match the framework's length-generator type.
        var sequenceNodes: [(nodeID: Int, positionRange: ClosedRange<Int>, elementCount: UInt64, maxLength: UInt64)] = []
        for node in graph.nodes {
            guard case let .sequence(metadata) = node.kind else { continue }
            guard let range = node.positionRange else { continue }
            let maxLength = metadata.lengthConstraint?.upperBound ?? UInt64.max
            sequenceNodes.append((
                nodeID: node.id,
                positionRange: range,
                elementCount: UInt64(metadata.elementCount),
                maxLength: maxLength
            ))
        }
        sequenceNodes.sort { $0.positionRange.lowerBound < $1.positionRange.lowerBound }

        // For each pair (source earlier, receiver later), check independence and capacity.
        for sourceIndex in 0 ..< sequenceNodes.count {
            let source = sequenceNodes[sourceIndex]
            guard source.elementCount > 0 else { continue }

            for receiverIndex in (sourceIndex + 1) ..< sequenceNodes.count {
                let receiver = sequenceNodes[receiverIndex]
                guard receiver.elementCount < receiver.maxLength else { continue }
                guard graph.areIndependent(source.nodeID, receiver.nodeID) else { continue }
                // Reject containment relationships.
                guard source.positionRange.contains(receiver.positionRange.lowerBound) == false,
                      receiver.positionRange.contains(source.positionRange.lowerBound) == false
                else { continue }

                // Collect source's element node IDs and full extents.
                // Use the sequence's stored child extents so transparent
                // wrapper markers (getSize-bind, transform-bind) move with
                // their value entries — otherwise migration leaves orphan
                // markers and the materializer rejects the candidate.
                let sourceNode = graph.nodes[source.nodeID]
                guard case let .sequence(sourceMetadata) = sourceNode.kind else { continue }
                guard sourceMetadata.childPositionRanges.count == sourceNode.children.count else { continue }
                var elementNodeIDs: [Int] = []
                var elementRanges: [ClosedRange<Int>] = []
                for (childIndex, childID) in sourceNode.children.enumerated() {
                    guard graph.nodes[childID].positionRange != nil else { continue }
                    elementNodeIDs.append(childID)
                    elementRanges.append(sourceMetadata.childPositionRanges[childIndex])
                }

                guard elementNodeIDs.isEmpty == false else { continue }

                // Yield: the position count of the elements being moved.
                // Moving them shortens the source (improves shortlex at earlier positions).
                let totalYield = elementRanges.reduce(0) { $0 + $1.count }

                // Start with moving ALL elements (most drastic).
                entries.append((
                    sourceSeqID: source.nodeID,
                    receiverSeqID: receiver.nodeID,
                    elementNodeIDs: elementNodeIDs,
                    elementRanges: elementRanges,
                    receiverRange: receiver.positionRange,
                    yield: totalYield
                ))
            }
        }

        // Sort by yield descending.
        entries.sort { $0.yield > $1.yield }
        candidates = entries
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

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
        guard index < candidates.count else { return nil }
        let entry = candidates[index]
        index += 1

        let scope = MigrationScope(
            sourceSequenceNodeID: entry.sourceSeqID,
            receiverSequenceNodeID: entry.receiverSeqID,
            elementNodeIDs: entry.elementNodeIDs,
            elementPositionRanges: entry.elementRanges,
            receiverPositionRange: entry.receiverRange
        )

        return GraphTransformation(
            operation: .migrate(scope),
            yield: TransformationYield(
                structural: entry.yield,
                value: 0,
                slack: .exact,
                estimatedProbes: 1
            ),
            precondition: .all([
                .sequenceLengthAboveMinimum(sequenceNodeID: entry.sourceSeqID),
                .nodeActive(entry.receiverSeqID),
            ]),
            postcondition: TransformationPostcondition(
                isStructural: true,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
    }
}
