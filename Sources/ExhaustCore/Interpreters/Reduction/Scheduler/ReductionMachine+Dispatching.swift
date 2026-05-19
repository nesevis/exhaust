//
//  ReductionMachine+Dispatching.swift
//  Exhaust
//

// MARK: - Dispatching Sub-Phases

extension ReductionMachine {
    /// Routes to the active ``DispatchPhase`` sub-step.
    mutating func stepDispatching() throws -> Transition {
        switch dispatchPhase {
        case .dispatch:
            return try stepDispatch()
        case .probing:
            return try stepProbing()
        case .rebuild:
            return stepRebuild()
        }
    }

    // MARK: - Dispatch

    /// Selects the highest-priority source, pulls the next transformation, and resolves the dispatch decision. On ``ChoiceGraphScheduler/DispatchDecision/readyToDispatch(boundValueFingerprint:)``, initializes the encoder and transitions to the ``DispatchPhase/probing`` sub-phase.
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
            gate: convergence.gate,
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
                convergence.gate.markFruitless(fingerprint)
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
            sources = CandidateSourceBuilder.buildSources(from: graph, deferBindInner: convergence.deferBindInner, previousGraph: graphBefore)
            graphIsStripped = false
            return .dispatched(decision: .rematerialized)

        case let .readyToDispatch(boundValueFingerprint):
            return beginProbeSession(
                transformation: transformation,
                boundValueFingerprint: boundValueFingerprint
            )
        }
    }

    // MARK: - Begin Probe Session

    private mutating func beginProbeSession(
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
                upstreamBudget: convergence.gate.decayedBudget(fingerprint: fingerprint)
            )
            convergence.gate.markDispatched(fingerprint)
        } else {
            encoder = ChoiceGraphScheduler.selectEncoder(for: transformation.operation)
        }

        encoder.start(scope: scope)

        activeSession = ProbeSession(
            encoder: encoder,
            transformation: transformation,
            boundValueFingerprint: boundValueFingerprint,
            baseSequence: sequence,
            hasBind: sequence.contains { entry in
                if case .bind = entry { return true }
                return false
            }
        )

        dispatchPhase = .probing
        return .dispatched(decision: .encoderStarted(encoder: encoder.name))
    }

    // MARK: - Probing

    /// Delegates to the active ``ProbeSession`` for one encode or decode sub-phase. On completion, applies the ``PassReport`` and routes to dispatch or rebuild.
    private mutating func stepProbing() throws -> Transition {
        guard var session = activeSession else {
            dispatchPhase = .dispatch
            return .dispatched(decision: .sourceExhausted)
        }

        let result = try session.step(state: &self)
        activeSession = session

        switch result {
        case let .encoded(encoder, cacheHit):
            return .encoded(encoder: encoder, cacheHit: cacheHit)

        case let .decoded(encoder, accepted):
            if isDeadlineExceeded() {
                activeSession = nil
                pendingReport = nil
                stats.reductionWasCapped = true
                phase = .reorderPass
                return .decoded(encoder: encoder, accepted: accepted)
            }
            return .decoded(encoder: encoder, accepted: accepted)

        case .finished:
            var s = activeSession!
            let report = s.report()
            activeSession = nil
            pendingReport = report
            return applyPassReport(report)
        }
    }

    // MARK: - Apply Pass Report

    /// Applies post-pass policy from a completed encoder pass.
    ///
    /// Called identically whether the pass was stepped (via the main dispatching loop) or run to completion (via reorder/relax). Handles convergence recording, gate outcome, shortlex rejection propagation, stats accumulation, logging, and acceptance evaluation routing.
    mutating func applyPassReport(_ report: PassReport) -> Transition {
        if report.convergenceRecords.isEmpty == false {
            graph.recordConvergence(byNodeID: report.convergenceRecords)
        }

        if let fingerprint = report.boundValueFingerprint {
            convergence.gate.recordOutcome(fingerprint: fingerprint, accepted: report.anyAccepted)
        }

        if hadReplacementShortlexRejection == false,
           report.hadReplacementShortlexRejection
        {
            hadReplacementShortlexRejection = true
        }

        if collectStats {
            stats.encoderProbes[report.encoderName, default: 0] += report.probeCount
            stats.encoderProbesAccepted[report.encoderName, default: 0] += report.acceptCount
            stats.encoderProbesRejectedByCache[report.encoderName, default: 0] += report.cacheHitCount
            stats.encoderProbesRejectedByDecoder[report.encoderName, default: 0] += report.decoderRejectCount
        }

        ChoiceGraphScheduler.logReducer("graph_encoder_pass", isInstrumented: isInstrumented, metadata: [
            "encoder": report.encoderName.rawValue, "probes": "\(report.probeCount)",
            "accepted": "\(report.acceptCount)", "cache_hits": "\(report.cacheHitCount)",
            "decoder_rejects": "\(report.decoderRejectCount)", "seq_len": "\(sequence.count)",
        ])

        let probeOutcome = ChoiceGraphScheduler.ProbeLoopOutcome(
            accepted: report.anyAccepted,
            requiresRebuild: report.anyRequiresRebuild,
            treeIsStripped: report.latestTreeIsStripped
        )

        let acceptanceAction = ChoiceGraphScheduler.evaluateAcceptance(
            outcome: probeOutcome,
            operation: report.transformation.operation
        )

        if report.anyAccepted {
            anyAccepted = true
        }

        switch acceptanceAction {
        case .continueDispatching:
            if report.anyAccepted == false {
                scopeRejectionCache.recordRejection(
                    operation: report.transformation.operation,
                    sequence: sequence,
                    graph: graph
                )
            }
            pendingReport = nil
            dispatchPhase = .dispatch
            return .dispatched(decision: .sourceExhausted)

        case .rebuildAndResume:
            dispatchPhase = .rebuild
            return .dispatched(decision: .sourceExhausted)
        }
    }

    // MARK: - Rebuild

    /// Rebuilds the graph from the current tree after a structural acceptance, clears stale convergence in bound subtrees when a bound value scope triggered the rebuild, and reconstructs candidate sources.
    private mutating func stepRebuild() -> Transition {
        var boundPositionRange: ClosedRange<Int>?
        if let report = pendingReport,
           case let .minimize(.boundValue(bindScope)) = report.transformation.operation,
           bindScope.bindNodeID < graph.nodes.count,
           case let .bind(bindMetadata) = graph.nodes[bindScope.bindNodeID].kind,
           graph.nodes[bindScope.bindNodeID].children.count > bindMetadata.boundChildIndex
        {
            let boundChildID = graph.nodes[bindScope.bindNodeID].children[bindMetadata.boundChildIndex]
            boundPositionRange = graph.nodes[boundChildID].positionRange
        }

        let latestTreeIsStripped = pendingReport?.latestTreeIsStripped ?? false

        let graphBefore = graph
        let graphStart = monotonicNanoseconds()
        let diff = rebuildAndUpdateGraph()
        graphIsStripped = latestTreeIsStripped

        if let boundRange = boundPositionRange {
            graph.clearConvergence(inPositionRange: boundRange)
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
                + CandidateSourceBuilder.buildValueSources(from: graph, deferBindInner: convergence.deferBindInner)

            ChoiceGraphScheduler.logReducer("graph_value_only_rebuild", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(sequence.count)", "nodes": "\(graph.nodes.count)", "sources": "\(sources.count)",
            ])
        } else {
            scopeRejectionCache.clear()
            sources = CandidateSourceBuilder.buildSources(from: graph, deferBindInner: convergence.deferBindInner, previousGraph: graphBefore)

            ChoiceGraphScheduler.logReducer("graph_structural_rebuild", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(sequence.count)", "nodes": "\(graph.nodes.count)", "sources": "\(sources.count)",
            ])
        }
        let sourceEnd = monotonicNanoseconds()

        if collectStats {
            stats.stepTimings.rebuildGraphNanoseconds += graphEnd - graphStart
            stats.stepTimings.rebuildSourceNanoseconds += sourceEnd - graphEnd
        }

        pendingReport = nil
        dispatchPhase = .dispatch
        return .rebuilt(sequenceLength: sequence.count, structurallyChanged: diff.isStructurallyIdentical == false)
    }
}
