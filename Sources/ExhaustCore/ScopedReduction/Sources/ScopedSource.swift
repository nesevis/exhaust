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
/// Priority inspection reads the next encoder scope without consuming it. The invalidation describes everything the source was prepared with and stays available after exhaustion.
final class ScopedSortedSource {
    private var cursor: BufferedScopeCursor<PricedEncoderScope>
    let invalidation: ScopedSourceInvalidation

    /// - Precondition: `encoderScopes` is already in dispatch order.
    init(_ encoderScopes: [PricedEncoderScope], invalidation: ScopedSourceInvalidation) {
        cursor = BufferedScopeCursor(encoderScopes)
        self.invalidation = invalidation
    }

    var dispatchPriority: DispatchPriority? {
        cursor.peekScope?.priority
    }

    func nextScope() -> PricedEncoderScope? {
        cursor.next()
    }
}

// MARK: - Staged Joint Source

/// Yields the one staged joint checkpoint, discovered the first time the source is peeked or pulled.
///
/// Discovery reads the stall evidence the runner holds: convergence in the graph, and which bound value searches came back fruitless. Its price depends on the discovered candidate pool, so a peek discovers too. A checkpoint equal to the last one searched is not offered again.
final class ScopedStagedJointSource {
    /// A searched checkpoint: the sequence it was discovered on and what it found.
    struct Checkpoint: Equatable {
        let base: ChoiceSequence
        let scope: ScopedStagedJointEncoder.Scope
    }

    private let graph: ChoiceGraph
    private let sequence: ChoiceSequence
    private let isFruitlessBind: (UInt64) -> Bool
    private let exhausted: Checkpoint?
    private let tuning: ScopedReductionTuning
    /// The checkpoint, discovered on first read and cleared once pulled.
    private lazy var pending: PricedEncoderScope? = discover()

    /// - Parameters:
    ///   - isFruitlessBind: Whether bound value search came back fruitless for the bind with this fingerprint.
    ///   - exhausted: The checkpoint the staged joint encoder's reducer last searched, if any.
    init(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        isFruitlessBind: @escaping (UInt64) -> Bool,
        exhausted: Checkpoint?,
        tuning: ScopedReductionTuning
    ) {
        self.graph = graph
        self.sequence = sequence
        self.isFruitlessBind = isFruitlessBind
        self.exhausted = exhausted
        self.tuning = tuning
    }

    var dispatchPriority: DispatchPriority? {
        pending?.priority
    }

    func nextScope() -> PricedEncoderScope? {
        let next = pending
        pending = nil
        return next
    }

    // MARK: - Helpers

