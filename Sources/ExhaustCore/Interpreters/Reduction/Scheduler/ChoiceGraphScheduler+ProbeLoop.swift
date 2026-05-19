//
//  ChoiceGraphScheduler+ProbeLoop.swift
//  Exhaust
//

// MARK: - Probe Loop Types

extension ChoiceGraphScheduler {
    /// Outcome summary for acceptance evaluation after a probe pass.
    struct ProbeLoopOutcome {
        let accepted: Bool
        let requiresRebuild: Bool
        let treeIsStripped: Bool
    }

    // MARK: - Decoder Selection

    /// Determines the decoder mode for a given probe mutation.
    ///
    /// Pure function of the mutation type, the encoder's decoder requirement, and whether the sequence contains binds. Returns two flags:
    /// - `preferExact`: true when the probe should use exact (non-guided) decoding.
    /// - `materializePicks`: true when the probe changes the active branch path and the decoder must reconstruct all branch alternatives.
    struct DecoderSelection {
        let preferExact: Bool
        let materializePicks: Bool
    }

    static func selectDecoder(
        for mutation: ProjectedMutation,
        requiresExactDecoder: Bool,
        hasBind: Bool
    ) -> DecoderSelection {
        let picksUnchanged = switch mutation {
        case let .leafValues(changes):
            changes.contains(where: \.mayReshape) == false
        case .sequenceElementsRemoved, .sequenceElementsMigrated, .siblingsSwapped, .sequenceReordered:
            true
        case .branchSelected, .selfSimilarReplaced, .descendantPromoted:
            false
        }
        let probeCanReshape = switch mutation {
        case let .leafValues(changes):
            changes.contains(where: \.mayReshape)
        default:
            hasBind
        }
        return DecoderSelection(
            preferExact: requiresExactDecoder || probeCanReshape == false,
            materializePicks: picksUnchanged == false
        )
    }

    /// Logs a `graph_probe_rejected` debug event for replacement probes rejected by the decoder.
    static func logReplacementProbeRejection(
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
