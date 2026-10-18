// MARK: - Preparation

/// Prepares source families and selects their dispatch order.
enum ScopeSources {
    /// Prepares the value-dependent families in the order lane collapse, depth collapse, minimization, exchange, omitting empty ones. The order matters only on priority ties, which go to the earlier source.
    static func prepareValueSources(
        from graph: ChoiceGraph,
        tuning: ReductionTuning
    ) -> [any ScopeSource] {
        var sources: [any ScopeSource] = []

        if let laneCollapse = laneCollapseEncoderScope(graph: graph) {
            sources.append(SortedScopeSource([laneCollapse], invalidation: .anyValueChange))
        }

        let depthCollapse = depthCollapseEncoderScopes(graph: graph)
        if depthCollapse.isEmpty == false {
            sources.append(SortedScopeSource(depthCollapse, invalidation: .anyValueChange))
        }

        let minimization = minimizationEncoderScopes(graph: graph, tuning: tuning)
        if minimization.isEmpty == false {
            sources.append(SortedScopeSource(minimization, invalidation: .anyValueChange))
        }

        let exchange = exchangeEncoderScopes(graph: graph, tuning: tuning)
        if exchange.isEmpty == false {
            sources.append(SortedScopeSource(exchange, invalidation: .anyValueChange))
        }

        return sources
    }

    /// The index of the source advertising the highest priority, the earliest one on ties, or nil when every source is exhausted. The earliest source that asks for its initial dispatch wins outright. Peeking may discover a lazy family's scopes.
    ///
    /// Removes exhausted sources, keeping the others in order. A source's priority changes only when it hands out a scope, and an exhausted source is never asked for one, so it stays exhausted.
    static func highestPrioritySourceIndex(_ sources: inout [any ScopeSource]) -> Int? {
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

    /// Prices minimization scopes by the bound subtree they could unlock, with the expected probe count as cost. A value leaf unlocks the subtree of the bind it controls, if any. A bound value scope's cost scales with ``ReductionTuning/boundValueBaseBudget``, its upstream budget.
    private static func minimizationEncoderScopes(
        graph: ChoiceGraph,
        tuning: ReductionTuning
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
    private static func exchangeEncoderScopes(graph: ChoiceGraph, tuning: ReductionTuning) -> [PricedEncoderScope] {
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
