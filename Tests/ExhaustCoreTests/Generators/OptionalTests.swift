//
//  OptionalTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

@Suite(".optional() combinator")
struct OptionalTests {
    @Test("Produces both nil and non-nil values")
    func producesBothBranches() {
        let gen = optionalGen(Gen.choose(in: 1 ... 100) as ReflectiveGenerator<Int>)

        var sawNil = false
        var sawSome = false

        for _ in 0 ..< 200 {
            var iterator = ValueInterpreter(gen)
            guard let value = iterator.next() else { break }
            if value == nil {
                sawNil = true
            } else {
                sawSome = true
            }
            if sawNil, sawSome { break }
        }

        #expect(sawNil, "Expected at least one nil value")
        #expect(sawSome, "Expected at least one non-nil value")
    }

    @Test("Non-nil values satisfy the underlying generator's constraints")
    func nonNilValuesSatisfyConstraints() {
        let gen = optionalGen(Gen.choose(in: 10 ... 20) as ReflectiveGenerator<Int>)

        for _ in 0 ..< 100 {
            var iterator = ValueInterpreter(gen)
            guard let value = iterator.next() else { break }
            if let unwrapped = value {
                #expect(10 ... 20 ~= unwrapped)
            }
        }
    }

    @Test("Round-trips through reflect and replay", arguments: [UInt64(1), 7, 42, 100, 999, 12345])
    func roundTrip(seed: UInt64) throws {
        let gen = optionalGen(Gen.choose(in: 0 ... 50) as ReflectiveGenerator<Int>)

        var optIter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: seed)
        let (value, tree) = try #require(optIter.prefix(1).last)
        let flattened = ChoiceSequence.flatten(tree)
        let materialized = try #require(try Interpreters.materialize(gen, with: tree, using: flattened))
        #expect(value == materialized)
    }

    @Test("Round-trips with validateGenerator helper")
    func roundTripValidate() throws {
        let gen = optionalGen(Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>)
        _ = try validateGenerator(gen)
    }

    @Test("Composes with arrayOf")
    func composesWithArray() throws {
        let gen = Gen.arrayOf(
            optionalGen(Gen.choose(in: 1 ... 10) as ReflectiveGenerator<Int>),
            exactly: 5
        )

        var iterator = ValueInterpreter(gen)
        let array = iterator.next()!
        #expect(array.count == 5)

        _ = try validateGenerator(gen)
    }

    @Test("Nested optional produces all three tiers")
    func nestedOptional() {
        let gen = optionalGen(optionalGen(Gen.choose(in: 1 ... 10) as ReflectiveGenerator<Int>))

        var sawNone = false        // .none
        var sawSomeNone = false    // .some(.none)
        var sawSomeSome = false    // .some(.some(_))

        for _ in 0 ..< 500 {
            var iterator = ValueInterpreter(gen)
            guard let value = iterator.next() else { break }
            switch value {
            case .none:
                sawNone = true
            case .some(.none):
                sawSomeNone = true
            case .some(.some):
                sawSomeSome = true
            }
            if sawNone, sawSomeNone, sawSomeSome { break }
        }

        #expect(sawNone, "Expected .none")
        #expect(sawSomeNone, "Expected .some(.none)")
        #expect(sawSomeSome, "Expected .some(.some(_))")
    }
}
