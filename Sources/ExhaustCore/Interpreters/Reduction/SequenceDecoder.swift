/// Materializes a candidate sequence and checks feasibility.
///
/// Selected by ``DecoderContext``, shared by all encoders at a given depth. This is the `dec` map from the paper. Implemented as a concrete enum to avoid heap allocation — decoder types carry associated data that exceeds Swift's three-word inline existential buffer.
///
/// ## Cases
///
/// - ``direct(strictness:)``: Tree-driven materialization. Exact — preserves the candidate exactly.
/// - ``guided(fallbackTree:strictness:)``: ``GuidedMaterializer`` with tiered resolution. Bounded — re-derivation can shift bound values, but the shortlex guard rejects regressions.
/// - ``crossStage(bindIndex:fallbackTree:strictness:)``: Per-candidate routing for cross-stage tactics (depth `.global`, binds present). Routes to direct if only bound values changed, guided if inner values changed.
public enum SequenceDecoder {
    /// Tree-driven materialization. Exact — preserves the candidate exactly.
    case direct(strictness: Interpreters.Strictness)

    /// ``GuidedMaterializer`` with tiered resolution. Bounded — re-derivation can shift bound values, but the shortlex guard rejects regressions.
    case guided(fallbackTree: ChoiceTree?, strictness: Interpreters.Strictness,
                maximizeBoundRegionIndices: Set<Int>? = nil)

