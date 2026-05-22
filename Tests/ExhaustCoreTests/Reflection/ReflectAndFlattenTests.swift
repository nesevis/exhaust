//
//  ReflectAndFlattenTests.swift
//  ExhaustTests
//
//  Tests that use Reflect to create ChoiceTrees from generators and values,
//  then test the flatten method on those reflected trees.
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Reflect and Flatten Integration Tests")
struct ReflectAndFlattenTests {
    @Test("Reflect and flatten simple integer")
    func reflectAndFlattenSimpleInteger() throws {
        let gen = Gen.choose(in: UInt64(0) ... 100)
        let value: UInt64 = 42

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized == value)
    }

    @Test("Reflect and flatten array")
    func reflectAndFlattenArray() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), exactly: 3)
        let value: [UInt64] = [1, 5, 9]

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized == value)
    }

    @Test("Reflect and flatten tuple")
    func reflectAndFlattenTuple() throws {
        let gen = Gen.zip(Gen.choose(in: UInt64(0) ... 100), Gen.choose(in: UInt64(0) ... 100))
        let value: (UInt64, UInt64) = (42, 99)

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized.0 == value.0)
        #expect(materialized.1 == value.1)
    }

    @Test("Reflect and flatten tuple of arrays")
    func reflectAndFlattenTupleOfArrays() throws {
        let gen = Gen.zip(
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 101), within: UInt64(1) ... 10),
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 101), within: UInt64(1) ... 20)
        )
        let value: ([UInt64], [UInt64]) = ([42], [99, 100, 101])

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        guard case let .success(materialised, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }

        #expect(value.0 == materialised.0)
        #expect(value.1 == materialised.1)
    }

    @Test("Reflect and flatten pick/branch")
    func reflectAndFlattenPick() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.just("first")),
            (1, Gen.just("second")),
            (1, Gen.just("third")),
        ])

        let value = "second"

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized == value)
    }

    @Test("Reflect and flatten nested structure")
    func reflectAndFlattenNestedStructure() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(1) ... 10),
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 2)
        )

        let value: (UInt64, [UInt64]) = (5, [20, 80])

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized.0 == value.0)
        #expect(materialized.1 == value.1)
    }

    @Test("Reflect and flatten with mapped")
    func reflectAndFlattenWithMapped() throws {
        let gen = Gen.contramap(
            { (value: UInt64) -> UInt64 in value / 2 },
            Gen.choose(in: UInt64(0) ... 100).map { $0 * 2 }
        )
        let value: UInt64 = 84

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized == value)
    }

    @Test("Reflect and flatten Bool")
    func reflectAndFlattenBool() throws {
        let gen = Gen.choose(from: [true, false])
        let value = true

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized == value)
    }

    @Test("Reflect and flatten String")
    func reflectAndFlattenString() throws {
        let gen = Gen.resize(3, stringGen())
        let value = "abc"

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized == value)
    }

    @Test("Reflect and flatten preserves metadata")
    func reflectAndFlattenPreservesMetadata() throws {
        let gen = Gen.choose(in: UInt64(10) ... 50)
        let value: UInt64 = 25

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)

        let valueChoices = flattened.compactMap { element -> ChoiceSequenceValue.Value? in
            if case let .value(v) = element { return v }
            return nil
        }
        let firstChoice = try #require(valueChoices.first)
        let validRange = try #require(firstChoice.validRange)
        #expect(validRange.contains(firstChoice.choice.bitPattern64))

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized == value)
    }

    @Test("Reflect and flatten empty array")
    func reflectAndFlattenEmptyArray() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), exactly: 0)
        let value: [UInt64] = []

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized == value)
    }

    @Test("Reflect and flatten complex nested pick")
    func reflectAndFlattenComplexPick() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.zip(Gen.just(1), Gen.just("a"))),
            (1, Gen.zip(Gen.just(2), Gen.just("b"))),
            (1, Gen.zip(Gen.just(3), Gen.just("c"))),
        ])

        let value = (2, "b")

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)
        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized.0 == value.0)
        #expect(materialized.1 == value.1)
    }

    @Test("Reflect and flatten with different types")
    func reflectAndFlattenMixedTypes() throws {
        let gen = Gen.zip(Gen.choose(in: UInt64(0) ... 100), Gen.choose(in: Int64(-50) ... 50), Gen.choose(in: 0.0 ... 1.0 as ClosedRange<Double>))

        let value: (UInt64, Int64, Double) = (42, -10, 0.5)

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized.0 == value.0)
        #expect(materialized.1 == value.1)
        #expect(materialized.2 == value.2)
    }

    @Test("Flatten count matches reflection complexity")
    func flattenCountMatchesReflection() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), exactly: 5)
        let value: [UInt64] = [1, 2, 3, 4, 5]

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let flattened = ChoiceSequence.flatten(tree)

        let groupCount = flattened.count(where: { element in
            if case .group = element { return true }
            return false
        })
        #expect(groupCount % 2 == 0)

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Materialize failed for reflected tree")
            return
        }
        #expect(materialized == value)
    }

    @Test("Materialising works for sequences")
    func materializationWithSequence() throws {
        // Use a variable-length generator so element deletion is valid
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: UInt64(0) ... 10)
        let value: [UInt64] = [1, 2, 3, 4, 5]

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        var flattened = ChoiceSequence.flatten(tree)

        // Do some shrinking!
        flattened.remove(at: 2)
        flattened.remove(at: 2)

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }

        #expect(materialized == [1, 4, 5])
    }

    @Test("Materialising works for picks")
    func materializationWithPick() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.choose(in: UInt64(11) ... 64)),
        ])

        // Reflect the generator with the value
        // For now it does not work with `materializePicks`
        // 1. If it is enabled, the flattened sequence contains N values
        // 2. The materializer will only use the `.selected` branch and leave the other values unconsumed.
        var rafIter1 = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1337)
        let (value, tree) = try #require(rafIter1.prefix(1).last)

        // Flatten the reflected tree
        var flattened = ChoiceSequence.flatten(tree)

        // Mess with it
        flattened[2] = .value(.init(choice: ChoiceValue(64 as UInt64, tag: .uint64), validRange: nil))

        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }

        #expect(value != 64)
        #expect(materialized == 64)
    }
}

// MARK: - Helpers

extension ExhaustRangeSet where Bound == Int {
    mutating func insert(contentsOf closedRange: ClosedRange<Bound>) {
        insert(contentsOf: closedRange.lowerBound ..< (closedRange.upperBound + 1))
    }
}
