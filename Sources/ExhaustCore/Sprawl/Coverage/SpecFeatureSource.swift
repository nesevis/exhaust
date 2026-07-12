// Spec composition feedback (experiment: specFeatures): command-bigram feature edges beside the sancov edges.
//
// Edge coverage carries no gradient for state-gated spec faults — a streak-gated or accumulation fault lights no new edge as it progresses, so the corpus never preserves partial progress (measured: the SW2 postmortem and the ConsecutiveLatch negative control). This source appends virtual feature edges after the base range: one edge per ordered pair of command-fingerprint buckets, whose per-attempt hit count is how often that bigram occurs in the generated sequence. HitCountBucket's boundaries (1, 2, 3, 4–7, 8–15, …) then ladder composition counts for free — a same-command streak of 2, 3, 4, 5, and 9 each cross a bucket boundary, so the corpus admits partial progress toward faults that edge coverage cannot see. Design and gate: ExhaustDocs/spec-state-feedback-proposal.md.

/// Wraps a base coverage source with command-composition bigram features reported as virtual edges after the base range.
///
/// Fingerprints come from the caller (the spec adapter hashes each command's synthesized `description`, so the alphabet is argument-sensitive: `pulse(7)` and `pulse(3)` are distinct). They bucket modulo ``SprawlTunables/specFeatureAlphabet``; collisions merge bigrams the same way hit-count saturation merges counts, trading precision for a bounded table. Everything downstream — admission, rarity, champion archive, plateau — treats feature edges as ordinary edges because they enter through `edgeCount` and `forEachHitEdge`.
///
/// - Note: While the `specFeatures` experiment is default-off, the report's covered and instrumented edge counts include feature edges (accepted blur). Symbolization is unaffected: virtual indices have no PC-table entry and render as bare edge numbers.
package final class SpecFeatureSource: CoverageSource, @unchecked Sendable {
    // @unchecked: featureCounts is mutated only inside the attribution bracket, which the runner serialises with the attribution token; everything else is immutable after init.
    private let base: any CoverageSource
    private let alphabet: Int
    private let fingerprintCommands: @Sendable (Any) -> [UInt64]?
    private var featureCounts: [UInt8]

    package let edgeCount: Int

    package var wantsValues: Bool {
        true
    }

    /// Wraps `base` with an alphabet² bigram feature table.
    ///
    /// - Parameters:
    ///   - base: The real coverage source; its edges keep their indices.
    ///   - alphabet: The fingerprint bucket count. Feature edges number `alphabet * alphabet`.
    ///   - fingerprintCommands: Maps the generated value to one stable fingerprint per command, or nil when the value is not a command sequence. Fingerprints must be process-independent (see ``fingerprint(of:)``) or replay and crash-recovery resume would recompute different admissions.
    package init(
        base: any CoverageSource,
        alphabet: Int,
        fingerprintCommands: @escaping @Sendable (Any) -> [UInt64]?
    ) {
        self.base = base
        self.alphabet = max(1, alphabet)
        self.fingerprintCommands = fingerprintCommands
        featureCounts = Array(repeating: 0, count: self.alphabet * self.alphabet)
        edgeCount = base.edgeCount + featureCounts.count
    }

    package func beginAttempt() {
        for index in featureCounts.indices {
            featureCounts[index] = 0
        }
        base.beginAttempt()
    }

    package func noteValue(_ value: Any) {
        if base.wantsValues {
            base.noteValue(value)
        }
        guard let fingerprints = fingerprintCommands(value), fingerprints.count >= 2 else {
            return
        }
        var previousBucket = Int(fingerprints[0] % UInt64(alphabet))
        for fingerprint in fingerprints.dropFirst() {
            let bucket = Int(fingerprint % UInt64(alphabet))
            let slot = previousBucket * alphabet + bucket
            // Saturating, matching the sancov counters the corpus expects.
            if featureCounts[slot] < UInt8.max {
                featureCounts[slot] += 1
            }
            previousBucket = bucket
        }
    }

    package func forEachHitEdge(_ body: (_ edge: Int, _ hitCount: UInt8) -> Void) {
        base.forEachHitEdge(body)
        for slot in featureCounts.indices where featureCounts[slot] != 0 {
            body(base.edgeCount + slot, featureCounts[slot])
        }
    }

    /// FNV-1a over the text's UTF-8 bytes: the stable command fingerprint.
    ///
    /// Deliberately not `Hashable`: Swift's hasher is seeded per process, and a fingerprint that changes across processes would make crash-recovery resume and pinned-seed replay recompute different feature admissions.
    package static func fingerprint(of text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
