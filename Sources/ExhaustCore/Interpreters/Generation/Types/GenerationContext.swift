//
//  GenerationContext.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/2/2026.
//

package struct GenerationContext: ~Copyable {
    // MARK: - Constants

    /// Maximum number of property invocations for this run.
    public let maxRuns: UInt64
    /// Seed used to derive per-run PRNG states.
    public let baseSeed: UInt64
    /// Maximum number of filter retry attempts before giving up on a single value.
    public static let maxFilterRuns: UInt64 = 500

    // MARK: - Mutable generation state

    /// Whether this context produces a fixed (non-random) value.
    public var isFixed: Bool
    /// Current size parameter controlling generator complexity scaling.
    public var size: UInt64
    /// When set, overrides the cycling size parameter for all generators.
    public var sizeOverride: UInt64?
    /// Pseudorandom number generator driving value generation.
    public var prng: Xoshiro256

    // MARK: - Caches

    /// Cache of CGS-tuned filter generators, keyed by fingerprint.
    public var tunedFilterCache: [UInt64: ReflectiveGenerator<Any>] = [:]
    /// Seen keys for `unique(by:)` deduplication, keyed by site fingerprint.
    public var uniqueSeenKeys: [UInt64: Set<AnyHashable>] = [:]
    /// Seen choice sequences for `unique()` deduplication, keyed by site fingerprint.
    public var uniqueSeenSequences: [UInt64: Set<ChoiceSequence>] = [:]

    /// Per-fingerprint filter predicate pass/fail observations.
    public var filterObservations: [UInt64: FilterObservation] = [:]

    // MARK: - VACTI/CGS tracking

    /// Whether to record materialized pick metadata in the choice tree.
    public var materializePicks: Bool = false
    /// Number of property invocations completed so far.
    public var runs: UInt64 = 0
    /// Per-site classification label sets, keyed by site fingerprint then label string.
    public var classifications: [UInt64: [String: Set<UInt64>]] = [:]

    // MARK: - Jump

    /// Returns a new context sharing this context's configuration but with a fresh PRNG seeded from the given value.
    public func jump(seed: UInt64) -> GenerationContext {
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
    public func printClassifications() {
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
    public static func scaledSize(forRun runIndex: UInt64) -> UInt64 {
        (runIndex % 100) + 1
    }

    // MARK: - Per-run seed derivation (SplitMix64 mixing)

    /// Derives a deterministic per-run seed from a base seed and run index using SplitMix64 mixing.
    // FIXME: Xoshiro features this
    public static func runSeed(base: UInt64, runIndex: UInt64) -> UInt64 {
        var z = base &+ runIndex &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
}
