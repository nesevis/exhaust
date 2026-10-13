//
//  BoundValueCompositionTypes+Shared.swift
//  Exhaust
//

// MARK: - Bound Value Composition Types

/// Where one composition sits in a chain of nested binds. Each case fixes the upstream encoder, whether the controller's current value is a candidate, and whether a lift may descend into a nested bind.
package enum BoundValueStage: String, Hashable, Sendable {
    /// The dispatched bind has no composable nested bind. Binary search over the controller, then a terminal search over the bound leaves.
    case single
    /// The dispatched bind, whose bound subtree holds one composable nested bind. Every lift descends, so the controller can move against a nested one.
    case chainRoot
    /// A nested bind with a further composable nested bind beneath it. Its current value stays a candidate so deeper controllers can move while it holds.
    case chainInterior
    /// The deepest composable nested bind. Every lift ends in a terminal search.
    case chainTail

    /// Whether the controller is enumerated across its domain rather than binary searched toward its target.
    var searchesWholeDomain: Bool {
        switch self {
            case .single:
                false
            case .chainRoot, .chainInterior, .chainTail:
                true
        }
    }

    var includesCurrentController: Bool {
        switch self {
            case .chainInterior:
                true
            case .single, .chainRoot, .chainTail:
                false
        }
    }

    var canRecurseIntoNestedBind: Bool {
        switch self {
            case .chainRoot, .chainInterior:
                true
            case .single, .chainTail:
                false
        }
    }
}

/// A controller candidate materialized through the generator, with the dispatched bind located again in the lifted graph.
struct LiftedBind {
    let sequence: ChoiceSequence
    let tree: ChoiceTree
    /// Controller topology only when ``isControllerTopology`` is true. See ``ChoiceGraphBuilder/buildControllerTopology(from:)``.
    let graph: ChoiceGraph
    /// The dispatched bind's node ID in ``graph``, which can differ from its ID in the parent graph.
    let bindNodeID: Int
    /// Sequence positions of the bind's bound subtree.
    let boundRange: ClosedRange<Int>
    /// True for an intermediate stage's lift, whose graph omits scalar array elements.
    let isControllerTopology: Bool

    /// The complete lifted graph a terminal search needs. Bind identity and the bound range were already resolved, so a rebuild only restores omitted value leaves.
    func terminalGraph() -> ChoiceGraph {
        guard isControllerTopology else {
            return graph
        }
        return ChoiceGraph.build(from: tree)
    }
}

/// The first step of a downstream build: a located lift, or the outcome that ended the build.
enum BoundValueLift {
    case lifted(LiftedBind)
    case failed(DownstreamBuildFailure)
}
