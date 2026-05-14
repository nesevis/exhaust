//
//  ReductionMachine+Dispatching.swift
//  Exhaust
//

// MARK: - Dispatching Sub-Phases

extension ReductionMachine {
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

    // MARK: - Evaluate

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

        activeEncoder = encoder
        activeTransformation = transformation
        activeBoundValueFingerprint = boundValueFingerprint
        candidateBuffer = sequence
        lastProbeAccepted = false
        encoderBaseHash = ZobristHash.hash(of: sequence)
        encoderHasBind = sequence.contains { entry in
            if case .bind = entry { return true }
            return false
        }

        encoderProbeCount = 0
        encoderAcceptCount = 0
        encoderCacheHitCount = 0
        encoderDecoderRejectCount = 0
        encoderAnyAccepted = false
        encoderAnyRequiresRebuild = false
        encoderLatestTreeIsStripped = false

        dispatchPhase = .encode
        return .dispatched(decision: .encoderStarted(encoder: encoder.name))
    }

    // MARK: - Encode

    private mutating func stepEncode() -> Transition {
        guard var encoder = activeEncoder else {
            dispatchPhase = .dispatch
            return .dispatched(decision: .sourceExhausted)
        }

        guard let mutation = encoder.nextProbe(into: &candidateBuffer, lastAccepted: lastProbeAccepted) else {
            activeEncoder = encoder
            dispatchPhase = .finishEncoder
            return .encoded(encoder: encoder.name, cacheHit: false)
        }

        encoderProbeCount += 1
        lastProbeAccepted = false

        let probeHash = ZobristHash.incrementalHash(
            baseHash: encoderBaseHash,
            baseSequence: sequence,
            probe: candidateBuffer
        )
        if rejectCache.contains(probeHash) {
            encoderCacheHitCount += 1
            activeEncoder = encoder
            return .encoded(encoder: encoder.name, cacheHit: true)
        }

        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: encoder.requiresExactDecoder,
            hasBind: encoderHasBind
        )

        pendingMutation = mutation
        pendingProbeHash = probeHash
        pendingDecoderSelection = selection
        activeEncoder = encoder
        dispatchPhase = .decode
        return .encoded(encoder: encoder.name, cacheHit: false)
    }

    // MARK: - Decode

    private mutating func stepDecode() throws -> Transition {
        guard var encoder = activeEncoder,
              let mutation = pendingMutation,
              let selection = pendingDecoderSelection
        else {
            dispatchPhase = .dispatch
            return .decoded(encoder: .valueSearch, accepted: false)
        }

        let encoderName = encoder.name

        let decoder: SequenceDecoder = selection.preferExact
            ? .exact(materializePicks: selection.materializePicks)
            : .guided(fallbackTree: tree, materializePicks: selection.materializePicks)

        var filterObservations: [UInt64: FilterObservation] = [:]

        if let result = try decoder.decodeAny(
            candidate: candidateBuffer,
            gen: gen,
            tree: tree,
            originalSequence: sequence,
            property: property,
            filterObservations: &filterObservations,
            precomputedHash: pendingProbeHash
        ) {
            sequence = result.sequence
            tree = result.tree
            output = result.output
            lastProbeAccepted = true
            encoderAnyAccepted = true
            encoderAcceptCount += 1

            if collectStats {
                stats.totalMaterializations += 1
            }
            encoderLatestTreeIsStripped = selection.materializePicks == false

            var mutatedStructurally = false
            if encoder.requiresExactDecoder {
                encoderAnyRequiresRebuild = true
                mutatedStructurally = true
            } else {
                let application = graph.apply(mutation)
                if application.requiresFullRebuild {
                    encoderAnyRequiresRebuild = true
                    activeEncoder = encoder
                    dispatchPhase = .finishEncoder
                    return .decoded(encoder: encoderName, accepted: true)
                }
            }

            countMaterialization()

            if mutatedStructurally {
                encoder.refreshState(graph: graph, sequence: sequence)
            }

            activeEncoder = encoder
            dispatchPhase = .encode
            return .decoded(encoder: encoderName, accepted: true)
        }

        rejectCache.insert(pendingProbeHash)
        encoderDecoderRejectCount += 1
        if isInstrumented {
            ChoiceGraphScheduler.logReplacementProbeRejection(
                mutation: mutation,
                encoder: encoderName,
                graph: graph,
                baseSequenceCount: sequence.count,
                probeSequenceCount: candidateBuffer.count,
                probeHash: pendingProbeHash
            )
        }

        countMaterialization()

        activeEncoder = encoder
        dispatchPhase = .encode
        return .decoded(encoder: encoderName, accepted: false)
    }

    // MARK: - Finish Encoder

    private mutating func stepFinishEncoder() -> Transition {
        guard var encoder = activeEncoder else {
            dispatchPhase = .dispatch
            return .dispatched(decision: .sourceExhausted)
        }

        let encoderName = encoder.name

        encoder.flushPartialConvergence()

        let convergence = encoder.convergenceRecords
        if convergence.isEmpty == false {
            graph.recordConvergence(byNodeID: convergence)
        }

        if let fingerprint = activeBoundValueFingerprint {
            gate.recordOutcome(fingerprint: fingerprint, accepted: encoderAnyAccepted)
        }

        if hadReplacementShortlexRejection == false,
           encoder.hadReplacementShortlexRejection
        {
            hadReplacementShortlexRejection = true
        }

        if collectStats {
            stats.encoderProbes[encoderName, default: 0] += encoderProbeCount
            stats.encoderProbesAccepted[encoderName, default: 0] += encoderAcceptCount
            stats.encoderProbesRejectedByCache[encoderName, default: 0] += encoderCacheHitCount
            stats.encoderProbesRejectedByDecoder[encoderName, default: 0] += encoderDecoderRejectCount
        }

        ChoiceGraphScheduler.logReducer("graph_encoder_pass", isInstrumented: isInstrumented, metadata: [
            "encoder": encoderName.rawValue, "probes": "\(encoderProbeCount)",
            "accepted": "\(encoderAcceptCount)", "cache_hits": "\(encoderCacheHitCount)",
            "decoder_rejects": "\(encoderDecoderRejectCount)", "seq_len": "\(sequence.count)",
        ])

        let probeOutcome = ChoiceGraphScheduler.ProbeLoopOutcome(
            accepted: encoderAnyAccepted,
            requiresRebuild: encoderAnyRequiresRebuild,
            treeIsStripped: encoderLatestTreeIsStripped
        )

        let transformation = activeTransformation!
        let acceptanceAction = ChoiceGraphScheduler.evaluateAcceptance(
            outcome: probeOutcome,
            operation: transformation.operation
        )

        if encoderAnyAccepted {
            anyAccepted = true
        }

        activeEncoder = nil
        activeBoundValueFingerprint = nil

        switch acceptanceAction {
        case .continueDispatching:
            if encoderAnyAccepted == false {
                scopeRejectionCache.recordRejection(
                    operation: transformation.operation,
                    sequence: sequence,
                    graph: graph
                )
            }
            activeTransformation = nil
            dispatchPhase = .dispatch
            return .dispatched(decision: .sourceExhausted)

        case .rebuildAndResume:
            dispatchPhase = .rebuild
            return .dispatched(decision: .sourceExhausted)
        }
    }

    // MARK: - Rebuild

    private mutating func stepRebuild() -> Transition {
        var boundPositionRange: ClosedRange<Int>?
        if let transformation = activeTransformation,
           case let .minimize(.boundValue(bindScope)) = transformation.operation,
           bindScope.bindNodeID < graph.nodes.count,
           case let .bind(bindMetadata) = graph.nodes[bindScope.bindNodeID].kind,
           graph.nodes[bindScope.bindNodeID].children.count > bindMetadata.boundChildIndex
        {
            let boundChildID = graph.nodes[bindScope.bindNodeID].children[bindMetadata.boundChildIndex]
            boundPositionRange = graph.nodes[boundChildID].positionRange
        }

        let graphBefore = graph
        let diff = rebuildAndUpdateGraph()
        graphIsStripped = encoderLatestTreeIsStripped

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

        activeTransformation = nil
        dispatchPhase = .dispatch
        return .rebuilt(sequenceLength: sequence.count, structurallyChanged: diff.isStructurallyIdentical == false)
    }
}
