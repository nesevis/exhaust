//
//  ScopeSource+Restructuring.swift
//  Exhaust
//

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
            let structuralYield: Int = switch scope {
            case let .selfSimilar(selfSimilar):
                max(0, selfSimilar.sizeDelta)
            case let .branchPivot(pivot):
                graph.nodes[pivot.pickNodeID].positionRange?.count ?? 0
            case let .descendantPromotion(promotion):
                promotion.sizeDelta
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

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard index < candidates.count else { return nil }
        let entry = candidates[index]
        index += 1

        let precondition: TransformationPrecondition = switch entry.scope {
        case let .selfSimilar(selfSimilar):
            .all([
                .nodeActive(selfSimilar.targetNodeID),
                .nodeActive(selfSimilar.donorNodeID),
            ])
        case let .branchPivot(pivot):
            .nodeActive(pivot.pickNodeID)
        case let .descendantPromotion(promotion):
            .all([
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

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
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
