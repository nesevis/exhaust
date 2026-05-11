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
    static func buildReplacementCandidates(graph: ChoiceGraph, previousGraph: ChoiceGraph? = nil) -> [GraphTransformation] {
        var results: [GraphTransformation] = []

        for scope in ReplacementQuery.build(graph: graph, previousGraph: previousGraph) {
            let structuralYield: Int = switch scope {
            case let .selfSimilar(_, _, sizeDelta):
                max(0, sizeDelta)
            case let .branchPivot(pickNodeID, _):
                graph.nodes[pickNodeID].positionRange?.count ?? 0
            case let .descendantPromotion(_, _, sizeDelta):
                sizeDelta
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

    static func buildPermutationCandidates(graph: ChoiceGraph) -> [GraphTransformation] {
        var entries: [(parentNodeID: Int, group: [Int], position: Int)] = []
        for scope in PermutationQuery.build(graph: graph) {
            guard case let .siblingPermutation(parentNodeID, swappableGroups) = scope else { continue }
            for group in swappableGroups {
                guard group.count >= 2 else { continue }
                let position = graph.nodes[group[0]].positionRange?.lowerBound ?? 0
                entries.append((parentNodeID: parentNodeID, group: group, position: position))
            }
        }
        // Order by position of the earliest child (earlier = more shortlex impact).
        entries.sort { $0.position < $1.position }

        return entries.map { entry in
            let estimatedCost = entry.group.count <= 2 ? 1 : (1 + Int(log2(Double(entry.group.count))))
            return GraphTransformation(
                operation: .permute(.siblingPermutation(
                    parentNodeID: entry.parentNodeID,
                    swappableGroups: [entry.group]
                )),
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
