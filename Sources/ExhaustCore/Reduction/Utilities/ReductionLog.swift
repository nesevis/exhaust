//
//  ReductionLog.swift
//  Exhaust
//

// MARK: - Reduction Log

/// Debug events the reducer emits.
enum ReductionLog {
    /// Emits `event` when `isInstrumented`, building its metadata only then.
    @inline(__always)
    static func reducer(
        _ event: String,
        isInstrumented: Bool,
        metadata: @autoclosure () -> [String: String]
    ) {
        guard isInstrumented else {
            return
        }
        ExhaustLog.debug(category: .reducer, event: event, metadata: metadata())
    }

    /// Logs a `graph_probe_rejected` debug event for a rejected replacement probe: a branch pivot, self-similar replacement, or descendant promotion. Other mutations log nothing.
    static func replacementProbeRejection(
        mutation: ProjectedMutation,
        encoder: EncoderName,
        graph: ChoiceGraph,
        baseSequenceCount: Int,
        probeSequenceCount: Int,
        probeHash: UInt64
    ) {
        let kind: String
        let subjectNodeIDs: [(label: String, id: Int)]
        switch mutation {
            case let .branchSelected(pickNodeID, newSelectedID):
                kind = "branchSelected"
                subjectNodeIDs = [
                    ("pick_node", pickNodeID),
                    ("new_selected_id", Int(newSelectedID)),
                ]
            case let .selfSimilarReplaced(targetNodeID, donorNodeID):
                kind = "selfSimilarReplaced"
                subjectNodeIDs = [
                    ("target_node", targetNodeID),
                    ("donor_node", donorNodeID),
                ]
            case let .descendantPromoted(ancestorPickNodeID, descendantPickNodeID):
                kind = "descendantPromoted"
                subjectNodeIDs = [
                    ("ancestor_node", ancestorPickNodeID),
                    ("descendant_node", descendantPickNodeID),
                ]
            case .leafValues, .sequenceElementsRemoved, .sequenceElementsMigrated,
                 .siblingsSwapped, .sequenceReordered:
                return
        }

        var metadata: [String: String] = [
            "encoder": encoder.rawValue,
            "mutation": kind,
            "base_seq_len": "\(baseSequenceCount)",
            "probe_seq_len": "\(probeSequenceCount)",
            "seq_len_delta": "\(probeSequenceCount - baseSequenceCount)",
            "probe_hash": "\(probeHash)",
        ]
        for (label, id) in subjectNodeIDs {
            metadata[label] = "\(id)"
            if id >= 0, id < graph.nodes.count {
                if let range = graph.nodes[id].positionRange {
                    metadata["\(label)_range"] = "\(range.lowerBound)...\(range.upperBound)"
                }
            }
        }

        ExhaustLog.debug(
            category: .reducer,
            event: "graph_probe_rejected",
            metadata: metadata
        )
    }
}
