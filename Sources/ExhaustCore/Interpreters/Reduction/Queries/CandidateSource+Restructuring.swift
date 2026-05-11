//
//  CandidateSource+Restructuring.swift
//  Exhaust
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Replacement Source

/// Emits replacement scopes in size-delta-descending order.
///
/// Includes self-similar substitutions, branch pivots, and descendant promotions. Each scope fully specifies the donor and target. One probe per scope.
struct ReplacementSource: CandidateSource {
    private var candidates: [(scope: ReplacementScope, priority: DispatchPriority)]
    private var index = 0

    init(graph: some ReadOnlyChoiceGraph) {
        var entries: [(scope: ReplacementScope, priority: DispatchPriority)] = []

        for scope in ReplacementQuery.build(graph: graph) {
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
                priority: DispatchPriority(
                    structuralBenefit: structuralYield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ))
        }
        candidates = entries.sorted { $0.priority > $1.priority }
    }

    var peekPriority: DispatchPriority? {
        guard index < candidates.count else { return nil }
        return candidates[index].priority
    }

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard index < candidates.count else { return nil }
        let entry = candidates[index]
        index += 1

        return GraphTransformation(
            operation: .replace(entry.scope),
            priority: entry.priority
        )
    }
}

// MARK: - Permutation Source

/// Emits sibling swap scopes with full same-shaped groups, ordered by zip position (earlier = more shortlex impact).
///
/// Each scope carries the complete group of same-shaped siblings. The encoder picks the first improving pair internally, then adaptively extends on success (pushing the moved content further rightward via doubling). This replaces the prior O(N^2) pairwise decomposition in the source with O(1) emission per group plus O(log N) adaptive probes in the encoder.
struct PermutationSource: CandidateSource {
    private var candidates: [(parentNodeID: Int, group: [Int])]
    private var index = 0

    init(graph: some ReadOnlyChoiceGraph) {
        var entries: [(parentNodeID: Int, group: [Int])] = []
        for scope in PermutationQuery.build(graph: graph) {
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

    var peekPriority: DispatchPriority? {
        guard index < candidates.count else { return nil }
        let groupSize = candidates[index].group.count
        let estimatedCost = groupSize <= 2 ? 1 : (1 + Int(log2(Double(groupSize))))
        return DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: estimatedCost
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

        let estimatedCost = entry.group.count <= 2 ? 1 : (1 + Int(log2(Double(entry.group.count))))
        return GraphTransformation(
            operation: .permute(.siblingPermutation(scope)),
            priority: DispatchPriority(
                structuralBenefit: 0,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: estimatedCost
            )
        )
    }
}
