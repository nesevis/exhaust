//
//  GraphOperation.swift
//  Exhaust
//

// MARK: - Graph Operation

/// The six fundamental operations on a ``ChoiceGraph``.
///
/// Each case corresponds to a morphism type in OptRed (Sepulveda-Jimenez): remove, replace, permute, and migrate are exact reductions; minimize is a multi-probe search; exchange is an approximate reduction with affine slack.
///
/// Five of six operations work within the generator's active execution path (nodes with non-nil position ranges). Only replace changes the active path — it may bring inactive content into the sequence, requiring tree editing and flattening.
enum GraphOperation {
    /// Remove containment-subtrees, reducing sequence length.
    case remove(RemovalScope)

    /// Replace one subtree with another along a structural edge. The only path-changing operation — may require tree edit and flatten when the donor is inactive.
    case replace(ReplacementScope)

    /// Drive leaf values toward semantic simplest.
    case minimize(MinimizationScope)

    /// Move magnitude between leaves to enable future operations.
    case exchange(ExchangeScope)

    /// Reorder children at a node for shortlex improvement.
    case permute(PermutationScope)

    /// Move elements between antichain-independent sequences to improve shortlex ordering.
    case migrate(MigrationScope)

    /// Reorder sequence elements into natural numeric order as a final canonicalization pass.
    ///
    /// Only dispatched post-loop by ``ChoiceGraphScheduler`` after all other reduction is complete. Never emitted by any ``ScopeSource``.
    case reorder(ReorderingScope)

    /// Whether this operation changes the generator's active execution path. Only replace is path-changing.
    var isPathChanging: Bool {
        if case .replace = self { return true }
        return false
    }

    /// Per-scope discriminator for the rejection cache. Branch pivot uses the target branch ID so that rejecting branch A at a pick site does not block branch B at the same site. All other operations return 0.
    var scopeSubDiscriminator: UInt64 {
        if case let .replace(.branchPivot(scope)) = self {
            return scope.targetBranchID
        }
        return 0
    }

    /// Collects node IDs whose position ranges are affected by this operation. Used by ``ScopeRejectionCache`` to compute position-scoped Zobrist hashes for deterministic duplicate detection.
    ///
    /// Returns nil for search-based operations (minimize, exchange) where the outcome is nondeterministic.
    func affectedNodeIDs(in _: ChoiceGraph) -> [Int]? {
        switch self {
        case let .remove(scope):
            switch scope {
            case let .elements(elementScope):
                elementScope.targets.flatMap(\.elementNodeIDs)
            case let .subtree(subtreeScope):
                [subtreeScope.nodeID]
            case .coveringAligned:
                nil
            }
        case let .replace(scope):
            switch scope {
            case let .selfSimilar(selfSimilarScope):
                [selfSimilarScope.targetNodeID, selfSimilarScope.donorNodeID]
            case let .branchPivot(pivotScope):
                [pivotScope.pickNodeID]
            case let .descendantPromotion(promotionScope):
                [promotionScope.ancestorPickNodeID, promotionScope.descendantPickNodeID]
            }
        case let .permute(scope):
            switch scope {
            case let .siblingPermutation(permScope):
                permScope.swappableGroups.flatMap(\.self)
            }
        case let .migrate(scope):
            scope.elementNodeIDs + [scope.receiverSequenceNodeID]
        case .minimize, .exchange:
            nil
        case .reorder:
            nil
        }
    }
}

// MARK: - Preconditions

/// Preconditions on graph state for a transformation to be valid.
///
/// Preconditions reference graph node state, not queue state. The scheduler evaluates them against the current graph before dispatching to an encoder. After a structural acceptance rebuilds the graph, preconditions are re-evaluated on the fresh queue.
enum TransformationPrecondition {
    /// Always satisfiable. The transformation can be attempted immediately.
    case unconditional

    /// Requires the target node to exist in the current graph with a non-nil position range.
    case nodeActive(Int)

    /// The dependency chain from this node to the root must have all bind-inner ancestors at their convergence floor.
    ///
    /// Evaluated by walking dependency edges in reverse from the leaf through bind-inner ancestors, checking each for a non-nil ``ChooseBitsMetadata/convergedOrigin``. O(bind depth), typically one to three hops.
    case dependencyChainConverged(Int)

