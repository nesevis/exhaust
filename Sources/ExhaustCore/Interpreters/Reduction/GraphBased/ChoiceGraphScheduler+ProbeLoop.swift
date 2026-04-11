//
//  ChoiceGraphScheduler+ProbeLoop.swift
//  Exhaust
//

// MARK: - Probe Loop

extension ChoiceGraphScheduler {
    /// Outcome of a single ``runProbeLoop`` invocation.
    ///
    /// Three accepted states:
    ///
    /// - ``requiresRebuild`` true: at least one accepted probe set ``ChangeApplication/requiresFullRebuild``. The graph is stale; the cycle loop must do a full rebuild + source rebuild before the next dispatch.
    /// - ``requiresSourceRebuild`` true (and ``requiresRebuild`` false): at least one accepted probe was a successful in-place reshape that added or removed graph nodes (Layer 4). The graph is in sync via ``ChoiceGraph/apply(_:freshTree:)``, but the existing scope sources captured node IDs at construction time and do not know about the new nodes. The cycle loop must rebuild sources from the (already up-to-date) graph; the graph itself does not need a full rebuild.
    /// - both false: every accepted probe was a pure value-only fast-path application that touched no node-set membership. The graph and the existing sources are both still valid.
    ///
    /// ``treeIsStripped`` reports whether the *latest* accepted probe used `materializePicks: false`. The cycle loop reads it before any rebuild path: when true, the carried `tree` is missing inactive pick branches and must be re-materialized with `materializePicks: true` before ``ChoiceGraph/build(from:)``, otherwise the rebuilt graph's ``PickMetadata/branchElements`` would contain only the selected branch and silently break ``GraphReplacementEncoder``'s branch enumeration on the next cycle. False when no probe accepted, when only `materializePicks: true` probes accepted, or when the latest acceptance happened to be a non-stripped one.
    struct ProbeLoopOutcome {
        let accepted: Bool
        let requiresRebuild: Bool
        let requiresSourceRebuild: Bool
        let treeIsStripped: Bool
        let probeCount: Int
        let acceptCount: Int
    }

