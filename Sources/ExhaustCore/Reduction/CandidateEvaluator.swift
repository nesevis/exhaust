/// Evaluates a candidate under the caller's admission policy without adopting it or changing the incumbent graph.
///
/// The cache lookup carries the decision context from the caller through decoding and recording. A missing lookup explicitly bypasses caching for relaxation.
enum CandidateEvaluator {
    /// Keeps cache hits distinct from decoded rejections so callers can report each without adopting either.
    enum Result {
        case cached
        case rejected(ReductionDecoding)
        case admitted(Counterexample, ReductionDecoding)
    }

    /// Records the terminal probe outcome once and caches every rejection when a lookup is supplied. Callers remain responsible for adopting and counting an admitted counterexample.
    ///
    /// Callers own emission and acceptance counts, deadline checks, and observations. They perform the cache lookup before calling, so lazy candidates can remain unwritten on a hit.
    ///
    /// - Parameters:
    ///   - admits: Whether a recovered counterexample satisfies the caller's policy.
    ///   - lookup: The cache's decision and precomputed hashes, or nil to bypass lookup and recording. Lazy callers may leave the candidate buffer unwritten on a hit.
    static func evaluate(
        _ candidate: ChoiceSequence,
        against incumbent: Counterexample,
        using selection: ReductionDecoder.Selection,
        decoder: ReductionDecoder,
        admits: (Counterexample) -> Bool,
        lookup: ProbeCache.Lookup?,
        cache: inout ProbeCache,
        counts: inout ReductionProbeCounts
    ) -> Result {
        if lookup?.isCached == true {
            counts.recordCacheRejection()
            return .cached
        }

        let decoding = decoder.decode(
            candidate,
            against: incumbent,
            selection: selection,
            precomputedHash: lookup?.probeHash
        )
        counts.recordOutcome(decoding.outcome)
        if let recovered = decoding.recovered, admits(recovered) {
            return .admitted(recovered, decoding)
        }
        if let lookup {
            cache.record(lookup, outcome: decoding.outcome)
        }
        return .rejected(decoding)
    }
}
