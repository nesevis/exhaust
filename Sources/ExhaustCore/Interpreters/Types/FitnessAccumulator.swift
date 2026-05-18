//
//  FitnessAccumulator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

/// Collects per-site, per-choice fitness data during tuning runs.
/// Reference semantics so the accumulator is shared across recursive calls.
///
/// - SeeAlso: ``FilterObservation`` (per-filter-site predicate satisfaction), ``CoOccurrenceMatrix`` (per-direction pairwise membership), ``ClassificationExploreRunner`` (per-direction hit tracking). These types accumulate empirical observations about different dimensions of the generator's output space — choice-level fitness, filter validity, and directional coverage — using the same count-based accumulation pattern.
package final class FitnessAccumulator {
    /// Identifies a specific choice at a specific pick site.
    public struct SiteChoiceKey: Hashable {
        /// The pick site's fingerprint.
        public let fingerprint: UInt64
        /// The branch identifier within the pick site.
        public let choiceID: UInt64
    }

    /// Accumulated fitness statistics for a single site-choice pair.
    public struct FitnessRecord {
        /// Sum of fitness values observed for this choice.
        public var totalFitness: UInt64 = 0
        /// Number of observations recorded for this choice.
        public var observationCount: UInt64 = 0
    }

    /// All accumulated records, keyed by site-choice pair.
    public private(set) var records: [SiteChoiceKey: FitnessRecord] = [:]

    /// Creates an empty accumulator.
    public init() {}

    /// Records a fitness observation for the given site and choice.
    public func record(fingerprint: UInt64, choiceID: UInt64, fitness: UInt64, observations: UInt64) {
        let key = SiteChoiceKey(fingerprint: fingerprint, choiceID: choiceID)
        records[key, default: FitnessRecord()].totalFitness += fitness
        records[key, default: FitnessRecord()].observationCount += observations
    }

    // MARK: - Convergence Detection

    /// Previous normalized weight shares per site, captured at the last `hasConverged` call. Compared to the current snapshot to detect stability.
    private var previousSiteShares: [UInt64: [UInt64: Double]]?

    /// Checks if the normalized weight distribution has stabilized across all observed pick sites. Computes current shares and compares to the previous snapshot; returns `true` when the maximum absolute shift across all sites and choices is below `threshold`.
    ///
    /// Each call captures a new snapshot, so call at regular intervals (for example, every 20 warmup runs) rather than on every run.
    public func hasConverged(threshold: Double = 0.05) -> Bool {
        // Group records by fingerprint
        var siteFitnesses: [UInt64: ContiguousArray<(choiceID: UInt64, fitness: Double)>] = [:]
        for (key, record) in records {
            siteFitnesses[key.fingerprint, default: []].append((key.choiceID, Double(record.totalFitness)))
        }

        // Compute current normalized shares per site
        var currentShares: [UInt64: [UInt64: Double]] = [:]
        for (fingerprint, choices) in siteFitnesses {
            let total = choices.reduce(0.0) { $0 + $1.fitness }
            guard total > 0 else { continue }
            var shares: [UInt64: Double] = [:]
            for (choiceID, fitness) in choices {
                shares[choiceID] = fitness / total
            }
            currentShares[fingerprint] = shares
        }

        defer { previousSiteShares = currentShares }

        // First snapshot — can't compare yet
        guard let previous = previousSiteShares, !currentShares.isEmpty else { return false }

        for (fingerprint, shares) in currentShares {
            guard let prevShares = previous[fingerprint] else { return false }
            for (choiceID, share) in shares where abs(share - (prevShares[choiceID] ?? 0)) > threshold {
                return false
            }
        }
        return true
    }
}
