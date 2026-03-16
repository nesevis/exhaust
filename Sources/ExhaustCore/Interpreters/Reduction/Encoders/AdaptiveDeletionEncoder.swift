/// Shared adaptive batch-deletion logic for all deletion encoders.
///
/// Uses ``FindIntegerStepper`` to binary-search for the largest contiguous batch of same-depth spans that can be deleted. Each concrete deletion encoder provides target filtering; this struct drives the probe loop.
struct AdaptiveDeletionEncoder {
    // MARK: - State

    private var sequence = ChoiceSequence()
    private var sortedSpans: [ChoiceSpan] = []
    private var spanIndex = 0
    private var maxBatch = 0
    private var stepper = FindIntegerStepper()
    private var needsNewGroup = true
    private var didEmitCandidate = false

    // MARK: - API

    /// Initializes the encoder with target spans (already filtered by the caller).
    mutating func start(sequence: ChoiceSequence, sortedSpans: [ChoiceSpan]) {
        self.sequence = sequence
        self.sortedSpans = sortedSpans
        spanIndex = 0
        needsNewGroup = true
        didEmitCandidate = false
    }

    /// Produces the next deletion candidate, or `nil` when all groups are exhausted.
    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        while spanIndex < sortedSpans.count {
            if needsNewGroup {
                maxBatch = 0
                let depth = sortedSpans[spanIndex].depth
                var j = spanIndex
                while j < sortedSpans.count, sortedSpans[j].depth == depth {
                    maxBatch += 1
                    j += 1
                }
                let firstProbe = stepper.start()
                needsNewGroup = false
                didEmitCandidate = false
                if let candidate = buildCandidate(batchSize: firstProbe) {
                    didEmitCandidate = true
                    return candidate
                }
            }

            // Use actual lastAccepted only if we emitted a candidate last time.
            // When buildCandidate returned nil, no probe was emitted,
            // so lastAccepted is stale — treat as rejection.
            let feedback = didEmitCandidate ? lastAccepted : false
            didEmitCandidate = false
            if let nextSize = stepper.advance(lastAccepted: feedback) {
                if let candidate = buildCandidate(batchSize: nextSize) {
                    didEmitCandidate = true
                    return candidate
                }
                continue
            }

            let accepted = stepper.bestAccepted
            spanIndex += accepted > 0 ? accepted : 1
            needsNewGroup = true
        }
        return nil
    }

    // MARK: - Helpers

    private func buildCandidate(batchSize: Int) -> ChoiceSequence? {
        guard batchSize > 0, batchSize <= maxBatch else { return nil }
        var rangeSet = RangeSet<Int>()
        var ii = 0
        while ii < batchSize {
            rangeSet.insert(contentsOf: sortedSpans[spanIndex + ii].range.asRange)
            ii += 1
        }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }
}
