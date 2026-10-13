//
//  ReplacementQuery+Shared.swift
//  Exhaust
//

// MARK: - Replacement Query

extension ReplacementQuery {
    // MARK: - Incremental Comparison

    /// Returns the set of fingerprints whose self-similarity groups are unchanged between `previousGraph` and `graph`.
    ///
    /// A group is unchanged when it has the same member count and the same sorted multiset of subtree sizes (position range counts). Unchanged groups produce identical replacement scopes, so mid-cycle rebuilds can skip them.
    static func unchangedFingerprints(
        graph: ChoiceGraph,
        previousGraph: ChoiceGraph?
    ) -> Set<UInt64> {
        guard let previousGraph else {
            return []
        }
        var unchanged = Set<UInt64>()
        for (fingerprint, newGroup) in graph.selfSimilarityGroups {
            guard let oldGroup = previousGraph.selfSimilarityGroups[fingerprint] else {
                continue
            }
            guard oldGroup.count == newGroup.count else {
                continue
            }
            let oldSizes = oldGroup.map { previousGraph.nodes[$0].positionRange?.count ?? 0 }.sorted()
            let newSizes = newGroup.map { graph.nodes[$0].positionRange?.count ?? 0 }.sorted()
            if oldSizes == newSizes {
                unchanged.insert(fingerprint)
            }
        }
        return unchanged
    }

    // MARK: - Pivot Eligibility

    /// Counts `.choice` leaves reachable from a choice tree subtree. Used by the leaf-count gate in branch pivot scope construction.
    static func leafCount(in tree: ChoiceTree) -> Int {
        switch tree {
            case .choice:
                1
            case .just,
                 .getSize:
                0
            case let .sequence(elements, _):
                elements.reduce(0) { $0 + leafCount(in: $1) }
            case let .branch(branch):
                leafCount(in: branch.choice)
            case let .group(children, _, _):
                children.reduce(0) { $0 + leafCount(in: $1) }
            case let .resize(_, choices):
                choices.reduce(0) { $0 + leafCount(in: $1) }
            case let .bind(_, inner, bound):
                leafCount(in: inner) + leafCount(in: bound)
        }
    }
}
