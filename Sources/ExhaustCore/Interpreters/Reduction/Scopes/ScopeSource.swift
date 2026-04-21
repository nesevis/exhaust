//
//  ScopeSource.swift
//  Exhaust
//

// MARK: - Scope Source Protocol

/// A pull-based iterator that lazily produces scopes in yield-descending order.
///
/// Each source represents one structural search space (a sequence to empty, a batch removal range, an aligned sibling set, a replacement candidate). It emits one fully specified scope at a time via ``next(lastAccepted:)``. The scheduler merges sources by ``peekYield``, pulling from whichever has the highest-yield next scope.
///
/// This is a graph-aware variant of the pull-based density algorithm used by ``PullBasedCoveringArrayGenerator``. The same pattern — lazy, greedy, demand-driven — applies to scope generation, with graph-specific advantages: heterogeneous unit sizes weighted by exact yield, independence structure from the antichain, constraint-aware pruning via length constraints, and hierarchical decomposition from the containment tree.
///
/// On structural acceptance, all sources are rebuilt from the new graph. On rejection, only the dispatched source advances.
///
/// Concrete sources live in sibling files grouped by domain:
/// - `ScopeSource+Removal.swift`: deletion-based sources (batched cross-sequence, emptying, batch, per-element, aligned).
/// - `ScopeSource+Migration.swift`: element migration between independent sequences.
/// - `ScopeSource+Restructuring.swift`: replacement and permutation.
/// - `ScopeSource+ValueSearch.swift`: minimization and exchange (search-based).
protocol ScopeSource {
    /// The yield of the scope that would be returned by the next call to ``next(lastAccepted:)``. Nil when exhausted.
    var peekYield: TransformationYield? { get }

    /// Produces the next scope, incorporating feedback from the prior probe.
    mutating func next(lastAccepted: Bool) -> GraphTransformation?
}

// MARK: - Source Collection Builder

/// Builds the collection of scope sources from a graph.
///
/// Creates one source per search space. The scheduler merges them by ``ScopeSource/peekYield``.
enum ScopeSourceBuilder {
    /// Builds all scope sources from the current graph.
    static func buildSources(from graph: ChoiceGraph) -> [any ScopeSource] {
        var sources: [any ScopeSource] = []

        // Batched cross-sequence removal — most drastic structural reduction.
        let batchedSource = BatchedCrossSequenceRemovalSource(graph: graph)
        if batchedSource.peekYield != nil {
            sources.append(batchedSource)
        }

        // Sequence emptying — per-sequence emptying.
        let emptyingSource = SequenceEmptyingSource(graph: graph)
        if emptyingSource.peekYield != nil {
            sources.append(emptyingSource)
        }

        // Batch removal — one source per sequence with deletable elements.
        // Geometric halving within each sequence (half → quarter → eighth).
        for scope in RemovalScopeQuery.elementRemovalScopes(graph: graph) {
            guard scope.targets.count == 1, let target = scope.targets.first else { continue }
            let source = BatchRemovalSource(
                sequenceNodeID: target.sequenceNodeID,
                graph: graph
            )
            if source.peekYield != nil {
                sources.append(source)
            }
        }

        // Migration — move elements between antichain-independent sequences.
        // Runs before per-element deletion: migrating all elements out of a source sequence and removing it is more powerful than deleting individual elements, and its low per-element yield would otherwise be starved by the stall budget.
        let migrationSource = MigrationSource(graph: graph)
        if migrationSource.peekYield != nil {
            sources.append(migrationSource)
        }

        // Per-element removal.
        let perElementSource = PerElementRemovalSource(graph: graph)
        if perElementSource.peekYield != nil {
            sources.append(perElementSource)
        }

        // Aligned removal — only if at least one participating sibling is dirty.
        let alignedSource = AlignedRemovalSource(graph: graph)
        if alignedSource.peekYield != nil {
            sources.append(alignedSource)
        }

        // Replacement.
        let replacementSource = ReplacementSource(graph: graph)
        if replacementSource.peekYield != nil {
            sources.append(replacementSource)
        }

        // Permutation.
        let permutationSource = PermutationSource(graph: graph)
        if permutationSource.peekYield != nil {
            sources.append(permutationSource)
        }

        // Minimization (search-based).
        let minimizationSource = MinimizationSource(graph: graph)
        if minimizationSource.peekYield != nil {
            sources.append(minimizationSource)
        }

        // Exchange (search-based).
        let exchangeSource = ExchangeSource(graph: graph)
        if exchangeSource.peekYield != nil {
            sources.append(exchangeSource)
        }

        return sources
    }
}
