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
    static func extractAllConvergence(from graph: ChoiceGraph) -> [ChoicePath: (origin: ConvergedOrigin, typeTag: TypeTag)] {
        var records: [ChoicePath: (origin: ConvergedOrigin, typeTag: TypeTag)] = [:]
        for (nodeID, origin) in graph.convergenceStore {
            guard nodeID < graph.nodes.count else { continue }
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            let path = graph.nodes[nodeID].choicePath
            guard path.isEmpty == false else { continue }
            records[path] = (origin: origin, typeTag: metadata.typeTag)
        }
        return records
    }

    /// Transfers convergence records from an old graph to matching leaves in the new graph. Matches by ``ChoicePath`` + type tag. Records whose path does not appear in the new graph are dropped.
    static func transferConvergence(
        _ records: [ChoicePath: (origin: ConvergedOrigin, typeTag: TypeTag)],
        to graph: inout ChoiceGraph
    ) {
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard graph.nodes[nodeID].positionRange != nil else { continue }

            let path = graph.nodes[nodeID].choicePath
            guard path.isEmpty == false else { continue }
            guard let oldRecord = records[path] else { continue }
            guard oldRecord.typeTag == metadata.typeTag else { continue }

            graph.convergenceStore[nodeID] = oldRecord.origin
        }
    }
}
