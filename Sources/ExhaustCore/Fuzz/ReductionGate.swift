// Backpressure between failure discovery and reduction.
//
// Densification deliberately steers the mutation phase back into failing regions, so a hot fault produces
// failures at a high rate; reducing every failure inline would let reduction outconsume exploration.
// The gate's dedup and per-symptom cap bound how many failures earn a reduction's cost.

/// Decides, on the exploration loop, whether a failure earns a reduction.
package struct ReductionGate {
    /// The gate's verdict for one failure.
    package enum Verdict: Equatable {
        /// Reduce this failure. `escape` marks an admission that went through the capped symptom's escape hatch, so the caller can feed the classification outcome back into the adaptive interval.
        case reduce(escape: Bool)
        /// Record the failure as an unreduced cluster member; its symptom's cap is reached.
        case recordUnreduced
        /// A failure with an identical choice sequence was already admitted; drop it entirely.
        case duplicate
    }

    private var dispatchedHashes: Set<UInt64> = []
    private var dispatchedCountsBySymptom: [FailureSymptom: Int] = [:]
    private var seenCountsBySymptom: [FailureSymptom: Int] = [:]

    // MARK: - Adaptive Escape State (Experiment: escapeBackoff)

    // The fixed every-K-th escape reduces forever on a saturated symptom: at fuzzing volume that is thousands of redundant reductions whose only novel output is stalled-reduction residuals. The adaptive interval widens geometrically while escapes keep confirming the known cluster and snaps back the moment one discovers something new, preserving the insurance the hatch exists for. The anchor is the seen count at the last escape (or the first capped failure), so an interval change from ``noteEscapeOutcome(symptom:isNewCluster:)`` applies to the very next scheduling decision.
    private var escapeIntervalsBySymptom: [FailureSymptom: Int] = [:]
    private var escapeAnchorsBySymptom: [FailureSymptom: Int] = [:]

    private let experiments: FuzzExperiments

    package init(experiments: FuzzExperiments = FuzzExperiments()) {
        self.experiments = experiments
    }

    /// Evaluates one failure. Mutates the gate's counters according to the verdict, so call exactly once per failure.
    ///
    /// The per-symptom cap uses *admitted* counts as a proxy for the cluster's reduced count — a symptom does not map one-to-one onto a cluster, so the true per-cluster count is not addressable from here. Symptom matching is exactly the weak signal the inventory distrusts, so a capped symptom still escapes, bounding the risk of a genuinely new bug hiding behind a familiar symptom. With the `escapeBackoff` experiment off, the escape fires every fixed K-th seen failure. With it on, a coverage-novel failure escapes immediately — a new fault's first failing input necessarily lights edges nothing else has hit, so novelty is a far sharper new-bug signal than cadence — and the periodic fallback (for new bugs on already-covered paths) adapts through ``noteEscapeOutcome(symptom:isNewCluster:)``.
    package mutating func admit(sequenceHash: UInt64, symptom: FailureSymptom, coverageNovel: Bool = false) -> Verdict {
        guard dispatchedHashes.contains(sequenceHash) == false else {
            return .duplicate
        }
        seenCountsBySymptom[symptom, default: 0] += 1
        let dispatched = dispatchedCountsBySymptom[symptom, default: 0]
        var isEscape = false
        if dispatched >= FuzzTunables.perClusterReductionCap {
            let seen = seenCountsBySymptom[symptom, default: 0]
            if experiments.escapeBackoff {
                if coverageNovel {
                    escapeAnchorsBySymptom[symptom] = seen
                } else {
                    let interval = escapeIntervalsBySymptom[symptom] ?? FuzzTunables.reductionEscapeInterval
                    guard let anchor = escapeAnchorsBySymptom[symptom] else {
                        // First capped failure of this symptom anchors the schedule and declines.
                        escapeAnchorsBySymptom[symptom] = seen
                        return .recordUnreduced
                    }
                    guard seen >= anchor + interval else {
                        return .recordUnreduced
                    }
                    escapeAnchorsBySymptom[symptom] = seen
                }
            } else {
                guard seen % FuzzTunables.reductionEscapeInterval == 0 else {
                    return .recordUnreduced
                }
            }
            isEscape = true
        }
        dispatchedHashes.insert(sequenceHash)
        dispatchedCountsBySymptom[symptom, default: 0] = dispatched + 1
        return .reduce(escape: isEscape)
    }

    /// Feeds an escape reduction's classification back into the symptom's interval: confirmation of a known cluster doubles it (capped), a new cluster resets it to the base interval. The updated interval applies from the next admission — the anchor-based schedule holds no precomputed deadline to go stale.
    package mutating func noteEscapeOutcome(symptom: FailureSymptom, isNewCluster: Bool) {
        guard experiments.escapeBackoff else {
            return
        }
        if isNewCluster {
            escapeIntervalsBySymptom[symptom] = FuzzTunables.reductionEscapeInterval
        } else {
            let current = escapeIntervalsBySymptom[symptom] ?? FuzzTunables.reductionEscapeInterval
            escapeIntervalsBySymptom[symptom] = min(current * 2, FuzzTunables.reductionEscapeIntervalCap)
        }
    }
}
