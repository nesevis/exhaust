//
//  ScopedSource.swift
//  Exhaust
//

// MARK: - Priced Encoder Scope

/// A discovered scope with the priority it advertises for dispatch.
struct PricedEncoderScope {
    let encoderScope: AnyEncoderScope
    let priority: DispatchPriority
}

// MARK: - Sorted Source

/// Yields encoder scopes that were priced and sorted when the source was prepared.
///
/// Priority inspection reads the next encoder scope without consuming it. The invalidation metadata describes everything the source was prepared with and stays available after exhaustion.
struct ScopedSortedSource {
    private var cursor: BufferedScopeCursor<PricedEncoderScope>
    let isValueDependent: Bool

    /// - Precondition: `encoderScopes` is already in dispatch order.
    init(_ encoderScopes: [PricedEncoderScope]) {
        cursor = BufferedScopeCursor(encoderScopes)
        isValueDependent = encoderScopes.contains { $0.encoderScope.encoder.isValueDependent }
    }

    var dispatchPriority: DispatchPriority? {
        cursor.peekScope?.priority
    }

    mutating func nextScope() -> PricedEncoderScope? {
        cursor.next()
    }
}

// MARK: - Staged Joint Source

/// Yields the one staged joint checkpoint, discovered the first time the source is peeked or pulled.
///
/// Discovery reads the stall evidence the runner holds: convergence in the graph, and which bound value searches came back fruitless. Its price depends on the discovered candidate pool, so a peek discovers too. A checkpoint equal to the last one searched is not offered again.
struct ScopedStagedJointSource {
    /// A searched checkpoint: the sequence it was discovered on and what it found.
    struct Checkpoint: Equatable {
        let base: ChoiceSequence
        let scope: ScopedStagedJointEncoder.Scope
    }

    private struct Discovery {
        let graph: ChoiceGraph
        let sequence: ChoiceSequence
        let deferBindInner: Bool
        let isFruitlessBind: (UInt64) -> Bool
        let exhausted: Checkpoint?
        let tuning: ScopedReductionTuning
    }

    private enum State {
        case pending(Discovery)
        case discovered(PricedEncoderScope?)
    }

    private var state: State
    let isValueDependent = true

    /// - Parameters:
    ///   - isFruitlessBind: Whether bound value search came back fruitless for the bind with this fingerprint.
    ///   - exhausted: The checkpoint the staged joint encoder's reducer last searched, if any.
    init(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        deferBindInner: Bool,
        isFruitlessBind: @escaping (UInt64) -> Bool,
        exhausted: Checkpoint?,
        tuning: ScopedReductionTuning
    ) {
        state = .pending(Discovery(
            graph: graph,
            sequence: sequence,
            deferBindInner: deferBindInner,
            isFruitlessBind: isFruitlessBind,
            exhausted: exhausted,
            tuning: tuning
        ))
    }

    var dispatchPriority: DispatchPriority? {
        mutating get {
            discoveredEncoderScope()?.priority
        }
    }

    mutating func nextScope() -> PricedEncoderScope? {
        let next = discoveredEncoderScope()
        state = .discovered(nil)
        return next
    }

    // MARK: - Helpers

    private mutating func discoveredEncoderScope() -> PricedEncoderScope? {
        switch state {
            case let .discovered(encoderScope):
                return encoderScope
            case let .pending(discovery):
                let encoderScope = Self.discover(discovery)
                state = .discovered(encoderScope)
                return encoderScope
        }
    }

    /// Offers the checkpoint when pairs exist and it differs from the exhausted one. Priced with no benefit and the first stage's budget as cost.
    private static func discover(_ discovery: Discovery) -> PricedEncoderScope? {
        let tuning = discovery.tuning
        guard tuning.stagedJointProbeBudget > 0, discovery.deferBindInner == false else {
            return nil
        }
        let pairs = ScopedStagedJointQuery.pairs(
            graph: discovery.graph,
            isFruitlessBind: discovery.isFruitlessBind,
            tuning: tuning
        )
        guard pairs.isEmpty == false else {
            return nil
        }
        let candidatePool = ScopedStagedJointQuery.candidatePool(
            graph: discovery.graph,
            isFruitlessBind: discovery.isFruitlessBind,
            tuning: tuning
        )
        let scope = ScopedStagedJointEncoder.Scope(pairs: pairs, candidatePool: candidatePool)
        guard discovery.exhausted != Checkpoint(base: discovery.sequence, scope: scope) else {
            return nil
        }
        let firstStageBudget = ScopedStagedJointEncoder.stageBudget(
            arity: 2,
            candidatePool: candidatePool,
            remaining: tuning.stagedJointProbeBudget,
            calculationsRemaining: tuning.numericJointGroupCalculationLimit,
            tuning: tuning
        )
        return PricedEncoderScope(
            encoderScope: .stagedJoint(scope),
            priority: DispatchPriority(
                structuralBenefit: 0,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: firstStageBudget
            )
        )
    }
}

