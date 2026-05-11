//
//  CandidateSource.swift
//  Exhaust
//

// MARK: - Scope Source Protocol

/// A pull-based iterator that lazily produces scopes in yield-descending order.
///
/// Each source represents one structural search space (a sequence to empty, a batch removal range, an aligned sibling set, a replacement candidate). It emits one fully specified scope at a time via ``next(lastAccepted:)``. The scheduler merges sources by ``peekPriority``, pulling from whichever has the highest-yield next scope.
///
/// This is a graph-aware variant of the pull-based density algorithm used by ``PullBasedCoveringArrayGenerator``. The same pattern — lazy, greedy, demand-driven — applies to scope generation, with graph-specific advantages: heterogeneous unit sizes weighted by exact yield, independence structure from the antichain, constraint-aware pruning via length constraints, and hierarchical decomposition from the containment tree.
///
/// On structural acceptance, all sources are rebuilt from the new graph. On rejection, only the dispatched source advances.
///
/// Concrete sources live in sibling files grouped by domain:
/// - `CandidateSource+Removal.swift`: deletion-based sources (batched cross-sequence, emptying, batch, per-element, aligned).
/// - `CandidateSource+Migration.swift`: element migration between independent sequences.
/// - `CandidateSource+Restructuring.swift`: replacement and permutation.
/// - `CandidateSource+ValueSearch.swift`: minimization and exchange (search-based).
protocol CandidateSource {
    /// The yield of the scope that would be returned by the next call to ``next(lastAccepted:)``. Nil when exhausted.
    var peekPriority: DispatchPriority? { get }

    /// Produces the next scope, incorporating feedback from the prior probe.
    mutating func next(lastAccepted: Bool) -> GraphTransformation?
}

// MARK: - Source Collection Builder

/// Builds the collection of scope sources from a graph.
///
/// Creates one source per search space. The scheduler merges them by ``CandidateSource/peekPriority``.
enum CandidateSourceBuilder {
    /// Builds all scope sources from the current graph.
    ///
    /// - Parameter deferBindInner: When true, bind-inner value leaves and bound value scopes are excluded from the minimization source. The scheduler sets this while structural reduction is still active to avoid probing values on nodes that will be structurally removed.
    static func buildSources(from graph: some ReadOnlyChoiceGraph, deferBindInner: Bool = false) -> [any CandidateSource] {
        var sources: [any CandidateSource] = []

        // Batched cross-sequence removal — most drastic structural reduction.
        let batchedSource = BatchedCrossSequenceRemovalSource(graph: graph)
        if batchedSource.peekPriority != nil {
            sources.append(batchedSource)
        }

        // Sequence emptying — per-sequence emptying.
        let emptyingSource = SequenceEmptyingSource(graph: graph)
        if emptyingSource.peekPriority != nil {
            sources.append(emptyingSource)
        }

        // Batch removal — one source per sequence with deletable elements.
        // Geometric halving within each sequence (half → quarter → eighth).
        for scope in RemovalQuery.elementRemovalScopes(graph: graph) {
            guard scope.targets.count == 1, let target = scope.targets.first else { continue }
            let source = BatchRemovalSource(
                sequenceNodeID: target.sequenceNodeID,
                graph: graph
            )
            if source.peekPriority != nil {
                sources.append(source)
            }
        }

        // Migration — move elements between antichain-independent sequences.
        // Runs before per-element deletion: migrating all elements out of a source sequence and removing it is more powerful than deleting individual elements, and its low per-element yield would otherwise be starved by the stall budget.
        let migrationSource = MigrationSource(graph: graph)
        if migrationSource.peekPriority != nil {
            sources.append(migrationSource)
        }

        // Per-element removal.
        let perElementSource = PerElementRemovalSource(graph: graph)
        if perElementSource.peekPriority != nil {
            sources.append(perElementSource)
        }

        // Aligned removal — only if at least one participating sibling is dirty.
        let alignedSource = AlignedRemovalSource(graph: graph)
        if alignedSource.peekPriority != nil {
            sources.append(alignedSource)
        }

        // Replacement.
        let replacementSource = ReplacementSource(graph: graph)
        if replacementSource.peekPriority != nil {
            sources.append(replacementSource)
        }

        // Permutation.
        let permutationSource = PermutationSource(graph: graph)
        if permutationSource.peekPriority != nil {
            sources.append(permutationSource)
        }

        // Minimization (search-based).
        let minimizationSource = MinimizationSource(graph: graph, deferBindInner: deferBindInner)
        if minimizationSource.peekPriority != nil {
            sources.append(minimizationSource)
        }

        // Exchange (search-based).
        let exchangeSource = ExchangeSource(graph: graph)
        if exchangeSource.peekPriority != nil {
            sources.append(exchangeSource)
        }

        return sources
    }
}
