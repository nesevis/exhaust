//
//  GraphOperation.swift
//  Exhaust
//

// MARK: - Academic Background

// The operation taxonomy, encoder/decoder split, priority-based scheduling, and relax round are informed by Sepulveda-Jimenez, "Categories of Optimization Reductions" (2026), which formalises reduce-solve-recover pipelines as morphisms in a graded category with approximation slack and resource tracking. The paper is an optimization algebra designed for composing known reductions; Exhaust adapts it for morphism discovery, where candidates are proposed speculatively and certified by an opaque property oracle.

// MARK: - Graph Operation

/// The seven operations on a ``ChoiceGraph``.
///
/// Remove, replace, permute, and migrate are exact (one-shot) reductions. Minimize is a multi-probe binary search. Exchange is an approximate reduction that may temporarily worsen shortlex before enabling further progress. Reorder is a final canonicalization pass.
///
/// Six of seven operations work within the generator's active execution path (nodes with non-nil position ranges). Only replace changes the active path — it may bring inactive content into the sequence, requiring tree editing and flattening.
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
    /// Only dispatched post-loop by ``ChoiceGraphScheduler`` after all other reduction is complete. Never emitted by any ``CandidateSource``.
    case reorder(ReorderingScope)

    /// The encoder name that will handle this operation. Used by the ``ReducerConfiguration/enabledEncoders`` filter to skip operations targeting disabled encoders without instantiating the encoder.
    var encoderName: EncoderName {
        switch self {
            case .remove: .deletion
            case .replace: .substitution
            case .migrate: .migration
            case .minimize(.valueLeaves): .valueSearch
            case .minimize(.floatLeaves): .floatSearch
            case .minimize(.boundValue): .boundValueSearch
            case .minimize(.laneCollapse): .laneCollapse
            case .exchange(.redistribution): .redistribution
            case .exchange(.tandem): .lockstep
            case .exchange(.relation): .relationSearch
            case .permute: .siblingSwap
            case .reorder: .numericReorder
        }
    }

    /// Whether this operation changes the generator's active execution path. Only replace is path-changing.
    var isPathChanging: Bool {
        if case .replace = self { return true }
        return false
    }

    /// Whether this operation's scope data depends on leaf values (ChoiceValue, validRange, distance-to-target) rather than just graph topology. Value-dependent sources must be rebuilt after any value change, even structurally-identical ones.
    var isValueDependent: Bool {
        switch self {
            case .minimize, .exchange:
                return true
            case .remove, .replace, .permute, .migrate, .reorder:
                return false
        }
    }

    /// Per-scope discriminator for the rejection cache. Branch pivot uses the target branch ID so that rejecting branch A at a pick site does not block branch B at the same site. All other operations return 0.
    var scopeSubDiscriminator: UInt64 {
        if case let .replace(.branchPivot(_, targetBranchID)) = self {
            return targetBranchID
        }
        return 0
    }

    /// Invokes `body` for each node ID whose position range is affected by this operation. Used by ``CandidateRejectionCache`` to compute position-scoped Zobrist hashes inline.
    ///
    /// Returns `false` for search-based operations (minimize, exchange) and covering-aligned removal where the affected set is nondeterministic or not applicable.
    func forEachAffectedNodeID(_ body: (Int) -> Void) -> Bool {
        switch self {
            case let .remove(scope):
                switch scope {
                    case let .elements(elementScope):
                        for target in elementScope.targets {
                            for nodeID in target.elementNodeIDs {
                                body(nodeID)
                            }
                        }
                    case let .subtree(nodeID, _):
                        body(nodeID)
                    case .coveringAligned:
                        return false
                }
            case let .replace(scope):
                switch scope {
                    case let .selfSimilar(targetNodeID, donorNodeID, _):
                        body(targetNodeID)
                        body(donorNodeID)
                    case let .branchPivot(pickNodeID, _):
                        body(pickNodeID)
                    case let .descendantPromotion(ancestorPickNodeID, descendantPickNodeID, _):
                        body(ancestorPickNodeID)
                        body(descendantPickNodeID)
                }
            case let .permute(scope):
                for group in scope.swappableGroups {
                    for nodeID in group {
                        body(nodeID)
                    }
                }
            case let .migrate(scope):
                for nodeID in scope.elementNodeIDs {
                    body(nodeID)
                }
                body(scope.receiverSequenceNodeID)
            case .minimize, .exchange:
                return false
            case .reorder:
                return false
        }
        return true
    }
}

