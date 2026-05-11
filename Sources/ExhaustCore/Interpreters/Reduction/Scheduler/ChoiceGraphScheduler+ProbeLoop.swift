//
//  ChoiceGraphScheduler+ProbeLoop.swift
//  Exhaust
//

// MARK: - Probe Loop

extension ChoiceGraphScheduler {
    /// Outcome of a single ``runProbeLoop`` invocation.
    ///
    /// ``requiresRebuild`` is true when at least one accepted probe triggered a structural change (reshape, removal, pivot). The scheduler must rebuild the graph from the tree before the next dispatch. When false, all accepted probes were value-only and the graph remains structurally valid.
    ///
    /// ``treeIsStripped`` reports whether the latest accepted probe used `materializePicks: false`. When true and a rebuild is needed, the scheduler must re-materialize with `materializePicks: true` first.
    struct ProbeLoopOutcome {
        let accepted: Bool
        let requiresRebuild: Bool
        let treeIsStripped: Bool
    }

    /// Runs an encoder's probe loop, accepting improvements.
    static func runProbeLoop(
        encoder: inout any GraphEncoder,
        scope: EncoderInput,
        state: inout ReductionState
    ) throws -> ProbeLoopOutcome {
        encoder.start(scope: scope)

        var lastAccepted = false
        var anyAccepted = false
        var anyRequiresRebuild = false
        var latestAcceptedTreeIsStripped = false
        var probeCount = 0
        var acceptCount = 0
        var cacheHitCount = 0
        var decoderRejectCount = 0
        let baseHash = ZobristHash.hash(of: state.sequence)
        let hasBind = state.sequence.contains { entry in
            if case .bind = entry { return true }
            return false
        }

        var candidateBuffer = state.sequence
        while let mutation = encoder.nextProbe(into: &candidateBuffer, lastAccepted: lastAccepted) {
            probeCount += 1
            lastAccepted = false
            var mutatedStructurally = false

            let probeHash = ZobristHash.incrementalHash(
                baseHash: baseHash,
                baseSequence: state.sequence,
                probe: candidateBuffer
            )
            if state.rejectCache.contains(probeHash) {
                cacheHitCount += 1
                continue
            }

            let selection = Self.selectDecoder(
                for: mutation,
                requiresExactDecoder: encoder.requiresExactDecoder,
                hasBind: hasBind
            )
            let decoder: SequenceDecoder = selection.preferExact
                ? .exact(materializePicks: selection.materializePicks)
                : .guided(fallbackTree: state.tree, materializePicks: selection.materializePicks)

            var filterObservations: [UInt64: FilterObservation] = [:]

            if let result = try decoder.decodeAny(
                candidate: candidateBuffer,
                gen: state.gen,
                tree: state.tree,
                originalSequence: state.sequence,
                property: state.property,
                filterObservations: &filterObservations,
                precomputedHash: probeHash
            ) {
                state.sequence = result.sequence
                state.tree = result.tree
                state.output = result.output
                lastAccepted = true
                anyAccepted = true
                acceptCount += 1
                // Accepted probes cost two materialisations: one for the property check (counted
                // unconditionally below), one for tree reconstruction (counted here).
                if state.collectStats {
                    state.stats.totalMaterializations += 1
                }
                latestAcceptedTreeIsStripped = selection.materializePicks == false

                if encoder.requiresExactDecoder {
                    anyRequiresRebuild = true
                    mutatedStructurally = true
                } else {
                    let application = state.graph.apply(mutation, freshTree: state.tree)
                    if application.requiresFullRebuild {
                        anyRequiresRebuild = true
                        break
                    }
                }
            } else {
                state.rejectCache.insert(probeHash)
                decoderRejectCount += 1
                if state.isInstrumented {
                    logReplacementProbeRejection(
                        mutation: mutation,
                        encoder: encoder.name,
                        graph: state.graph,
                        baseSequenceCount: state.sequence.count,
                        probeSequenceCount: candidateBuffer.count,
                        probeHash: probeHash
                    )
                }
            }

            // One materialisation per non-cache-hit probe (the property check).
            // Accepted probes add a second materialisation above for tree reconstruction.
            if state.collectStats {
                state.stats.totalMaterializations += 1
            }

            if mutatedStructurally {
                encoder.refreshState(graph: state.graph, sequence: state.sequence)
            }
        }

        if state.collectStats {
            state.stats.encoderProbes[encoder.name, default: 0] += probeCount
            state.stats.encoderProbesAccepted[encoder.name, default: 0] += acceptCount
            state.stats.encoderProbesRejectedByCache[encoder.name, default: 0] += cacheHitCount
            state.stats.encoderProbesRejectedByDecoder[encoder.name, default: 0] += decoderRejectCount
        }

        Self.logReducer("graph_encoder_pass", isInstrumented: state.isInstrumented, metadata: [
            "encoder": encoder.name.rawValue, "probes": "\(probeCount)",
            "accepted": "\(acceptCount)", "cache_hits": "\(cacheHitCount)",
            "decoder_rejects": "\(decoderRejectCount)", "seq_len": "\(state.sequence.count)",
        ])

        return ProbeLoopOutcome(
            accepted: anyAccepted,
            requiresRebuild: anyRequiresRebuild,
            treeIsStripped: latestAcceptedTreeIsStripped
        )
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
    private static func logReplacementProbeRejection(
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
