//
//  ReflectAndFlattenTests.swift
//  ExhaustTests
//
//  Tests that use Reflect to create ChoiceTrees from generators and values,
//  then test the flatten method on those reflected trees.
//

import Testing
@testable import ExhaustCore

@Suite("Reflect and Flatten Integration Tests")
struct ReflectAndFlattenTests {
    @Test("Reflect and flatten simple integer")
    func reflectAndFlattenSimpleInteger() throws {
        let gen = Gen.choose(in: UInt64(0) ... 100)
        let value: UInt64 = 42

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Should have one value representing the choice of 42
        #expect(flattened.count >= 1)

        // Find the actual value choice (skipping group markers)
        let valueChoices = flattened.compactMap { element -> ChoiceSequenceValue.Value? in
            if case let .value(v) = element {
                return v
            }
            return nil
        }

        #expect(valueChoices.count >= 1)
        // The reflected tree contains the value - verify via bit pattern since it could be signed or unsigned
        #expect(valueChoices[0].choice == .unsigned(42, .uint64))
    }

    @Test("Reflect and flatten array")
    func reflectAndFlattenArray() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), exactly: 3)
        let value: [UInt64] = [1, 5, 9]

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Extract value choices
        let valueChoices = flattened.compactMap { element -> ChoiceSequenceValue.Value? in
            if case let .value(v) = element {
                return v
            }
            return nil
        }

        // Should have values for: length + elements
        // The exact structure depends on how arrayOf is implemented
        #expect(valueChoices.count >= 3) // At least the 3 elements

        // Verify the array elements are present
        let elementValues = valueChoices.compactMap { choice -> UInt64? in
            if case let .unsigned(val, _) = choice.choice {
                return val
            }
            return nil
        }

        #expect(elementValues.contains(1))
        #expect(elementValues.contains(5))
        #expect(elementValues.contains(9))
    }

    @Test("Reflect and flatten tuple")
    func reflectAndFlattenTuple() throws {
        let gen = Gen.zip(Gen.choose(in: UInt64(0) ... 100), Gen.choose(in: UInt64(0) ... 100))
        let value: (UInt64, UInt64) = (42, 99)

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Extract value choices
        let valueChoices = flattened.compactMap { element -> ChoiceSequenceValue.Value? in
            if case let .value(v) = element {
                return v
            }
            return nil
        }

        // Should have 2 values for the tuple elements
        #expect(valueChoices.count >= 2)

        let unsignedValues = valueChoices.compactMap { choice -> UInt64? in
            if case let .unsigned(val, _) = choice.choice {
                return val
            }
            return nil
        }

        #expect(unsignedValues.contains(42))
        #expect(unsignedValues.contains(99))
    }

    @Test("Reflect and flatten tuple of arrays")
    func reflectAndFlattenTupleOfArrays() throws {
        let gen = Gen.zip(
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 101), within: UInt64(1) ... 10),
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 101), within: UInt64(1) ... 20),
        )
        let value: ([UInt64], [UInt64]) = ([42], [99, 100, 101])

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        let materialised = try Interpreters.materialize(gen, with: tree, using: flattened)

        #expect(value.0 == materialised?.0)
        #expect(value.1 == materialised?.1)
    }

    @Test("Reflect and flatten pick/branch")
    func reflectAndFlattenPick() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.just("first")),
            (1, Gen.just("second")),
            (1, Gen.just("third")),
        ])

        let value = "second"

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // With branches, all children are flattened
        // Should have group markers wrapping the branches
        let groupMarkers = flattened.compactMap { element -> Bool? in
            if case let .group(isOpen) = element {
                return isOpen
            }
            return nil
        }

        // Should have balanced group markers
        #expect(groupMarkers.count(where: { $0 }) == groupMarkers.count(where: { !$0 }))
    }

    @Test("Reflect and flatten nested structure")
    func reflectAndFlattenNestedStructure() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(1) ... 10),
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 2),
        )

        let value: (UInt64, [UInt64]) = (5, [20, 80])

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Extract value choices
        let valueChoices = flattened.compactMap { element -> ChoiceSequenceValue.Value? in
            if case let .value(v) = element {
                return v
            }
            return nil
        }

        // Should have values for: first element + array length + array elements
        #expect(valueChoices.count >= 3)

        let unsignedValues = valueChoices.compactMap { choice -> UInt64? in
            if case let .unsigned(val, _) = choice.choice {
                return val
            }
            return nil
        }

        #expect(unsignedValues.contains(5))
        #expect(unsignedValues.contains(20))
        #expect(unsignedValues.contains(80))
    }

    @Test("Reflect and flatten with mapped")
    func reflectAndFlattenWithMapped() throws {
        let gen = Gen.contramap(
            { (value: UInt64) -> UInt64 in value / 2 },
            Gen.choose(in: UInt64(0) ... 100)._map { $0 * 2 }
        )
        let value: UInt64 = 84 // 42 * 2

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Extract value choices
        let valueChoices = flattened.compactMap { element -> ChoiceSequenceValue.Value? in
            if case let .value(v) = element {
                return v
            }
            return nil
        }

        #expect(valueChoices.count >= 1)

        // The reflected tree should contain 42 (the original choice before mapping)
        let unsignedValues = valueChoices.compactMap { choice -> UInt64? in
            if case let .unsigned(val, _) = choice.choice {
                return val
            }
            return nil
        }

        #expect(unsignedValues.contains(42))
    }

    @Test("Reflect and flatten Bool")
    func reflectAndFlattenBool() throws {
        let gen = Gen.choose(from: [true, false])
        let value = true

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Bool.arbitrary uses pick, so we should have branch/group structure
        #expect(flattened.isEmpty == false)
    }

    @Test("Reflect and flatten String", .disabled("No more character use in shrinking"))
    func reflectAndFlattenString() throws {
        let gen = Gen.resize(3, stringGen())
        let value = "abc"

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Extract value choices
        let valueChoices = flattened.compactMap { element -> ChoiceSequenceValue.Value? in
            if case let .value(v) = element {
                return v
            }
            return nil
        }

        // Should have values for the characters (now as Int indices via .signed)
        #expect(valueChoices.count >= 3)
    }

    @Test("Reflect and flatten preserves metadata")
    func reflectAndFlattenPreservesMetadata() throws {
        let gen = Gen.choose(in: UInt64(10) ... 50)
        let value: UInt64 = 25

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Extract value choices
        let valueChoices = flattened.compactMap { element -> ChoiceSequenceValue.Value? in
            if case let .value(v) = element {
                return v
            }
            return nil
        }

        #expect(valueChoices.count >= 1)

        // Check that valid ranges are preserved
        let firstChoice = valueChoices[0]
        #expect(firstChoice.validRange != nil)

        // The value should fit in its valid range
        let fits = firstChoice.validRange?.contains(firstChoice.choice.bitPattern64) ?? false
        #expect(fits)
    }

    @Test("Reflect and flatten empty array")
    func reflectAndFlattenEmptyArray() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), exactly: 0)
        let value: [UInt64] = []

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Should have at least group markers, possibly a length choice
        #expect(flattened.isEmpty == false)
    }

    @Test("Reflect and flatten complex nested pick")
    func reflectAndFlattenComplexPick() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.zip(Gen.just(1), Gen.just("a"))),
            (1, Gen.zip(Gen.just(2), Gen.just("b"))),
            (1, Gen.zip(Gen.just(3), Gen.just("c"))),
        ])

        let value = (2, "b")

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Should have group markers and nested structure
        #expect(flattened.isEmpty == false)

        // Verify balanced group markers
        var openCount = 0
        var closeCount = 0
        for element in flattened {
            if case let .group(isOpen) = element {
                if isOpen {
                    openCount += 1
                } else {
                    closeCount += 1
                }
            }
        }

        #expect(openCount == closeCount)
    }

    @Test("Reflect and flatten with different types")
    func reflectAndFlattenMixedTypes() throws {
        let gen = Gen.zip(Gen.choose(in: UInt64(0) ... 100), Gen.choose(in: Int64(-50) ... 50), Gen.choose(in: 0.0 ... 1.0 as ClosedRange<Double>))

        let value: (UInt64, Int64, Double) = (42, -10, 0.5)

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Extract value choices
        let valueChoices = flattened.compactMap { element -> ChoiceSequenceValue.Value? in
            if case let .value(v) = element {
                return v
            }
            return nil
        }

        // Should have at least 3 values for the tuple elements
        #expect(valueChoices.count >= 3)

        // Check we have different types
        let hasUnsigned = valueChoices.contains { choice in
            if case .unsigned = choice.choice { return true }
            return false
        }

        let hasSigned = valueChoices.contains { choice in
            if case .signed = choice.choice { return true }
            return false
        }

        let hasFloating = valueChoices.contains { choice in
            if case .floating = choice.choice { return true }
            return false
        }

        #expect(hasUnsigned)
        #expect(hasSigned)
        #expect(hasFloating)
    }

    @Test("Flatten count matches reflection complexity")
    func flattenCountMatchesReflection() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), exactly: 5)
        let value: [UInt64] = [1, 2, 3, 4, 5]

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Extract value choices and group markers
        let valueCount = flattened.count(where: { element in
            if case .value = element { return true }
            return false
        })

        let groupCount = flattened.count(where: { element in
            if case .group = element { return true }
            return false
        })

        // Should have at least 5 values for the array elements
        #expect(valueCount >= 5)

        // Group markers should be balanced (even count)
        #expect(groupCount % 2 == 0)
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

        let materialized = try Interpreters.materialize(gen, with: tree, using: flattened)

        #expect(materialized == [1, 4, 5])
    }

    @Test("Materialising works for picks")
    func materializationWithPick() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.choose(in: UInt64(11) ... 12)),
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
        flattened[2] = .value(.init(choice: .unsigned(64, .uint64), validRange: nil))

        let materialized = try Interpreters.materialize(gen, with: tree, using: flattened)

        #expect(materialized == 64)
    }

    @Test("Test cross-boundary shrinking")
    func crossBoundaryShrinkingWorks() throws {
        let gen = Gen.arrayOf(Gen.arrayOf(Gen.choose(in: 1 ... 10 as ClosedRange<Int>), within: UInt64(1) ... 10), within: UInt64(1) ... 10)
        var rafIter2 = ValueAndChoiceTreeInterpreter(gen, seed: 1337)
        let (value, tree) = try #require(rafIter2.prefix(50).last)

        var sequence = ChoiceSequence.flatten(tree)

        let sequenceStarts = sequence
            .enumerated()
            .filter { $0.element == .sequence(true) }
            .map(\.offset)
            .dropFirst()

        // Remove a sequence close and open to remove the barrier between two arrays, collapsing them
        let candidate = sequenceStarts.last!
        sequence.removeSubrange((candidate - 1) ... candidate)
        try #require(ChoiceSequence.validate(sequence))
        let materialized = try #require(try Interpreters.materialize(gen, with: tree, using: sequence, strictness: .relaxed))

        // Merging removed one boundary, so one fewer array
        #expect(materialized.count == value.count - 1)
        // Elements are the same, even if the exact division isn't
        #expect(value.flatMap(\.self) == materialized.flatMap(\.self))
    }
}

extension RangeSet where Bound == Int {
    mutating func insert(contentsOf closedRange: ClosedRange<Bound>) {
        insert(contentsOf: closedRange.lowerBound ..< (closedRange.upperBound + 1))
    }
}
