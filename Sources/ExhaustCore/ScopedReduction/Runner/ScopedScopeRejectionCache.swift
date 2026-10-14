//
//  ScopedScopeRejectionCache.swift
//  Exhaust
//

// MARK: - Scope Rejection Cache

/// Remembers structural scopes that rejected every probe, so dispatch can skip them while they would only repeat the same probes.
///
/// Replacement, removal, and migration are keyed by operation and targeted node IDs alone, without leaf values, and the runner clears those keys at the start of every cycle, which bounds how long a value change can go unnoticed. Swaps and bind pivots are keyed by the values at their targeted positions, so a value change invalidates them by itself. Everything is cleared after a rebuild that changes structure.
struct ScopedScopeRejectionCache {
    private var rejectedHashes = Set<UInt64>()
    private var coarseRejectedHashes = Set<UInt64>()

    mutating func recordRejection(
        _ opportunity: ScopedOpportunity,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) {
        if Self.usesCoarseKey(opportunity) {
            if let hash = coarseScopeHash(opportunity) {
                coarseRejectedHashes.insert(hash)
            }
            return
        }
        if let hash = scopeHash(opportunity, sequence: sequence, graph: graph) {
            rejectedHashes.insert(hash)
        }
    }

    func isRejected(
        _ opportunity: ScopedOpportunity,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> Bool {
        if Self.usesCoarseKey(opportunity) {
            guard let hash = coarseScopeHash(opportunity) else {
                return false
            }
            return coarseRejectedHashes.contains(hash)
        }
        guard let hash = scopeHash(opportunity, sequence: sequence, graph: graph) else {
            return false
        }
        return rejectedHashes.contains(hash)
    }

    mutating func clear() {
        rejectedHashes.removeAll(keepingCapacity: true)
        coarseRejectedHashes.removeAll(keepingCapacity: true)
    }

    /// Clears only the value-independent keys.
    mutating func clearCoarse() {
        coarseRejectedHashes.removeAll(keepingCapacity: true)
    }

    // MARK: - Helpers

    private static func usesCoarseKey(_ opportunity: ScopedOpportunity) -> Bool {
        switch opportunity {
            case .substitution, .branchPivot, .removal, .migration:
                true
            case .boundValue, .boundExchange, .bindPivot, .depthCollapse, .laneCollapse, .valueSearch, .redistribution,
                 .lockstep, .relation, .stagedJoint, .swap, .reorder:
                false
        }
    }

    /// Mixes the Zobrist contributions at the targeted positions into the operation's discriminator. Nil for searches, whose outcomes the scope does not determine.
    private func scopeHash(
        _ opportunity: ScopedOpportunity,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> UInt64? {
        var hash = Self.operationDiscriminator(opportunity)
        hash ^= opportunity.scopeSubDiscriminator

        guard opportunity.forEachAffectedNodeID({ nodeID in
            guard nodeID < graph.nodes.count,
                  let range = graph.nodes[nodeID].positionRange
            else {
                return
            }
            for position in range {
                guard position < sequence.count else {
                    break
                }
                hash ^= ZobristHash.contribution(at: position, sequence[position])
            }
        }) else {
            return nil
        }

        return hash
    }

    /// Mixes the targeted node IDs into the operation's discriminator, so the same scope hashes alike whatever its leaf values.
    private func coarseScopeHash(_ opportunity: ScopedOpportunity) -> UInt64? {
        var hash: UInt64 = Self.operationDiscriminator(opportunity) ^ 0xC0A8_5E00_DEAD_BEEF
        hash ^= opportunity.scopeSubDiscriminator

        guard opportunity.forEachAffectedNodeID({ nodeID in
            var bits = UInt64(nodeID) &* 0x9E37_79B9_7F4A_7C15
            bits = (bits ^ (bits >> 30)) &* 0xBF58_476D_1CE4_E5B9
            bits = (bits ^ (bits >> 27)) &* 0x94D0_49BB_1331_11EB
            bits ^= bits >> 31
            hash ^= bits
        }) else {
            return nil
        }

        return hash
    }

    private static func operationDiscriminator(_ opportunity: ScopedOpportunity) -> UInt64 {
        switch opportunity {
            case .removal:
                0xA1B2_C3D4_E5F6_0718
            case .substitution, .branchPivot:
                0x1827_3645_5463_7281
            case .swap:
                0x9182_7364_5546_3728
            case .migration:
                0x6372_8190_A0B0_C0D0
            case .bindPivot:
                0x4B1D_9140_7A5E_0002
            case .boundValue, .boundExchange, .depthCollapse, .laneCollapse, .valueSearch, .redistribution, .lockstep,
                 .relation, .stagedJoint, .reorder:
                0
        }
    }
}
