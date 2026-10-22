//
//  Reducer+Evaluation.swift
//  Exhaust
//

// MARK: - Evaluation

extension Reducer {
    /// What evaluating and, when admitted, committing one search candidate produced.
    struct Evaluation {
        /// `.initial` when the candidate was interrupted before decoding, so the search has no feedback waiting.
        let feedback: SearchFeedback
        let isAccepted: Bool
        /// Set when further exploration requires rebuilding the graph, or the deadline passes before decoding. Acceptance alone does not stop a search.
        let stop: SearchStopReason?
    }

    /// Takes one candidate through the rejection cache, decoding, and the ordering check, and commits it when admitted.
    ///
    /// The decoder is selected before the cache is consulted, because the cache key records how the candidate is decided as well as what it is.
    static func evaluateAndCommit(_ candidate: ReductionCandidate, configuration: SearchConfiguration, recoveryMutation: ProjectedMutation? = nil, context: inout Context) -> Evaluation {
        let mutation = recoveryMutation ?? candidate.mutation
        let admission = candidate.admission
        let probeHash: UInt64
        switch candidate.contents {
            case .eager:
                probeHash = ZobristHash.incrementalHash(
                    baseHash: context.baseHash,
                    baseSequence: context.incumbent.sequence,
                    probe: context.candidateBuffer
                )
                context.previousPatch = nil
            case let .lazy(patch):
                probeHash = patch.hash(baseHash: context.baseHash, baseSequence: context.incumbent.sequence)
        }

        let selection = context.decoder.selection(for: DecodingRequirement(
            requiresExactDecoder: configuration.requiresExactDecoder,
            mutation: mutation,
            admission: admission
        ))
        let cacheKey = context.rejectCache.key(
            probeHash: probeHash,
            decision: ProbeDecision(selection),
            incumbentHash: context.baseHash
        )

        let cacheHit = context.rejectCache.contains(cacheKey)
        if case let .lazy(patch) = candidate.contents {
            // Observers still see every emitted sequence. Unobserved cache hits leave the buffer and its previous edits untouched.
            if cacheHit == false || context.observer != nil {
                if let previousPatch = context.previousPatch {
                    previousPatch.restore(into: &context.candidateBuffer, baseSequence: context.incumbent.sequence)
                } else {
                    context.candidateBuffer = context.incumbent.sequence
                }
                patch.write(into: &context.candidateBuffer)
                context.previousPatch = patch
            }
        }

        context.report.counts.recordEmission()
        var observationID: Int?
        if let observer = context.observer {
            context.nextProbeID += 1
            observationID = context.nextProbeID
            observer(.emitted(probeID: context.nextProbeID, sequence: context.candidateBuffer, mutation: mutation))
        }

        context.probeTiming?.chargeEncode()

        // Selection is reported after decoding, so a probe interrupted here has no selection event.
        if cacheHit == false, context.isExpired {
            terminate(observationID, .interrupted, context: &context)
            return Evaluation(feedback: .initial, isAccepted: false, stop: .deadline)
        }

        let evaluation = CandidateEvaluator.evaluate(
            context.candidateBuffer,
            against: context.incumbent,
            using: selection,
            decoder: context.decoder,
            admits: { [incumbent = context.incumbent, order = context.encoder.admissionOrder] in
                incumbent.admits($0, under: order)
            },
            probeHash: probeHash,
            cacheHit: cacheHit,
            cacheKey: cacheKey,
            cache: &context.rejectCache,
            counts: &context.report.counts
        )
        let decoding: ReductionDecoding
        switch evaluation {
            case .cached:
                terminate(observationID, .cacheRejected, context: &context)
                return Evaluation(feedback: .rejected(.cached), isAccepted: false, stop: nil)
            case let .rejected(result), let .admitted(_, result):
                decoding = result
        }

        if let observationID {
            context.observer?(.decoderSelected(
                probeID: observationID,
                preferExact: decoding.selection.preferExact,
                materializePicks: decoding.selection.materializePicks
            ))
        }
        let outcome = decoding.outcome
        if let observationID, let result = outcome.reduction {
            context.observer?(.decoded(probeID: observationID, sequence: result.sequence))
        }

        if case let .admitted(recovered, _) = evaluation {
            commit(recovered, mutation: mutation, decoding: decoding, observationID: observationID, context: &context)
            let stop = updateGraphAfterAcceptance(mutation, policy: configuration.graphUpdate, isLifted: recoveryMutation != nil, context: &context)
            context.probeTiming?.chargeDecode()
            return Evaluation(feedback: .accepted(recovered: recovered.sequence), isAccepted: true, stop: stop)
        }

        let disposition: ProbeDisposition = switch outcome {
            case .materializationRejected:
                .materializationRejected
            case .propertyPassed:
                .propertyPassed
            case .propertyFailed(nil, _):
                .propertyFailedNotAdmitted(.decoderReturnedNoReduction)
            case .propertyFailed:
                .propertyFailedNotAdmitted(.enlargingCommit)
        }
        terminate(observationID, disposition, materializationAttempts: outcome.materializationAttempts, context: &context)

        if context.isInstrumented {
            ReductionLog.replacementProbeRejection(
                mutation: mutation,
                encoder: context.encoder.name,
                graph: context.graph,
                baseSequenceCount: context.incumbent.sequence.count,
                probeSequenceCount: context.candidateBuffer.count,
                probeHash: probeHash
            )
        }
        let rejection: CandidateRejection = switch outcome {
            case .materializationRejected:
                .materializationRejected
            case .propertyPassed:
                .propertyPassed
            case .propertyFailed:
                .failedNotAdmitted
        }
        context.probeTiming?.chargeDecode()
        return Evaluation(feedback: .rejected(rejection), isAccepted: false, stop: nil)
    }

