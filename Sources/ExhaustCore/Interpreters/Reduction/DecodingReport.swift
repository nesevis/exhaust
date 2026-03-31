/// Resolution tier for a single coordinate in the canonical cartesian lift.
///
/// Ordered from highest fidelity (exact carry-forward from the prefix) to lowest (PRNG fallback).
/// The raw value encodes this ordering for use in ``DecodingReport/fidelity``.
public enum ResolutionTier: UInt8, Sendable {
    /// Value carried forward unchanged from the prefix — the canonical lift.
    case exactCarryForward = 0
    /// Value resolved from the fallback tree (clamped to the new domain).
    case fallbackTree = 1
    /// Value generated from PRNG — no prefix or fallback data available.
    case prng = 2
}

/// Diagnostics collected during a single materialization pass.
///
/// Tracks per-coordinate resolution tier counts (how closely the canonical lift preserved the original value assignment) and per-fingerprint filter predicate observations. Resolution tier data is meaningful for guided mode; filter observations are populated in both exact and guided modes.
public struct DecodingReport: Sendable {
    private var exactCarryForwardCount = 0
    private var fallbackTreeCount = 0
    private var prngCount = 0

    /// Records that one coordinate was resolved at the given tier.
    mutating func record(tier: ResolutionTier) {
        switch tier {
        case .exactCarryForward:
            exactCarryForwardCount += 1
        case .fallbackTree:
            fallbackTreeCount += 1
        case .prng:
            prngCount += 1
        }
    }

    /// Total number of coordinates resolved across all tiers.
    var totalCount: Int {
        exactCarryForwardCount + fallbackTreeCount + prngCount
    }

    /// Weighted fidelity score in `[0, 1]`.
    ///
    /// Exact carry-forward scores 1.0, fallback tree scores 0.5, PRNG scores 0.0. Returns 0.0
    /// when no coordinates have been recorded (empty lift).
    var fidelity: Double {
        let total = totalCount
        guard total > 0 else { return 0.0 }
        let score = Double(exactCarryForwardCount) + 0.5 * Double(fallbackTreeCount)
        return score / Double(total)
    }

    /// Fraction of coordinates resolved from any data source (prefix or fallback tree) rather
    /// than blind PRNG.
    ///
    /// Together with ``fidelity``, forms a sufficient statistic for the full tier distribution:
    /// - Exact fraction: `2 * fidelity - coverage`.
    /// - Fallback fraction: `2 * (coverage - fidelity)`.
    /// - PRNG fraction: `1 - coverage`.
    ///
    /// Returns 0.0 when no coordinates have been recorded.
    var coverage: Double {
        let total = totalCount
        guard total > 0 else { return 0.0 }
        return Double(exactCarryForwardCount + fallbackTreeCount) / Double(total)
    }

    /// Minimum coverage required for a convergence point to be considered reliable enough to cache.
    ///
    /// Below this threshold, too many coordinates were resolved via PRNG for the convergence outcome
    /// to be reproducible — a different seed could yield a different result. Empirically, structural-phase
    /// probes land at 0.167–0.250 while stable value-phase probes reach 1.0, so 0.9 cleanly separates
    /// the two regimes.
    static let convergenceCacheCoverageThreshold: Double = 0.9

    /// Whether this materialization's coverage is high enough for convergence points to be cached.
    var isReliableForConvergenceCache: Bool {
        coverage >= Self.convergenceCacheCoverageThreshold
    }

    /// Per-fingerprint filter predicate observations accumulated during this materialization.
    var filterObservations: [UInt64: FilterObservation] = [:]
}
