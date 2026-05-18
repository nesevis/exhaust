// MARK: - Scope Stability

/// Classifies a scope's sensitivity to graph changes.
///
/// Structural scopes (removal, replacement, permutation, migration) are derived from graph topology (node kinds, parent-child relationships, self-similarity groups) and remain valid as long as the graph is structurally identical. Value scopes (minimization, exchange) depend on leaf values (current bit pattern, distance to target) and must be rebuilt after any value-only acceptance.
///
/// This classification was previously implicit in ``CandidateSourceBuilder``'s two-method split (`buildStructuralSources` / `buildValueSources`). Making it a property of the scope lets the scheduler reason about rebuild necessity per-scope.
enum ScopeStability {
    /// Valid as long as the graph is structurally identical. Removal, replacement, permutation, migration, reordering.
    case structural

    /// Must be rebuilt after any leaf value change. Minimization, exchange.
    case valueDerived
}

// MARK: - Reduction Scope Protocol

/// Scheduler-facing contract shared by all scope types.
///
/// Each of the seven scope families (``RemovalScope``, ``ReplacementScope``, ``MinimizationScope``, ``ExchangeScope``, ``PermutationScope``, ``MigrationScope``, ``ReorderingScope``) conforms to this protocol. The scheduler uses it to make dispatch decisions (priority ordering, rebuild gating, convergence checks) without knowing the encoder-facing payload.
///
/// The protocol does not replace ``GraphOperation`` — it annotates it. The flat enum remains the dispatch mechanism; the protocol names the contract.
protocol ReductionScope {
    /// The operation this scope targets, wrapped in the corresponding ``GraphOperation`` case.
    var operation: GraphOperation { get }

    /// Scheduling priority: structural benefit, value benefit, reduction magnitude, estimated cost.
    var priority: DispatchPriority { get }

    /// Whether this scope's data depends on leaf values and must be rebuilt after value-only acceptances.
    var stability: ScopeStability { get }

    /// Node IDs whose position ranges are affected by this scope's operation. Nil for search-based operations (minimize, exchange) where the outcome is nondeterministic.
    func affectedNodeIDs(in graph: ChoiceGraph) -> [Int]?
}

// MARK: - Conformances

extension RemovalScope: ReductionScope {
    var operation: GraphOperation { .remove(self) }

    var priority: DispatchPriority {
        let structuralBenefit: Int
        switch self {
        case let .elements(scope):
            structuralBenefit = scope.maxElementYield * scope.maxBatch
        case let .subtree(_, yield):
            structuralBenefit = yield
        case let .coveringAligned(scope):
            structuralBenefit = scope.maxElementYield
        }
        return DispatchPriority(
            structuralBenefit: structuralBenefit,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 1
        )
    }

    var stability: ScopeStability { .structural }

    func affectedNodeIDs(in graph: ChoiceGraph) -> [Int]? {
        operation.affectedNodeIDs(in: graph)
    }
}

extension ReplacementScope: ReductionScope {
    var operation: GraphOperation { .replace(self) }

    var priority: DispatchPriority {
        let structuralBenefit: Int
        switch self {
        case let .selfSimilar(_, _, sizeDelta):
            structuralBenefit = sizeDelta
        case .branchPivot:
            structuralBenefit = 1
        case let .descendantPromotion(_, _, sizeDelta):
            structuralBenefit = sizeDelta
        }
        return DispatchPriority(
            structuralBenefit: structuralBenefit,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 1
        )
    }

    var stability: ScopeStability { .structural }

    func affectedNodeIDs(in graph: ChoiceGraph) -> [Int]? {
        operation.affectedNodeIDs(in: graph)
    }
}

extension MinimizationScope: ReductionScope {
    var operation: GraphOperation { .minimize(self) }

    var priority: DispatchPriority {
        DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 1
        )
    }

    var stability: ScopeStability { .valueDerived }

    func affectedNodeIDs(in graph: ChoiceGraph) -> [Int]? {
        nil
    }
}

extension ExchangeScope: ReductionScope {
    var operation: GraphOperation { .exchange(self) }

    var priority: DispatchPriority {
        DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 1
        )
    }

    var stability: ScopeStability { .valueDerived }

    func affectedNodeIDs(in graph: ChoiceGraph) -> [Int]? {
        nil
    }
}

extension PermutationScope: ReductionScope {
    var operation: GraphOperation { .permute(self) }

    var priority: DispatchPriority {
        DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 1
        )
    }

    var stability: ScopeStability { .structural }

    func affectedNodeIDs(in graph: ChoiceGraph) -> [Int]? {
        operation.affectedNodeIDs(in: graph)
    }
}

extension MigrationScope: ReductionScope {
    var operation: GraphOperation { .migrate(self) }

    var priority: DispatchPriority {
        DispatchPriority(
            structuralBenefit: elementNodeIDs.count,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 1
        )
    }

    var stability: ScopeStability { .structural }

    func affectedNodeIDs(in graph: ChoiceGraph) -> [Int]? {
        operation.affectedNodeIDs(in: graph)
    }
}

extension ReorderingScope: ReductionScope {
    var operation: GraphOperation { .reorder(self) }

    var priority: DispatchPriority {
        DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 1
        )
    }

    var stability: ScopeStability { .structural }

    func affectedNodeIDs(in graph: ChoiceGraph) -> [Int]? {
        nil
    }
}
