//
//  GenerationContext.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/2/2026.
//

/// Holds the mutable state for a single generation pass: PRNG, size parameter, filter observations, and choice tree construction metadata.
package struct GenerationContext: ~Copyable {
    // MARK: - Constants

    /// Maximum number of property invocations for this run.
    package let maxRuns: UInt64
    /// Seed used to derive per-run PRNG states.
    package let baseSeed: UInt64
    /// Maximum number of filter retry attempts before giving up on a single value.
    package static let maxFilterRuns: UInt64 = 500

    // MARK: - Mutable generation state

    /// Whether this context produces a fixed (non-random) value.
    package var isFixed: Bool
    /// Current size parameter controlling generator complexity scaling.
    package var size: UInt64
    /// When set, overrides the cycling size parameter for all generators.
    package var sizeOverride: UInt64?
    /// Pseudorandom number generator driving value generation.
    package var prng: Xoshiro256

    // MARK: - Caches

    /// CGS-tuned filter generators for bind-inner filters, keyed by source-location fingerprint. Populated on first encounter when ``Gen/isInterpreting`` caused the filter to defer eager tuning.
    package var tunedFilterCache: [UInt64: AnyGenerator] = [:]
    /// Seen keys for `unique(by:)` deduplication, keyed by site fingerprint.
    package var uniqueSeenKeys: [UInt64: Set<AnyHashable>] = [:]
    /// Seen choice sequences for `unique()` deduplication, keyed by site fingerprint.
    package var uniqueSeenSequences: [UInt64: Set<ChoiceSequence>] = [:]

    /// Per-fingerprint filter predicate pass/fail observations.
    package var filterObservations: [UInt64: FilterObservation] = [:]

    // MARK: - VACTI/CGS tracking

    /// Whether to record materialized pick metadata in the choice tree.
    package var materializePicks: Bool = false
    /// Number of property invocations completed so far.
    package var runs: UInt64 = 0
    /// Per-site classification label sets, keyed by site fingerprint then label string.
    package var classifications: [UInt64: [String: Set<UInt64>]] = [:]

    // MARK: - Jump

    /// Returns a new context sharing this context's configuration but with a fresh PRNG seeded from the given value.
    package func jump(seed: UInt64) -> GenerationContext {
        GenerationContext(
            maxRuns: maxRuns,
            baseSeed: baseSeed,
            isFixed: isFixed,
            size: size,
            prng: .init(seed: seed),
            materializePicks: materializePicks,
            runs: runs
        )
    }

    // MARK: - Classifications

    /// Logs all accumulated classification counts to the generation log category.
    package func printClassifications() {
        for (_, classifications) in classifications {
            ExhaustLog.info(
                category: .generation,
                event: "classifications_summary"
            )
            for (label, runs) in classifications {
                ExhaustLog.info(
                    category: .generation,
                    event: "classification_count",
                    metadata: [
                        "label": label,
                        "count": "\(runs.count)",
                    ]
                )
            }
        }
    }

    // MARK: - Cycling size (1–100, independent of maxRuns)

    /// Returns the size parameter for a given run index, cycling through 1 to 100 independently of ``maxRuns``.
    package static func scaledSize(forRun runIndex: UInt64) -> UInt64 {
        (runIndex % 100) + 1
    }
}
