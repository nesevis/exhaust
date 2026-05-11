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

// MARK: - Builder Functions

extension CandidateSourceBuilder {
    static func buildReplacementCandidates(graph: some ReadOnlyChoiceGraph) -> [GraphTransformation] {
        var results: [GraphTransformation] = []

        for scope in ReplacementQuery.build(graph: graph) {
            let structuralYield: Int = switch scope {
            case let .selfSimilar(selfSimilar):
                max(0, selfSimilar.sizeDelta)
            case let .branchPivot(pivot):
                graph.nodes[pivot.pickNodeID].positionRange?.count ?? 0
            case let .descendantPromotion(promotion):
                promotion.sizeDelta
            }
            results.append(GraphTransformation(
                operation: .replace(scope),
                priority: DispatchPriority(
                    structuralBenefit: structuralYield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ))
        }

        results.sort { $0.priority > $1.priority }
        return results
    }

    static func buildPermutationCandidates(graph: some ReadOnlyChoiceGraph) -> [GraphTransformation] {
        var entries: [(parentNodeID: Int, group: [Int], position: Int)] = []
        for scope in PermutationQuery.build(graph: graph) {
            guard case let .siblingPermutation(permScope) = scope else { continue }
            for group in permScope.swappableGroups {
                guard group.count >= 2 else { continue }
                let position = graph.nodes[group[0]].positionRange?.lowerBound ?? 0
                entries.append((parentNodeID: permScope.parentNodeID, group: group, position: position))
            }
        }
        // Order by position of the earliest child (earlier = more shortlex impact).
        entries.sort { $0.position < $1.position }

        return entries.map { entry in
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
}
