/// Prepares replacement streams in dispatch or discovery order.
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
        ReplacementCandidateSource(pivotGraph: graph)
    }

    /// Preserves the original scope order for relax-round candidate-length ties.
    static func discoveryCursor(graph: ChoiceGraph, previousGraph: ChoiceGraph? = nil) -> ReplacementCandidateSource {
        ReplacementCandidateSource(graph: graph, previousGraph: previousGraph, order: .discovery)
    }
}
