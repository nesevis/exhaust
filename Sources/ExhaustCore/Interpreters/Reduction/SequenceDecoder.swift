/// Materializes a candidate sequence and checks feasibility.
///
/// Selected by ``DecoderContext``, shared by all encoders at a given depth. This is the `dec` map from the paper. Implemented as a concrete enum to avoid heap allocation — decoder types carry associated data that exceeds Swift's three-word inline existential buffer.b
public enum SequenceDecoder {
    /// ``ReductionMaterializer`` exact mode. Produces a fresh tree with current `validRange` and
    /// all branch alternatives. Inner values are rejected if out-of-range; bound values are clamped.
    case exactFresh

    /// ``ReductionMaterializer`` guided mode. Produces a fresh tree with current `validRange` and
    /// all branch alternatives. Tiered resolution: prefix → fallback → PRNG. Cursor suspension
    /// at bind sites.
    case guidedFresh(fallbackTree: ChoiceTree?,
                     maximizeBoundRegionIndices: Set<Int>? = nil)

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
    ) throws -> ShrinkResult<Output>? {
        switch self {
        case .exactFresh:
            decodeExactFresh(
                candidate: consume candidate, gen: gen,
                fallbackTree: tree,
                originalSequence: originalSequence, property: property
            )

        case let .guidedFresh(fallbackTree, maximizeBoundRegionIndices):
            decodeGuidedFresh(
                candidate: consume candidate, gen: gen,
                fallbackTree: fallbackTree ?? tree,
                maximizeBoundRegionIndices: maximizeBoundRegionIndices,
                originalSequence: originalSequence, property: property
            )
        }
    }

    // MARK: - Decode Implementations

    private func decodeDirect<Output>(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        strictness: Interpreters.Strictness,
        property: (Output) -> Bool
    ) throws -> ShrinkResult<Output>? {
        guard let output = try? Interpreters.materialize(
            gen, with: tree, using: candidate, strictness: strictness
        ) else {
            return nil
        }
        guard property(output) == false else { return nil }
        return ShrinkResult(
            sequence: consume candidate,
            tree: tree,
            output: output,
            evaluations: 1
        )
    }

    private func decodeGuided<Output>(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        fallbackTree: ChoiceTree,
        strictness _: Interpreters.Strictness,
        maximizeBoundRegionIndices: Set<Int>? = nil,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool
    ) -> ShrinkResult<Output>? {
        let seed = ZobristHash.hash(of: candidate)
        switch GuidedMaterializer.materialize(gen, prefix: consume candidate, seed: seed, fallbackTree: fallbackTree, maximizeBoundRegionIndices: maximizeBoundRegionIndices) {
        case let .success(reDerivedOutput, reDerivedSequence, reDerivedTree):
            guard reDerivedSequence.shortLexPrecedes(originalSequence) else { return nil }
            guard property(reDerivedOutput) == false else { return nil }
            return ShrinkResult(
                sequence: reDerivedSequence,
                tree: reDerivedTree,
                output: reDerivedOutput,
                evaluations: 1
            )
        case .filterEncountered, .failed:
            return nil
        }
    }

    private func decodeCrossStage<Output>(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        bindIndex: BindSpanIndex,
        fallbackTree: ChoiceTree,
        strictness: Interpreters.Strictness,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool
    ) throws -> ShrinkResult<Output>? {
        // Check whether inner values changed. If only bound values were modified,
        // the strategy's values are authoritative — re-derivation would replace
        // carefully redistributed values with PRNG noise.
        let innerValuesChanged = bindIndex.regions.contains { region in
            region.innerRange.contains { idx in
                candidate[idx].shortLexCompare(originalSequence[idx]) != .eq
            }
        }

        if innerValuesChanged {
            return decodeGuided(
                candidate: consume candidate, gen: gen,
                fallbackTree: fallbackTree, strictness: strictness,
                originalSequence: originalSequence, property: property
            )
        } else {
            return try decodeDirect(
                candidate: consume candidate, gen: gen, tree: tree,
                strictness: strictness, property: property
            )
        }
    }

    // MARK: - Fresh Decode Implementations

    private func decodeExactFresh<Output>(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        fallbackTree: ChoiceTree,
        originalSequence _: ChoiceSequence,
        property: (Output) -> Bool
    ) -> ShrinkResult<Output>? {
        switch ReductionMaterializer.materialize(
            gen, prefix: consume candidate,
            mode: .exact, fallbackTree: fallbackTree
        ) {
        case let .success(output, freshTree):
            guard property(output) == false else { return nil }
            let freshSequence = ChoiceSequence(freshTree)
            return ShrinkResult(
                sequence: freshSequence,
                tree: freshTree,
                output: output,
                evaluations: 1
            )
        case .rejected, .failed:
            return nil
        }
    }

    private func decodeGuidedFresh<Output>(
        candidate: consuming ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        fallbackTree: ChoiceTree,
        maximizeBoundRegionIndices: Set<Int>? = nil,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool
    ) -> ShrinkResult<Output>? {
        let seed = ZobristHash.hash(of: candidate)
        switch ReductionMaterializer.materialize(
            gen, prefix: consume candidate,
            mode: .guided(seed: seed, fallbackTree: fallbackTree,
                          maximizeBoundRegionIndices: maximizeBoundRegionIndices)
        ) {
        case let .success(output, freshTree):
            let freshSequence = ChoiceSequence(freshTree)
            guard freshSequence.shortLexPrecedes(originalSequence) else { return nil }
            guard property(output) == false else { return nil }
            return ShrinkResult(
                sequence: freshSequence,
                tree: freshTree,
                output: output,
                evaluations: 1
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

        switch context.depth {
        case .global:
            // Cross-stage redistribution: guided re-derivation handles both
            // inner and bound value changes uniformly.
            return .guidedFresh(fallbackTree: context.fallbackTree)

        case .specific(0):
            if hasBinds || context.strictness == .relaxed {
                return .guidedFresh(fallbackTree: context.fallbackTree)
            }
            return .exactFresh

        case .specific:
            if context.strictness == .relaxed {
                return .guidedFresh(fallbackTree: context.fallbackTree)
            }
            return .exactFresh
        }
    }
}
