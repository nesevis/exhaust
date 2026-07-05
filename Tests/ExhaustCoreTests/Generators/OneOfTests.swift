//
//  OneOfTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 26/2/2026.
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("oneOf combinator")
struct OneOfTests {
    // MARK: - Equal-weight oneOf

    @Test("Equal-weight oneOf produces values from all branches")
    func equalWeightProducesVariety() throws {
        let gen: Generator<String> = Gen.pick(choices: [
            (1, Gen.just("alpha")),
            (1, Gen.just("beta")),
            (1, Gen.just("gamma")),
        ])
        var seen: Set<String> = []
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 200)
        for _ in 0 ..< 200 {
            guard let value = try iterator.next() else { break }
            seen.insert(value)
        }
        #expect(seen.count == 3, "Expected all three branches, saw \(seen)")
    }

    // MARK: - Weighted oneOf

    @Test("Weighted oneOf produces values from all branches")
    func weightedProducesVariety() throws {
        let gen: Generator<String> = Gen.pick(choices: [
            (1, Gen.just("rare")),
            (5, Gen.just("common")),
        ])
        var seen: Set<String> = []
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 200)
        for _ in 0 ..< 200 {
            guard let value = try iterator.next() else { break }
            seen.insert(value)
        }
        #expect(seen.count == 2, "Expected both branches, saw \(seen)")
    }

    @Test("Weights bias branch selection in proportion")
    func weightsBiasSelection() throws {
        // 9:1 weighting; over 500 draws the common branch should dominate by a wide margin.
        // The 3:1 threshold leaves generous slack below the expected 9:1 split at seed 42.
        let gen: Generator<String> = Gen.pick(choices: [
            (9, Gen.just("common")),
            (1, Gen.just("rare")),
        ])
        var counts: [String: Int] = [:]
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 500)
        while let value = try iterator.next() {
            counts[value, default: 0] += 1
        }

        let common = counts["common", default: 0]
        let rare = counts["rare", default: 0]
        #expect(common + rare == 500)
        #expect(rare > 0, "The rare branch must still be reachable")
        #expect(common > rare * 3, "9:1 weights should skew selection heavily: common=\(common), rare=\(rare)")
    }

    // MARK: - Round-trip

    @Test("oneOf round-trips through choice tree and materialize", arguments: [UInt64(1), 7, 42, 100, 999, 12345])
    func roundTripAcrossSeeds(seed: UInt64) throws {
        let gen: Generator<String> = Gen.pick(choices: [
            (1, Gen.just("alpha")),
            (1, Gen.just("beta")),
            (1, Gen.just("gamma")),
        ])
        let (original, materialized) = try roundTrip(gen, seed: seed)
        #expect(original == materialized)
    }

    @Test("Weighted oneOf round-trips through choice tree and materialize", arguments: [UInt64(1), 7, 42, 100, 999])
    func weightedRoundTrip(seed: UInt64) throws {
        let gen: Generator<String> = Gen.pick(choices: [
            (1, Gen.just("rare")),
            (3, Gen.just("medium")),
            (5, Gen.just("common")),
        ])
        let (original, materialized) = try roundTrip(gen, seed: seed)
        #expect(original == materialized)
    }

    // MARK: - Gen.pick integration

    @Test("oneOf works with Gen.pick and map")
    func worksWithPickAndMap() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.just(1)),
            (1, Gen.just(2)),
            (1, Gen.just(3)),
        ]).map { $0 * 10 }
        var iterator = ValueInterpreter(gen, seed: 42)
        let value = try iterator.next()
        #expect(value == 10 || value == 20 || value == 30)
    }
}