// MARK: - Family Sources

/// One source per discovery family. A family yields several encoders' scopes in one priority order, so ties keep the order the family's query emits them in.
///
/// Families hold only encoder scopes for registered encoders. Scopes the family's query finds for other operations are dropped at preparation.
enum ScopedSource {
    // MARK: Value Families

    /// The single ``LaneCollapseQuery`` scope.
    case laneCollapse(ScopedSortedSource)
    /// ``DepthCollapseQuery`` scopes, deepest first.
    case depthCollapse(ScopedSortedSource)
    /// ``MinimizationQuery`` scopes: integer and float value search, bound value, and bind pivot.
    case minimization(ScopedSortedSource)
    /// ``ExchangeQuery`` scopes: redistribution, lockstep, relation, and bound exchange.
    case exchange(ScopedSortedSource)
    /// The staged joint checkpoint, for the post-cycle phase.
    case stagedJoint(ScopedStagedJointSource)

    // MARK: Structural Families

    /// All compatible sequences at their minimum lengths, bisected on rejection.
    case batchedCrossSequenceRemoval(ScopedBatchedCrossSequenceRemovalSource)
    /// Each sequence with no minimum length, emptied whole, largest first.
    case emptying(ScopedSortedSource)
    /// One sequence's halving batches and interior window seeds.
    case batchRemoval(ScopedBatchRemovalSource)
    /// Center-out window growth, one scope per sequence.
    case centeredWindows(ScopedSortedSource)
    /// Equal prefix and suffix window growth, one scope per sequence.
    case symmetricWindows(ScopedSortedSource)
    /// Every element of an earlier sequence moved into a later compatible one.
    case migration(ScopedMigrationSource)
    /// Single-element removals, at-target elements first.
    case perElementRemoval(ScopedSortedSource)
    /// Covering-array removal across sibling sequences under one zip.
    case alignedRemoval(ScopedSortedSource)
    /// Self-similar replacement, descendant promotion, and branch pivots, in descending benefit.
    case replacement(ScopedReplacementSource)
    /// Same-shaped sibling swaps under each zip.
    case permutation(ScopedSortedSource)
    /// The numeric reordering of every reorderable sibling group, for the final pass.
    case numericReorder(ScopedSortedSource)

    /// Mutating because a lazy family discovers its scopes on first peek.
    var dispatchPriority: DispatchPriority? {
        mutating get {
            switch self {
                case let .laneCollapse(source), let .depthCollapse(source), let .minimization(source), let .exchange(source),
                     let .emptying(source), let .centeredWindows(source), let .symmetricWindows(source),
                     let .perElementRemoval(source), let .alignedRemoval(source), let .permutation(source), let .numericReorder(source):
                    return source.dispatchPriority
                case var .stagedJoint(source):
                    let priority = source.dispatchPriority
                    self = .stagedJoint(source)
                    return priority
                case let .batchedCrossSequenceRemoval(source):
                    return source.dispatchPriority
                case let .batchRemoval(source):
                    return source.dispatchPriority
                case let .migration(source):
                    return source.dispatchPriority
                case let .replacement(source):
                    return source.dispatchPriority
            }
        }
    }

    var isValueDependent: Bool {
        switch self {
            case let .laneCollapse(source), let .depthCollapse(source), let .minimization(source), let .exchange(source),
                 let .emptying(source), let .centeredWindows(source), let .symmetricWindows(source),
                 let .perElementRemoval(source), let .alignedRemoval(source), let .permutation(source), let .numericReorder(source):
                source.isValueDependent
            case let .stagedJoint(source):
                source.isValueDependent
            case .batchedCrossSequenceRemoval, .batchRemoval, .migration, .replacement:
                false
        }
    }

    /// Whether the family groups siblings by shape, which a change of leaf kind can invalidate without changing node identities.
    var isPermutationSource: Bool {
        switch self {
            case .permutation:
                true
            case .laneCollapse, .depthCollapse, .minimization, .exchange, .stagedJoint,
                 .batchedCrossSequenceRemoval, .emptying, .batchRemoval, .centeredWindows, .symmetricWindows,
                 .migration, .perElementRemoval, .alignedRemoval, .replacement, .numericReorder:
                false
        }
    }

