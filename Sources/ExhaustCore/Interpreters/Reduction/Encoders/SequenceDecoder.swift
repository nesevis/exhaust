/// Materializes a candidate sequence and checks feasibility.
///
/// Selected by ``DecoderContext``, shared by all encoders at a given depth. Implemented as a concrete enum to avoid heap allocation — decoder types carry associated data that exceeds Swift's three-word inline existential buffer.
package enum SequenceDecoder {
    /// Materializes in exact mode. Produces a fresh tree with current ``validRange`` and all branch alternatives. Rejects inner values that are out of range; clamps bound values.
    case exact(materializePicks: Bool = false)

    /// Materializes in guided mode. Produces a fresh tree with current ``validRange`` and all branch alternatives. Resolves values via prefix → fallback → PRNG, with cursor suspension at bind sites.
    case guided(fallbackTree: ChoiceTree?, maximizeBoundRegionIndices: Set<Int>? = nil,
                materializePicks: Bool = false, usePRNGFallback: Bool = false,
                skipShortlexCheck: Bool = false, prngSalt: UInt64 = 0)

    /// Salt mixed into the reject cache key so the same candidate with a different PRNG salt gets an independent cache entry.
    var rejectCacheSalt: UInt64 {
        switch self {
        case .exact:
            0
        case let .guided(_, _, _, _, _, prngSalt):
            prngSalt
        }
    }

    // MARK: - Decode

    /// Materializes a candidate and checks feasibility against the property.
    ///
    /// - Parameter filterObservations: Accumulator for per-fingerprint filter predicate observations. Merged from every materialization's ``DecodingReport``, including rejected and failed attempts.
    /// - Returns: A ``ReductionResult`` if the candidate produces a failing output that is shortlex-smaller than the original, or `nil` if the candidate is rejected.
    public func decode<Output>(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool,
        filterObservations: inout [UInt64: FilterObservation],
        precomputedHash: UInt64? = nil
    ) throws -> ReductionResult<Output>? {
        switch self {
        case let .exact(materializePicks):
            decodeExact(
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
            decodeGuided(
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

    /// Materializes a candidate and checks feasibility against the property.
    ///
    /// Convenience overload that discards filter observations.
    public func decode<Output>(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool
    ) throws -> ReductionResult<Output>? {
        var discarded: [UInt64: FilterObservation] = [:]
        return try decode(
            candidate: consume candidate, gen: gen, tree: tree,
            originalSequence: originalSequence, property: property,
            filterObservations: &discarded
        )
    }

    /// Non-generic decoding entry point.
    ///
    /// Hot-path callers (the graph reducer probe loop) hold an already-erased ``ReflectiveGenerator<Any>`` and a property closure that takes ``Any``, so the entire decoding chain runs without `<Output>` specialization and the runtime metadata cache no longer thrashes per call.
    public func decodeAny(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Any>,
        tree: ChoiceTree,
        originalSequence: ChoiceSequence,
        property: (Any) -> Bool,
        filterObservations: inout [UInt64: FilterObservation],
        precomputedHash: UInt64? = nil
    ) throws -> ReductionResult<Any>? {
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
        gen: ReflectiveGenerator<Any>,
        fallbackTree: ChoiceTree,
        originalSequence _: ChoiceSequence,
        property: (Any) -> Bool,
        materializePicks: Bool,
        filterObservations: inout [UInt64: FilterObservation],
        precomputedHash: UInt64? = nil
    ) -> ReductionResult<Any>? {
        switch Materializer.materializeAny(
            gen, prefix: consume candidate,
            mode: .exact, fallbackTree: fallbackTree,
            materializePicks: materializePicks,
            precomputedSeed: precomputedHash
        ) {
        case let .success(output, freshTree, decodingReport):
            mergeFilterObservations(from: decodingReport, into: &filterObservations)
            guard property(output) == false else { return nil }
            let freshSequence = ChoiceSequence(freshTree)
            return ReductionResult(
                sequence: freshSequence,
                tree: freshTree,
                output: output,
                evaluations: 1,
                decodingReport: nil
            )
        case let .rejected(decodingReport), let .failed(decodingReport):
            mergeFilterObservations(from: decodingReport, into: &filterObservations)
            return nil
        }
    }

    private func decodeGuidedAny(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Any>,
        fallbackTree: ChoiceTree?,
        maximizeBoundRegionIndices: Set<Int>? = nil,
        originalSequence: ChoiceSequence,
        property: (Any) -> Bool,
        materializePicks: Bool,
        skipShortlexCheck: Bool = false,
        prngSalt: UInt64 = 0,
        filterObservations: inout [UInt64: FilterObservation],
        precomputedHash: UInt64? = nil
    ) -> ReductionResult<Any>? {
        let seed = (precomputedHash ?? ZobristHash.hash(of: candidate)) &+ prngSalt
        switch Materializer.materializeAny(
            gen,
            prefix: consume candidate,
            mode: .guided(
                seed: seed,
                fallbackTree: fallbackTree,
                maximizeBoundRegionIndices: maximizeBoundRegionIndices
            ),
            materializePicks: materializePicks
        ) {
        case let .success(output, freshTree, decodingReport):
            mergeFilterObservations(from: decodingReport, into: &filterObservations)
            guard property(output) == false else { return nil }
            let freshSequence = ChoiceSequence(freshTree)
            if skipShortlexCheck == false {
                guard freshSequence.shortLexPrecedes(originalSequence) else { return nil }
            }
            if let report = decodingReport, ExhaustLog.isEnabled(.debug, for: .reducer) {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "guided_materialization_fidelity",
                    metadata: [
                        "fidelity": String(format: "%.3f", report.fidelity),
                        "coverage": String(format: "%.3f", report.coverage),
                    ]
                )
            }
            return ReductionResult(
                sequence: freshSequence,
                tree: freshTree,
                output: output,
                evaluations: 1,
                decodingReport: decodingReport
            )
        case let .rejected(decodingReport), let .failed(decodingReport):
            mergeFilterObservations(from: decodingReport, into: &filterObservations)
            return nil
        }
    }

    // MARK: - Decode Implementations

    private func decodeExact<Output>(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        fallbackTree: ChoiceTree,
        originalSequence _: ChoiceSequence,
        property: (Output) -> Bool,
        materializePicks: Bool,
        filterObservations: inout [UInt64: FilterObservation],
        precomputedHash: UInt64? = nil
    ) -> ReductionResult<Output>? {
        switch Materializer.materialize(
            gen, prefix: consume candidate,
            mode: .exact, fallbackTree: fallbackTree,
            materializePicks: materializePicks,
            precomputedSeed: precomputedHash
        ) {
        case let .success(output, freshTree, decodingReport):
            mergeFilterObservations(from: decodingReport, into: &filterObservations)
            guard property(output) == false else { return nil }
            let freshSequence = ChoiceSequence(freshTree)
            return ReductionResult(
                sequence: freshSequence,
                tree: freshTree,
                output: output,
                evaluations: 1,
                decodingReport: nil
            )
        case let .rejected(decodingReport), let .failed(decodingReport):
            mergeFilterObservations(from: decodingReport, into: &filterObservations)
            return nil
        }
    }

    private func decodeGuided<Output>(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        fallbackTree: ChoiceTree?,
        maximizeBoundRegionIndices: Set<Int>? = nil,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool,
        materializePicks: Bool,
        skipShortlexCheck: Bool = false,
        prngSalt: UInt64 = 0,
        filterObservations: inout [UInt64: FilterObservation],
        precomputedHash: UInt64? = nil
    ) -> ReductionResult<Output>? {
        let seed = (precomputedHash ?? ZobristHash.hash(of: candidate)) &+ prngSalt
        switch Materializer.materialize(
            gen,
            prefix: consume candidate,
            mode: .guided(
                seed: seed,
                fallbackTree: fallbackTree,
                maximizeBoundRegionIndices: maximizeBoundRegionIndices
            ),
            materializePicks: materializePicks
        ) {
        case let .success(output, freshTree, decodingReport):
            mergeFilterObservations(from: decodingReport, into: &filterObservations)
            guard property(output) == false else { return nil }
            let freshSequence = ChoiceSequence(freshTree)
            if skipShortlexCheck == false {
                guard freshSequence.shortLexPrecedes(originalSequence) else { return nil }
            }
            if let report = decodingReport, ExhaustLog.isEnabled(.debug, for: .reducer) {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "guided_materialization_fidelity",
                    metadata: [
                        "fidelity": String(format: "%.3f", report.fidelity),
                        "coverage": String(format: "%.3f", report.coverage),
                    ]
                )
            }
            return ReductionResult(
                sequence: freshSequence,
                tree: freshTree,
                output: output,
                evaluations: 1,
                decodingReport: decodingReport
            )
        case let .rejected(decodingReport), let .failed(decodingReport):
            mergeFilterObservations(from: decodingReport, into: &filterObservations)
            return nil
        }
    }

    // MARK: - Filter Observation Merging

    private func mergeFilterObservations(
        from report: DecodingReport?,
        into accumulator: inout [UInt64: FilterObservation]
    ) {
        guard let report, report.filterObservations.isEmpty == false else { return }
        for (fingerprint, observation) in report.filterObservations {
            accumulator[fingerprint, default: FilterObservation()].attempts += observation.attempts
            accumulator[fingerprint, default: FilterObservation()].passes += observation.passes
        }
    }
}
