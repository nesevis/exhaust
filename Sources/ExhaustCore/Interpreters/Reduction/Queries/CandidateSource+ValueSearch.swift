//
//  CandidateSource+ValueSearch.swift
//  Exhaust
//

// MARK: - Builder Functions

extension CandidateSourceBuilder {
    static func buildMinimizationCandidates(graph: some ReadOnlyChoiceGraph, deferBindInner: Bool) -> [GraphTransformation] {
        let innerDescendantToBind = QueryHelpers.buildInnerDescendantToBind(graph: graph)
        var results: [GraphTransformation] = []

        for scope in MinimizationQuery.build(graph: graph, innerDescendantToBind: innerDescendantToBind, deferBindInner: deferBindInner) {
            let valueYield: Int = switch scope {
            case let .valueLeaves(integerScope):
                integerScope.leaves.reduce(0) { maxSoFar, leaf in
                    max(maxSoFar, computeValueYield(leafNodeID: leaf.nodeID, graph: graph, innerDescendantToBind: innerDescendantToBind))
                }
            case let .floatLeaves(floatScope):
                floatScope.leaves.reduce(0) { maxSoFar, leaf in
                    max(maxSoFar, computeValueYield(leafNodeID: leaf.nodeID, graph: graph, innerDescendantToBind: innerDescendantToBind))
                }
            case let .boundValue(bindScope):
                bindScope.boundSubtreeSize
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

    static func buildExchangeCandidates(graph: some ReadOnlyChoiceGraph) -> [GraphTransformation] {
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

    private static func computeValueYield(leafNodeID: Int, graph: some ReadOnlyChoiceGraph, innerDescendantToBind: [Int: Int]) -> Int {
        guard let bindNodeID = innerDescendantToBind[leafNodeID] else { return 0 }
        guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else { return 0 }
        guard metadata.isStructurallyConstant == false else { return 0 }
        guard graph.nodes[bindNodeID].children.count >= 2 else { return 0 }
        let boundChildID = graph.nodes[bindNodeID].children[metadata.boundChildIndex]
        return graph.nodes[boundChildID].positionRange?.count ?? 0
    }
}
