//
//  ScopeSource+Restructuring.swift
//  Exhaust
//

import Foundation

// MARK: - Replacement Source

/// Emits replacement scopes in size-delta-descending order.
///
/// Includes self-similar substitutions, branch pivots, and descendant promotions. Each scope fully specifies the donor and target. One probe per scope.
struct ReplacementSource: ScopeSource {
    private var candidates: [(scope: ReplacementScope, yield: TransformationYield)]
    private var index = 0

    init(graph: ChoiceGraph) {
        var entries: [(scope: ReplacementScope, yield: TransformationYield)] = []

        for scope in ReplacementScopeQuery.build(graph: graph) {
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

/// Emits sibling swap scopes with full same-shaped groups, ordered by zip position (earlier = more shortlex impact).
///
/// Each scope carries the complete group of same-shaped siblings. The encoder picks the first improving pair internally, then adaptively extends on success (pushing the moved content further rightward via doubling). This replaces the prior O(N^2) pairwise decomposition in the source with O(1) emission per group plus O(log N) adaptive probes in the encoder.
struct PermutationSource: ScopeSource {
    private var candidates: [(parentNodeID: Int, group: [Int])]
    private var index = 0

    init(graph: ChoiceGraph) {
        var entries: [(parentNodeID: Int, group: [Int])] = []
        for scope in PermutationScopeQuery.build(graph: graph) {
            guard case let .siblingPermutation(permScope) = scope else { continue }
            for group in permScope.swappableGroups {
                guard group.count >= 2 else { continue }
                entries.append((parentNodeID: permScope.parentNodeID, group: group))
            }
        }
        // Order by position of the earliest child (earlier = more shortlex impact).
        entries.sort { entryA, entryB in
            let positionA = graph.nodes[entryA.group[0]].positionRange?.lowerBound ?? 0
            let positionB = graph.nodes[entryB.group[0]].positionRange?.lowerBound ?? 0
            return positionA < positionB
        }
        candidates = entries
    }

    var peekYield: TransformationYield? {
        guard index < candidates.count else { return nil }
        let groupSize = candidates[index].group.count
        let estimatedProbes = groupSize <= 2 ? 1 : (1 + Int(log2(Double(groupSize))))
        return TransformationYield(
            structural: 0,
            value: 0,
            slack: .exact,
            estimatedProbes: estimatedProbes
        )
    }

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard index < candidates.count else { return nil }
        let entry = candidates[index]
        index += 1

        let scope = SiblingPermutationScope(
            parentNodeID: entry.parentNodeID,
            swappableGroups: [entry.group]
        )

        let estimatedProbes = entry.group.count <= 2 ? 1 : (1 + Int(log2(Double(entry.group.count))))
        return GraphTransformation(
            operation: .permute(.siblingPermutation(scope)),
            yield: TransformationYield(
                structural: 0,
                value: 0,
                slack: .exact,
                estimatedProbes: estimatedProbes
            ),
            precondition: .nodeActive(entry.parentNodeID),
            postcondition: TransformationPostcondition(
                isStructural: false,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
    }
}
