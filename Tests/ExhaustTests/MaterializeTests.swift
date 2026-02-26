//
//  MaterializeTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/2/2026.
//

import Testing
@testable import Exhaust

@Suite("Materialize")
struct MaterializeTests {
    // MARK: - Helpers

    /// Generate a value, get its tree, flatten to a sequence, then materialize.
    private func roundTrip<Output: Equatable>(
        _ gen: ReflectiveGenerator<Output>,
        seed: UInt64 = 42,
        materializePicks: Bool = false,
    ) throws -> (original: Output, materialized: Output) {
        let (value, tree) = try #require(
            Array(ValueAndChoiceTreeInterpreter(gen, materializePicks: materializePicks, seed: seed).prefix(1)).first,
        )
        let flattened = ChoiceSequence.flatten(tree)
        let materialized = try #require(try Interpreters.materialize(gen, with: tree, using: flattened))
        return (value, materialized)
    }

    /// Generate, flatten, and materialize without Equatable constraint. Returns both values for manual comparison.
    private func roundTripUntyped<Output>(
        _ gen: ReflectiveGenerator<Output>,
        seed: UInt64 = 42,
        materializePicks: Bool = false,
    ) throws -> (original: Output, materialized: Output) {
        let (value, tree) = try #require(
            Array(ValueAndChoiceTreeInterpreter(gen, materializePicks: materializePicks, seed: seed).prefix(1)).first,
        )
        let flattened = ChoiceSequence.flatten(tree)
        let materialized = try #require(try Interpreters.materialize(gen, with: tree, using: flattened))
        return (value, materialized)
    }

    // MARK: - chooseBits (primitive values)

    @Test("Materialize UInt64 via chooseBits")
    func materializeUInt64() throws {
        let gen = Gen.choose(in: UInt64(0) ... 1000)
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    @Test("Materialize Int via chooseBits")
    func materializeInt() throws {
        let gen = Int.arbitrary
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    @Test("Materialize Bool via chooseBits")
    func materializeBool() throws {
        let gen = Bool.arbitrary
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    @Test("Materialize Character via chooseBits")
    func materializeCharacter() throws {
        let gen = Character.arbitrary
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    // MARK: - just

    @Test("Materialize Gen.just constant")
    func materializeJust() throws {
        let gen = Gen.just(42)
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
        #expect(materialized == 42)
    }

    @Test("Materialize Gen.just string constant")
    func materializeJustString() throws {
        let gen = Gen.just("hello")
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    // MARK: - pick (branching)

    @Test("Materialize simple pick")
    func materializePick() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.just("alpha")),
            (1, Gen.just("beta")),
            (1, Gen.just("gamma")),
        ])
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    @Test("Materialize pick with generated sub-values")
    func materializePickWithGenerators() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.choose(in: UInt64(100) ... 200)),
        ])
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    @Test("Materialize nested pick")
    func materializeNestedPick() throws {
        let inner = Gen.pick(choices: [
            (1, Gen.just("inner1")),
            (1, Gen.just("inner2")),
        ])
        let gen = Gen.pick(choices: [
            (1, inner),
            (1, Gen.just("outer")),
        ])
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    @Test("Materialize pick across multiple seeds")
    func materializePickMultipleSeeds() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.just("A")),
            (1, Gen.just("B")),
            (1, Gen.just("C")),
        ])
        for seed in [UInt64(1), 42, 100, 999, 12345] {
            let (original, materialized) = try roundTrip(gen, seed: seed)
            #expect(original == materialized)
        }
    }

    // MARK: - sequence (arrays)

    @Test("Materialize fixed-length array")
    func materializeFixedArray() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 5)
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    @Test("Materialize variable-length array")
    func materializeVariableArray() throws {
        let gen = UInt64.arbitrary.proliferate(with: 2 ... 8)
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    @Test("Materialize empty array via sequence removal")
    func materializeEmptySequence() throws {
        // Use a variable-length generator so element deletion is valid
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 0 ... 10)
        let (_, tree) = try #require(
            Array(ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42).prefix(1)).first,
        )
        let flattened = ChoiceSequence.flatten(tree)
        // Keep only non-element tokens: strip values inside the sequence
        var emptySequence: ChoiceSequence = []
        var insideSequence = false
        for element in flattened {
            switch element {
            case .sequence(true):
                emptySequence.append(element)
                insideSequence = true
            case .sequence(false):
                emptySequence.append(element)
                insideSequence = false
            default:
                if !insideSequence {
                    emptySequence.append(element)
                }
            }
        }
        let materialized = try Interpreters.materialize(gen, with: tree, using: emptySequence)
        #expect(materialized == [])
    }

    @Test("Materialize nested arrays")
    func materializeNestedArrays() throws {
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), exactly: 3)
        let gen = Gen.arrayOf(innerGen, exactly: 2)
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    @Test("Materialize sequence with shrunk elements", .disabled("Size scaling changed from logarithmic to linear"))
    func materializeSequenceShrunk() throws {
        // Use a variable-length generator so element deletion is valid
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 0 ... 10)
        let (_, tree) = try #require(
            Array(ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42).prefix(2)).last,
        )
        var flattened = ChoiceSequence.flatten(tree)
        let originalCount = flattened.count
        flattened.remove(at: 2)
        flattened.remove(at: 2)
        let materialized = try #require(try Interpreters.materialize(gen, with: tree, using: flattened))
        #expect(materialized.count < originalCount)
    }

    // MARK: - zip (tuples / groups)

    @Test("Materialize zip of two generators")
    func materializeZipTwo() throws {
        let gen = Gen.zip(UInt64.arbitrary, Bool.arbitrary)
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    @Test("Materialize zip of three generators")
    func materializeZipThree() throws {
        let gen = Gen.zip(UInt64.arbitrary, Int.arbitrary, Bool.arbitrary)
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
        #expect(original.2 == materialized.2)
    }

    @Test("Materialize zip containing arrays")
    func materializeZipWithArrays() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(0) ... 100).proliferate(with: 1 ... 5),
            Gen.choose(in: UInt64(0) ... 100).proliferate(with: 1 ... 5),
        )
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    @Test("Materialize choose bound to zip")
    func materializeChooseBoundToZip() throws {
        let gen = Gen.choose(in: UInt64(0) ... 100)
            .bind { minimum in
                Gen.zip(
                    Gen.choose(in: minimum ... minimum + 5),
                    Gen.choose(in: minimum ... minimum + 5),
                )
            }

        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    // MARK: - contramap / mapped (bidirectional transformation)

    @Test("Materialize mapped generator")
    func materializeMapped() throws {
        let gen = UInt64.arbitrary
            .mapped(
                forward: { Int($0) },
                backward: { UInt64($0) },
            )
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    @Test("Materialize complex mapped struct")
    func materializeMappedStruct() throws {
        struct Point: Equatable {
            let x: UInt64
            let y: UInt64
        }
        let gen = Gen.zip(
            Gen.choose(in: UInt64(0) ... 100),
            Gen.choose(in: UInt64(0) ... 100),
        ).mapped(
            forward: { Point(x: $0.0, y: $0.1) },
            backward: { ($0.x, $0.y) },
        )
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    // MARK: - filter

    @Test("Materialize filtered generator")
    func materializeFiltered() throws {
        let gen = Gen.choose(in: UInt64(0) ... 100).filter { $0 % 2 == 0 }
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
        #expect(materialized % 2 == 0)
    }

    // MARK: - classify

    @Test("Materialize classified generator")
    func materializeClassified() throws {
        let gen = Gen.classify(
            Gen.choose(in: UInt64(0) ... 100),
            ("small", { $0 < 50 }),
            ("large", { $0 >= 50 }),
        )
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    // MARK: - getSize

    @Test("Materialize getSize")
    func materializeGetSize() throws {
        let gen = Gen.getSize()
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    // MARK: - resize

    @Test("Materialize resize wrapping a value")
    func materializeResize() throws {
        // resize is used internally by sized generators (e.g. proliferate)
        // Test it via a variable-length array which uses resize internally
        // This does not work very well. There is a bug here. The array length is affected yes, but so are the ranges of the UInt64s, clamped to 0...1 (limit of taking the prefix?)
        let gen = Gen.resize(50, Gen.arrayOf(Gen.choose(in: Int(1000) ... 10000)))
        let (original, materialized) = try roundTrip(gen)
        print()
        #expect(original == materialized)
    }

    // MARK: - prune (partial backward path)

    @Test("Materialize with pruned mapped generator")
    func materializePrune() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 50)),
            (1, Gen.choose(in: UInt64(51) ... 100)),
        ])
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    // MARK: - Complex compositions

    @Test("Materialize String (character sequence + pick + resize)")
    func materializeString() throws {
        let gen = String.arbitrary
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    @Test("Materialize pick of arrays")
    func materializePickOfArrays() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), exactly: 3)),
            (1, Gen.arrayOf(Gen.choose(in: UInt64(100) ... 200), exactly: 2)),
        ])
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    @Test("Materialize deeply nested composition")
    func materializeDeeplyNested() throws {
        let mid = Gen.arrayOf(UInt64.arbitrary, exactly: 3)
        let gen = Gen.zip(mid, Gen.choose(in: UInt64(0) ... 100))
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    @Test("Materialize zip containing picks and arrays")
    func materializeZipPicksArrays() throws {
        let pickGen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.choose(in: UInt64(11) ... 20)),
        ])
        let arrayGen = Gen.arrayOf(UInt64.arbitrary, exactly: 3)
        let gen = Gen.zip(pickGen, arrayGen)
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    @Test("Materialize Person struct (pick + string + zip + mapped)")
    func materializePersonStruct() throws {
        struct Person: Equatable {
            let age: UInt64
            let name: String
        }
        let ageGen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.choose(in: UInt64(11) ... 84)),
        ])
        let gen = Gen.zip(ageGen, String.arbitrary)
            .mapped(
                forward: { Person(age: $0.0, name: $0.1) },
                backward: { ($0.age, $0.name) },
            )
        let (original, materialized) = try roundTrip(gen)
        #expect(original == materialized)
    }

    // MARK: - Multiple seeds consistency

    @Test("Materialize round-trip across many seeds", arguments: [UInt64(1), 7, 42, 100, 256, 999, 5555, 12345])
    func materializeMultipleSeeds(seed: UInt64) throws {
        let gen = Gen.zip(
            UInt64.arbitrary,
            Gen.pick(choices: [
                (1, Gen.just("a")),
                (1, Gen.just("b")),
            ]),
            Bool.arbitrary,
        )
        let (original, materialized) = try roundTripUntyped(gen, seed: seed)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
        #expect(original.2 == materialized.2)
    }

    // MARK: - Sequence mutation (materialize with modified sequences)

    @Test("Materialize with modified values reproduces modified output")
    func materializeModifiedValues() throws {
        let gen = Gen.choose(in: UInt64(0) ... 1000)
        let (_, tree) = try #require(
            Array(ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42).prefix(1)).first,
        )
        let replacement = ChoiceSequenceValue.Value(choice: .unsigned(777, UInt64.self), validRanges: [0 ... 1000])
        let modified: ChoiceSequence = [.value(replacement)]
        let materialized = try Interpreters.materialize(gen, with: tree, using: modified)
        #expect(materialized == 777)
    }

    @Test("Materialize array with values set to minimum")
    func materializeArrayMinimized() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 5)
        let (_, tree) = try #require(
            Array(ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42).prefix(1)).first,
        )
        let flattened = ChoiceSequence.flatten(tree)
        let minimized = flattened.map { element -> ChoiceSequenceValue in
            guard case .value = element else { return element }
            return .value(.init(choice: .unsigned(0, UInt64.self), validRanges: []))
        }
        let materialized = try #require(try Interpreters.materialize(gen, with: tree, using: ContiguousArray(minimized)))
        #expect(materialized == [0, 0, 0, 0, 0])
    }

    // MARK: - materializeWithChoices path (via groups)

    @Test("Materialize chooseBits through group path")
    func materializeChooseBitsThroughGroup() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(0) ... 100),
            Gen.choose(in: UInt64(0) ... 100),
            Gen.choose(in: UInt64(0) ... 100),
        )
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
        #expect(original.2 == materialized.2)
    }

    @Test("Materialize just through group path")
    func materializeJustThroughGroup() throws {
        let gen = Gen.zip(Gen.just(42), Gen.just(99))
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    @Test("Materialize getSize through group path")
    func materializeGetSizeThroughGroup() throws {
        let gen = Gen.zip(Gen.getSize(), Gen.choose(in: UInt64(0) ... 10))
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    @Test("Materialize resize through group path")
    func materializeResizeThroughGroup() throws {
        // resize is exercised via proliferate (variable-length array)
        let gen = Gen.zip(
            UInt64.arbitrary.proliferate(with: 2 ... 4),
            Gen.choose(in: UInt64(0) ... 100),
        )
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    @Test("Materialize sequence through group path")
    func materializeSequenceThroughGroup() throws {
        let gen = Gen.zip(
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), exactly: 3),
            Gen.choose(in: UInt64(0) ... 100),
        )
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    @Test("Materialize contramap/prune through group path")
    func materializeContramapThroughGroup() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(100) ... 1000)
                .mapped(
                    forward: { Int($0) },
                    backward: { UInt64($0) },
                ),
            UInt64.arbitrary,
        )
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    @Test("Materialize filter through group path")
    func materializeFilterThroughGroup() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(0) ... 100).filter { $0 % 2 == 0 },
            UInt64.arbitrary,
        )
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    @Test("Materialize classify through group path")
    func materializeClassifyThroughGroup() throws {
        let gen = Gen.zip(
            Gen.classify(Gen.choose(in: UInt64(0) ... 100), ("low", { $0 < 50 })),
            UInt64.arbitrary,
        )
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    @Test("Materialize pick through group path (materializeWithChoicesHelper pick)")
    func materializePickThroughGroup() throws {
        let gen = Gen.zip(
            Gen.pick(choices: [
                (1, Gen.choose(in: UInt64(0) ... 10)),
                (1, Gen.choose(in: UInt64(11) ... 20)),
            ]),
            Gen.choose(in: UInt64(0) ... 100),
        )
        let (original, materialized) = try roundTripUntyped(gen)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    // MARK: - materializePicks mode

    @Test("Materialize pick without materializePicks")
    func materializePickWithoutMaterializePicks() throws {
        // materializePicks: false is the standard mode for materialize round-trips with picks
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.choose(in: UInt64(11) ... 20)),
        ])
        let (original, materialized) = try roundTrip(gen, materializePicks: false)
        #expect(original == materialized)
    }

    @Test("Materialize complex generator without materializePicks")
    func materializeComplexWithoutMaterializePicks() throws {
        let gen = Gen.zip(
            Gen.pick(choices: [
                (1, Gen.just("first")),
                (1, Gen.just("second")),
            ]),
            Gen.arrayOf(UInt64.arbitrary, exactly: 3),
        )
        let (original, materialized) = try roundTripUntyped(gen, materializePicks: false)
        #expect(original.0 == materialized.0)
        #expect(original.1 == materialized.1)
    }

    // MARK: - Idempotent round-trip

    @Test("Materialize same generator twice with same sequence is idempotent")
    func materializeIdempotent() throws {
        let gen = Gen.zip(
            Gen.pick(choices: [
                (1, Gen.choose(in: UInt64(0) ... 10)),
                (1, Gen.choose(in: UInt64(11) ... 20)),
            ]),
            Gen.arrayOf(UInt64.arbitrary, exactly: 3),
        )
        let (_, tree) = try #require(
            Array(ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42).prefix(1)).first,
        )
        let flattened = ChoiceSequence.flatten(tree)
        let first = try #require(try Interpreters.materialize(gen, with: tree, using: flattened))
        let second = try #require(try Interpreters.materialize(gen, with: tree, using: flattened))
        #expect(first.0 == second.0)
        #expect(first.1 == second.1)
    }
}
