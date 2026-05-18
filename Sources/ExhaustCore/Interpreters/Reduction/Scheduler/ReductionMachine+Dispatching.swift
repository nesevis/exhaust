//
//  ReductionMachine+Dispatching.swift
//  Exhaust
//

// MARK: - Dispatching Sub-Phases

extension ReductionMachine {
    /// Routes to the active ``DispatchPhase`` sub-step. Each call performs one of: selecting and evaluating a source (``dispatch``), producing a candidate via ``GraphEncoder/nextProbe(into:lastAccepted:)`` (``encode``), materializing and property-checking the candidate (``decode``), flushing encoder state after a pass completes (``finishEncoder``), or rebuilding the graph after a structural acceptance (``rebuild``).
    mutating func stepDispatching() throws -> Transition {
        switch dispatchPhase {
        case .dispatch:
            return try stepDispatch()
        case .encode:
            return stepEncode()
        case .decode:
            return try stepDecode()
        case .finishEncoder:
            return stepFinishEncoder()
        case .rebuild:
            return stepRebuild()
        }
    }

    // MARK: - Dispatch

    /// Selects the highest-priority source, pulls the next transformation, and resolves the dispatch decision. On ``ChoiceGraphScheduler/DispatchDecision/readyToDispatch(boundValueFingerprint:)``, initializes the encoder and transitions to the ``DispatchPhase/encode`` sub-phase.
    private mutating func stepDispatch() throws -> Transition {
        guard let sourceIndex = ChoiceGraphScheduler.highestPrioritySourceIndex(sources) else {
            phase = .endCycle
            return .dispatched(decision: .sourceExhausted)
        }

        guard let transformation = sources[sourceIndex].next(lastAccepted: false) else {
            sources.swapAt(sourceIndex, sources.count - 1)
            sources.removeLast()
            return .dispatched(decision: .sourceExhausted)
        }

        var decision = ChoiceGraphScheduler.evaluateDispatch(
            transformation: transformation,
            graph: graph,
            sequence: sequence,
            gate: gate,
            scopeCache: scopeRejectionCache,
            graphIsStripped: graphIsStripped,
            anyAccepted: anyAccepted
        )

        if case let .classifyBind(bindNodeID, fingerprint) = decision {
            guard case let .minimize(.boundValue(bindScope)) = transformation.operation else {
                return .dispatched(decision: .skipped)
            }
            graph.classifyBind(
                at: bindNodeID,
                gen: gen,
                baseSequence: sequence,
                fallbackTree: tree,
                upstreamLeafNodeID: bindScope.upstreamLeafNodeID
            )
            guard case let .bind(updatedMetadata) = graph.nodes[bindNodeID].kind,
                  let classification = updatedMetadata.classification
            else {
                return .dispatched(decision: .skipped)
            }
            if classification.topology != .identical || classification.liftability != .both {
                gate.markFruitless(fingerprint)
                return .dispatched(decision: .skipped)
            }
            decision = .readyToDispatch(boundValueFingerprint: fingerprint)
        }

        switch decision {
        case .skip:
            return .dispatched(decision: .skipped)

        case .classifyBind:
            return .dispatched(decision: .skipped)

        case .rematerialize:
            if case let .success(_, fullTree, _) = Materializer.materializeAny(
                gen,
                prefix: sequence,
                mode: .exact,
                fallbackTree: tree,
                materializePicks: true
            ) {
                tree = fullTree
            }
            let graphBefore = graph
            _ = rebuildAndUpdateGraph()
            sources = CandidateSourceBuilder.buildSources(from: graph, deferBindInner: deferBindInner, previousGraph: graphBefore)
            graphIsStripped = false
            return .dispatched(decision: .rematerialized)

        case let .readyToDispatch(boundValueFingerprint):
            return beginEncoderPass(
                transformation: transformation,
                boundValueFingerprint: boundValueFingerprint
            )
        }
    }

    // MARK: - Begin Encoder Pass

