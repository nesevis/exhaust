/// Resolution tier for a single coordinate during guided materialization.
///
/// Ordered from highest fidelity (exact carry-forward from the prefix) to lowest (PRNG fallback).
/// The raw value encodes this ordering for use in ``DecodingReport/fidelity``.
package enum ResolutionTier: UInt8, Sendable {
    /// Value carried forward unchanged from the prefix.
    case exactCarryForward = 0
    /// Value resolved from the fallback tree (clamped to the new domain).
    case fallbackTree = 1
    /// Value generated from PRNG — no prefix or fallback data available.
    case prng = 2
    /// Drawn fresh from the PRNG on purpose, at a site a value reseed marked: the caller asked for this draw, so it counts as resolved rather than as a fall-through.
    case reseeded = 3
}

/// Diagnostics collected during a single materialization pass.
///
/// Source provenance and filter observations are collected in both exact and guided modes. Per-coordinate resolution tier counts describe guided fidelity only: they track the surviving attempt, while sources retain dependencies from discarded attempts as well.
package struct DecodingReport: Sendable {
    /// Accumulates dependencies across the whole walk, even when fidelity counts are rolled back after a discarded attempt.
    package private(set) var sources: MaterializationSources

    /// Unobserved reports start with unknown dependencies; a materializer that records resolutions starts with an empty set.
    init(sources: MaterializationSources = .unknown) {
        self.sources = sources
    }

    /// Separates scalar fidelity accounting from structural dependencies and conservative uncertainty.
    enum Resolution {
        case scalar(ResolutionTier)
        /// Structural choices contribute provenance without increasing the scalar count.
        case branch(MaterializationSources)
        case length(MaterializationSources)
        case zipBoundary(MaterializationSources)
        /// Screening pins depth to policy's maximum rather than reading the prefix.
        case maximumScreeningDepth
        /// Discarded arms can influence the surviving branch and PRNG stream.
        case audition
        /// A rejected attempt consumes randomness before the surviving attempt.
        case filterRetry
        /// Explicit reseeding deliberately ignores part of the prefix.
        case reseed
    }

    /// Records structural inputs and uncertainty alongside scalar provenance, so fidelity alone never certifies cache reuse.
    mutating func recordResolution(_ resolution: Resolution) {
        switch resolution {
            case let .scalar(tier):
                record(tier: tier)
            case let .branch(sources), let .length(sources), let .zipBoundary(sources):
                record(sources: sources)
            case .maximumScreeningDepth:
                record(sources: .screeningPolicy)
            case .audition, .filterRetry, .reseed:
                record(sources: .unknown)
        }
    }

    /// Keeps dependencies monotonic even when a discarded attempt's scalar counts are restored.
    mutating func record(sources: MaterializationSources) {
        self.sources.formUnion(sources)
    }

    private var exactCarryForwardCount = 0
    private var fallbackTreeCount = 0
    private var prngCount = 0
    private var reseededCount = 0

    /// Records each scalar's source as well as its fidelity tier; reseeded draws remain distinguishable in fidelity diagnostics.
    mutating func record(tier: ResolutionTier) {
        switch tier {
            case .exactCarryForward:
                sources.insert(.prefix)
                exactCarryForwardCount += 1
            case .fallbackTree:
                sources.insert(.fallbackTree)
                fallbackTreeCount += 1
            case .prng:
                sources.insert(.prng)
                prngCount += 1
            case .reseeded:
                sources.insert(.prng)
                reseededCount += 1
        }
    }

    /// Total number of coordinates resolved across all tiers.
    package var totalCount: Int {
        exactCarryForwardCount + fallbackTreeCount + prngCount + reseededCount
    }

    /// Coordinates drawn afresh inside a reseeded span. A reseed that was asked for and left this at zero carried its span forward instead.
    package var reseededResolutionCount: Int {
        reseededCount
    }

    /// Coordinates resolved from the fallback tree. The filter retry gate reads the delta to detect row-identity consumption, which must stay single-shot.
    var fallbackResolutionCount: Int {
        fallbackTreeCount
    }

    /// Weighted fidelity score in `[0, 1]`.
    ///
    /// Exact carry-forward scores 1.0, fallback tree scores 0.5, PRNG scores 0.0. Returns 0.0 when no coordinates have been recorded (empty lift).
    package var fidelity: Double {
        let total = totalCount
        guard total > 0 else {
            return 0.0
        }
        let score = Double(exactCarryForwardCount) + 0.5 * Double(fallbackTreeCount)
        return score / Double(total)
    }

    /// Fraction of coordinates resolved from any data source (prefix or fallback tree) rather than blind PRNG.
    ///
    /// Together with ``fidelity``, forms a sufficient statistic for the full tier distribution:
    /// - Exact fraction: `2 * fidelity - convergence`.
    /// - Fallback fraction: `2 * (convergence - fidelity)`.
    /// - PRNG fraction: `1 - convergence`.
    ///
    /// Returns 0.0 when no coordinates have been recorded.
    package var convergence: Double {
        let total = totalCount
        guard total > 0 else {
            return 0.0
        }
        return Double(exactCarryForwardCount + fallbackTreeCount + reseededCount) / Double(total)
    }

    /// Minimum convergence required for a convergence point to be considered reliable enough to cache.
    ///
    /// Below this threshold, too many coordinates were resolved via PRNG for the convergence outcome to be reproducible — a different seed could yield a different result. Empirically, structural-phase probes land at 0.167–0.250 while stable value-phase probes reach 1.0, so 0.9 cleanly separates the two regimes.
    static let convergenceCacheThreshold: Double = 0.9

    /// Whether this materialization's convergence is high enough for convergence points to be cached.
    var isReliableForConvergenceCache: Bool {
        convergence >= Self.convergenceCacheThreshold
    }

    /// Per-fingerprint filter predicate observations accumulated during this materialization. Package so the spec screening row loop can read them off failed rows.
    package var filterObservations: [UInt64: FilterObservation] = [:]
}
