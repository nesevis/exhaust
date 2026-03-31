//
//  GenerationContext.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/2/2026.
//

public struct GenerationContext: ~Copyable {
    // Constants
    public let maxRuns: UInt64
    public let baseSeed: UInt64
    public static let maxFilterRuns: UInt64 = 500

    // Mutable generation state
    public var isFixed: Bool
    public var size: UInt64
    public var sizeOverride: UInt64?
    public var prng: Xoshiro256

    // Caches
    public var tunedFilterCache: [UInt64: ReflectiveGenerator<Any>] = [:]
    public var uniqueSeenKeys: [UInt64: Set<AnyHashable>] = [:]
    public var uniqueSeenSequences: [UInt64: Set<ChoiceSequence>] = [:]

    // Filter observation tracking
    public var filterObservations: [UInt64: FilterObservation] = [:]

    // VaCT/CGS tracking (harmless defaults for ValueInterpreter)
    public var materializePicks: Bool = false
    public var runs: UInt64 = 0
    public var classifications: [UInt64: [String: Set<UInt64>]] = [:]

    /// Tracks how many pick operations deep the interpreter has descended.
    /// Combined with the base siteID to disambiguate recursive generator depths.
    public var pickDepth: UInt64 = 0

    // MARK: - Jump

    public func jump(seed: UInt64) -> GenerationContext {
        var jumped = GenerationContext(
            maxRuns: maxRuns,
            baseSeed: baseSeed,
            isFixed: isFixed,
            size: size,
            prng: .init(seed: seed),
            materializePicks: materializePicks,
            runs: runs
        )
        jumped.pickDepth = pickDepth
        return jumped
    }

    // MARK: - Classifications

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

    public static func scaledSize(forRun runIndex: UInt64) -> UInt64 {
        (runIndex % 100) + 1
    }

    // MARK: - Per-run seed derivation (SplitMix64 mixing)

    // FIXME: Xoshiro features this
    public static func runSeed(base: UInt64, runIndex: UInt64) -> UInt64 {
        var z = base &+ runIndex &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
}
