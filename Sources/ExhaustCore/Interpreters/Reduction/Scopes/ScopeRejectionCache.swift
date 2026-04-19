//
//  ScopeRejectionCache.swift
//  Exhaust
//

// MARK: - Scope Rejection Cache

/// Deterministic duplicate detection for structural graph operations using position-scoped Zobrist hashes.
///
/// For each rejected structural operation, computes a hash from the operation discriminator and the ``ZobristHash`` contributions at the targeted positions. The hash naturally invalidates when any targeted value changes — no explicit dirty tracking needed.
///
/// Cleared on structural acceptance (graph rebuild changes positions). Persists across cycles for value-only changes.
struct ScopeRejectionCache {
    private var rejectedHashes = Set<UInt64>()

    /// Value-independent hash for replacement operations only. Keyed by (operation type, targeted node IDs) without leaf values. Branch pivot is genuinely value-independent because the encoder speculatively minimizes all leaves via ``GraphStructuralEncoder/minimizingLeaves(in:)``. Self-similar substitution and descendant promotion copy donor entries verbatim, so they are technically value-dependent — but the coarse cache is cleared per-cycle via ``clearCoarse()``, which limits stale rejections to within a single cycle. Deletion and migration are excluded because their acceptance depends on leaf values: a deletion rejected when the element had value 5 may succeed after value search minimizes it to 0.
    private var coarseRejectedHashes = Set<UInt64>()

    /// Records a rejected structural transformation.
    mutating func recordRejection(
        operation: GraphOperation,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) {
        // Structural operations (replacement, deletion, migration) use the coarse (value-independent) cache, cleared per-cycle. A structural operation rejected with old leaf values may succeed after value search changes the surrounding tree — the property outcome depends on the whole tree, not just the targeted positions. Value-based operations (minimization, exchange) use the fine-grained cache.
        switch operation {
        case .replace, .remove, .migrate:
            if let hash = coarseScopeHash(operation: operation, graph: graph) {
                coarseRejectedHashes.insert(hash)
            }
        default:
            if let hash = scopeHash(operation: operation, sequence: sequence, graph: graph) {
                rejectedHashes.insert(hash)
            }
        }
    }

    /// Returns true if this transformation was previously rejected. Checks the coarse (value-independent) cache for structural operations, the fine-grained (value-dependent) cache for value-based operations.
    func isRejected(
        operation: GraphOperation,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> Bool {
        switch operation {
        case .replace, .remove, .migrate:
            guard let hash = coarseScopeHash(operation: operation, graph: graph) else {
                return false
            }
            return coarseRejectedHashes.contains(hash)
        default:
            break
        }
        guard let hash = scopeHash(operation: operation, sequence: sequence, graph: graph) else {
            return false
        }
        return rejectedHashes.contains(hash)
    }

    /// Clears all cached rejections. Called on structural acceptance (graph rebuild).
    mutating func clear() {
        rejectedHashes.removeAll(keepingCapacity: true)
        coarseRejectedHashes.removeAll(keepingCapacity: true)
    }

    /// Clears only the coarse cache. Called at the top of each cycle to guard against stale value-independent rejections when leaf values changed since the rejection was recorded.
    mutating func clearCoarse() {
        coarseRejectedHashes.removeAll(keepingCapacity: true)
    }

    /// Computes a deterministic Zobrist-based hash from the operation discriminator and the values at targeted positions.
    ///
    /// Returns nil for search-based operations (minimize, exchange) whose outcomes are nondeterministic.
    private func scopeHash(
        operation: GraphOperation,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> UInt64? {
        guard let nodeIDs = operation.affectedNodeIDs(in: graph) else {
            return nil
        }

        var hash = operationDiscriminator(operation)
        hash ^= operation.scopeSubDiscriminator

        // Mix in Zobrist contributions at each targeted position.
        for nodeID in nodeIDs {
            guard nodeID < graph.nodes.count,
                  let range = graph.nodes[nodeID].positionRange
            else {
                continue
            }
            for position in range {
                guard position < sequence.count else { break }
                hash ^= ZobristHash.contribution(at: position, sequence[position])
            }
        }

        return hash
    }

    /// Value-independent hash for structural operations. Uses node IDs instead of sequence values, so a deletion targeting the same nodes produces the same hash regardless of leaf values.
    private func coarseScopeHash(
        operation: GraphOperation,
        graph: ChoiceGraph
    ) -> UInt64? {
        guard let nodeIDs = operation.affectedNodeIDs(in: graph) else {
            return nil
        }

        // Use a different discriminator salt to avoid collisions with the fine-grained hash.
        var hash: UInt64 = operationDiscriminator(operation) ^ 0xC0A8_5E00_DEAD_BEEF
        hash ^= operation.scopeSubDiscriminator

        for nodeID in nodeIDs {
            var bits = UInt64(nodeID) &* 0x9E37_79B9_7F4A_7C15
            bits = (bits ^ (bits >> 30)) &* 0xBF58_476D_1CE4_E5B9
            bits = (bits ^ (bits >> 27)) &* 0x94D0_49BB_1331_11EB
            bits ^= bits >> 31
            hash ^= bits
        }

        return hash
    }

    private func operationDiscriminator(_ operation: GraphOperation) -> UInt64 {
        switch operation {
        case .remove: 0xA1B2_C3D4_E5F6_0718
        case .replace: 0x1827_3645_5463_7281
        case .permute: 0x9182_7364_5546_3728
        case .migrate: 0x6372_8190_A0B0_C0D0
        case .minimize, .exchange, .reorder: 0
        }
    }
}
