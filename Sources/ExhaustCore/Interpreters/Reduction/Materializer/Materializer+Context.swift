package extension Materializer.Context {
    /// Prepares a one-shot materialization without starting its execution deadline.
    ///
    /// Guided mode's embedded fallback takes precedence over `fallbackTree`. Exact mode retains fallback structure for zip scoping, but values still come from the prefix. A fresh context is required for every tree, value-only or flat replay.
    ///
    /// - Parameters:
    ///   - prefix: The owned choice sequence to replay.
    ///   - mode: Choice resolution policy and, for guided replay, its seed.
    ///   - fallbackTree: Root fallback when the mode does not provide one.
    ///   - materializePicks: Whether tree emission includes unselected alternatives. Must be false for flat emission.
    ///   - precomputedSeed: Avoids hashing the prefix for exact replay with pick materialization. Guided mode uses its own seed.
    ///   - skipTree: Disables tree allocation for value-only replay. Flat replay enables this automatically.
    ///   - collectDecodingReport: Allocates resolution diagnostics when true.
    ///   - shouldUseMaximumDepthForScreening: Pins guided structural depth controls to their size-feasible upper bounds; exact replay remains prefix-driven.
    ///   - reseedRanges: Ordered, disjoint prefix spans to regenerate during guided replay.
    init(
        prefix: consuming ChoiceSequence,
        mode: Materializer.Mode,
        fallbackTree: ChoiceTree? = nil,
        materializePicks: Bool = false,
        precomputedSeed: UInt64? = nil,
        skipTree: Bool = false,
        collectDecodingReport: Bool = true,
        shouldUseMaximumDepthForScreening: Bool = false,
        reseedRanges: [ClosedRange<Int>] = []
    ) {
        let seed: UInt64
        let resolvedFallbackTree: ChoiceTree?
        let maximizeBoundRegionIndices: Set<Int>?
        switch mode {
            case .exact:
                // Without alternative materialization exact replay never needs randomness, so skip the prefix hash.
                seed = precomputedSeed ?? (materializePicks ? ZobristHash.hash(of: prefix) : 0)
                resolvedFallbackTree = fallbackTree
                maximizeBoundRegionIndices = nil
            case let .guided(guidedSeed, guidedFallback, indices):
                seed = guidedSeed
                resolvedFallbackTree = guidedFallback ?? fallbackTree
                maximizeBoundRegionIndices = indices
        }
        self.init(
            rootFallbackTree: resolvedFallbackTree,
            cursor: Materializer.Cursor(from: consume prefix),
            prng: Xoshiro256(seed: seed),
            mode: mode.internalMode,
            // Replay uses full-size ranges unless an enclosing resize overrides them.
            size: 100,
            maximizeBoundRegionIndices: maximizeBoundRegionIndices,
            materializePicks: materializePicks,
            shouldUseMaximumDepthForScreening: shouldUseMaximumDepthForScreening,
            skipTree: skipTree,
            decodingReport: collectDecodingReport ? DecodingReport() : nil,
            reseedRanges: reseedRanges,
            hasPendingReseed: reseedRanges.isEmpty == false
        )
    }
}
