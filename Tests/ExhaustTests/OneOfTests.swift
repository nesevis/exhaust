//
//  OneOfTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 26/2/2026.
//

import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("oneOf combinator")
struct OneOfTests {
    // MARK: - Helpers

    private func roundTrip<Output: Equatable>(
        _ gen: ReflectiveGenerator<Output>,
        seed: UInt64 = 42,
    ) throws -> (original: Output, materialized: Output) {
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: seed)
        let (value, tree) = try #require(interpreter.prefix(1).last)
        let flattened = ChoiceSequence.flatten(tree)
        let materialized = try #require(try Interpreters.materialize(gen, with: tree, using: flattened))
        return (value, materialized)
    }

    // MARK: - Equal-weight oneOf

    @Test("Equal-weight oneOf produces values from all branches")
    func equalWeightProducesVariety() {
        let gen: ReflectiveGenerator<String> = .oneOf(
            .just("alpha"),
            .just("beta"),
            .just("gamma"),
        )
        var seen: Set<String> = []
        var iterator = ValueInterpreter(gen)
        for _ in 0 ..< 200 {
            guard let value = iterator.next() else { break }
            seen.insert(value)
        }
        #expect(seen.count == 3, "Expected all three branches, saw \(seen)")
    }

    // MARK: - Weighted oneOf

    @Test("Weighted oneOf produces values from all branches")
    func weightedProducesVariety() {
        let gen: ReflectiveGenerator<String> = .oneOf(weighted:
            (1, .just("rare")),
            (5, .just("common")))
        var seen: Set<String> = []
        var iterator = ValueInterpreter(gen)
        for _ in 0 ..< 200 {
            guard let value = iterator.next() else { break }
            seen.insert(value)
        }
        #expect(seen.count == 2, "Expected both branches, saw \(seen)")
    }

    // MARK: - Round-trip

    @Test("oneOf round-trips through choice tree and materialize", arguments: [UInt64(1), 7, 42, 100, 999, 12345])
    func roundTripAcrossSeeds(seed: UInt64) throws {
        let gen: ReflectiveGenerator<String> = .oneOf(
            .just("alpha"),
            .just("beta"),
            .just("gamma"),
        )
        let (original, materialized) = try roundTrip(gen, seed: seed)
        #expect(original == materialized)
    }

    @Test("Weighted oneOf round-trips through choice tree and materialize")
    func weightedRoundTrip() throws {
        let gen: ReflectiveGenerator<String> = .oneOf(weighted:
            (1, .just("rare")),
            (3, .just("medium")),
            (5, .just("common")))
        for seed in [UInt64(1), 7, 42, 100, 999] {
            let (original, materialized) = try roundTrip(gen, seed: seed)
            #expect(original == materialized)
        }
    }

    // MARK: - #gen integration

    @Test("oneOf works inside #gen macro")
    func worksInsideGenMacro() {
        let gen = #gen(.oneOf(.just(1), .just(2), .just(3))) { $0 * 10 }
        var iterator = ValueInterpreter(gen)
        let value = iterator.next()
        #expect(value == 10 || value == 20 || value == 30)
    }
}
