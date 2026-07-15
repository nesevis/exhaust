/// Distinguishes the terminal property outcome from the reducer's later admission decision.
enum SequenceDecodingOutcome {
    /// Materialization did not produce a value, so the property was not invoked.
    case materializationRejected(materializationAttempts: Int)

    /// Materialization produced a value for which the property held.
    case propertyPassed(materializationAttempts: Int)

    /// Materialization produced a value for which the property failed. The reduction is `nil` when a later materialization or admission check rejected the proposal.
    case propertyFailed(
        reduction: ReductionResult<Any>?,
        materializationAttempts: Int
    )

    /// The number of materializer entries consumed while resolving this outcome.
    var materializationAttempts: Int {
        switch self {
            case let .materializationRejected(materializationAttempts),
                 let .propertyPassed(materializationAttempts),
                 let .propertyFailed(_, materializationAttempts):
                materializationAttempts
        }
    }

    /// The admitted reduction, or `nil` when the reducer did not accept the proposal.
    var reduction: ReductionResult<Any>? {
        guard case let .propertyFailed(reduction, _) = self else {
            return nil
        }
        return reduction
    }
}

/// Materializes a candidate sequence and checks feasibility.
///
/// Selected by ``ProbeSession``, shared by all encoders at a given depth. Implemented as a concrete enum to avoid heap allocation because decoder types carry associated data that exceeds Swift's three-word inline existential buffer.
package enum SequenceDecoder {
    /// Materializes in exact mode. Produces a fresh tree with current ``validRange`` and all branch alternatives. Rejects inner values that are out of range; clamps bound values.
    case exact(materializePicks: Bool = false)

    /// Materializes in guided mode. Produces a fresh tree with current ``validRange`` and all branch alternatives. Resolves values via prefix → fallback → PRNG, with cursor suspension at bind sites.
    case guided(fallbackTree: ChoiceTree?, maximizeBoundRegionIndices: Set<Int>? = nil,
                materializePicks: Bool = false, usePRNGFallback: Bool = false,
                skipShortlexCheck: Bool = false, prngSalt: UInt64 = 0)

    // MARK: - Decode

    /// Materializes a candidate and checks feasibility against the property.
    ///
    /// All callers in the reduction pipeline hold an already-erased ``AnyGenerator`` and a property closure that takes `Any`, so the entire decoding chain runs without generic specialization and the runtime metadata cache does not thrash per call.
    ///
    /// Uses a two-phase optimization: Phase 1 materializes value-only (no tree construction) and checks the property. Phase 2 re-materializes with full tree construction only after the property fails, avoiding the tree allocation cost for passing probes.
    ///
    /// - Parameter filterObservations: Accumulator for per-fingerprint filter predicate observations. Merged from every materialization's ``DecodingReport``, including rejected and failed attempts.
    /// - Returns: An outcome that separates materialization rejection, property success, and property failure. A property failure carries a ``ReductionResult`` only when the candidate also satisfies the decoder mode's admission policy. Guided decoding requires the materialized sequence to be shortlex-smaller than the original unless its `skipShortlexCheck` option is `true`. Exact decoding does not check ordering; its producer enforces any phase-specific ordering requirement.
    func decodeAny(
        candidate: consuming ChoiceSequence,
        gen: AnyGenerator,
        tree: ChoiceTree,
        originalSequence: ChoiceSequence,
        property: (Any) -> Bool,
        filterObservations: inout [UInt64: FilterObservation],
        precomputedHash: UInt64? = nil
    ) throws -> SequenceDecodingOutcome {
        switch self {
            case let .exact(materializePicks):
                decodeExactAny(
                    candidate: consume candidate, gen: gen,
                    fallbackTree: tree,
                    originalSequence: originalSequence, property: property,
                    materializePicks: materializePicks,
                    filterObservations: &filterObservations,
                    precomputedHash: precomputedHash
                )

            case let .guided(
            fallbackTree, maximizeBoundRegionIndices,
            materializePicks, usePRNGFallback,
            skipShortlexCheck, prngSalt
        ):
                decodeGuidedAny(
                    candidate: consume candidate, gen: gen,
                    fallbackTree: usePRNGFallback ? nil : (fallbackTree ?? tree),
                    maximizeBoundRegionIndices: maximizeBoundRegionIndices,
                    originalSequence: originalSequence, property: property,
                    materializePicks: materializePicks,
                    skipShortlexCheck: skipShortlexCheck,
                    prngSalt: prngSalt,
                    filterObservations: &filterObservations,
                    precomputedHash: precomputedHash
                )
        }
    }

    private func decodeExactAny(
        candidate: consuming ChoiceSequence,
        gen: AnyGenerator,
        fallbackTree: ChoiceTree,
        originalSequence _: ChoiceSequence,
        property: (Any) -> Bool,
        materializePicks: Bool,
        filterObservations: inout [UInt64: FilterObservation],
        precomputedHash: UInt64? = nil
    ) -> SequenceDecodingOutcome {
        let candidateForPhase2 = copy candidate

        switch Materializer.materializeAny(
            gen, prefix: consume candidate,
            mode: .exact, fallbackTree: fallbackTree,
            materializePicks: false,
            precomputedSeed: precomputedHash,
            skipTree: true
        ) {
            case let .success(output, _, decodingReport):
                mergeFilterObservations(from: decodingReport, into: &filterObservations)
                guard property(output) == false else {
                    return .propertyPassed(materializationAttempts: 1)
                }

                switch Materializer.materializeAny(
                    gen, prefix: candidateForPhase2,
                    mode: .exact, fallbackTree: fallbackTree,
                    materializePicks: materializePicks,
                    precomputedSeed: precomputedHash
                ) {
                    case let .success(_, freshTree, _):
                        let freshSequence = ChoiceSequence(freshTree)
                        return .propertyFailed(
                            reduction: ReductionResult(
                                sequence: freshSequence,
                                tree: freshTree,
                                output: output,
                                evaluations: 1,
                                decodingReport: nil
                            ),
                            materializationAttempts: 2
                        )
                    case .rejected, .failed:
                        return .propertyFailed(
                            reduction: nil,
                            materializationAttempts: 2
                        )
                }

            case let .rejected(decodingReport), let .failed(decodingReport):
                mergeFilterObservations(from: decodingReport, into: &filterObservations)
                return .materializationRejected(materializationAttempts: 1)
        }
    }

    private func decodeGuidedAny(
        candidate: consuming ChoiceSequence,
        gen: AnyGenerator,
        fallbackTree: ChoiceTree?,
        maximizeBoundRegionIndices: Set<Int>? = nil,
        originalSequence: ChoiceSequence,
        property: (Any) -> Bool,
        materializePicks: Bool,
        skipShortlexCheck: Bool = false,
        prngSalt: UInt64 = 0,
        filterObservations: inout [UInt64: FilterObservation],
        precomputedHash: UInt64? = nil
    ) -> SequenceDecodingOutcome {
        let seed = (precomputedHash ?? ZobristHash.hash(of: candidate)) &+ prngSalt
        let candidateForPhase2 = copy candidate

        switch Materializer.materializeAny(
            gen,
            prefix: consume candidate,
            mode: .guided(
                seed: seed,
                fallbackTree: fallbackTree,
                maximizeBoundRegionIndices: maximizeBoundRegionIndices
            ),
            materializePicks: false,
            skipTree: true
        ) {
            case let .success(output, _, decodingReport):
                mergeFilterObservations(from: decodingReport, into: &filterObservations)
                guard property(output) == false else {
                    logDecoderRejection(
                        reason: "property_passed",
                        probeHash: precomputedHash,
                        extra: ["output": String(describing: output)]
                    )
                    return .propertyPassed(materializationAttempts: 1)
                }

                switch Materializer.materializeAny(
                    gen,
                    prefix: candidateForPhase2,
                    mode: .guided(
                        seed: seed,
                        fallbackTree: fallbackTree,
                        maximizeBoundRegionIndices: maximizeBoundRegionIndices
                    ),
                    materializePicks: materializePicks
                ) {
                    case let .success(_, freshTree, phase2Report):
                        let freshSequence = ChoiceSequence(freshTree)
                        if skipShortlexCheck == false {
                            let passes = freshSequence.shortLexPrecedes(originalSequence)
                            if ExhaustLog.isEnabled(.debug, for: .reducer) {
                                ExhaustLog.debug(
                                    category: .reducer,
                                    event: "shortlex_check",
                                    metadata: [
                                        "passes": "\(passes)",
                                        "fresh_len": "\(freshSequence.count)",
                                        "original_len": "\(originalSequence.count)",
                                        "fresh_seq": freshSequence.shortString,
                                        "original_seq": originalSequence.shortString,
                                        "output": String(describing: output),
                                    ]
                                )
                            }
                            guard passes else {
                                logDecoderRejection(
                                    reason: "not_shortlex",
                                    probeHash: precomputedHash,
                                    extra: [
                                        "fresh_seq_len": "\(freshSequence.count)",
                                        "output": String(describing: output),
                                    ]
                                )
                                return .propertyFailed(
                                    reduction: nil,
                                    materializationAttempts: 2
                                )
                            }
                        }
                        if let report = phase2Report, ExhaustLog.isEnabled(.debug, for: .reducer) {
                            ExhaustLog.debug(
                                category: .reducer,
                                event: "guided_materialization_fidelity",
                                metadata: [
                                    "fidelity": String(format: "%.3f", report.fidelity),
                                    "convergence": String(format: "%.3f", report.convergence),
                                ]
                            )
                        }
                        return .propertyFailed(
                            reduction: ReductionResult(
                                sequence: freshSequence,
                                tree: freshTree,
                                output: output,
                                evaluations: 1,
                                decodingReport: phase2Report
                            ),
                            materializationAttempts: 2
                        )
                    case .rejected, .failed:
                        return .propertyFailed(
                            reduction: nil,
                            materializationAttempts: 2
                        )
                }

            case let .rejected(decodingReport):
                mergeFilterObservations(from: decodingReport, into: &filterObservations)
                logDecoderRejection(reason: "materialization_rejected", probeHash: precomputedHash)
                return .materializationRejected(materializationAttempts: 1)

            case let .failed(decodingReport):
                mergeFilterObservations(from: decodingReport, into: &filterObservations)
                logDecoderRejection(reason: "materialization_failed", probeHash: precomputedHash)
                return .materializationRejected(materializationAttempts: 1)
        }
    }

    /// Emits a `graph_decoder_rejected` debug event so the upstream probe-loop's `graph_probe_rejected` entry can be correlated with the decoder-side rejection reason via `probe_hash`.
    private func logDecoderRejection(
        reason: String,
        probeHash: UInt64?,
        extra: [String: String] = [:]
    ) {
        guard ExhaustLog.isEnabled(.debug, for: .reducer) else { return }
        var metadata: [String: String] = ["reason": reason]
        if let probeHash {
            metadata["probe_hash"] = "\(probeHash)"
        }
        for (key, value) in extra {
            metadata[key] = value
        }
        ExhaustLog.debug(
            category: .reducer,
            event: "graph_decoder_rejected",
            metadata: metadata
        )
    }

    // MARK: - Filter Observation Merging

    private func mergeFilterObservations(
        from report: DecodingReport?,
        into accumulator: inout [UInt64: FilterObservation]
    ) {
        guard let report, report.filterObservations.isEmpty == false else { return }
        for (fingerprint, observation) in report.filterObservations {
            accumulator[fingerprint, default: FilterObservation()].merge(observation)
        }
    }
}
