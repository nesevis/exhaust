//
//  UniquenessConstraintTests.swift
//  Exhaust
//
//  Created by Claude on 25/2/2026.
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Uniqueness Constraint")
struct UniquenessConstraintTests {
    // MARK: - Choice-sequence uniqueness via combinator

    @Test("High-cardinality generator produces all maxRuns unique values")
    func highCardinalityProducesAllUnique() throws {
        // Use a non-size-scaled generator to avoid collisions from small sizes
        let gen = uniqueGen(Gen.choose(in: UInt64(0) ... UInt64.max))
        let maxRuns: UInt64 = 50
        var iterator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: 42,
            maxRuns: maxRuns
        )

        var values = [UInt64]()
        while let (value, _) = try iterator.next() {
            values.append(value)
        }

        #expect(values.count == Int(maxRuns))
        let uniqueValues = Set(values)
        #expect(uniqueValues.count == Int(maxRuns), "All values should be unique")
    }

    @Test("Low-cardinality generator exhausts retry budget")
    func lowCardinalityExhaustsRetryBudget() throws {
        // Gen.exact always produces the same value with the same choice sequence
        let gen = uniqueGen(Gen.exact(42))
        var iterator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: 1,
            maxRuns: 10
        )

        var count = 0
        while try iterator.next() != nil {
            count += 1
        }

        #expect(count == 1, "Gen.exact(42).unique() can only produce 1 unique value, got \(count)")
    }

    @Test("Bool generator produces exactly 2 unique values")
    func boolProducesExactlyTwo() throws {
        let gen = uniqueGen(Gen.choose(from: [true, false]))
        var iterator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: 42,
            maxRuns: 100
        )

        var values = Set<Bool>()
        while let (value, _) = try iterator.next() {
            values.insert(value)
        }

        #expect(values.count == 2, "Bool should produce exactly 2 unique values")
        #expect(values.contains(true))
        #expect(values.contains(false))
    }

    @Test("Determinism: same seed produces identical unique results")
    func determinism() throws {
        let gen = uniqueGen(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling))
        let seed: UInt64 = 99
        let maxRuns: UInt64 = 20

        var iter1 = ValueAndChoiceTreeInterpreter(
            gen, seed: seed, maxRuns: maxRuns
        )
        var iter2 = ValueAndChoiceTreeInterpreter(
            gen, seed: seed, maxRuns: maxRuns
        )

        var values1 = [UInt64]()
        var values2 = [UInt64]()
        while let (v, _) = try iter1.next() {
            values1.append(v)
        }
        while let (v, _) = try iter2.next() {
            values2.append(v)
        }

        #expect(values1 == values2, "Same seed should produce identical unique sequences")
    }

    // MARK: - ValueInterpreter with unique combinator

    @Test("ValueInterpreter with unique combinator produces unique values")
    func valueInterpreterUniqueness() throws {
        // Use a non-size-scaled generator to avoid collisions from small sizes
        let gen = uniqueGen(Gen.choose(in: UInt64(0) ... UInt64.max))
        let seed: UInt64 = 42
        let maxRuns: UInt64 = 20

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: maxRuns)

        var values = [UInt64]()
        while let v = try vi.next() {
            values.append(v)
        }

        let uniqueValues = Set(values)
        #expect(values.count == uniqueValues.count, "ValueInterpreter with .unique() should produce unique values")
    }

    // MARK: - Key-based uniqueness (unique(by:) with key path)

    @Test("unique(by:) deduplicates by key path")
    func uniqueByKeyPath() throws {
        // Generate pairs where first element varies but second is bounded (0-4)
        let secondGen = Gen.choose(in: UInt64(0) ... UInt64(4))
        let innerPairGen = Gen.zip(
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling),
            secondGen
        )
        let pairGen = uniqueGen(innerPairGen, by: { (pair: (UInt64, UInt64)) in AnyHashable(pair.1) })

        var iterator = ValueAndChoiceTreeInterpreter(
            pairGen,
            seed: 42,
            maxRuns: 100
        )

        var seenKeys = Set<UInt64>()
        var count = 0
        while let (pair, _) = try iterator.next() {
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
    func uniqueByTransform() throws {
        // Generate values and deduplicate by modulo 5
        let gen = uniqueGen(
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling),
            by: { (v: UInt64) in AnyHashable(v % 5) }
        )

        var iterator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: 42,
            maxRuns: 100
        )

        var seenRemainders = Set<UInt64>()
        var count = 0
        while let (value, _) = try iterator.next() {
            let remainder = value % 5
            let inserted = seenRemainders.insert(remainder).inserted
            #expect(inserted, "Remainder \(remainder) was already seen — unique(by:) should deduplicate")
            count += 1
        }

        #expect(count == 5, "Should produce exactly 5 unique remainders (0-4), got \(count)")
    }

    // MARK: - CGS tuning transparency

    @Test("CGS interpreter treats keyed uniqueness as tuning-transparent")
    func choiceGradientSamplingTreatsKeyedUniquenessAsTransparent() throws {
        let generator = uniqueGen(
            Gen.just(1),
            by: { (value: Int) in AnyHashable(value) }
        )

        var iterator = OnlineCGSInterpreter(
            generator,
            predicate: { _ in true },
            seed: 42,
            maxRuns: 3
        )

        var values = [Int]()
        while let value = try iterator.next() {
            values.append(value)
        }

        #expect(values == [1, 1, 1])
    }
}

// MARK: - Helpers

/// Wraps a generator with the `.unique` operation (no key extractor).
private func uniqueGen<Value>(_ gen: Generator<Value>) -> Generator<Value> {
    .impure(
        operation: .unique(gen: gen.erase(), fingerprint: 0, keyExtractor: nil),
        continuation: { .pure($0 as! Value) }
    )
}

/// Wraps a generator with the `.unique` operation using a key extractor.
private func uniqueGen<Value>(_ gen: Generator<Value>, by keyExtractor: @escaping (Value) -> AnyHashable) -> Generator<Value> {
    .impure(
        operation: .unique(gen: gen.erase(), fingerprint: 0, keyExtractor: { value in keyExtractor(value as! Value) }),
        continuation: { .pure($0 as! Value) }
    )
}
