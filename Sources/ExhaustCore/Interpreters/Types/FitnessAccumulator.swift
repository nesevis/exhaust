//
//  FitnessAccumulator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

/// Collects per-site, per-choice fitness data during tuning runs.
/// Reference semantics so the accumulator is shared across recursive calls.
public final class FitnessAccumulator {
    public struct SiteChoiceKey: Hashable {
        public let siteID: UInt64
        public let choiceID: UInt64
    }

    public struct FitnessRecord {
        public var totalFitness: UInt64 = 0
        public var observationCount: UInt64 = 0
    }

    public private(set) var records: [SiteChoiceKey: FitnessRecord] = [:]

    public init() {}

    public func record(siteID: UInt64, choiceID: UInt64, fitness: UInt64, observations: UInt64) {
        let key = SiteChoiceKey(siteID: siteID, choiceID: choiceID)
        records[key, default: FitnessRecord()].totalFitness += fitness
        records[key, default: FitnessRecord()].observationCount += observations
    }

    // MARK: - Convergence Detection

    /// Previous normalized weight shares per site, captured at the last `hasConverged` call. Compared to the current snapshot to detect stability.
    private var previousSiteShares: [UInt64: [UInt64: Double]]?

    /// Checks if the normalized weight distribution has stabilized across all observed pick sites. Computes current shares and compares to the previous snapshot; returns `true` when the maximum absolute shift across all sites and choices is below `threshold`.
    ///
    /// Each call captures a new snapshot, so call at regular intervals (e.g., every 20 warmup runs) rather than on every run.
    public func hasConverged(threshold: Double = 0.05) -> Bool {
        // Group records by siteID
        var siteFitnesses: [UInt64: ContiguousArray<(choiceID: UInt64, fitness: Double)>] = [:]
        for (key, record) in records {
            siteFitnesses[key.siteID, default: []].append((key.choiceID, Double(record.totalFitness)))
        }

        // Compute current normalized shares per site
        var currentShares: [UInt64: [UInt64: Double]] = [:]
        for (siteID, choices) in siteFitnesses {
            let total = choices.reduce(0.0) { $0 + $1.fitness }
            guard total > 0 else { continue }
            var shares: [UInt64: Double] = [:]
            for (choiceID, fitness) in choices {
                shares[choiceID] = fitness / total
            }
            currentShares[siteID] = shares
        }

        defer { previousSiteShares = currentShares }

        // First snapshot — can't compare yet
        guard let previous = previousSiteShares, !currentShares.isEmpty else { return false }

        for (siteID, shares) in currentShares {
            // New site not in previous snapshot — not converged
            guard let prevShares = previous[siteID] else { return false }
            for (choiceID, share) in shares {
                if abs(share - (prevShares[choiceID] ?? 0)) > threshold { return false }
            }
        }
        return true
    }
}
