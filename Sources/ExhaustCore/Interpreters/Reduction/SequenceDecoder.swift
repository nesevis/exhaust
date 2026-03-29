/// Materializes a candidate sequence and checks feasibility.
///
/// Selected by ``DecoderContext``, shared by all encoders at a given depth. This is the `dec` map from the paper. Implemented as a concrete enum to avoid heap allocation — decoder types carry associated data that exceeds Swift's three-word inline existential buffer.b
public enum SequenceDecoder {
    /// ``ReductionMaterializer`` exact mode. Produces a fresh tree with current `validRange` and
    /// all branch alternatives. Inner values are rejected if out-of-range; bound values are clamped.
    case exact(materializePicks: Bool = false)

    /// ``ReductionMaterializer`` guided mode. Produces a fresh tree with current `validRange` and
    /// all branch alternatives. Tiered resolution: prefix → fallback → PRNG. Cursor suspension
    /// at bind sites.
    case guided(fallbackTree: ChoiceTree?, maximizeBoundRegionIndices: Set<Int>? = nil,
                materializePicks: Bool = false, usePRNGFallback: Bool = false,
                skipShortlexCheck: Bool = false, prngSalt: UInt64 = 0)

    /// Salt mixed into the reject cache key so the same candidate with a different PRNG salt
    /// gets an independent cache entry.
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
    /// - Returns: A ``ShrinkResult`` if the candidate produces a failing output that is shortlex-smaller than the original, or `nil` if the candidate is rejected.
    public func decode<Output>(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool
    ) throws -> ReductionResult<Output>? {
        switch self {
        case let .exact(materializePicks):
            decodeExact(
                candidate: consume candidate, gen: gen,
                fallbackTree: tree,
                originalSequence: originalSequence, property: property,
                materializePicks: materializePicks
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
                prngSalt: prngSalt
            )
        }
    }

    // MARK: - Decode Implementations

    private func decodeExact<Output>(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        fallbackTree: ChoiceTree,
        originalSequence _: ChoiceSequence,
        property: (Output) -> Bool,
        materializePicks: Bool
    ) -> ReductionResult<Output>? {
        switch ReductionMaterializer.materialize(
            gen, prefix: consume candidate,
            mode: .exact, fallbackTree: fallbackTree,
            materializePicks: materializePicks
        ) {
        case let .success(output, freshTree, _):
            guard property(output) == false else { return nil }
            let freshSequence = ChoiceSequence(freshTree)
            return ReductionResult(
                sequence: freshSequence,
                tree: freshTree,
                output: output,
                evaluations: 1,
                decodingReport: nil
            )
        case .rejected, .failed:
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
        prngSalt: UInt64 = 0
    ) -> ReductionResult<Output>? {
        let seed = ZobristHash.hash(of: candidate) &+ prngSalt
        switch ReductionMaterializer.materialize(
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
        case .rejected, .failed:
            return nil
        }
    }

    // MARK: - Decoder Selection

    /// Decoder selection using ``ReductionMaterializer``-backed decoders.
    ///
    /// Simpler than the legacy path: the fresh materializer always produces a consistent
    /// (sequence, tree) pair, so the exact/guided distinction maps cleanly to value vs
    /// structural changes.
    public static func `for`(_ context: DecoderContext) -> SequenceDecoder {
        let hasBinds = context.bindIndex != nil
            && context.bindIndex?.isEmpty == false
        let picks = context.materializePicks

        switch context.depth {
        case .global:
            // Cross-stage redistribution: guided re-derivation handles both
            // inner and bound value changes uniformly.
            return .guided(fallbackTree: context.fallbackTree, materializePicks: picks)

        case .specific(0):
            if hasBinds || context.strictness == .relaxed {
                return .guided(fallbackTree: context.fallbackTree, materializePicks: picks)
            }
            return .exact(materializePicks: picks)

        case .specific:
            if context.strictness == .relaxed {
                return .guided(fallbackTree: context.fallbackTree, materializePicks: picks)
            }
            return .exact(materializePicks: picks)
        }
    }
}
