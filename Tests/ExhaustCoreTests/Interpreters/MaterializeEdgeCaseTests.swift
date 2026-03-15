//
//  MaterializeEdgeCaseTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

@Suite("Materialize edge cases")
struct MaterializeEdgeCaseTests {
    // MARK: - Helpers

    private func roundTrip<Output: Equatable>(
        _ gen: ReflectiveGenerator<Output>,
        seed: UInt64 = 42,
        maxRuns: UInt64 = 20
    ) throws -> [(original: Output, materialized: Output)] {
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: seed, maxRuns: maxRuns)
        var results: [(original: Output, materialized: Output)] = []
        while let (value, tree) = try iterator.next() {
            let sequence = ChoiceSequence(tree)
            let materialized = try #require(try Interpreters.materialize(gen, with: tree, using: sequence))
            results.append((value, materialized))
        }
        return results
    }

    // MARK: - Sequences of just elements

    @Test("Array of just values materializes correctly")
    func arrayOfJustValues() throws {
        let gen = Gen.arrayOf(Gen.just("hello"), exactly: 3)
        let results = try roundTrip(gen)
        for result in results {
            #expect(result.original == result.materialized)
        }
    }

    @Test("Array of just values with variable length materializes correctly")
    func arrayOfJustValuesVariableLength() throws {
        let gen = Gen.arrayOf(Gen.just(42 as UInt), within: 0 ... 5, scaling: .constant)
        let results = try roundTrip(gen)
        for result in results {
            #expect(result.original == result.materialized)
        }
    }

    @Test("Nested arrays where inner elements are just")
    func nestedArrayOfJust() throws {
        let inner = Gen.arrayOf(Gen.just("x"), within: 0 ... 3, scaling: .constant)
        let gen = Gen.arrayOf(inner, within: 1 ... 3, scaling: .constant)
        let results = try roundTrip(gen)
        for result in results {
            #expect(result.original == result.materialized)
        }
    }

    @Test("Pick between just values inside an array")
    func pickOfJustInArray() throws {
        let pick: ReflectiveGenerator<String> = Gen.pick(choices: [
            (weight: 1, generator: Gen.just("a")),
            (weight: 1, generator: Gen.just("b")),
            (weight: 1, generator: Gen.just("c")),
        ])
        let gen = Gen.arrayOf(pick, within: 1 ... 5, scaling: .constant)
        let results = try roundTrip(gen)
        for result in results {
            #expect(result.original == result.materialized)
        }
    }
}
