//
//  ScopedReductionInterpreter+Evaluation.swift
//  Exhaust
//

// MARK: - Evaluation

extension ScopedReductionInterpreter {
    /// What evaluating one candidate produced.
    struct Evaluation {
        /// `.initial` when the candidate was interrupted before decoding, so the search has no feedback waiting.
        let feedback: ScopedSearchFeedback
        let isAccepted: Bool
        /// Set when this candidate ends the search: an acceptance under `.stop` or a rebuild, or the deadline before decoding.
        let stop: ScopedStopReason?
    }

    /// Takes one candidate through the rejection cache, decoding, and the ordering check, and commits it when admitted.
    static func evaluate(_ candidate: ScopedCandidate, configuration: ScopedSearchConfiguration, context: inout Context) -> Evaluation {
        let mutation: EncoderProbe
        let admission: DecoderAdmission
        let probeHash: UInt64
        let cacheHit: Bool
        switch candidate {
            case let .written(writtenMutation, writtenAdmission):
                mutation = configuration.reportedMutation ?? writtenMutation
                admission = writtenAdmission
                probeHash = ZobristHash.incrementalHash(baseHash: context.baseHash, baseSequence: context.incumbent.sequence, probe: context.candidateBuffer)
                cacheHit = context.rejectCache.contains(probeHash)
                context.previousSparseProbe = nil
            case let .sparse(probe, baseSequence, sparseAdmission):
                mutation = configuration.reportedMutation ?? probe.mutation
                admission = sparseAdmission
                probeHash = probe.hash(baseHash: context.baseHash, baseSequence: baseSequence)
                cacheHit = context.rejectCache.contains(probeHash)
                // Observers still see every emitted sequence. Unobserved cache hits leave the buffer and its previous edits untouched.
                if cacheHit == false || context.observer != nil {
                    if let previousSparseProbe = context.previousSparseProbe {
                        previousSparseProbe.restore(into: &context.candidateBuffer, baseSequence: baseSequence)
                    } else {
                        context.candidateBuffer = baseSequence
                    }
                    probe.write(into: &context.candidateBuffer)
                    context.previousSparseProbe = probe
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

        if cacheHit {
            context.report.counts.recordCacheRejection()
            terminate(observationID, .cacheRejected, context: &context)
            return Evaluation(feedback: .rejected(.cached), isAccepted: false, stop: nil)
        }

        // Selection is reported after decoding, so a probe interrupted here has no selection event.
        if context.isExpired {
            terminate(observationID, .interrupted, context: &context)
            return Evaluation(feedback: .initial, isAccepted: false, stop: .deadline)
        }

        let decoding = context.decoder.decode(
            context.candidateBuffer,
            against: context.incumbent,
            requirement: ScopedDecodingRequirement(
                requiresExactDecoder: configuration.requiresExactDecoder,
                mutation: mutation,
                admission: admission
            ),
            precomputedHash: probeHash
        )
        if let observationID {
            context.observer?(.decoderSelected(
                probeID: observationID,
                preferExact: decoding.selection.preferExact,
                materializePicks: decoding.selection.materializePicks
            ))
        }
        let outcome = decoding.outcome
        context.report.counts.recordOutcome(outcome)
        if let observationID, let result = outcome.reduction {
            context.observer?(.decoded(probeID: observationID, sequence: result.sequence))
        }

        if let recovered = decoding.recovered, context.incumbent.admits(recovered, under: context.encoder.admissionOrder) {
            let evaluation = commit(recovered, mutation: mutation, decoding: decoding, configuration: configuration, observationID: observationID, context: &context)
            context.probeTiming?.chargeDecode()
            return evaluation
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

        context.rejectCache.insert(probeHash)
        if context.isInstrumented {
            ScopedReductionLog.replacementProbeRejection(
                mutation: mutation,
                encoder: context.encoder.name,
                graph: context.graph,
                baseSequenceCount: context.incumbent.sequence.count,
                probeSequenceCount: context.candidateBuffer.count,
                probeHash: probeHash
            )
        }
        let rejection: ScopedRejection = switch outcome {
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

    /// Makes `recovered` the incumbent and applies what the search does after an acceptance.
    private static func commit(
        _ recovered: ScopedCounterexample,
        mutation: EncoderProbe,
        decoding: ScopedDecoding,
        configuration: ScopedSearchConfiguration,
        observationID: Int?,
        context: inout Context
    ) -> Evaluation {
        context.report.counts.recordAcceptance()
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

        let feedback = ScopedSearchFeedback.accepted(recovered: recovered.sequence)
        switch configuration.acceptance {
            case .stop:
                context.report.anyRequiresRebuild = true
                return Evaluation(feedback: feedback, isAccepted: true, stop: .accepted)
            case .rebuildAndContinue:
                context.report.anyRequiresRebuild = true
                return Evaluation(feedback: feedback, isAccepted: true, stop: nil)
            case .continue:
                let application = context.graph.apply(mutation)
                if application.requiresFullRebuild {
                    context.report.anyRequiresRebuild = true
                    return Evaluation(feedback: feedback, isAccepted: true, stop: .accepted)
                }
                return Evaluation(feedback: feedback, isAccepted: true, stop: nil)
        }
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