    /// The parent sequence must have more elements than its minimum length constraint.
    case sequenceLengthAboveMinimum(sequenceNodeID: Int)

    /// Conjunction of multiple preconditions. Satisfied when all sub-preconditions are satisfied.
    case all([TransformationPrecondition])

    /// Evaluates this precondition against the current graph state.
    ///
    /// - Parameter graph: The current choice graph.
    /// - Returns: Whether the precondition is satisfied.
    func isSatisfied(in graph: ChoiceGraph) -> Bool {
        switch self {
        case .unconditional:
            return true

        case let .nodeActive(nodeID):
            guard nodeID < graph.nodes.count else { return false }
            return graph.nodes[nodeID].positionRange != nil

        case let .dependencyChainConverged(leafNodeID):
            return TransformationPrecondition.checkDependencyChain(
                from: leafNodeID,
                in: graph
            )

        case let .sequenceLengthAboveMinimum(sequenceNodeID):
            guard sequenceNodeID < graph.nodes.count else { return false }
            guard case let .sequence(metadata) = graph.nodes[sequenceNodeID].kind else {
                return false
            }
            let minLength = metadata.lengthConstraint?.lowerBound ?? 0
            return UInt64(metadata.elementCount) > minLength

        case let .all(preconditions):
            return preconditions.allSatisfy { $0.isSatisfied(in: graph) }
        }
    }
}

extension TransformationPrecondition {
    /// Walks dependency edges in reverse from a leaf to verify all bind-inner ancestors have convergence records.
    private static func checkDependencyChain(
        from leafNodeID: Int,
        in graph: ChoiceGraph
    ) -> Bool {
        // Find bind nodes where this leaf (or an ancestor) is the inner child.
        // Walk up the containment tree from the leaf, checking each bind-inner ancestor for convergence.
        var currentNodeID = leafNodeID
        while let parentID = graph.nodes[currentNodeID].parent {
            let parentNode = graph.nodes[parentID]
            if case let .bind(metadata) = parentNode.kind,
               parentNode.children.count >= 2
            {
                let innerChildID = parentNode.children[metadata.innerChildIndex]
                // If the current node is in the bound subtree (not the inner), check that the inner child has converged.
                let boundChildID = parentNode.children[metadata.boundChildIndex]
                if let boundRange = graph.nodes[boundChildID].positionRange,
                   let leafRange = graph.nodes[leafNodeID].positionRange,
                   boundRange.contains(leafRange.lowerBound)
                {
                    // This leaf is in the bound subtree — the inner must be converged.
                    guard case let .chooseBits(innerMetadata) = graph.nodes[innerChildID].kind,
                          innerMetadata.convergedOrigin != nil
                    else {
                        return false
                    }
                }
            }
            currentNodeID = parentID
        }
        return true
    }
}

// MARK: - Postconditions

/// Predicted graph state changes on acceptance.
///
/// The scheduler reads postconditions to determine whether a structural rebuild is needed and which convergence records to invalidate.
struct TransformationPostcondition {
    /// Whether this acceptance changes the graph's structure (requires queue rebuild).
    let isStructural: Bool

    /// Node IDs whose convergence records are invalidated by this acceptance.
    let invalidatesConvergence: [Int]

    /// Node IDs that become new removal candidates after this acceptance (for example, after exchange zeroes a value).
    let enablesRemoval: [Int]
}

// MARK: - Graph Transformation

/// A graph-derived transformation scope with yield estimate and precondition.
///
/// This is a morphism in OptRed_{T,alpha} (Sepulveda-Jimenez, Def. 10.3): the operation defines enc_a, the materializer provides dec_a, and the grade packages approximation slack with resource cost.
struct GraphTransformation {
    /// The graph operation this transformation enacts.
    let operation: GraphOperation

    /// Graph-computable yield estimate (the grade).
    let yield: TransformationYield

    /// Preconditions on graph node state.
    let precondition: TransformationPrecondition

    /// Predicted graph state changes on acceptance.
    let postcondition: TransformationPostcondition
}

