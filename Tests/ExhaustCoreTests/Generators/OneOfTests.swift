//
//  OneOfTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 26/2/2026.
//

import ExhaustCore
import Testing

@Suite("oneOf combinator")
struct OneOfTests {
    // MARK: - Helpers

    private func roundTrip<Output: Equatable>(
        _ gen: ReflectiveGenerator<Output>,
        seed: UInt64 = 42
    ) throws -> (original: Output, materialized: Output) {
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: seed)
        let (value, tree) = try #require(try interpreter.prefix(1).last)
        let flattened = ChoiceSequence.flatten(tree)
        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return (value, value)
        }
        return (value, materialized)
    }

    // MARK: - Equal-weight oneOf

    @Test("Equal-weight oneOf produces values from all branches")
    func equalWeightProducesVariety() throws {
        let gen: ReflectiveGenerator<String> = Gen.pick(choices: [
            (1, Gen.just("alpha")),
            (1, Gen.just("beta")),
            (1, Gen.just("gamma")),
        ])
        var seen: Set<String> = []
        var iterator = ValueInterpreter(gen)
        for _ in 0 ..< 200 {
            guard let value = try iterator.next() else { break }
            seen.insert(value)
        }
        #expect(seen.count == 3, "Expected all three branches, saw \(seen)")
    }

    // MARK: - Weighted oneOf

    @Test("Weighted oneOf produces values from all branches")
    func weightedProducesVariety() throws {
        let gen: ReflectiveGenerator<String> = Gen.pick(choices: [
            (1, Gen.just("rare")),
            (5, Gen.just("common")),
        ])
        var seen: Set<String> = []
        var iterator = ValueInterpreter(gen)
        for _ in 0 ..< 200 {
            guard let value = try iterator.next() else { break }
            seen.insert(value)
        }
        #expect(seen.count == 2, "Expected both branches, saw \(seen)")
    }

    // MARK: - Round-trip

    @Test("oneOf round-trips through choice tree and materialize", arguments: [UInt64(1), 7, 42, 100, 999, 12345])
    func roundTripAcrossSeeds(seed: UInt64) throws {
        let gen: ReflectiveGenerator<String> = Gen.pick(choices: [
            (1, Gen.just("alpha")),
            (1, Gen.just("beta")),
            (1, Gen.just("gamma")),
        ])
        let (original, materialized) = try roundTrip(gen, seed: seed)
        #expect(original == materialized)
    }

    @Test("Weighted oneOf round-trips through choice tree and materialize")
    func weightedRoundTrip() throws {
        let gen: ReflectiveGenerator<String> = Gen.pick(choices: [
            (1, Gen.just("rare")),
            (3, Gen.just("medium")),
            (5, Gen.just("common")),
        ])
        for seed in [UInt64(1), 7, 42, 100, 999] {
            let (original, materialized) = try roundTrip(gen, seed: seed)
            #expect(original == materialized)
        }
    }

    // MARK: - Gen.pick integration

    @Test("oneOf works with Gen.pick and map")
    func worksWithPickAndMap() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.just(1)),
            (1, Gen.just(2)),
            (1, Gen.just(3)),
        ])._map { $0 * 10 }
        var iterator = ValueInterpreter(gen)
        let value = try iterator.next()
        #expect(value == 10 || value == 20 || value == 30)
    }
}
