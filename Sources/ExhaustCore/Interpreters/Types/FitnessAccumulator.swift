//
//  FitnessAccumulator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

/// Collects per-site, per-choice fitness data during tuning runs.
/// Reference semantics so the accumulator is shared across recursive calls.
@_spi(ExhaustInternal) public final class FitnessAccumulator {
    @_spi(ExhaustInternal) public struct SiteChoiceKey: Hashable {
        public let siteID: UInt64
        public let choiceID: UInt64
    }

    @_spi(ExhaustInternal) public struct FitnessRecord {
        public var totalFitness: UInt64 = 0
        public var observationCount: UInt64 = 0
    }

    @_spi(ExhaustInternal) public private(set) var records: [SiteChoiceKey: FitnessRecord] = [:]

    @_spi(ExhaustInternal) public init() {}

    func record(siteID: UInt64, choiceID: UInt64, fitness: UInt64, observations: UInt64) {
        let key = SiteChoiceKey(siteID: siteID, choiceID: choiceID)
        records[key, default: FitnessRecord()].totalFitness += fitness
        records[key, default: FitnessRecord()].observationCount += observations
    }
}
