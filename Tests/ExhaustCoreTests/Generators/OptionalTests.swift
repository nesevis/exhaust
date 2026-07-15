//
//  OptionalTests.swift
//  Exhaust
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite(".optional() combinator")
struct OptionalTests {
    @Test("Produces both nil and non-nil values")
    func producesBothBranches() throws {
        let gen = optionalGen(Gen.choose(in: 1 ... 100) as Generator<Int>)

        var sawNil = false
        var sawSome = false

        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 200)
        while let value = try iterator.next() {
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
    func nonNilValuesSatisfyConstraints() throws {
        let gen = optionalGen(Gen.choose(in: 10 ... 20) as Generator<Int>)

        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 100)
        var drawn = 0
        while let value = try iterator.next() {
            drawn += 1
            if let unwrapped = value {
                #expect(10 ... 20 ~= unwrapped)
            }
        }
        #expect(drawn == 100)
    }

    @Test("Round-trips with validateGenerator helper")
    func roundTripValidate() throws {
        let gen = optionalGen(Gen.choose(in: 0 ... 100) as Generator<Int>)
        _ = try validateGenerator(gen)
    }

    @Test("Composes with arrayOf")
    func composesWithArray() throws {
        let gen = Gen.arrayOf(
            optionalGen(Gen.choose(in: 1 ... 10) as Generator<Int>),
            exactly: 5
        )

        var iterator = ValueInterpreter(gen, seed: 42)
        let array = try #require(try iterator.next())
        #expect(array.count == 5)

        _ = try validateGenerator(gen)
    }

    @Test("Nested optional produces all three tiers")
    func nestedOptional() throws {
        let gen = optionalGen(optionalGen(Gen.choose(in: 1 ... 10) as Generator<Int>))

        var sawNone = false // .none
        var sawSomeNone = false // .some(.none)
        var sawSomeSome = false // .some(.some(_))

        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 500)
        while let value = try iterator.next() {
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
