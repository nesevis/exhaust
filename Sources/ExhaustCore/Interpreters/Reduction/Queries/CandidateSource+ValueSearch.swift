//
//  CandidateSource+ValueSearch.swift
//  Exhaust
//

// MARK: - Minimization Source

/// Emits minimization scopes for value search. These are search-based — the encoder handles multi-probe internally.
///
/// Produces one scope per leaf type (integer, float) and one per bound value edge, ordered by value yield descending.
struct MinimizationSource: CandidateSource {
    private var scopes: [(scope: MinimizationScope, priority: DispatchPriority)]
    private var index = 0

    init(graph: some ReadOnlyChoiceGraph, deferBindInner: Bool = false) {
        let innerDescendantToBind = QueryHelpers.buildInnerDescendantToBind(graph: graph)
        var entries: [(scope: MinimizationScope, priority: DispatchPriority)] = []

        for scope in MinimizationQuery.build(graph: graph, innerDescendantToBind: innerDescendantToBind, deferBindInner: deferBindInner) {
            let valueYield: Int = switch scope {
            case let .valueLeaves(integerScope):
                integerScope.leaves.reduce(0) { maxSoFar, leaf in
                    max(maxSoFar, Self.computeValueYield(leafNodeID: leaf.nodeID, graph: graph, innerDescendantToBind: innerDescendantToBind))
                }
            case let .floatLeaves(floatScope):
                floatScope.leaves.reduce(0) { maxSoFar, leaf in
                    max(maxSoFar, Self.computeValueYield(leafNodeID: leaf.nodeID, graph: graph, innerDescendantToBind: innerDescendantToBind))
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

            entries.append((
                scope: scope,
                priority: DispatchPriority(
                    structuralBenefit: 0,
                    valueBenefit: valueYield,
                    reductionMagnitude: 0,
                    estimatedCost: estimatedCost
                )
            ))
        }
        scopes = entries.sorted { $0.priority > $1.priority }
    }

    var peekPriority: DispatchPriority? {
        guard index < scopes.count else { return nil }
        return scopes[index].priority
    }

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard index < scopes.count else { return nil }
        let entry = scopes[index]
        index += 1

        return GraphTransformation(
            operation: .minimize(entry.scope),
            priority: entry.priority,
        )
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

// MARK: - Exchange Source

/// Emits exchange scopes for value redistribution and tandem reduction.
///
/// Search-based — the encoder handles multi-probe magnitude search internally.
struct ExchangeSource: CandidateSource {
    private var scopes: [(scope: ExchangeScope, priority: DispatchPriority)]
    private var index = 0

    init(graph: some ReadOnlyChoiceGraph) {
        var entries: [(scope: ExchangeScope, priority: DispatchPriority)] = []
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

            entries.append((
                scope: scope,
                priority: DispatchPriority(
                    structuralBenefit: 0,
                    valueBenefit: 0,
                    reductionMagnitude: sourceDistance,
                    estimatedCost: estimatedCost
                )
            ))
        }
        scopes = entries.sorted { $0.priority > $1.priority }
    }

    var peekPriority: DispatchPriority? {
        guard index < scopes.count else { return nil }
        return scopes[index].priority
    }

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard index < scopes.count else { return nil }
        let entry = scopes[index]
        index += 1

        return GraphTransformation(
            operation: .exchange(entry.scope),
            priority: entry.priority,
        )
    }
}