    private mutating func beginEncoderPass(
        transformation: GraphTransformation,
        boundValueFingerprint: UInt64?
    ) -> Transition {
        let warmStarts = ChoiceGraphScheduler.extractWarmStarts(from: graph)
        let scope = EncoderInput(
            transformation: transformation,
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: warmStarts
        )

        var encoder: any GraphEncoder
        if case let .minimize(.boundValue(bindScope)) = transformation.operation,
           let fingerprint = boundValueFingerprint
        {
            encoder = ChoiceGraphScheduler.makeBoundValueComposition(
                bindScope: bindScope,
                scope: scope,
                graph: graph,
                gen: gen,
                upstreamBudget: gate.decayedBudget(fingerprint: fingerprint)
            )
            gate.markDispatched(fingerprint)
        } else {
            encoder = ChoiceGraphScheduler.selectEncoder(for: transformation.operation)
        }

        encoder.start(scope: scope)

        activePass = EncoderPass(
            encoder: encoder,
            transformation: transformation,
            boundValueFingerprint: boundValueFingerprint,
            baseHash: ZobristHash.hash(of: sequence),
            hasBind: sequence.contains { entry in
                if case .bind = entry { return true }
                return false
            },
            candidateBuffer: sequence
        )

        dispatchPhase = .encode
        return .dispatched(decision: .encoderStarted(encoder: encoder.name))
    }

    // MARK: - Encode

    /// Asks the active encoder for its next candidate via ``GraphEncoder/nextProbe(into:lastAccepted:)``. Returns `nil` from the encoder as a transition to ``DispatchPhase/finishEncoder``. A reject-cache hit skips decoding and stays in the encode phase for the next probe.
    private mutating func stepEncode() -> Transition {
        guard var pass = activePass else {
            dispatchPhase = .dispatch
            return .dispatched(decision: .sourceExhausted)
        }

        let lastAccepted = pass.lastProbeAccepted
        guard let mutation = pass.encoder.nextProbe(
            into: &pass.candidateBuffer,
            lastAccepted: lastAccepted
        ) else {
            activePass = pass
            dispatchPhase = .finishEncoder
            return .encoded(encoder: pass.encoder.name, cacheHit: false)
        }

        pass.probeCount += 1
        pass.lastProbeAccepted = false

        let probeHash = ZobristHash.incrementalHash(
            baseHash: pass.baseHash,
            baseSequence: sequence,
            probe: pass.candidateBuffer
        )
        if rejectCache.contains(probeHash) {
            pass.cacheHitCount += 1
            activePass = pass
            return .encoded(encoder: pass.encoder.name, cacheHit: true)
        }

        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: pass.encoder.requiresExactDecoder,
            hasBind: pass.hasBind
        )

