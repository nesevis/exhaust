//
//  ScopeSource+ValueSearch.swift
//  Exhaust
//

// MARK: - Minimization Source

/// Emits minimization scopes for value search. These are search-based — the encoder handles multi-probe internally.
///
/// Produces one scope per leaf type (integer, float) and one per bound value edge, ordered by value yield descending.
struct MinimizationSource: ScopeSource {
    private var scopes: [(scope: MinimizationScope, yield: TransformationYield)]
    private var index = 0

    init(graph: ChoiceGraph) {
        let innerChildToBind = ScopeQueryHelpers.buildInnerChildToBind(graph: graph)
        var entries: [(scope: MinimizationScope, yield: TransformationYield)] = []

        for scope in MinimizationScopeQuery.build(graph: graph, innerChildToBind: innerChildToBind) {
            let valueYield: Int = switch scope {
            case let .valueLeaves(integerScope):
                integerScope.leafNodeIDs.reduce(0) { maxSoFar, nodeID in
                    max(maxSoFar, Self.computeValueYield(leafNodeID: nodeID, graph: graph, innerChildToBind: innerChildToBind))
                }
            case let .floatLeaves(floatScope):
                floatScope.leafNodeIDs.reduce(0) { maxSoFar, nodeID in
                    max(maxSoFar, Self.computeValueYield(leafNodeID: nodeID, graph: graph, innerChildToBind: innerChildToBind))
                }
            case let .boundValue(fibreScope):
                fibreScope.boundSubtreeSize
            case let .pivotThenMinimize(pivotScope):
                pivotScope.subtreeSize
            }

            let estimatedProbes: Int = switch scope {
            case let .valueLeaves(integerScope):
                1 + integerScope.leafNodeIDs.count * 16
            case let .floatLeaves(floatScope):
                floatScope.leafNodeIDs.count * 15
            case let .boundValue(fibreScope):
                15 + min(128, fibreScope.boundSubtreeSize)
            case let .pivotThenMinimize(pivotScope):
                pivotScope.alternativeBranchCount * 16
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

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
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
        for scope in ExchangeScopeQuery.build(graph: graph) {
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

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
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