// MARK: - Validity

extension GraphOperation {
    /// Validates whether the operation's target nodes still exist and satisfy its preconditions in the current graph state.
    func isValid(in graph: ChoiceGraph) -> Bool {
        switch self {
            case let .remove(.elements(scope)):
                return scope.targets.allSatisfy { target in
                    guard target.sequenceNodeID < graph.nodes.count else { return false }
                    guard case let .sequence(metadata) = graph.nodes[target.sequenceNodeID].kind else { return false }
                    return UInt64(metadata.elementCount) > (metadata.lengthConstraint?.lowerBound ?? 0)
                }
            case let .remove(.subtree(nodeID, _)):
                return nodeID < graph.nodes.count
                    && graph.nodes[nodeID].positionRange != nil
            case let .remove(.coveringAligned(scope)):
                return scope.siblings.allSatisfy { sibling in
                    guard sibling.sequenceNodeID < graph.nodes.count else { return false }
                    guard case let .sequence(metadata) = graph.nodes[sibling.sequenceNodeID].kind else { return false }
                    return UInt64(metadata.elementCount) > (metadata.lengthConstraint?.lowerBound ?? 0)
                }
            case let .replace(.selfSimilar(targetNodeID, donorNodeID, _)):
                return targetNodeID < graph.nodes.count
                    && graph.nodes[targetNodeID].positionRange != nil
                    && donorNodeID < graph.nodes.count
                    && graph.nodes[donorNodeID].positionRange != nil
            case let .replace(.branchPivot(pickNodeID, _)):
                return pickNodeID < graph.nodes.count
                    && graph.nodes[pickNodeID].positionRange != nil
            case let .replace(.descendantPromotion(ancestorPickNodeID, descendantPickNodeID, _)):
                return ancestorPickNodeID < graph.nodes.count
                    && graph.nodes[ancestorPickNodeID].positionRange != nil
                    && descendantPickNodeID < graph.nodes.count
                    && graph.nodes[descendantPickNodeID].positionRange != nil
            case let .permute(scope):
                return scope.parentNodeID < graph.nodes.count
                    && graph.nodes[scope.parentNodeID].positionRange != nil
            case let .migrate(scope):
                if let parentSeqID = scope.sourceParentSequenceNodeID {
                    guard parentSeqID < graph.nodes.count else { return false }
                    guard case let .sequence(metadata) = graph.nodes[parentSeqID].kind else { return false }
                    guard UInt64(metadata.elementCount) > (metadata.lengthConstraint?.lowerBound ?? 0) else { return false }
                } else {
                    guard scope.sourceSequenceNodeID < graph.nodes.count else { return false }
                    guard case let .sequence(metadata) = graph.nodes[scope.sourceSequenceNodeID].kind else { return false }
                    guard UInt64(metadata.elementCount) > (metadata.lengthConstraint?.lowerBound ?? 0) else { return false }
                }
                return scope.receiverSequenceNodeID < graph.nodes.count
                    && graph.nodes[scope.receiverSequenceNodeID].positionRange != nil
            case .minimize, .exchange, .reorder:
                return true
        }
    }
}

// MARK: - Graph Transformation

/// Pairs a ``GraphOperation`` with a ``DispatchPriority`` for scheduling by the scope source.
struct GraphTransformation {
    /// The graph operation this transformation enacts.
    let operation: GraphOperation

    /// Graph-computable scheduling priority.
    let priority: DispatchPriority
}
