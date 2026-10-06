/// Prepares replacement cursors while retaining eager materialization for callers that explicitly request all scopes.
enum ReplacementQuery {
    /// Streams replacement transformations in descending structural priority, including stable discovery-order ties.
    static func cursor(
        graph: ChoiceGraph,
        previousGraph: ChoiceGraph? = nil
    ) -> ReplacementCandidateSource {
        ReplacementCandidateSource(graph: graph, previousGraph: previousGraph)
    }

    /// Visits only branch pivots in discovery order, avoiding preparation and enumeration of self-similar pairs.
    static func pivotCursor(graph: ChoiceGraph) -> ReplacementCandidateSource {
        ReplacementCandidateSource(graph: graph, order: .discovery, onlyPivots: true)
    }

    /// Preserves the original scope order for relax-round candidate-length ties.
    static func discoveryCursor(graph: ChoiceGraph, previousGraph: ChoiceGraph? = nil) -> ReplacementCandidateSource {
        ReplacementCandidateSource(graph: graph, previousGraph: previousGraph, order: .discovery)
    }

    /// Materializes the discovery stream for compatibility with callers inspecting all replacement scopes.
    ///
    /// Production dispatch and relaxation use cursors directly. When `previousGraph` is present, unchanged self-similarity families are suppressed while pivots remain available.
    static func build(graph: ChoiceGraph, previousGraph: ChoiceGraph? = nil) -> [ReplacementScope] {
        var cursor = discoveryCursor(graph: graph, previousGraph: previousGraph)
        var scopes: [ReplacementScope] = []
        while let transformation = cursor.next(lastAccepted: false) {
            guard case let .replace(scope) = transformation.operation else {
                continue
            }
            scopes.append(scope)
        }
        return scopes
    }

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