    /// Offers the checkpoint when pairs exist and it differs from the exhausted one. Priced with no benefit and the first stage's budget as cost.
    private func discover() -> PricedEncoderScope? {
        guard tuning.stagedJointProbeBudget > 0 else {
            return nil
        }
        let pairs = ScopedStagedJointQuery.pairs(
            graph: graph,
            isFruitlessBind: isFruitlessBind,
            tuning: tuning
        )
        guard pairs.isEmpty == false else {
            return nil
        }
        let candidatePool = ScopedStagedJointQuery.candidatePool(
            graph: graph,
            isFruitlessBind: isFruitlessBind,
            tuning: tuning
        )
        let scope = ScopedStagedJointEncoder.Scope(pairs: pairs, candidatePool: candidatePool)
        guard exhausted != Checkpoint(base: sequence, scope: scope) else {
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

// MARK: - Invalidation

/// The least graph change that invalidates a family's scopes, which decides whether the family survives a rebuild.
enum ScopedSourceInvalidation {
    /// Any value change: the scopes read leaf values.
    case anyValueChange
    /// A change of leaf kind: the family groups siblings by shape, which a leaf-kind change can invalidate without changing node identities.
    case leafKindChange
    /// Only a structural change: the scopes depend on graph topology alone.
    case structuralChange
}

// MARK: - Family Sources

/// One source per discovery family. A family yields several encoders' scopes in one priority order, so ties keep the order the family's query emits them in.
///
/// Families hold only encoder scopes for registered encoders. Scopes the family's query finds for other operations are dropped at preparation. Families whose scopes are discovered and priced up front share ``ScopedSortedSource``, which records their invalidation; the other families each discover lazily.
///
/// Every payload is a reference that advances in place, so a copy of a source shares its position. Nothing copies a source to read it independently; the relax round sets the outer sources aside and restores the same objects.
enum ScopedSource {
    /// A family whose scopes were priced and sorted at preparation.
    case sorted(ScopedSortedSource)
    /// The staged joint checkpoint, for the post-cycle phase.
    case stagedJoint(ScopedStagedJointSource)
    /// All compatible sequences at their minimum lengths, bisected on rejection.
    case batchedCrossSequenceRemoval(ScopedBatchedCrossSequenceRemovalSource)
    /// One sequence's halving batches and interior window seeds.
    case batchRemoval(ScopedBatchRemovalSource)
    /// Every element of an earlier sequence moved into a later compatible one.
    case migration(ScopedMigrationSource)
    /// Self-similar replacement, descendant promotion, and branch pivots, in descending benefit.
    case replacement(ScopedReplacementSource)

    /// A lazy family discovers its scopes on first peek.
    var dispatchPriority: DispatchPriority? {
        switch self {
            case let .sorted(source):
                source.dispatchPriority
            case let .stagedJoint(source):
                source.dispatchPriority
            case let .batchedCrossSequenceRemoval(source):
                source.dispatchPriority
            case let .batchRemoval(source):
                source.dispatchPriority
            case let .migration(source):
                source.dispatchPriority
            case let .replacement(source):
                source.dispatchPriority
        }
    }

    var invalidation: ScopedSourceInvalidation {
        switch self {
            case let .sorted(source):
                source.invalidation
            case .stagedJoint:
                .anyValueChange
            case .batchedCrossSequenceRemoval, .batchRemoval, .migration, .replacement:
                .structuralChange
        }
    }

    /// Whether the family asks for one scope before ordinary priority ordering resumes. Only batched cross-sequence removal does, for its all-sequence probe.
    var prefersInitialDispatch: Bool {
        guard case let .batchedCrossSequenceRemoval(source) = self else {
            return false
        }
        return source.prefersInitialDispatch
    }

    func nextScope() -> PricedEncoderScope? {
        switch self {
            case let .sorted(source):
                source.nextScope()
            case let .stagedJoint(source):
                source.nextScope()
            case let .batchedCrossSequenceRemoval(source):
                source.nextScope()
            case let .batchRemoval(source):
                source.nextScope()
            case let .migration(source):
                source.nextScope()
            case let .replacement(source):
                source.nextScope()
        }
    }
}

// MARK: - Preparation

extension ScopedSource {
    /// Prepares the value-dependent families in the order lane collapse, depth collapse, minimization, exchange, omitting empty ones. The order matters only on priority ties, which go to the earlier source.
    static func prepareValueSources(
        from graph: ChoiceGraph,
        tuning: ScopedReductionTuning
    ) -> [ScopedSource] {
        var sources: [ScopedSource] = []

        if let laneCollapse = laneCollapseEncoderScope(graph: graph) {
            sources.append(.sorted(ScopedSortedSource([laneCollapse], invalidation: .anyValueChange)))
        }

        let depthCollapse = depthCollapseEncoderScopes(graph: graph)
        if depthCollapse.isEmpty == false {
            sources.append(.sorted(ScopedSortedSource(depthCollapse, invalidation: .anyValueChange)))
        }

        let minimization = minimizationEncoderScopes(graph: graph, tuning: tuning)
        if minimization.isEmpty == false {
            sources.append(.sorted(ScopedSortedSource(minimization, invalidation: .anyValueChange)))
        }

        let exchange = exchangeEncoderScopes(graph: graph, tuning: tuning)
        if exchange.isEmpty == false {
            sources.append(.sorted(ScopedSortedSource(exchange, invalidation: .anyValueChange)))
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
        isFruitlessBind: @escaping (UInt64) -> Bool,
        exhausted: ScopedStagedJointSource.Checkpoint?,
        tuning: ScopedReductionTuning
    ) -> ScopedSource {
        .stagedJoint(ScopedStagedJointSource(
            graph: graph,
            sequence: sequence,
            isFruitlessBind: isFruitlessBind,
            exhausted: exhausted,
            tuning: tuning
        ))
    }

    /// The index of the source advertising the highest priority, the earliest one on ties, or nil when every source is exhausted. The earliest source that asks for its initial dispatch wins outright. Peeking may discover a lazy family's scopes.
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
        tuning: ScopedReductionTuning
    ) -> [PricedEncoderScope] {
        var results: [PricedEncoderScope] = []

        // TODO: Document or derive the per-leaf and per-downstream probe estimates (16, 15, 64, 8).
        for scope in MinimizationQuery.build(graph: graph) {
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

    /// The size of the bound subtree `leafNodeID` controls as a bind inner, or zero when it controls none. Array counts can depend on controllers even in structurally constant binds.
    private static func computeValueYield(leafNodeID: Int, graph: ChoiceGraph) -> Int {
        let annotation = graph.nodes[leafNodeID].scopeAnnotation
        guard let bindNodeID = annotation.controllingBindNodeID else {
            return 0
        }
        guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else {
            return 0
        }
        guard graph.nodes[bindNodeID].children.count >= 2 else {
            return 0
        }
        let boundChildID = graph.nodes[bindNodeID].children[metadata.boundChildIndex]
        return graph.nodes[boundChildID].positionRange?.count ?? 0
    }
}
