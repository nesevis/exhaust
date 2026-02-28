//
//  GenerationContext.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/2/2026.
//

struct GenerationContext {
    // Constants
    let maxRuns: UInt64
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

    // MARK: - Linear size scaling (1–100)

    static func scaledSize(_ maxRuns: UInt64, _ completedRuns: UInt64) -> UInt64 {
        guard maxRuns > 1 else { return 1 }
        return 1 + completedRuns * 99 / (maxRuns - 1)
    }
}
