//
//  CandidateSource+ValueSearch.swift
//  Exhaust
//

// MARK: - Builder Functions

extension CandidateSourceBuilder {
    /// Constructs minimization candidates that drive leaf values toward their reduction targets via binary search.
    static func buildMinimizationCandidates(graph: ChoiceGraph, deferBindInner: Bool) -> [GraphTransformation] {
        var results: [GraphTransformation] = []

        for scope in MinimizationQuery.build(graph: graph, deferBindInner: deferBindInner) {
            let valueYield: Int = switch scope {
                case let .valueLeaves(integerScope):
                    integerScope.leaves.reduce(0) { maxSoFar, leaf in
                        max(maxSoFar, computeValueYield(leafNodeID: leaf.nodeID, graph: graph))
                    }
                case let .floatLeaves(floatScope):
                    floatScope.leaves.reduce(0) { maxSoFar, leaf in
                        max(maxSoFar, computeValueYield(leafNodeID: leaf.nodeID, graph: graph))
                    }
                case let .boundValue(bindScope):
                    bindScope.boundSubtreeSize
                case let .bindPivot(pivotScope):
                    pivotScope.boundSubtreeSize
                case .laneCollapse, .depthCollapse:
                    0
            }

            let estimatedCost: Int = switch scope {
                case let .valueLeaves(integerScope):
                    1 + integerScope.leaves.count * 16
                case let .floatLeaves(floatScope):
                    floatScope.leaves.count * 15
                case let .boundValue(bindScope):
                    15 * (bindScope.downstreamNodeIDs.count == 1
                        ? 16
                        : min(64, bindScope.downstreamNodeIDs.count * 8))
                case let .bindPivot(pivotScope):
                    pivotScope.estimatedProbes
                case .laneCollapse, .depthCollapse:
                    0
            }

            results.append(GraphTransformation(
                operation: .minimize(scope),
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

    /// Constructs exchange candidates (redistribution pairs and tandem groups) that transfer value magnitude between leaves without changing the total.
    static func buildExchangeCandidates(graph: ChoiceGraph) -> [GraphTransformation] {
        var results: [GraphTransformation] = []

        for scope in ExchangeQuery.build(graph: graph) {
            let estimatedCost: Int
            let sourceDistance: Int
            switch scope {
                case let .redistribution(redistScope):
                    let maxDistance = redistScope.pairs.reduce(UInt64(0)) { maxSoFar, pair in
                        guard case let .chooseBits(metadata) = graph.nodes[pair.source.nodeID].kind else {
                            return maxSoFar
                        }
                        let target = metadata.value.reductionTarget(in: metadata.validRange)
                        let distance = metadata.value.bitPattern64 > target
                            ? metadata.value.bitPattern64 - target
                            : target - metadata.value.bitPattern64
                        return max(maxSoFar, distance)
                    }
                    sourceDistance = Int(min(maxDistance, UInt64(Int.max)))
                    estimatedCost = min(24, redistScope.pairs.count)
                case let .tandem(tandemScope):
                    let maxDistance = tandemScope.groups.reduce(UInt64(0)) { maxSoFar, group in
                        let groupMax = group.leaves.reduce(UInt64(0)) { leafMax, leaf in
                            guard case let .chooseBits(metadata) = graph.nodes[leaf.nodeID].kind else {
                                return leafMax
                            }
                            let target = metadata.value.reductionTarget(in: metadata.validRange)
                            let distance = metadata.value.bitPattern64 > target
                                ? metadata.value.bitPattern64 - target
                                : target - metadata.value.bitPattern64
                            return max(leafMax, distance)
                        }
                        return max(maxSoFar, groupMax)
                    }
                    sourceDistance = Int(min(maxDistance, UInt64(Int.max)))
                    estimatedCost = tandemScope.groups.count * 8
                case let .relation(relationScope):
                    // Zero magnitude ranks relation search below redistribution and tandem: it is the last-resort joint move for pairs where every cheaper encoder has already stalled.
                    sourceDistance = 0
                    estimatedCost = relationScope.pairs.count * 8
            }

            results.append(GraphTransformation(
                operation: .exchange(scope),
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

    private static func computeValueYield(leafNodeID: Int, graph: ChoiceGraph) -> Int {
        let annotation = graph.nodes[leafNodeID].scopeAnnotation
        guard let bindNodeID = annotation.controllingBindNodeID else { return 0 }
        guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else { return 0 }
        guard metadata.isStructurallyConstant == false else { return 0 }
        guard graph.nodes[bindNodeID].children.count >= 2 else { return 0 }
        let boundChildID = graph.nodes[bindNodeID].children[metadata.boundChildIndex]
        return graph.nodes[boundChildID].positionRange?.count ?? 0
    }

    static func buildLaneCollapseCandidates(graph: ChoiceGraph) -> [GraphTransformation] {
        guard let scope = LaneCollapseQuery.build(graph: graph) else { return [] }
        return [GraphTransformation(
            operation: .minimize(scope),
            priority: DispatchPriority(
                structuralBenefit: 1,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
        )]
    }

    /// One transformation per depth-control leaf, or none when the graph holds no depth control.
    ///
    /// The structural benefit is the leaf's distance to its floor: every layer dropped removes a whole subtree, which is structural rather than value work, and the deepest leaf is tried first. The cost is the binary search's step count over that distance.
    static func buildDepthCollapseCandidates(graph: ChoiceGraph) -> [GraphTransformation] {
        DepthCollapseQuery.build(graph: graph).map { scope in
            GraphTransformation(
                operation: .minimize(scope),
                priority: DispatchPriority(
                    structuralBenefit: DepthCollapseQuery.distanceToFloor(of: scope, graph: graph),
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: DepthCollapseQuery.estimatedProbes(of: scope, graph: graph)
                )
            )
        }
    }
}
