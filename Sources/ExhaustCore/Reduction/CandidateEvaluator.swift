/// Evaluates a candidate under the caller's admission policy without adopting it or changing the incumbent graph.
///
/// Cache keys and bypass decisions remain caller-owned because a rejection under one policy need not answer for another.
enum CandidateEvaluator {
    enum Result {
        case cached
        case rejected(ReductionDecoding)
        case admitted(Counterexample, ReductionDecoding)
    }

    /// Records the terminal probe outcome once and caches every rejection when a key is supplied. Admission does not record acceptance: confirmation may use a failure as evidence without committing it.
    ///
    /// Callers own emission and acceptance counts, deadline checks, and observations. They perform the cache lookup before calling, so lazy candidates can remain unwritten on a hit.
    ///
    /// - Parameters:
    ///   - admits: Whether a recovered counterexample satisfies the caller's policy.
    ///   - cacheHit: The caller's lookup result, or false when bypassing the cache or when a cursor has already established a miss.
    ///   - cacheKey: The rejection key, or nil to bypass insertion. Relaxation bypasses both lookup and insertion when trying perturbations rejected under ordinary reduction.
    ///   - probeHash: The candidate's precomputed hash, when already available.
    static func evaluate(
        _ candidate: ChoiceSequence,
        against incumbent: Counterexample,
        using selection: ReductionDecoder.Selection,
        decoder: ReductionDecoder,
        admits: (Counterexample) -> Bool,
        probeHash: UInt64? = nil,
        cacheHit: Bool,
        cacheKey: UInt64?,
        cache: inout ProbeCache,
        counts: inout ReductionProbeCounts
    ) -> Result {
        if cacheHit {
            counts.recordCacheRejection()
            return .cached
        }

        let decoding = decoder.decode(candidate, against: incumbent, selection: selection, precomputedHash: probeHash)
        counts.recordOutcome(decoding.outcome)
        if let recovered = decoding.recovered, admits(recovered) {
            return .admitted(recovered, decoding)
        }
        if let cacheKey {
            cache.insert(cacheKey)
        }
        return .rejected(decoding)
    }
}