    /// Leaf-kind changes invalidate value-dependent scopes and sibling-shape groups, even when node identities remain stable.
    var canReuseAfterLeafKindChange: Bool {
        isValueDependent == false && isPermutationSource == false
    }

    /// Whether the family asks for one scope before ordinary priority ordering resumes. Only batched cross-sequence removal does, for its all-sequence probe.
    var prefersInitialDispatch: Bool {
        guard case let .batchedCrossSequenceRemoval(source) = self else {
            return false
        }
        return source.prefersInitialDispatch
    }

    /// Releases the source's storage before advancing, so its buffer stays uniquely referenced.
    mutating func nextScope() -> PricedEncoderScope? {
        switch consume self {
            case var .laneCollapse(source):
                let next = source.nextScope()
                self = .laneCollapse(source)
                return next
            case var .depthCollapse(source):
                let next = source.nextScope()
                self = .depthCollapse(source)
                return next
            case var .minimization(source):
                let next = source.nextScope()
                self = .minimization(source)
                return next
            case var .exchange(source):
                let next = source.nextScope()
                self = .exchange(source)
                return next
            case var .stagedJoint(source):
                let next = source.nextScope()
                self = .stagedJoint(source)
                return next
            case var .batchedCrossSequenceRemoval(source):
                let next = source.nextScope()
                self = .batchedCrossSequenceRemoval(source)
                return next
            case var .emptying(source):
                let next = source.nextScope()
                self = .emptying(source)
                return next
            case var .batchRemoval(source):
                let next = source.nextScope()
                self = .batchRemoval(source)
                return next
            case var .centeredWindows(source):
                let next = source.nextScope()
                self = .centeredWindows(source)
                return next
            case var .symmetricWindows(source):
                let next = source.nextScope()
                self = .symmetricWindows(source)
                return next
            case var .migration(source):
                let next = source.nextScope()
                self = .migration(source)
                return next
            case var .perElementRemoval(source):
                let next = source.nextScope()
                self = .perElementRemoval(source)
                return next
            case var .alignedRemoval(source):
                let next = source.nextScope()
                self = .alignedRemoval(source)
                return next
            case var .replacement(source):
                let next = source.nextScope()
                self = .replacement(source)
                return next
            case var .permutation(source):
                let next = source.nextScope()
                self = .permutation(source)
                return next
            case var .numericReorder(source):
                let next = source.nextScope()
                self = .numericReorder(source)
                return next
        }
    }
}

// MARK: - Preparation

extension ScopedSource {
    /// Prepares the value-dependent families in the order lane collapse, depth collapse, minimization, exchange, omitting empty ones. The order matters only on priority ties, which go to the earlier source.
    static func prepareValueSources(
        from graph: ChoiceGraph,
        deferBindInner: Bool,
        tuning: ScopedReductionTuning
    ) -> [ScopedSource] {
        var sources: [ScopedSource] = []

        if let laneCollapse = laneCollapseEncoderScope(graph: graph) {
            sources.append(.laneCollapse(ScopedSortedSource([laneCollapse])))
        }

        let depthCollapse = depthCollapseEncoderScopes(graph: graph)
        if depthCollapse.isEmpty == false {
            sources.append(.depthCollapse(ScopedSortedSource(depthCollapse)))
        }

        let minimization = minimizationEncoderScopes(graph: graph, deferBindInner: deferBindInner, tuning: tuning)
        if minimization.isEmpty == false {
            sources.append(.minimization(ScopedSortedSource(minimization)))
        }

        let exchange = exchangeEncoderScopes(graph: graph, tuning: tuning)
        if exchange.isEmpty == false {
            sources.append(.exchange(ScopedSortedSource(exchange)))
        }

        return sources
    }

    /// The staged joint family over the current graph. It discovers nothing until it is peeked or pulled.
    ///
    /// - Parameters:
    ///   - isFruitlessBind: Whether bound value search came back fruitless for the bind with this fingerprint.
    ///   - exhausted: The checkpoint the staged joint encoder's reducer last searched, if any.
    static func prepareStagedJointSource(
        from graph: ChoiceGraph,
        sequence: ChoiceSequence,
        deferBindInner: Bool,
        isFruitlessBind: @escaping (UInt64) -> Bool,
        exhausted: ScopedStagedJointSource.Checkpoint?,
        tuning: ScopedReductionTuning
    ) -> ScopedSource {
        .stagedJoint(ScopedStagedJointSource(
            graph: graph,
            sequence: sequence,
            deferBindInner: deferBindInner,
            isFruitlessBind: isFruitlessBind,
            exhausted: exhausted,
            tuning: tuning
        ))
    }