    // swiftlint:disable function_parameter_count
    /// Runs an encoder's probe loop, accepting improvements.
    static func runProbeLoop(
        encoder: inout any GraphEncoder,
        scope: TransformationScope,
        graph: ChoiceGraph,
        sequence: inout ChoiceSequence,
        tree: inout ChoiceTree,
        output: inout Any,
        gen: ReflectiveGenerator<Any>,
        property: @escaping (Any) -> Bool,
        rejectCache: inout Set<UInt64>,
        stats: inout ReductionStats,
        collectStats: Bool,
        isInstrumented: Bool
    ) throws -> ProbeLoopOutcome {
        encoder.start(scope: scope)

        var lastAccepted = false
        var anyAccepted = false
        var anyRequiresRebuild = false
        var anyRequiresSourceRebuild = false
        // Layer 7a: tracks whether the *latest* accepted probe used
        // `materializePicks: false`. The cycle loop reads it from the
        // outcome to decide whether the carried `tree` needs re-materializing
        // before any subsequent ``ChoiceGraph/build(from:)`` call. Only the
        // latest acceptance matters because each accepted probe overwrites
        // the tree state.
        var latestAcceptedTreeIsStripped = false
        var probeCount = 0
        var acceptCount = 0
        // Per-encoder rejection breakdown for the wasted-mats investigation
        // (Bonsai vs Graph mat-count gap). Cache hits cost zero materializations;
        // decoder rejections cost one materialization each. Aggregated into
        // `stats.encoderProbesAccepted` and so on at the end of the loop.
        var cacheHitCount = 0
        var decoderRejectCount = 0
        let baseHash = ZobristHash.hash(of: sequence)
        // Bind status is structural — value-only mutations within the probe
        // loop cannot add or remove bind markers. Hoisted to avoid an O(N)
        // scan on every probe iteration.
        let hasBind = sequence.contains { entry in
            if case .bind = entry { return true }
            return false
        }

        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            probeCount += 1
            lastAccepted = false
            // True when this probe's acceptance structurally mutated the graph
            // (in-place reshape that added/removed nodes, or any change that
            // forced ``ChangeApplication/requiresFullRebuild``). The encoder's
            // ``IntegerState/leafPositions`` (and equivalent caches in float
            // and exchange encoders) are built once at ``start(scope:)`` and
            // are no longer valid against the live graph after such a
            // mutation. The scheduler calls ``encoder.refreshScope`` at the
            // bottom of the iteration when this is true so the encoder can
            // re-derive its scope state in place against the post-mutation
            // graph. See ExhaustDocs/graph-reducer-position-drift-bug.md.
            var mutatedStructurally = false

            let probeHash = ZobristHash.incrementalHash(
                baseHash: baseHash,
                baseSequence: sequence,
                probe: probe.candidate
            )
            if rejectCache.contains(probeHash) {
                cacheHitCount += 1
                continue
            }

            // Layer 6 + Layer 7a: probes whose mutation does not change
            // which branch is selected at any pick site can skip
            // `materializePicks: true`. The graph's structural skeleton —
            // including non-selected pick branches — persists across
            // cycles via the in-place reshape path, so the decoder no
            // longer needs to re-materialize inactive branches on every
            // probe.
            //
            // Layer 6 covers value-only ``ProjectedMutation/leafValues(_:)``
            // with no reshape leaves. Layer 7a extends the same check to
            // ``ProjectedMutation/sequenceElementsRemoved(seqNodeID:removedNodeIDs:)``,
            // ``ProjectedMutation/sequenceElementsMigrated(sourceSeqID:receiverSeqID:movedNodeIDs:insertionOffset:)``,
            // and ``ProjectedMutation/siblingsSwapped(zipNodeID:idA:idB:)``
            // — none of these change branch selections, so any branch
            // pivot encoder dispatched on the next cycle still finds its
            // alternative branches in ``PickMetadata/branchElements``,
            // which is captured at graph construction time.
            //
            // Pivoting mutations (``ProjectedMutation/branchSelected(pickNodeID:newSelectedID:)``,
            // ``ProjectedMutation/selfSimilarReplaced(targetNodeID:donorNodeID:)``,
            // ``ProjectedMutation/descendantPromoted(ancestorPickNodeID:descendantPickNodeID:)``)
            // and reshape leafValues keep `materializePicks: true`
            // because the resulting tree feeds the splice path or future
            // branch pivots that need the inactive subtree content.
            //
            // Safety: when an accepted probe sets ``ChangeApplication/requiresFullRebuild``
            // true (which every Layer 7a structural case does until Layer 7
            // implements them in ``ChoiceGraph/apply(_:freshTree:)``), the
            // cycle loop's rebuild path at the call site re-materializes
            // the sequence with `materializePicks: true` before calling
            // ``ChoiceGraph/build(from:)``, so the rebuilt graph never
            // sees a stripped tree.
            let picksUnchanged = switch probe.mutation {
            case let .leafValues(changes):
                changes.contains(where: \.mayReshape) == false
            case .sequenceElementsRemoved, .sequenceElementsMigrated, .siblingsSwapped:
                true
            case .branchSelected, .selfSimilarReplaced, .descendantPromoted:
                false
            }
            let materializePicks = picksUnchanged == false
            // Composed encoders (kleisli fibre) emit post-lift candidates whose
            // bound subtree differs from the parent ``tree``. Guided decoding
            // would substitute stale fallback content; force the exact decoder
            // when the encoder requests it.
            let preferExact = encoder.requiresExactDecoder || hasBind == false
            let decoder: SequenceDecoder = preferExact
                ? .exact(materializePicks: materializePicks)
                : .guided(fallbackTree: tree, materializePicks: materializePicks)

            var filterObservations: [UInt64: FilterObservation] = [:]

            if let result = try decoder.decodeAny(
                candidate: probe.candidate,
                gen: gen,
                tree: tree,
                originalSequence: sequence,
                property: property,
                filterObservations: &filterObservations,
                precomputedHash: probeHash
            ) {
                sequence = result.sequence
                tree = result.tree
                output = result.output
                lastAccepted = true
                anyAccepted = true
                acceptCount += 1
                // Track whether the latest accepted probe stripped the
                // tree. The cycle loop reads this via ``ProbeLoopOutcome/treeIsStripped``
                // to decide whether to re-materialize before any rebuild.
                latestAcceptedTreeIsStripped = picksUnchanged

                // Composed encoders (``GraphComposedEncoder``) skip the
                // in-place ``ChoiceGraph/apply(_:freshTree:)`` path entirely.
                // The dispatch site forces a full ``ChoiceGraph/build(from:)``
                // rebuild after every kleisli pass anyway (see the
                // `isKleisliFibre || outcome.requiresRebuild` branch in
                // ``runCore``), which discards any in-place mutations the
                // probe loop would have made. Calling ``applyBindReshape``
                // on every accepted probe is pure waste — for BinaryHeap
                // that was 250K applyBindReshape calls per 1000-seed run,
                // each tombstoning the old bound subtree and splicing the
                // new one, only to be thrown away seconds later by the
                // post-pass rebuild.
                //
                // Standard encoders still take the in-place fast path so
                // value-only acceptances don't pay the rebuild cost.
                let application: ChangeApplication
                if encoder.requiresExactDecoder {
                    application = ChangeApplication()
                    anyRequiresRebuild = true
                    // Signal structural mutation so refreshScope is called below.
                    // Encoders with requiresExactDecoder (kleisli compositions) skip
                    // graph.apply, so requiresFullRebuild is never set on the
                    // ChangeApplication — but their cached state is equally stale after
                    // an acceptance and needs the same reset treatment.
                    mutatedStructurally = true
                } else {
                    application = graph.apply(probe.mutation, freshTree: tree)
                    if application.requiresFullRebuild {
                        anyRequiresRebuild = true
                        mutatedStructurally = true
                    }
                }
                // A successful in-place reshape adds or removes graph
                // nodes — the graph stays consistent via apply, but the
                // existing scope sources captured the old node set at
                // construction time and miss the new ones. Signal the
                // cycle loop to rebuild sources without rebuilding the
                // graph itself.
                if application.addedNodeIDs.isEmpty == false
                    || application.removedNodeIDs.isEmpty == false
                {
                    anyRequiresSourceRebuild = true
                    mutatedStructurally = true
                }
                if isInstrumented, application.requiresFullRebuild == false {
                    let fresh = ChoiceGraph.build(from: tree)
                    if graph.structuralFingerprint != fresh.structuralFingerprint {
                        ExhaustLog.warning(
                            category: .reducer,
                            event: "graph_apply_shadow_mismatch",
                            metadata: [
                                "encoder": encoder.name.rawValue,
                                "live_fp": "\(graph.structuralFingerprint)",
                                "fresh_fp": "\(fresh.structuralFingerprint)",
                            ]
                        )
                    }
                }
            } else {
                rejectCache.insert(probeHash)
                decoderRejectCount += 1
            }

            if collectStats {
                stats.totalMaterializations += 1
            }

            // Refresh the encoder's scope on structural mutation. The
            // encoder's cached state (for example, ``IntegerState/leafPositions``)
            // was built at ``start(scope:)`` against the pre-mutation
            // graph and cannot be safely re-used after a reshape
            // tombstones leaves and splices in new nodes. Continuing to
            // iterate without a refresh would let the encoder address
            // ``state.sequence`` at stale indices and silently corrupt
            // either the live sequence or the new spliced leaves' values,
            // producing the position drift bug documented in
            // ExhaustDocs/graph-reducer-position-drift-bug.md. Calling
            // ``refreshScope`` lets the encoder re-derive its scope state
            // from the live graph in place — preserving in-pass
            // convergence records keyed by nodeID, picking up new leaves
            // the splice created, and dropping tombstoned ones — without
            // paying the full source-rebuild + dispatch overhead the
            // earlier `break`-out fix imposed.
            if mutatedStructurally {
                encoder.refreshScope(graph: graph, sequence: sequence)
            }
        }

