//
//  UniquenessConstraintTests.swift
//  Exhaust
//
//  Created by Claude on 25/2/2026.
//

import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("Uniqueness Constraint")
struct UniquenessConstraintTests {
    // MARK: - Choice-sequence uniqueness via combinator

    @Test("High-cardinality generator produces all maxRuns unique values")
    func highCardinalityProducesAllUnique() {
        // Use a non-size-scaled generator to avoid collisions from small sizes
        let gen = #gen(.uint64(in: 0 ... UInt64.max)).unique()
        let maxRuns: UInt64 = 50
        var iterator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: 42,
            maxRuns: maxRuns,
        )

        var values = [UInt64]()
        while let (value, _) = iterator.next() {
            values.append(value)
        }

        #expect(values.count == Int(maxRuns))
        let uniqueValues = Set(values)
        #expect(uniqueValues.count == Int(maxRuns), "All values should be unique")
    }

    @Test("Low-cardinality generator exhausts retry budget")
    func lowCardinalityExhaustsRetryBudget() {
        // Gen.exact always produces the same value with the same choice sequence
        let gen = Gen.exact(42).unique()
        var iterator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: 1,
            maxRuns: 10,
        )

        var count = 0
        while iterator.next() != nil {
            count += 1
        }

        #expect(count == 1, "Gen.exact(42).unique() can only produce 1 unique value, got \(count)")
    }

    @Test("Bool generator produces exactly 2 unique values")
    func boolProducesExactlyTwo() {
        let gen = Bool.arbitrary.unique()
        var iterator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: 42,
            maxRuns: 100,
        )

        var values = Set<Bool>()
        while let (value, _) = iterator.next() {
            values.insert(value)
        }

        #expect(values.count == 2, "Bool should produce exactly 2 unique values")
        #expect(values.contains(true))
        #expect(values.contains(false))
    }

    @Test("Determinism: same seed produces identical unique results")
    func determinism() {
        let gen = UInt64.arbitrary.unique()
        let seed: UInt64 = 99
        let maxRuns: UInt64 = 20

        var iter1 = ValueAndChoiceTreeInterpreter(
            gen, seed: seed, maxRuns: maxRuns,
        )
        var iter2 = ValueAndChoiceTreeInterpreter(
            gen, seed: seed, maxRuns: maxRuns,
        )

        var values1 = [UInt64]()
        var values2 = [UInt64]()
        while let (v, _) = iter1.next() {
            values1.append(v)
        }
        while let (v, _) = iter2.next() {
            values2.append(v)
        }

        #expect(values1 == values2, "Same seed should produce identical unique sequences")
    }

    // MARK: - ValueInterpreter with unique combinator

    @Test("ValueInterpreter with unique combinator produces unique values")
    func valueInterpreterUniqueness() {
        // Use a non-size-scaled generator to avoid collisions from small sizes
        let gen = #gen(.uint64(in: 0 ... UInt64.max)).unique()
        let seed: UInt64 = 42
        let maxRuns: UInt64 = 20

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: maxRuns)

        var values = [UInt64]()
        while let v = vi.next() {
            values.append(v)
        }

        let uniqueValues = Set(values)
        #expect(values.count == uniqueValues.count, "ValueInterpreter with .unique() should produce unique values")
    }

    // MARK: - Key-based uniqueness (unique(by:) with key path)

    @Test("unique(by:) deduplicates by key path")
    func uniqueByKeyPath() {
        // Generate pairs where first element varies but second is bounded (0-4)
        let secondGen = #gen(.uint64(in: 0 ... 4))
        let pairGen = #gen(
            UInt64.arbitrary,
            secondGen,
        ).unique(by: \.1)

        var iterator = ValueAndChoiceTreeInterpreter(
            pairGen,
            seed: 42,
            maxRuns: 100,
        )

        var seenKeys = Set<UInt64>()
        var count = 0
        while let (pair, _) = iterator.next() {
            let key = pair.1
            let inserted = seenKeys.insert(key).inserted
            #expect(inserted, "Key \(key) was already seen — unique(by: \\.1) should deduplicate")
            count += 1
        }

        // There are only 5 possible keys (0...4), so we should get at most 5
        #expect(count <= 5, "Should produce at most 5 unique keys, got \(count)")
        #expect(count >= 3, "Should produce at least 3 unique keys, got \(count)")
    }

    // MARK: - Key-based uniqueness (unique(by:) with transform)

    @Test("unique(by:) deduplicates by transform function")
    func uniqueByTransform() {
        // Generate values and deduplicate by modulo 5
        let gen = UInt64.arbitrary
            .unique(by: { $0 % 5 })

        var iterator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: 42,
            maxRuns: 100,
        )

        var seenRemainders = Set<UInt64>()
        var count = 0
        while let (value, _) = iterator.next() {
            let remainder = value % 5
            let inserted = seenRemainders.insert(remainder).inserted
            #expect(inserted, "Remainder \(remainder) was already seen — unique(by:) should deduplicate")
            count += 1
        }

        #expect(count == 5, "Should produce exactly 5 unique remainders (0-4), got \(count)")
    }

    // MARK: - CGS interpreter with unique combinator

    @Test("CGS interpreter with unique combinator produces unique values")
    func cgsUniqueness() {
        let gen = #gen(.oneOf(weighted:
            (1, .just(1)),
            (1, .just(2)),
            (1, .just(3))
        )).unique(by: { AnyHashable($0) })

        var iterator = OnlineCGSInterpreter(
            gen,
            predicate: { _ in true },
            seed: 42,
            maxRuns: 100,
        )

        var values = Set<Int>()
        while let value = iterator.next() {
            let (inserted, _) = values.insert(value)
            #expect(inserted, "Every yielded value should be unique")
        }

        #expect(values.count == 3, "3-way pick should produce exactly 3 unique values, got \(values.count)")
    }

    // MARK: - PropertyTest with unique combinator

    @Test("PropertyTest with unique combinator passes through")
    func propertyTestPassthrough() throws {
        let gen = Bool.arbitrary.unique()
        var seen = Set<Bool>()

        #exhaust(gen, .maxIterations(100), .replay(42)) { value in
            seen.insert(value)
            return true
        }

        #expect(seen.count == 2, "Bool with .unique() should produce both true and false")
    }
}
