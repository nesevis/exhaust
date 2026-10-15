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
        _ encoderScope: AnyEncoderScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) {
        guard let key = encoderScope.typed.rejectionKey else {
            return
        }
        if key.isCoarse {
            coarseRejectedHashes.insert(Self.coarseScopeHash(key))
            return
        }
        rejectedHashes.insert(Self.scopeHash(key, sequence: sequence, graph: graph))
    }

    func isRejected(
        _ encoderScope: AnyEncoderScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> Bool {
        guard let key = encoderScope.typed.rejectionKey else {
            return false
        }
        if key.isCoarse {
            return coarseRejectedHashes.contains(Self.coarseScopeHash(key))
        }
        return rejectedHashes.contains(Self.scopeHash(key, sequence: sequence, graph: graph))
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

    /// Mixes the Zobrist contributions at the affected positions into the key's discriminator.
    private static func scopeHash(
        _ key: ScopedRejectionKey,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> UInt64 {
        var hash = key.discriminator
        for nodeID in key.affectedNodeIDs {
            guard nodeID < graph.nodes.count,
                  let range = graph.nodes[nodeID].positionRange
            else {
                continue
            }
            for position in range {
                guard position < sequence.count else {
                    break
                }
                hash ^= ZobristHash.contribution(at: position, sequence[position])
            }
        }
        return hash
    }

    /// Mixes the affected node IDs into the key's discriminator, so the same scope hashes alike whatever its leaf values.
    private static func coarseScopeHash(_ key: ScopedRejectionKey) -> UInt64 {
        var hash: UInt64 = key.discriminator ^ 0xC0A8_5E00_DEAD_BEEF
        // SplitMix64 finalizer per node ID, so nearby IDs do not cancel under XOR.
        for nodeID in key.affectedNodeIDs {
            var bits = UInt64(nodeID) &* 0x9E37_79B9_7F4A_7C15
            bits = (bits ^ (bits >> 30)) &* 0xBF58_476D_1CE4_E5B9
            bits = (bits ^ (bits >> 27)) &* 0x94D0_49BB_1331_11EB
            bits ^= bits >> 31
            hash ^= bits
        }
        return hash
    }
}
