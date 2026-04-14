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
            if metadata.convergedOrigin != nil { continue }
            return false
        }
        return true
    }

    /// Extracts warm-start convergence records from all leaf nodes, keyed by graph nodeID.
    ///
    /// NodeID keying lets the encoder look up records via `state.warmStartRecords[leaf.nodeID]` and survives any in-pass refresh that shifts the leaf's sequence position. The previous positional keying broke as soon as a refresh re-derived `leaf.sequenceIndex`.
    static func extractWarmStarts(from graph: ChoiceGraph) -> [Int: ConvergedOrigin] {
        var records: [Int: ConvergedOrigin] = [:]
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            records[nodeID] = origin
        }
        return records
    }

    /// Extracts all convergence records with leaf metadata for transfer matching.
    static func extractAllConvergence(from graph: ChoiceGraph) -> [Int: (origin: ConvergedOrigin, typeTag: TypeTag, validRange: ClosedRange<UInt64>?, isStructurallyConstant: Bool)] {
        var records: [Int: (origin: ConvergedOrigin, typeTag: TypeTag, validRange: ClosedRange<UInt64>?, isStructurallyConstant: Bool)] = [:]
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            let isConstant = isInStructurallyConstantContext(nodeID: nodeID, graph: graph)
            records[range.lowerBound] = (origin: origin, typeTag: metadata.typeTag, validRange: metadata.validRange, isStructurallyConstant: isConstant)
        }
        return records
    }

    /// Transfers convergence records from old graph positions to matching leaves in the new graph.
    ///
    /// Two-tier policy:
    /// - Leaves in structurally-constant bind subtrees (or outside any bind): match on position + typeTag only. The validRange may have changed but the materializer handles clamping.
    /// - Leaves in non-constant bind subtrees: match on position + typeTag + validRange. The subtree was rebuilt — ranges may be different.
    static func transferConvergence(
        _ records: [Int: (origin: ConvergedOrigin, typeTag: TypeTag, validRange: ClosedRange<UInt64>?, isStructurallyConstant: Bool)],
        to graph: ChoiceGraph
    ) {
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            guard let oldRecord = records[range.lowerBound] else { continue }

            // Type tag must always match.
            guard oldRecord.typeTag == metadata.typeTag else { continue }

            // Two-tier: constant context requires only position + typeTag.
            // Non-constant requires validRange match too.
            if oldRecord.isStructurallyConstant == false {
                guard oldRecord.validRange == metadata.validRange else { continue }
            }

            graph.recordConvergence([range.lowerBound: oldRecord.origin])
        }
    }

    /// Checks whether a leaf node is in a structurally-constant context (all ancestor binds are structurally constant, or not in any bind).
    static func isInStructurallyConstantContext(nodeID: Int, graph: ChoiceGraph) -> Bool {
        var current = nodeID
        while let parentID = graph.nodes[current].parent {
            if case let .bind(metadata) = graph.nodes[parentID].kind {
                if metadata.isStructurallyConstant == false {
                    // Check if this leaf is in the bound subtree (not the inner).
                    let boundChildID = graph.nodes[parentID].children[metadata.boundChildIndex]
                    if let boundRange = graph.nodes[boundChildID].positionRange,
                       let leafRange = graph.nodes[nodeID].positionRange,
                       boundRange.contains(leafRange.lowerBound)
                    {
                        return false
                    }
                }
            }
            current = parentID
        }
        return true
    }
}