    /// Makes an admitted counterexample the incumbent and records acceptance independently of how the graph will be maintained.
    private static func commit(
        _ recovered: Counterexample,
        mutation: ProjectedMutation,
        decoding: ReductionDecoding,
        observationID: Int?,
        context: inout Context
    ) {
        context.report.counts.recordAcceptance()
        // The buffer holds the candidate, which decoding may have changed, so the next lazy probe starts from the new base rather than restoring the last one's positions.
        context.previousPatch = nil
        context.incumbent = recovered
        context.baseHash = ZobristHash.hash(of: recovered.sequence)
        context.report.anyAccepted = true
        terminate(observationID, .accepted, materializationAttempts: decoding.outcome.materializationAttempts, context: &context)

        if case let .leafValues(changes) = mutation {
            for change in changes {
                context.report.acceptedLeafNodeIDs.insert(change.leafNodeID)
            }
        }
        context.report.latestTreeIsStripped = decoding.selection.materializePicks == false
    }

    /// Maintains the graph after the incumbent has been committed. Returns a stop reason only when the pass must end before further exploration; deferred rebuilds allow the search to continue.
    private static func updateGraphAfterAcceptance(
        _ mutation: ProjectedMutation,
        policy: GraphUpdatePolicy,
        isLifted: Bool,
        context: inout Context
    ) -> SearchStopReason? {
        // Lifted node IDs cannot update the incumbent graph, and acceptance invalidates every other attempt's lifted snapshot.
        if isLifted {
            context.report.anyRequiresRebuild = true
            return .graphInvalidated
        }
        switch policy {
            case .rebuildAfterPass:
                context.report.anyRequiresRebuild = true
                return nil
            case .applyMutation:
                let application = context.graph.apply(Self.decodedMutation(
                    mutation,
                    recovered: context.incumbent.sequence,
                    candidateCount: context.candidateBuffer.count,
                    graph: context.graph
                ))
                if application.requiresFullRebuild {
                    context.report.anyRequiresRebuild = true
                    return .graphInvalidated
                }
                return nil
        }
    }

    /// The mutation to write into the graph in place: each changed leaf takes the value decoding produced at its position, which is not the candidate's when exact decoding clamped it. A change whose position no longer holds a value, or a decoding of a different length, is marked reshaping so the graph is rebuilt instead.
    private static func decodedMutation(
        _ mutation: ProjectedMutation,
        recovered: ChoiceSequence,
        candidateCount: Int,
        graph: ChoiceGraph
    ) -> ProjectedMutation {
        guard case let .leafValues(changes) = mutation else {
            return mutation
        }
        let isAligned = recovered.count == candidateCount
        return .leafValues(changes.map { change in
            guard isAligned,
                  change.leafNodeID < graph.nodes.count,
                  let position = graph.nodes[change.leafNodeID].positionRange?.lowerBound,
                  position < recovered.count,
                  let decoded = recovered[position].value?.choice
            else {
                return LeafChange(leafNodeID: change.leafNodeID, newValue: change.newValue, mayReshape: true)
            }
            return LeafChange(leafNodeID: change.leafNodeID, newValue: decoded, mayReshape: change.mayReshape)
        })
    }

    private static func terminate(
        _ observationID: Int?,
        _ disposition: ProbeDisposition,
        materializationAttempts: Int = 0,
        context: inout Context
    ) {
        guard let observationID else {
            return
        }
        context.observer?(.terminated(
            probeID: observationID,
            disposition: disposition,
            materializationAttempts: materializationAttempts
        ))
    }
}