    /// Per-candidate routing for cross-stage tactics. Routes to direct if only bound values changed, guided if inner values changed.
    case crossStage(bindIndex: BindSpanIndex, fallbackTree: ChoiceTree?, strictness: Interpreters.Strictness)

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
        candidate: ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool
    ) throws -> ShrinkResult<Output>? {
        switch self {
        case let .direct(strictness):
            return try decodeDirect(
                candidate: candidate, gen: gen, tree: tree,
                strictness: strictness, property: property
            )

        case let .guided(fallbackTree, strictness, maximizeBoundRegionIndices):
            return decodeGuided(
                candidate: candidate, gen: gen,
                fallbackTree: fallbackTree ?? tree, strictness: strictness,
                maximizeBoundRegionIndices: maximizeBoundRegionIndices,
                originalSequence: originalSequence, property: property
            )

        case let .crossStage(bindIndex, fallbackTree, strictness):
            return try decodeCrossStage(
                candidate: candidate, gen: gen, tree: tree,
                bindIndex: bindIndex, fallbackTree: fallbackTree ?? tree,
                strictness: strictness,
                originalSequence: originalSequence, property: property
            )

        case .exactFresh:
            return decodeExactFresh(
                candidate: candidate, gen: gen,
                fallbackTree: tree,
                originalSequence: originalSequence, property: property
            )

        case let .guidedFresh(fallbackTree, maximizeBoundRegionIndices):
            return decodeGuidedFresh(
                candidate: candidate, gen: gen,
                fallbackTree: fallbackTree ?? tree,
                maximizeBoundRegionIndices: maximizeBoundRegionIndices,
                originalSequence: originalSequence, property: property
            )
        }
    }

    // MARK: - Decode Implementations

    private func decodeDirect<Output>(
        candidate: ChoiceSequence,
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
            sequence: candidate,
            tree: tree,
            output: output,
            evaluations: 1
        )
    }

    private func decodeGuided<Output>(
        candidate: ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        fallbackTree: ChoiceTree,
        strictness: Interpreters.Strictness,
        maximizeBoundRegionIndices: Set<Int>? = nil,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool
    ) -> ShrinkResult<Output>? {
        let seed = ZobristHash.hash(of: candidate)
        switch GuidedMaterializer.materialize(gen, prefix: candidate, seed: seed, fallbackTree: fallbackTree, maximizeBoundRegionIndices: maximizeBoundRegionIndices) {
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
        candidate: ChoiceSequence,
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
                candidate: candidate, gen: gen,
                fallbackTree: fallbackTree, strictness: strictness,
                originalSequence: originalSequence, property: property
            )
        } else {
            return try decodeDirect(
                candidate: candidate, gen: gen, tree: tree,
                strictness: strictness, property: property
            )
        }
    }

    // MARK: - Fresh Decode Implementations

    private func decodeExactFresh<Output>(
        candidate: ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        fallbackTree: ChoiceTree,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool
    ) -> ShrinkResult<Output>? {
        switch ReductionMaterializer.materialize(
            gen, prefix: candidate,
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
        candidate: ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        fallbackTree: ChoiceTree,
        maximizeBoundRegionIndices: Set<Int>? = nil,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool
    ) -> ShrinkResult<Output>? {
        let seed = ZobristHash.hash(of: candidate)
        switch ReductionMaterializer.materialize(
            gen, prefix: candidate,
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

    /// Returns the appropriate decoder for a given context.
    ///
    /// One decoder per context means all encoders sharing a context share the same `dec`, forming a uniform hom-set.
    ///
    /// Two independent reasons trigger non-direct decoders:
    /// 1. Bind re-derivation (`.specific(0)`, binds present): inner value changes require bound
    ///    content to be re-derived via ``GuidedMaterializer``.
    /// 2. Cross-stage routing (`.global`, binds present): redistribution may or may not change
    ///    inner values — routing is per-candidate.
    ///
    /// Three independent reasons trigger non-direct decoders:
    /// 1. Bind re-derivation (`.specific(0)`, binds present): bound content must be re-derived after inner value changes.
    /// 2. Structural invalidity (`.relaxed` strictness): deletion invalidates the tree's positional mapping. ``GuidedMaterializer`` re-derives a consistent (sequence, tree) pair from the prefix.
    /// 3. Cross-stage routing (`.global`, binds present): redistribution may or may not change inner values — routing is per-candidate.
    ///
    /// Value reduction at depths > 0 always uses `.direct` — even with binds. These positions are
    /// bound values, and `.guided` would ignore candidate modifications via cursor suspension.
    public static func `for`(_ context: DecoderContext) -> SequenceDecoder {
        if context.useReductionMaterializer {
            return forFresh(context)
        }
        return forLegacy(context)
    }

    /// Decoder selection using ``ReductionMaterializer``-backed decoders.
    ///
    /// Simpler than the legacy path: the fresh materializer always produces a consistent
    /// (sequence, tree) pair, so the exact/guided distinction maps cleanly to value vs
    /// structural changes.
    private static func forFresh(_ context: DecoderContext) -> SequenceDecoder {
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

    /// Legacy decoder selection using `Interpreters.materialize()` and ``GuidedMaterializer``.
    private static func forLegacy(_ context: DecoderContext) -> SequenceDecoder {
        let hasBinds = context.bindIndex != nil
            && context.bindIndex?.isEmpty == false

        switch context.depth {
        case .global:
            if hasBinds {
                return .crossStage(
                    bindIndex: context.bindIndex!,
                    fallbackTree: context.fallbackTree,
                    strictness: context.strictness
                )
            }
            return .direct(strictness: context.strictness)

        case .specific(0):
            if hasBinds {
                return .guided(
                    fallbackTree: context.fallbackTree,
                    strictness: context.strictness
                )
            }
            // Deletion (.relaxed) invalidates the tree's positional mapping even
            // without binds. GuidedMaterializer rebuilds a consistent (sequence,
            // tree) pair and applies the shortlex guard. Without this, the .direct
            // decoder returns a stale tree, and the re-derivation in accept() can
            // produce a longer sequence than the deletion candidate.
            if context.strictness == .relaxed {
                return .guided(
                    fallbackTree: context.fallbackTree,
                    strictness: context.strictness
                )
            }
            return .direct(strictness: context.strictness)

        case .specific:
            // Depths > 0: deletion with binds needs guided re-derivation; value reduction
            if context.strictness == .relaxed {
                return .guided(
                    fallbackTree: context.fallbackTree,
                    strictness: context.strictness
                )
            }
            return .direct(strictness: context.strictness)
        }
    }
}
