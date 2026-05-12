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
    ///
    /// Keyed by ``ChoicePath`` for stable identity across rebuilds. Falls back to position-based keying for leaves with empty paths (inactive branches).
    static func extractAllConvergence(from graph: ChoiceGraph) -> (byPath: [ChoicePath: (origin: ConvergedOrigin, typeTag: TypeTag, validRange: ClosedRange<UInt64>?, isStructurallyConstant: Bool)], byPosition: [Int: (origin: ConvergedOrigin, typeTag: TypeTag, validRange: ClosedRange<UInt64>?, isStructurallyConstant: Bool)]) {
        var byPath: [ChoicePath: (origin: ConvergedOrigin, typeTag: TypeTag, validRange: ClosedRange<UInt64>?, isStructurallyConstant: Bool)] = [:]
        var byPosition: [Int: (origin: ConvergedOrigin, typeTag: TypeTag, validRange: ClosedRange<UInt64>?, isStructurallyConstant: Bool)] = [:]
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            let isConstant = isInStructurallyConstantContext(nodeID: nodeID, graph: graph)
            let record = (origin: origin, typeTag: metadata.typeTag, validRange: metadata.validRange, isStructurallyConstant: isConstant)
            let path = graph.nodes[nodeID].choicePath
            if path.isEmpty == false {
                byPath[path] = record
            }
            if let range = graph.nodes[nodeID].positionRange {
                byPosition[range.lowerBound] = record
            }
        }
        return (byPath: byPath, byPosition: byPosition)
    }

    /// Transfers convergence records from an old graph to matching leaves in the new graph.
    ///
    /// Primary matching by ``ChoicePath`` — structural address is stable across rebuilds even when positions shift due to deletions or insertions. Falls back to position-based matching for leaves whose path didn't match (structural change above the leaf).
    ///
    /// Two-tier validation policy:
    /// - Leaves in structurally-constant bind subtrees (or outside any bind): match on path/position + typeTag only.
    /// - Leaves in non-constant bind subtrees: also require validRange match.
    static func transferConvergence(
        _ records: (byPath: [ChoicePath: (origin: ConvergedOrigin, typeTag: TypeTag, validRange: ClosedRange<UInt64>?, isStructurallyConstant: Bool)], byPosition: [Int: (origin: ConvergedOrigin, typeTag: TypeTag, validRange: ClosedRange<UInt64>?, isStructurallyConstant: Bool)]),
        to graph: inout ChoiceGraph
    ) {
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }

            let path = graph.nodes[nodeID].choicePath
            let oldRecord = (path.isEmpty == false ? records.byPath[path] : nil) ?? records.byPosition[range.lowerBound]
            guard let oldRecord else { continue }

            guard oldRecord.typeTag == metadata.typeTag else { continue }

            if oldRecord.isStructurallyConstant == false {
                guard oldRecord.validRange == metadata.validRange else { continue }
            }

            graph.recordConvergence([range.lowerBound: oldRecord.origin])
        }
    }

    /// Checks whether a leaf node sits inside a structurally-constant bind context, meaning every ancestor bind either is structurally constant or the leaf is not in that bind's bound subtree. Convergence records from structurally-constant contexts can be transferred across rebuilds without validating the valid range, because the bound subtree's shape does not depend on the inner leaf's value.
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