    /// The index of the source advertising the highest priority, the earliest one on ties, or nil when every source is exhausted. The earliest source that asks for its initial dispatch wins outright. Peeking may discover a lazy family's scopes, so the sources are inout.
    ///
    /// Removes exhausted sources, keeping the others in order. A source's priority changes only when it hands out a scope, and an exhausted source is never asked for one, so it stays exhausted.
    static func highestPrioritySourceIndex(_ sources: inout [ScopedSource]) -> Int? {
        var keptCount = 0
        var initialIndex: Int?
        var bestIndex: Int?
        var bestPriority: DispatchPriority?
        for index in sources.indices {
            guard let priority = sources[index].dispatchPriority else {
                continue
            }
            // Every source between the kept ones and this one is exhausted, so the swap keeps the live sources in order.
            sources.swapAt(keptCount, index)
            if initialIndex == nil, sources[keptCount].prefersInitialDispatch {
                initialIndex = keptCount
            }
            if let currentBest = bestPriority {
                if priority > currentBest {
                    bestIndex = keptCount
                    bestPriority = priority
                }
            } else {
                bestIndex = keptCount
                bestPriority = priority
            }
            keptCount += 1
        }
        sources.removeSubrange(keptCount...)
        return initialIndex ?? bestIndex
    }

    /// The one lane collapse encoder scope, covering every nonzero lane marker. It advertises a unit structural benefit, so it runs before any value work.
    private static func laneCollapseEncoderScope(graph: ChoiceGraph) -> PricedEncoderScope? {
        guard case let .laneCollapse(laneScope) = LaneCollapseQuery.build(graph: graph) else {
            return nil
        }
        return PricedEncoderScope(
            encoderScope: .laneCollapse(laneScope),
            priority: DispatchPriority(
                structuralBenefit: 1,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
        )
    }

    /// One encoder scope per depth-control leaf, in the query's deepest-first order. Every layer dropped removes a whole subtree, so the benefit is structural: the leaf's distance to its floor. The cost is the binary search's step count over that distance.
    private static func depthCollapseEncoderScopes(graph: ChoiceGraph) -> [PricedEncoderScope] {
        DepthCollapseQuery.build(graph: graph).compactMap { scope in
            guard case let .depthCollapse(valueScope) = scope else {
                return nil
            }
            return PricedEncoderScope(
                encoderScope: .depthCollapse(valueScope),
                priority: DispatchPriority(
                    structuralBenefit: DepthCollapseQuery.distanceToFloor(of: scope, graph: graph),
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: DepthCollapseQuery.estimatedProbes(of: scope, graph: graph)
                )
            )
        }
    }

    /// Prices minimization scopes by the bound subtree they could unlock, with the expected probe count as cost. A value leaf unlocks the subtree of the bind it controls, if any. A bound value scope's cost scales with ``ScopedReductionTuning/boundValueBaseBudget``, its upstream budget.
    private static func minimizationEncoderScopes(
        graph: ChoiceGraph,
        deferBindInner: Bool,
        tuning: ScopedReductionTuning
    ) -> [PricedEncoderScope] {
        var results: [PricedEncoderScope] = []

        // TODO: Document or derive the per-leaf and per-downstream probe estimates (16, 15, 64, 8).
        for scope in MinimizationQuery.build(graph: graph, deferBindInner: deferBindInner) {
            let encoderScope: AnyEncoderScope
            let valueYield: Int
            let estimatedCost: Int
            switch scope {
                case let .valueLeaves(integerScope):
                    encoderScope = .valueSearch(integerScope)
                    valueYield = integerScope.leaves.reduce(0) { maxSoFar, leaf in
                        max(maxSoFar, computeValueYield(leafNodeID: leaf.nodeID, graph: graph))
                    }
                    estimatedCost = 1 + integerScope.leaves.count * 16
                case let .floatLeaves(floatScope):
                    encoderScope = .floatSearch(floatScope)
                    valueYield = floatScope.leaves.reduce(0) { maxSoFar, leaf in
                        max(maxSoFar, computeValueYield(leafNodeID: leaf.nodeID, graph: graph))
                    }
                    estimatedCost = floatScope.leaves.count * 15
                case let .boundValue(bindScope):
                    encoderScope = .boundValue(bindScope)
                    valueYield = bindScope.boundSubtreeSize
                    estimatedCost = bindScope.downstreamNodeIDs.count == 1
                        ? tuning.boundValueBaseBudget * 16
                        : tuning.boundValueBaseBudget * min(64, bindScope.downstreamNodeIDs.count * 8)
                case let .bindPivot(pivotScope):
                    encoderScope = .bindPivot(pivotScope)
                    valueYield = pivotScope.boundSubtreeSize
                    estimatedCost = pivotScope.estimatedProbes
                case .laneCollapse, .depthCollapse:
                    continue
            }

            results.append(PricedEncoderScope(
                encoderScope: encoderScope,
                priority: DispatchPriority(
                    structuralBenefit: 0,
                    valueBenefit: valueYield,
                    reductionMagnitude: 0,
                    estimatedCost: estimatedCost
                )
            ))
        }

        results.sort { $0.priority > $1.priority }
        return results
    }

    /// Prices exchange scopes by how far their sources are from their targets, with the expected probe count as cost.
    private static func exchangeEncoderScopes(graph: ChoiceGraph, tuning: ScopedReductionTuning) -> [PricedEncoderScope] {
        var results: [PricedEncoderScope] = []

        // TODO: Document or derive the probe estimates (24 pairs, 8 per group or pair).
        for scope in ExchangeQuery.build(graph: graph) {
            let encoderScope: AnyEncoderScope
            let estimatedCost: Int
            let sourceDistance: Int
            switch scope {
                case let .redistribution(redistributionScope):
                    encoderScope = .redistribution(redistributionScope)
                    sourceDistance = Int(min(redistributionScope.maximumSourceDistance, UInt64(Int.max)))
                    estimatedCost = min(24, redistributionScope.pairCount)
                case let .boundExchange(exchange):
                    // Ranked by the source's distance to target, like redistribution. Each probe pays a lift before the property runs.
                    guard case let .chooseBits(metadata) = graph.nodes[exchange.sourceLeafNodeID].kind else {
                        continue
                    }
                    let target = metadata.value.reductionTarget(in: metadata.validRange)
                    let distance = metadata.value.bitPattern64.absoluteDifference(target)
                    encoderScope = .boundExchange(exchange)
                    sourceDistance = Int(min(distance, UInt64(Int.max)))
                    estimatedCost = tuning.keptExchangeLiftBudget
                case let .tandem(tandemScope):
                    let maxDistance = tandemScope.groups.reduce(UInt64(0)) { maxSoFar, group in
                        let groupMax = group.leaves.reduce(UInt64(0)) { leafMax, leaf in
                            guard case let .chooseBits(metadata) = graph.nodes[leaf.nodeID].kind else {
                                return leafMax
                            }
                            let target = metadata.value.reductionTarget(in: metadata.validRange)
                            let distance = metadata.value.bitPattern64.absoluteDifference(target)
                            return max(leafMax, distance)
                        }
                        return max(maxSoFar, groupMax)
                    }
                    encoderScope = .lockstep(tandemScope)
                    sourceDistance = Int(min(maxDistance, UInt64(Int.max)))
                    estimatedCost = tandemScope.groups.count * 8
                case let .relation(relationScope):
                    // Zero magnitude ranks relation search below redistribution and lockstep: it is the last-resort joint move for pairs where every cheaper encoder has already stalled.
                    encoderScope = .relation(relationScope)
                    sourceDistance = 0
                    estimatedCost = relationScope.pairs.count * 8
                case .stagedNumericPairs, .numericJoint:
                    continue
            }

            results.append(PricedEncoderScope(
                encoderScope: encoderScope,
                priority: DispatchPriority(
                    structuralBenefit: 0,
                    valueBenefit: 0,
                    reductionMagnitude: sourceDistance,
                    estimatedCost: estimatedCost
                )
            ))
        }

        results.sort { $0.priority > $1.priority }
        return results
    }

    /// The size of the bound subtree `leafNodeID` controls as a bind inner, or zero when it controls none or the bind is structurally constant.
    private static func computeValueYield(leafNodeID: Int, graph: ChoiceGraph) -> Int {
        let annotation = graph.nodes[leafNodeID].scopeAnnotation
        guard let bindNodeID = annotation.controllingBindNodeID else {
            return 0
        }
        guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else {
            return 0
        }
        guard metadata.isStructurallyConstant == false else {
            return 0
        }
        guard graph.nodes[bindNodeID].children.count >= 2 else {
            return 0
        }
        let boundChildID = graph.nodes[bindNodeID].children[metadata.boundChildIndex]
        return graph.nodes[boundChildID].positionRange?.count ?? 0
    }
}