        pass.pendingMutation = mutation
        pass.pendingProbeHash = probeHash
        pass.pendingDecoderSelection = selection
        activePass = pass
        dispatchPhase = .decode
        return .encoded(encoder: pass.encoder.name, cacheHit: false)
    }

    // MARK: - Decode

    /// Materializes the pending candidate through ``SequenceDecoder/decodeAny`` and checks the property. On acceptance, updates core state and applies the mutation to the graph. On rejection, inserts the probe hash into the reject cache. Transitions to ``DispatchPhase/encode`` for the next probe, or ``DispatchPhase/finishEncoder`` when the graph requires a full rebuild.
    private mutating func stepDecode() throws -> Transition {
        guard var pass = activePass,
              let mutation = pass.pendingMutation,
              let selection = pass.pendingDecoderSelection
        else {
            dispatchPhase = .dispatch
            return .decoded(encoder: .valueSearch, accepted: false)
        }

        let encoderName = pass.encoder.name

        let decoder: SequenceDecoder = selection.preferExact
            ? .exact(materializePicks: selection.materializePicks)
            : .guided(fallbackTree: tree, materializePicks: selection.materializePicks)

        var filterObservations: [UInt64: FilterObservation] = [:]

        if let result = try decoder.decodeAny(
            candidate: pass.candidateBuffer,
            gen: gen,
            tree: tree,
            originalSequence: sequence,
            property: property,
            filterObservations: &filterObservations,
            precomputedHash: pass.pendingProbeHash
        ) {
            sequence = result.sequence
            tree = result.tree
            output = result.output
            pass.lastProbeAccepted = true
            pass.anyAccepted = true
            pass.acceptCount += 1

            if collectStats {
                stats.totalMaterializations += 1
            }
            pass.latestTreeIsStripped = selection.materializePicks == false

            var mutatedStructurally = false
            if pass.encoder.requiresExactDecoder {
                pass.anyRequiresRebuild = true
                mutatedStructurally = true
            } else {
                let application = graph.apply(mutation)
                if application.requiresFullRebuild {
                    pass.anyRequiresRebuild = true
                    activePass = pass
                    dispatchPhase = .finishEncoder
                    return .decoded(encoder: encoderName, accepted: true)
                }
            }

            countMaterialization()

            if mutatedStructurally {
                pass.encoder.refreshState(graph: graph, sequence: sequence)
            }

            if isDeadlineExceeded() {
                activePass = nil
                stats.reductionWasCapped = true
                phase = .reorderPass
                return .decoded(encoder: encoderName, accepted: true)
            }

            activePass = pass
            dispatchPhase = .encode
            return .decoded(encoder: encoderName, accepted: true)
        }

        rejectCache.insert(pass.pendingProbeHash)
        pass.decoderRejectCount += 1
        if isInstrumented {
            ChoiceGraphScheduler.logReplacementProbeRejection(
                mutation: mutation,
                encoder: encoderName,
                graph: graph,
                baseSequenceCount: sequence.count,
                probeSequenceCount: pass.candidateBuffer.count,
                probeHash: pass.pendingProbeHash
            )
        }

        countMaterialization()

        if isDeadlineExceeded() {
            activePass = nil
            stats.reductionWasCapped = true
            phase = .reorderPass
            return .decoded(encoder: encoderName, accepted: false)
        }

        activePass = pass
        dispatchPhase = .encode
        return .decoded(encoder: encoderName, accepted: false)
    }

    // MARK: - Finish Encoder

    /// Flushes partial convergence, harvests convergence records, records gate outcomes for bound value scopes, accumulates per-encoder stats, and evaluates the post-acceptance action. Transitions to ``DispatchPhase/dispatch`` (continue dispatching) or ``DispatchPhase/rebuild`` (structural acceptance requires graph rebuild).
    private mutating func stepFinishEncoder() -> Transition {
        guard var pass = activePass else {
            dispatchPhase = .dispatch
            return .dispatched(decision: .sourceExhausted)
        }

        let encoderName = pass.encoder.name

        pass.encoder.flushPartialConvergence()

        let convergence = pass.encoder.convergenceRecords
        if convergence.isEmpty == false {
            graph.recordConvergence(byNodeID: convergence)
        }

        if let fingerprint = pass.boundValueFingerprint {
            gate.recordOutcome(fingerprint: fingerprint, accepted: pass.anyAccepted)
        }

        if hadReplacementShortlexRejection == false,
           pass.encoder.hadReplacementShortlexRejection
        {
            hadReplacementShortlexRejection = true
        }

        if collectStats {
            stats.encoderProbes[encoderName, default: 0] += pass.probeCount
            stats.encoderProbesAccepted[encoderName, default: 0] += pass.acceptCount
            stats.encoderProbesRejectedByCache[encoderName, default: 0] += pass.cacheHitCount
            stats.encoderProbesRejectedByDecoder[encoderName, default: 0] += pass.decoderRejectCount
        }

        ChoiceGraphScheduler.logReducer("graph_encoder_pass", isInstrumented: isInstrumented, metadata: [
            "encoder": encoderName.rawValue, "probes": "\(pass.probeCount)",
            "accepted": "\(pass.acceptCount)", "cache_hits": "\(pass.cacheHitCount)",
            "decoder_rejects": "\(pass.decoderRejectCount)", "seq_len": "\(sequence.count)",
        ])

        let probeOutcome = ChoiceGraphScheduler.ProbeLoopOutcome(
            accepted: pass.anyAccepted,
            requiresRebuild: pass.anyRequiresRebuild,
            treeIsStripped: pass.latestTreeIsStripped
        )

        let acceptanceAction = ChoiceGraphScheduler.evaluateAcceptance(
            outcome: probeOutcome,
            operation: pass.transformation.operation
        )

        if pass.anyAccepted {
            anyAccepted = true
        }

        switch acceptanceAction {
        case .continueDispatching:
            if pass.anyAccepted == false {
                scopeRejectionCache.recordRejection(
                    operation: pass.transformation.operation,
                    sequence: sequence,
                    graph: graph
                )
            }
            activePass = nil
            dispatchPhase = .dispatch
            return .dispatched(decision: .sourceExhausted)

        case .rebuildAndResume:
            activePass = pass
            dispatchPhase = .rebuild
            return .dispatched(decision: .sourceExhausted)
        }
    }

    // MARK: - Rebuild

    /// Rebuilds the graph from the current tree after a structural acceptance, clears stale convergence in bound subtrees when a bound value scope triggered the rebuild, and reconstructs candidate sources. Uses ``ChoiceGraphDiff/isStructurallyIdentical`` to decide whether structural sources can be preserved or must also be rebuilt.
    private mutating func stepRebuild() -> Transition {
        var boundPositionRange: ClosedRange<Int>?
        if let pass = activePass,
           case let .minimize(.boundValue(bindScope)) = pass.transformation.operation,
           bindScope.bindNodeID < graph.nodes.count,
           case let .bind(bindMetadata) = graph.nodes[bindScope.bindNodeID].kind,
           graph.nodes[bindScope.bindNodeID].children.count > bindMetadata.boundChildIndex
        {
            let boundChildID = graph.nodes[bindScope.bindNodeID].children[bindMetadata.boundChildIndex]
            boundPositionRange = graph.nodes[boundChildID].positionRange
        }

        let latestTreeIsStripped = activePass?.latestTreeIsStripped ?? false

        let graphBefore = graph
        let graphStart = monotonicNanoseconds()
        let diff = rebuildAndUpdateGraph()
        graphIsStripped = latestTreeIsStripped

        if let boundRange = boundPositionRange {
            for nodeID in graph.leafNodes {
                guard let nodeRange = graph.nodes[nodeID].positionRange else { continue }
                guard boundRange.contains(nodeRange.lowerBound) else { continue }
                guard case var .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
                guard metadata.convergedOrigin != nil else { continue }
                metadata.convergedOrigin = nil
                graph.nodes[nodeID] = graph.nodes[nodeID].with(kind: .chooseBits(metadata))
            }
        }
        let graphEnd = monotonicNanoseconds()

        if diff.isStructurallyIdentical {
            let structuralSources = sources.filter { source in
                guard let sorted = source as? SortedCandidateSource,
                      let first = sorted.peekTransformation
                else {
                    return true
                }
                return first.operation.isValueDependent == false
            }
            sources = structuralSources
                + CandidateSourceBuilder.buildValueSources(from: graph, deferBindInner: deferBindInner)

            ChoiceGraphScheduler.logReducer("graph_value_only_rebuild", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(sequence.count)", "nodes": "\(graph.nodes.count)", "sources": "\(sources.count)",
            ])
        } else {
            scopeRejectionCache.clear()
            sources = CandidateSourceBuilder.buildSources(from: graph, deferBindInner: deferBindInner, previousGraph: graphBefore)

            ChoiceGraphScheduler.logReducer("graph_structural_rebuild", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(sequence.count)", "nodes": "\(graph.nodes.count)", "sources": "\(sources.count)",
            ])
        }
        let sourceEnd = monotonicNanoseconds()

        if collectStats {
            stats.stepTimings.rebuildGraphNanoseconds += graphEnd - graphStart
            stats.stepTimings.rebuildSourceNanoseconds += sourceEnd - graphEnd
        }

        activePass = nil
        dispatchPhase = .dispatch
        return .rebuilt(sequenceLength: sequence.count, structurallyChanged: diff.isStructurallyIdentical == false)
    }
}
