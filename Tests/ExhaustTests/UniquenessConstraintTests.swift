//
//  UniquenessConstraintTests.swift
//  Exhaust
//
//  Created by Claude on 25/2/2026.
//

import Testing
@testable import Exhaust

@Suite("Uniqueness Constraint")
struct UniquenessConstraintTests {
    // MARK: - ValueAndChoiceTreeInterpreter

    @Test("High-cardinality generator produces all maxRuns unique values")
    func highCardinalityProducesAllUnique() {
        let gen = UInt64.arbitrary
        let maxRuns: UInt64 = 50
        var iterator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: 42,
            maxRuns: maxRuns,
            uniqueMaxAttempts: 200
        )

        var values = [UInt64]()
        var sequences = Set<ChoiceSequence>()
        while let (value, tree) = iterator.next() {
            values.append(value)
            let seq = ChoiceSequence.flatten(tree)
            sequences.insert(seq)
        }

        #expect(values.count == Int(maxRuns))
        #expect(sequences.count == Int(maxRuns), "All choice sequences should be unique")
    }

    @Test("Low-cardinality generator exhausts budget early")
    func lowCardinalityExhaustsBudget() {
        // Gen.exact always produces the same value with the same choice sequence
        let gen = Gen.exact(42)
        var iterator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: 1,
            maxRuns: 10,
            uniqueMaxAttempts: 20
        )

        var count = 0
        while iterator.next() != nil {
            count += 1
        }

        #expect(count == 1, "Gen.exact(42) can only produce 1 unique value, got \(count)")
    }

    @Test("Bool generator produces exactly 2 unique values")
    func boolProducesExactlyTwo() {
        let gen = Bool.arbitrary
        var iterator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: 42,
            maxRuns: 100,
            uniqueMaxAttempts: 200
        )

        var values = Set<Bool>()
        while let (value, _) = iterator.next() {
            values.insert(value)
        }

        #expect(values.count == 2, "Bool should produce exactly 2 unique values")
        #expect(values.contains(true))
        #expect(values.contains(false))
    }

    @Test("Determinism: same seed and uniqueMaxAttempts produces identical results")
    func determinism() {
        let gen = UInt64.arbitrary
        let seed: UInt64 = 99
        let maxRuns: UInt64 = 20
        let maxAttempts: UInt64 = 100

        var iter1 = ValueAndChoiceTreeInterpreter(
            gen, seed: seed, maxRuns: maxRuns, uniqueMaxAttempts: maxAttempts
        )
        var iter2 = ValueAndChoiceTreeInterpreter(
            gen, seed: seed, maxRuns: maxRuns, uniqueMaxAttempts: maxAttempts
        )

        var values1 = [UInt64]()
        var values2 = [UInt64]()
        while let (v, _) = iter1.next() { values1.append(v) }
        while let (v, _) = iter2.next() { values2.append(v) }

        #expect(values1 == values2, "Same seed should produce identical unique sequences")
    }

    @Test("Without uniqueMaxAttempts, behavior is unchanged")
    func noUniquenessIsIdentical() {
        let gen = UInt64.arbitrary

        var withoutUniqueness = ValueAndChoiceTreeInterpreter(
            gen, seed: 42, maxRuns: 10
        )
        var withNil = ValueAndChoiceTreeInterpreter(
            gen, seed: 42, maxRuns: 10, uniqueMaxAttempts: nil
        )

        var valuesA = [UInt64]()
        var valuesB = [UInt64]()
        while let (v, _) = withoutUniqueness.next() { valuesA.append(v) }
        while let (v, _) = withNil.next() { valuesB.append(v) }

        #expect(valuesA == valuesB, "nil uniqueMaxAttempts should not change behavior")
    }

    // MARK: - ValueInterpreter delegation

    @Test("ValueInterpreter with uniqueMaxAttempts delegates to VACTI")
    func valueInterpreterDelegation() {
        let gen = UInt64.arbitrary
        let seed: UInt64 = 42
        let maxRuns: UInt64 = 20
        let maxAttempts: UInt64 = 100

        var vacti = ValueAndChoiceTreeInterpreter(
            gen, seed: seed, maxRuns: maxRuns, uniqueMaxAttempts: maxAttempts
        )
        var vi = ValueInterpreter(
            gen, seed: seed, maxRuns: maxRuns, uniqueMaxAttempts: maxAttempts
        )

        var vactiValues = [UInt64]()
        var viValues = [UInt64]()
        while let (v, _) = vacti.next() { vactiValues.append(v) }
        while let v = vi.next() { viValues.append(v) }

        #expect(vactiValues == viValues, "ValueInterpreter delegation should match VACTI output")
    }

    // MARK: - CGSValueAndChoiceTreeInterpreter

    @Test("CGS interpreter with uniqueness produces unique values")
    func cgsUniqueness() {
        let gen = Gen.pick(choices: [
            (1, Gen.just(1)),
            (1, Gen.just(2)),
            (1, Gen.just(3)),
        ])

        var iterator = CGSValueAndChoiceTreeInterpreter(
            gen,
            predicate: { _ in true },
            seed: 42,
            maxRuns: 100,
            uniqueMaxAttempts: 200
        )

        var sequences = Set<ChoiceSequence>()
        while let (_, tree) = iterator.next() {
            let seq = ChoiceSequence.flatten(tree)
            let (inserted, _) = sequences.insert(seq)
            #expect(inserted, "Every yielded value should have a unique choice sequence")
        }

        #expect(sequences.count == 3, "3-way pick should produce exactly 3 unique values, got \(sequences.count)")
    }

    // MARK: - PropertyTest

    @Test("PropertyTest.test with uniqueMaxAttempts passes through to interpreter")
    func propertyTestPassthrough() throws {
        let gen = Bool.arbitrary
        var seen = Set<Bool>()

        try PropertyTest.test(
            gen,
            maxIterations: 100,
            seed: 42,
            uniqueMaxAttempts: 200
        ) { value in
            seen.insert(value)
            return true
        }

        #expect(seen.count == 2, "Bool with uniqueness should produce both true and false")
    }
}
