//
//  ChoiceGraphScheduler+Convergence.swift
//  Exhaust
//

// MARK: - Convergence

extension ChoiceGraphScheduler {
    /// Returns true when every leaf value is either at its reduction target or has a convergence record.
    static func allValuesConverged(
        in _: ChoiceSequence,
        graph: ChoiceGraph
    ) -> Bool {
        for nodeID in graph.leafNodes {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }
            let currentBitPattern = metadata.value.bitPattern64
            let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
            if currentBitPattern == targetBitPattern { continue }
            if graph.convergenceStore[nodeID] != nil { continue }
            return false
        }
        return true
    }

    /// Extracts warm-start convergence records from the graph's convergence store, keyed by graph nodeID.
    ///
    /// NodeID keying lets the encoder look up records via `state.warmStartRecords[leaf.nodeID]` and survives any in-pass refresh that shifts the leaf's sequence position.
    static func extractWarmStarts(from graph: ChoiceGraph) -> [Int: ConvergedOrigin] {
        graph.convergenceStore
    }

    /// Extracts all convergence records keyed by ``ChoicePath`` for cross-rebuild transfer. Leaves with empty paths (inactive branches) are skipped — their convergence records do not survive structural rebuilds.
    ///
    /// Each record carries the leaf's current bit pattern at extraction time, or nil for exempt leaves. ``transferConvergence(_:to:)`` uses the bit pattern as an occupant-continuity guard: `sequenceChild` path steps are positional sibling indices, so after an index-shifting acceptance (mid-sequence deletion, migration, or sibling swap) the same path can address a different logical element in the new graph. A surviving element's value is unchanged by structural acceptances, so a value mismatch at the same path means the old record cannot safely transfer to the new occupant.
    ///
    /// `valueGuardExemptNodeIDs` names leaves whose old-graph value is known stale because they accepted a change in the pass that triggered this rebuild: reshape and stateful encoder passes skip the in-place ``ChoiceGraph/apply(_:)`` write, so the old graph still holds the pre-acceptance value while the new graph holds the accepted one. Their records are extracted with a nil bit pattern and transfer on path + type tag alone. This is alias-safe because value passes do not shift sibling indices.
    static func extractAllConvergence(
        from graph: ChoiceGraph,
        valueGuardExemptNodeIDs: Set<Int> = []
    ) -> [ChoicePath: (origin: ConvergedOrigin, typeTag: TypeTag, bitPattern: UInt64?)] {
        var records: [ChoicePath: (origin: ConvergedOrigin, typeTag: TypeTag, bitPattern: UInt64?)] = [:]
        for (nodeID, origin) in graph.convergenceStore {
            guard nodeID < graph.nodes.count else { continue }
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            let path = graph.nodes[nodeID].choicePath
            guard path.isEmpty == false else { continue }
            let bitPattern: UInt64? = valueGuardExemptNodeIDs.contains(nodeID)
                ? nil
                : metadata.value.bitPattern64
            records[path] = (origin: origin, typeTag: metadata.typeTag, bitPattern: bitPattern)
        }
        return records
    }

    /// Transfers convergence records from an old graph to compatible leaves at matching structural addresses. Matches by ``ChoicePath`` + type tag + current bit pattern when the record carries one. Records whose path does not appear in the new graph, or whose path now addresses a leaf with a different value, are dropped.
    ///
    /// The bit-pattern guard prevents positional aliasing: without it, a record for a deleted-or-shifted element transfers onto whichever element inherited its sibling index, seeding that leaf with another element's floor. Two elements holding identical values at the same shifted path remain indistinguishable, so such records still transfer. That residual is accepted because no per-element identity survives sibling mutation.
    static func transferConvergence(
        _ records: [ChoicePath: (origin: ConvergedOrigin, typeTag: TypeTag, bitPattern: UInt64?)],
        to graph: inout ChoiceGraph
    ) {
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard graph.nodes[nodeID].positionRange != nil else { continue }

            let path = graph.nodes[nodeID].choicePath
            guard path.isEmpty == false else { continue }
            guard let oldRecord = records[path] else { continue }
            guard oldRecord.typeTag == metadata.typeTag else { continue }
            if let bitPattern = oldRecord.bitPattern,
               bitPattern != metadata.value.bitPattern64
            {
                continue
            }

            graph.convergenceStore[nodeID] = oldRecord.origin
        }
    }
}
