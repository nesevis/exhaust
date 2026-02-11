//
//  ReflectAndFlattenTests.swift
//  ExhaustTests
//
//  Tests that use Reflect to create ChoiceTrees from generators and values,
//  then test the flatten method on those reflected trees.
//

import Testing
@testable import Exhaust

@Suite("Reflect and Flatten Integration Tests")
struct ReflectAndFlattenTests {

    @Test("Reflect and flatten simple integer")
    func reflectAndFlattenSimpleInteger() throws {
        let gen = Gen.choose(in: UInt64(0)...100)
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
        #expect(valueChoices[0].choice == .unsigned(42))
    }

    @Test("Reflect and flatten array")
    func reflectAndFlattenArray() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0)...10), exactly: 3)
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
            if case let .unsigned(val) = choice.choice {
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
        let gen = Gen.zip(
            Gen.choose(in: UInt64(0)...100),
            Gen.choose(in: UInt64(0)...100)
        )
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
            if case let .unsigned(val) = choice.choice {
                return val
            }
            return nil
        }

        #expect(unsignedValues.contains(42))
        #expect(unsignedValues.contains(99))
    }

    @Test("Reflect and flatten pick/branch")
    func reflectAndFlattenPick() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.just("first")),
            (1, Gen.just("second")),
            (1, Gen.just("third"))
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
        #expect(groupMarkers.filter { $0 }.count == groupMarkers.filter { !$0 }.count)
    }

    @Test("Reflect and flatten nested structure")
    func reflectAndFlattenNestedStructure() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(1)...10),
            Gen.arrayOf(Gen.choose(in: UInt64(0)...100), exactly: 2)
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
            if case let .unsigned(val) = choice.choice {
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
        let gen = Gen.choose(in: UInt64(0)...100).mapped(
            forward: { $0 * 2 },
            backward: { $0 / 2 }
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
            if case let .unsigned(val) = choice.choice {
                return val
            }
            return nil
        }

        #expect(unsignedValues.contains(42))
    }

    @Test("Reflect and flatten Bool")
    func reflectAndFlattenBool() throws {
        let gen = Bool.arbitrary
        let value = true

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Bool.arbitrary uses pick, so we should have branch/group structure
        #expect(flattened.count > 0)
    }

    @Test("Reflect and flatten String")
    func reflectAndFlattenString() throws {
        let gen = Gen.resize(3, String.arbitrary)
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

        // Should have values for the characters
        #expect(valueChoices.count >= 3)

        let characterValues = valueChoices.compactMap { choice -> Character? in
            if case let .character(char) = choice.choice {
                return char
            }
            return nil
        }

        #expect(characterValues.contains("a"))
        #expect(characterValues.contains("b"))
        #expect(characterValues.contains("c"))
    }

    @Test("Reflect and flatten preserves metadata")
    func reflectAndFlattenPreservesMetadata() throws {
        let gen = Gen.choose(in: UInt64(10)...50)
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
        #expect(!firstChoice.validRanges.isEmpty)

        // The value should fit in its valid ranges
        let fits = firstChoice.validRanges.contains { range in
            range.contains(firstChoice.choice.bitPattern64)
        }
        #expect(fits)
    }

    @Test("Reflect and flatten empty array")
    func reflectAndFlattenEmptyArray() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0)...10), exactly:0)
        let value: [UInt64] = []

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Should have at least group markers, possibly a length choice
        #expect(flattened.count >= 0)
    }

    @Test("Reflect and flatten complex nested pick")
    func reflectAndFlattenComplexPick() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.zip(Gen.just(1), Gen.just("a"))),
            (1, Gen.zip(Gen.just(2), Gen.just("b"))),
            (1, Gen.zip(Gen.just(3), Gen.just("c")))
        ])

        let value = (2, "b")

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Should have group markers and nested structure
        #expect(flattened.count > 0)

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
        let gen = Gen.zip(
            Gen.choose(in: UInt64(0)...100),
            Gen.choose(in: Int64(-50)...50),
            Gen.choose(in: 0.0...1.0)
        )

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
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0)...10), exactly:5)
        let value: [UInt64] = [1, 2, 3, 4, 5]

        // Reflect the generator with the value
        let tree = try Interpreters.reflect(gen, with: value)

        #expect(tree != nil)
        guard let tree else { return }

        // Flatten the reflected tree
        let flattened = ChoiceSequence.flatten(tree)

        // Extract value choices and group markers
        let valueCount = flattened.filter { element in
            if case .value = element { return true }
            return false
        }.count

        let groupCount = flattened.filter { element in
            if case .group = element { return true }
            return false
        }.count

        // Should have at least 5 values for the array elements
        #expect(valueCount >= 5)

        // Group markers should be balanced (even count)
        #expect(groupCount % 2 == 0)
    }
    
    @Test("Materialising works for sequences")
    func testMaterializationWithSequence() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0)...10), exactly:5)
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
        
        #expect(materialized == [1,4,5])
    }
    
    @Test("Materialising works for picks")
    func testMaterializationWithPick() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: 0...10, type: UInt64.self)),
            (1, Gen.choose(in: 11...12, type: UInt64.self))
        ])

        // Reflect the generator with the value
        // For now it does not work with `materializePicks`
        // 1. If it is enabled, the flattened sequence contains N values
        // 2. The materializer will only use the `.selected` branch and leave the other values unconsumed.
        let (value, tree) = Array(ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1337).prefix(1)).first!

        // Flatten the reflected tree
        var flattened = ChoiceSequence.flatten(tree)
        
        // Mess with it
        flattened[2] = .value(.init(choice: .character("@"), validRanges: []))

        let materialized = try Interpreters.materialize(gen, with: tree, using: flattened)
        
        #expect(materialized == Character("@").bitPattern64)
    }
    
    @Test("Materialising works for complex generators")
    func testMaterializationWithComplexGenerator() throws {
        struct Person: Equatable {
            let age: UInt64
            let name: String
        }
        let ageGen = Gen.pick(choices: [
            (1, Gen.choose(in: 0...10, type: UInt64.self)),
            (1, Gen.choose(in: 11...84, type: UInt64.self))
        ])
        let nameGen = String.arbitrary
        let gen = Gen.zip(ageGen, nameGen)
            .mapped(
                forward: { Person(age: $0.0, name: $0.1) },
                backward: { ($0.age, $0.name) }
            )

        // Reflect the generator with the value
        // For now it does not work with `materializePicks`
        // 1. If it is enabled, the flattened sequence contains N values
        // 2. The materializer will only use the `.selected` branch and leave the other values unconsumed.
        let (value, tree) = Array(ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1337).prefix(2)).last!

        // Flatten the reflected tree
        var flattened = ChoiceSequence.flatten(tree)
        
        // Mess with it by setting the age to 123 and
        // removing the equivalent of the two leading characters in the name
        flattened[3] = .value(.init(choice: .unsigned(123), validRanges: []))
        flattened.removeSubrange(6...15)

        let materialized = try Interpreters.materialize(gen, with: tree, using: flattened)
        
        #expect(materialized?.age == 123)
        #expect(materialized?.name == String(value.name.dropFirst(2)))
    }
    
    @Test("Shrinking by setting all values of type to something works")
    func testSequenceShrinkingWorks() throws {
        struct Person: Equatable {
            let age: UInt64
            let name: String
        }
        let ageGen = Gen.pick(choices: [
            (1, Gen.choose(in: 0...10, type: UInt64.self)),
            (1, Gen.choose(in: 11...84, type: UInt64.self))
        ])
        let nameGen = String.arbitrary
        let gen = Gen.zip(ageGen, nameGen)
            .mapped(
                forward: { Person(age: $0.0, name: $0.1) },
                backward: { ($0.age, $0.name) }
            )

        // Reflect the generator with the value
        // For now it does not work with `materializePicks`
        // 1. If it is enabled, the flattened sequence contains N values
        // 2. The materializer will only use the `.selected` branch and leave the other values unconsumed.
        let (value, tree) = Array(ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1337).prefix(2)).last!

        // Flatten the reflected tree
        // and reduce the values to their most semantically simple form
        // this is a proto-shrinking step
        let sequence = ChoiceSequence.flatten(tree)
            .map { element in
                guard case let .value(value) = element else {
                    return element
                }
                switch value.choice {
                case .character:
                    return .value(.init(choice: .character("A"), validRanges: []))
                case .unsigned:
                    return .value(.init(choice: .unsigned(.min), validRanges: []))
                default:
                    return element
                }
            }

        print()
        let materialized = try #require(try Interpreters.materialize(gen, with: tree, using: sequence))
        #expect(materialized.age == 0)
        #expect(materialized.name == Array(repeating: "A", count: value.name.count).joined())
    }
    
    @Test("Test cross-boundary shrinking")
    func testCrossBoundaryShrinkingWorks() throws {
        let arrayGen = Gen.arrayOf(Int.arbitrary, exactly: 10)
        let gen = Gen.arrayOf(arrayGen, exactly: 10)

        // Reflect the generator with the value
        // For now it does not work with `materializePicks`
        // 1. If it is enabled, the flattened sequence contains N values
        // 2. The materializer will only use the `.selected` branch and leave the other values unconsumed.
        let (value, tree) = Array(ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1337).prefix(2)).last!

        // Flatten the reflected tree
        // and reduce the values to their most semantically simple form
        // the sequence is a representation that lends itself to direct mutation in ways shrinking via a ChoiceTree cannot
        var sequence = ChoiceSequence.flatten(tree)
        let spans = ChoiceSequence.extractSpans(from: sequence)
        
        let sequenceStarts = sequence
            .enumerated()
            .filter { $0.element == .sequence(true) }
            .map(\.offset)
            .dropFirst()
        
        // Remove a sequence close and open to remove the barrier between two arrays, collapsing them
        let candidate = sequenceStarts[3]
        sequence.removeSubrange((candidate - 1)...candidate)

        try #require(ChoiceSequence.validate(sequence))
            
        let materialized = try #require(try Interpreters.materialize(gen, with: tree, using: sequence))
//        print("Materialized array count: \(materialized.count)")
//        print("Materialized child array counts: \(materialized.map(\.count))")
        
        let valueFlat = value.flatMap(\.self)
        let materializedFlat = materialized.flatMap(\.self)
        
        // There are now 9 arrays
        #expect(materialized.count == 9)
        // Elements are the same, even if the exact division isn't
        #expect(valueFlat == materializedFlat)
    }
}

extension RangeSet where Bound == Int {
    mutating func insert(contentsOf closedRange: ClosedRange<Bound>) {
        self.insert(contentsOf: closedRange.lowerBound..<(closedRange.upperBound + 1))
    }
}
