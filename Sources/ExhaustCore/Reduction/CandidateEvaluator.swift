/// Evaluates a candidate without adopting it or changing the incumbent graph.
///
/// A recovered failure is evidence for the caller: ordinary reduction may commit it, convergence confirmation may invalidate a floor, and relaxation may adopt it provisionally. Only outcomes without a recovered failure are cached here; rejecting a recovered failure under a caller's ordering policy remains that caller's responsibility.
enum CandidateEvaluator {
    /// Returns nil for a cached rejection, otherwise the decoder's result, recording the terminal probe outcome exactly once.
    ///
    /// Callers own emission and admission counts, deadline checks, and observations. They can discard cached candidates before emission, interrupt an emitted probe, or use a recovered failure without adopting it.
    ///
    /// Callers with lazy candidates may leave their candidate buffer unwritten on a cache hit: it is read only after the cache lookup.
    ///
    /// - Parameters:
    ///   - cacheKey: The key for this candidate, decoder selection, and incumbent. Nil bypasses both cache lookup and insertion, as relaxation requires when trying perturbations rejected under ordinary reduction.
    ///   - probeHash: The candidate's precomputed hash, when already available.
    static func evaluate(
        _ candidate: ChoiceSequence,
        against incumbent: Counterexample,
        using selection: ReductionDecoder.Selection,
        decoder: ReductionDecoder,
        probeHash: UInt64? = nil,
        cacheKey: UInt64?,
        cache: inout ProbeCache,
        counts: inout ReductionProbeCounts
    ) -> ReductionDecoding? {
        if let cacheKey, cache.contains(cacheKey) {
            counts.recordCacheRejection()
            return nil
        }

        let decoding = decoder.decode(candidate, against: incumbent, selection: selection, precomputedHash: probeHash)
        counts.recordOutcome(decoding.outcome)
        if decoding.recovered == nil, let cacheKey {
            cache.insert(cacheKey)
        }
        return decoding
    }
}
