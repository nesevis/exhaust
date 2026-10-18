//
//  ReductionSession+Convergence.swift
//  Exhaust
//

// MARK: - Convergence

extension ReductionSession {
    /// A convergence record with the type tag and, unless exempt, the bit pattern it was recorded against, for transfer across a rebuild.
    typealias TransferableConvergence = (origin: ConvergedOrigin, typeTag: TypeTag, bitPattern: UInt64?)

    /// Whether every leaf is at its reduction target or has a convergence record.
    static func allValuesConverged(graph: ChoiceGraph) -> Bool {
        for nodeID in graph.leafNodes {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else {
                continue
            }
            let currentBitPattern = metadata.value.bitPattern64
            let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
            if currentBitPattern == targetBitPattern {
                continue
            }
            if graph.convergenceStore[nodeID] != nil {
                continue
            }
            return false
        }
        return true
    }

    /// Keys every convergence record by ``ChoicePath`` for transfer across a rebuild. Leaves with empty paths, on inactive branches, are skipped: their records do not survive structural rebuilds.
    ///
    /// Each record carries the leaf's current bit pattern, or nil for an exempt leaf. ``transferConvergence(_:to:)`` uses it as an occupant-continuity guard: sequence-child path steps are positional, so after an index-shifting acceptance the same path can address a different element, and a value mismatch at the same path means the record cannot safely move to the new occupant.
    ///
    /// - Parameter valueGuardExemptNodeIDs: Leaves whose old-graph value is known stale because they accepted a change in the pass that triggered this rebuild, which skipped the in-place graph write. Their records transfer on path and type tag alone, which is alias-safe because value passes do not shift sibling indices.
    static func extractAllConvergence(
        from graph: ChoiceGraph,
        valueGuardExemptNodeIDs: Set<Int> = []
    ) -> [ChoicePath: TransferableConvergence] {
        var records: [ChoicePath: TransferableConvergence] = [:]
        for (nodeID, origin) in graph.convergenceStore {
            guard nodeID < graph.nodes.count else {
                continue
            }
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
                continue
            }
            let path = graph.nodes[nodeID].choicePath
            guard path.isEmpty == false else {
                continue
            }
            let bitPattern: UInt64? = valueGuardExemptNodeIDs.contains(nodeID)
                ? nil
                : metadata.value.bitPattern64
            records[path] = (origin: origin, typeTag: metadata.typeTag, bitPattern: bitPattern)
        }
        return records
    }

    /// Moves records onto compatible leaves at the same ``ChoicePath`` and type tag, and the same bit pattern when the record carries one. Records whose path is gone, or now addresses a different value, are dropped.
    ///
    /// Two elements holding identical values at the same shifted path stay indistinguishable, so such records still transfer; no per-element identity survives sibling mutation.
    static func transferConvergence(
        _ records: [ChoicePath: TransferableConvergence],
        to graph: inout ChoiceGraph
    ) {
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
                continue
            }
            guard graph.nodes[nodeID].positionRange != nil else {
                continue
            }
            let path = graph.nodes[nodeID].choicePath
            guard path.isEmpty == false else {
                continue
            }
            guard let oldRecord = records[path] else {
                continue
            }
            guard oldRecord.typeTag == metadata.typeTag else {
                continue
            }
            if let bitPattern = oldRecord.bitPattern,
               bitPattern != metadata.value.bitPattern64
            {
                continue
            }
            graph.convergenceStore[nodeID] = oldRecord.origin
        }
    }
}