        if collectStats {
            stats.encoderProbes[encoder.name, default: 0] += probeCount
            stats.encoderProbesAccepted[encoder.name, default: 0] += acceptCount
            stats.encoderProbesRejectedByCache[encoder.name, default: 0] += cacheHitCount
            stats.encoderProbesRejectedByDecoder[encoder.name, default: 0] += decoderRejectCount
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "graph_encoder_pass",
                metadata: [
                    "encoder": encoder.name.rawValue,
                    "probes": "\(probeCount)",
                    "accepted": "\(acceptCount)",
                    "cache_hits": "\(cacheHitCount)",
                    "decoder_rejects": "\(decoderRejectCount)",
                    "seq_len": "\(sequence.count)",
                ]
            )
        }

        return ProbeLoopOutcome(
            accepted: anyAccepted,
            requiresRebuild: anyRequiresRebuild,
            requiresSourceRebuild: anyRequiresSourceRebuild,
            treeIsStripped: latestAcceptedTreeIsStripped,
            probeCount: probeCount,
            acceptCount: acceptCount
        )
    }

    // swiftlint:enable function_parameter_count
}

// MARK: - Pre-Started Adapter

/// Wraps a ``GraphEncoder`` so its ``GraphEncoder/start(scope:)`` always uses a pre-supplied scope instead of the one passed by the caller.
///
/// Used by ``ChoiceGraphScheduler/makeKleisliComposition(fibreScope:scope:gen:upstreamBudget:)`` so that the upstream encoder of a ``GraphComposedEncoder`` operates on a synthesised one-leaf integer scope rather than the kleisli fibre scope the composition was started with. The composition's ``GraphComposedEncoder/start(scope:)`` will pass the original parent scope to its upstream; the adapter swaps it for the synthesised one before forwarding to the inner encoder.
struct PreStartedAdapter: GraphEncoder {
    var name: EncoderName {
        inner.name
    }

    var requiresExactDecoder: Bool {
        inner.requiresExactDecoder
    }

    private var inner: any GraphEncoder
    private let scope: TransformationScope

    init(inner: any GraphEncoder, scope: TransformationScope) {
        self.inner = inner
        self.scope = scope
    }

    mutating func start(scope _: TransformationScope) {
        inner.start(scope: scope)
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        inner.nextProbe(lastAccepted: lastAccepted)
    }

    var convergenceRecords: [Int: ConvergedOrigin] {
        inner.convergenceRecords
    }
}
