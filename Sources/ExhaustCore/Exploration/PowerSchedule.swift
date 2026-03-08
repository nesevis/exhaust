//
//  PowerSchedule.swift
//  Exhaust
//

import Foundation

/// Determines how many mutations to attempt for a given seed before moving on.
public protocol PowerSchedule {
    /// How many mutations to attempt for this seed before moving on.
    func energy(for seed: Seed, poolSize: Int, averagePoolFitness: Double) -> Int
}

/// Default schedule: logarithmic energy scaled by novelty (or fitness) and pool size.
///
/// Higher-scoring seeds get more mutations. Larger pools reduce per-seed energy to maintain breadth. When `averagePoolFitness > 0`, fitness replaces novelty as the scaling signal.
public struct LogarithmicSchedule: PowerSchedule {
    private let baseEnergy: Int
    private let maxEnergy: Int

    public init(baseEnergy: Int = 8, maxEnergy: Int = 64) {
        self.baseEnergy = baseEnergy
        self.maxEnergy = maxEnergy
    }

    public func energy(
        for seed: Seed,
        poolSize: Int,
        averagePoolFitness: Double = 0,
    ) -> Int {
        let scoreFactor: Double
        if averagePoolFitness > 0 {
            // Fitness mode: seeds with above-average fitness get more energy
            scoreFactor = max(1.0, seed.fitness / averagePoolFitness)
        } else {
            // Novelty mode: scale by novelty (1.0 = baseline)
            scoreFactor = max(seed.noveltyScore, 0.25)
        }
        // Reduce energy as pool grows (log dampening)
        let poolFactor = 1.0 / max(1.0, log2(Double(poolSize)))
        let raw = Double(baseEnergy) * scoreFactor * poolFactor
        return min(max(Int(raw.rounded()), 1), maxEnergy)
    }
}
