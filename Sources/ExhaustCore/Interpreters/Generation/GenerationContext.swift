//
//  GenerationContext.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/2/2026.
//

struct GenerationContext {
    // Constants
    let maxRuns: UInt64
    let baseSeed: UInt64
    static let maxFilterRuns: UInt64 = 500

    // Mutable generation state
    var isFixed: Bool
    var size: UInt64
    var sizeOverride: UInt64?
    var prng: Xoshiro256

    // Caches
    var tunedFilterCache: [UInt64: ReflectiveGenerator<Any>] = [:]
    var uniqueSeenKeys: [UInt64: Set<AnyHashable>] = [:]
    var uniqueSeenSequences: [UInt64: Set<ChoiceSequence>] = [:]

    // VaCT/CGS tracking (harmless defaults for ValueInterpreter)
    var materializePicks: Bool = false
    var runs: UInt64 = 0
    var classifications: [UInt64: [String: Set<UInt64>]] = [:]

    // MARK: - Jump

    func jump(seed: UInt64) -> GenerationContext {
        GenerationContext(
            maxRuns: maxRuns,
            baseSeed: baseSeed,
            isFixed: isFixed,
            size: size,
            prng: .init(seed: seed),
            materializePicks: materializePicks,
            runs: runs,
        )
    }

    // MARK: - Classifications

    func printClassifications() {
        for (_, classifications) in classifications {
            ExhaustLog.info(
                category: .generation,
                event: "classifications_summary",
            )
            for (label, runs) in classifications {
                ExhaustLog.info(
                    category: .generation,
                    event: "classification_count",
                    metadata: [
                        "label": label,
                        "count": "\(runs.count)",
                    ],
                )
            }
        }
    }

    // MARK: - Cycling size (1–100, independent of maxRuns)

    static func scaledSize(forRun runIndex: UInt64) -> UInt64 {
        (runIndex % 100) + 1
    }

    // MARK: - Per-run seed derivation (SplitMix64 mixing)

    static func runSeed(base: UInt64, runIndex: UInt64) -> UInt64 {
        var z = base &+ runIndex &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
}
