//
//  MaterializeTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/2/2026.
//

import Foundation
import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("Materialize")
struct MaterializeTests {
    // MARK: - Helpers

    /// Reflects a value into a choice tree, flattens it, and materializes back.
    private func materializeViaReflection<Output>(
        _ gen: ReflectiveGenerator<Output>,
        _ value: Output,
    ) -> Output? {
        guard let tree = try? Interpreters.reflect(gen, with: value) else { return nil }
        let sequence = ChoiceSequence.flatten(tree)
        return try? Interpreters.materialize(gen, with: tree, using: sequence)
    }

    // MARK: - Round-trip properties

    @Test("Scalar generators round-trip through materialize")
    func scalarRoundtrip() {
        let uint64Gen = #gen(.uint64(in: 0 ... 1000))
        #exhaust(uint64Gen) { value in
            materializeViaReflection(uint64Gen, value) == value
        }

        let intGen = #gen(.int(in: -10000 ... 10000))
        #exhaust(intGen) { value in
            materializeViaReflection(intGen, value) == value
        }

        let boolGen = #gen(.bool())
        #exhaust(boolGen, .maxIterations(10)) { value in
            materializeViaReflection(boolGen, value) == value
        }

        let charGen = #gen(.character(from: .decimalDigits))
        #exhaust(charGen) { value in
            materializeViaReflection(charGen, value) == value
        }

        let justIntGen = #gen(.just(42))
        #exhaust(justIntGen, .maxIterations(10)) { value in
            materializeViaReflection(justIntGen, value) == value
        }

        let justStrGen = #gen(.just("hello"))
        #exhaust(justStrGen, .maxIterations(10)) { value in
            materializeViaReflection(justStrGen, value) == value
        }
    }

    @Test("Branching generators round-trip through materialize")
    func branchingRoundtrip() {
        let simpleGen = #gen(.oneOf(
            .just("alpha"),
            .just("beta"),
            .just("gamma"),
        ))
        #exhaust(simpleGen) { value in
            materializeViaReflection(simpleGen, value) == value
        }

        let withSubGen = #gen(.oneOf(
            .uint64(in: 0 ... 10),
            .uint64(in: 100 ... 200),
        ))
        #exhaust(withSubGen) { value in
            materializeViaReflection(withSubGen, value) == value
        }
    }

    @Test("Collection generators round-trip through materialize")
    func collectionRoundtrip() {
        let fixedGen = #gen(.uint64(in: 0 ... 100).array(length: 5 ... 5))
        #exhaust(fixedGen) { value in
            materializeViaReflection(fixedGen, value) == value
        }

        let varGen = #gen(.uint64().array(length: 2 ... 8))
        #exhaust(varGen) { value in
            materializeViaReflection(varGen, value) == value
        }

        let innerGen = #gen(.uint64(in: 0 ... 10).array(length: 3 ... 3))
        let nestedGen = innerGen.array(length: 2 ... 2)
        #exhaust(nestedGen) { value in
            materializeViaReflection(nestedGen, value) == value
        }

        let stringGen = #gen(.string())
        #exhaust(stringGen) { value in
            materializeViaReflection(stringGen, value) == value
        }
    }

    @Test("Composite generators round-trip through materialize")
    func compositeRoundtrip() {
        let zip2Gen = #gen(.uint64(), .bool())
        #exhaust(zip2Gen) { value in
            guard let mat = materializeViaReflection(zip2Gen, value) else { return false }
            return mat.0 == value.0 && mat.1 == value.1
        }

        let zip3Gen = #gen(.uint64(), .int(), .bool())
        #exhaust(zip3Gen) { value in
            guard let mat = materializeViaReflection(zip3Gen, value) else { return false }
            return mat.0 == value.0 && mat.1 == value.1 && mat.2 == value.2
        }

        let zipArrayGen = #gen(
            .uint64(in: 0 ... 100).array(length: 1 ... 5),
            .uint64(in: 0 ... 100).array(length: 1 ... 5),
        )
        #exhaust(zipArrayGen) { value in
            guard let mat = materializeViaReflection(zipArrayGen, value) else { return false }
            return mat.0 == value.0 && mat.1 == value.1
        }

        let filterGen = #gen(.uint64(in: 0 ... 100)).filter { $0 % 2 == 0 }
        #exhaust(filterGen) { value in
            materializeViaReflection(filterGen, value) == value
        }

        let classifyGen = #gen(.uint64(in: 0 ... 100)).classify(
            ("small", { $0 < 50 }),
            ("large", { $0 >= 50 }),
        )
        #exhaust(classifyGen) { value in
            materializeViaReflection(classifyGen, value) == value
        }

        let resizeGen = #gen(.int(in: 1000 ... 10000).array()).resize(50)
        #exhaust(resizeGen) { value in
            materializeViaReflection(resizeGen, value) == value
        }

        let pickArrayGen = #gen(.oneOf(
            .uint64(in: 0 ... 10).array(length: 3 ... 3),
            .uint64(in: 100 ... 200).array(length: 2 ... 2),
        ))
        #exhaust(pickArrayGen) { value in
            materializeViaReflection(pickArrayGen, value) == value
        }

        let deepGen = #gen(.uint64().array(length: 3 ... 3), .uint64(in: 0 ... 100))
        #exhaust(deepGen) { value in
            guard let mat = materializeViaReflection(deepGen, value) else { return false }
            return mat.0 == value.0 && mat.1 == value.1
        }

        let pickPart = #gen(.oneOf(
            .uint64(in: 0 ... 10),
            .uint64(in: 11 ... 20),
        ))
        let zipPickGen = #gen(pickPart, .uint64().array(length: 3 ... 3))
        #exhaust(zipPickGen) { value in
            guard let mat = materializeViaReflection(zipPickGen, value) else { return false }
            return mat.0 == value.0 && mat.1 == value.1
        }
    }

    @Test("Mapped generators round-trip through materialize")
    func mappedRoundtrip() {
        let mappedGen = #gen(.uint64(in: 0 ... 10000)).mapped(
            forward: { Int($0) },
            backward: { UInt64($0) },
        )
        #exhaust(mappedGen) { value in
            materializeViaReflection(mappedGen, value) == value
        }

        struct Point: Equatable {
            let x: UInt64
            let y: UInt64
        }
        let pointGen = #gen(.uint64(in: 0 ... 100), .uint64(in: 0 ... 100))
            .mapped(
                forward: { Point(x: $0.0, y: $0.1) },
                backward: { ($0.x, $0.y) },
            )
        #exhaust(pointGen) { value in
            materializeViaReflection(pointGen, value) == value
        }

        struct Person: Equatable {
            let age: UInt64
            let name: String
        }
        let ageGen = #gen(.oneOf(
            .uint64(in: 0 ... 10),
            .uint64(in: 11 ... 84),
        ))
        let personGen = #gen(ageGen, .string())
            .mapped(
                forward: { Person(age: $0.0, name: $0.1) },
                backward: { ($0.age, $0.name) },
            )
        #exhaust(personGen) { value in
            materializeViaReflection(personGen, value) == value
        }
    }

    @Test("Mapped-through-macro-expansion generators round-trip through materialize")
    func implicitlyMappedRoundtrip() {
        let mappedGen = #gen(.uint64(in: 0 ... 10000)) { Int($0) }
        #exhaust(mappedGen) { value in
            materializeViaReflection(mappedGen, value) == value
        }

        struct Point: Equatable {
            let x: UInt64
            let y: UInt64
        }

        let pointGen = #gen(.uint64(in: 0 ... 100), .uint64(in: 0 ... 100)) {
            Point(x: $0, y: $1)
        }
        #exhaust(pointGen) { value in
            materializeViaReflection(pointGen, value) == value
        }

        struct Person: Equatable {
            let age: UInt64
            let name: String
        }

        let ageGen = #gen(.oneOf(
            .uint64(in: 0 ... 10),
            .uint64(in: 11 ... 84),
        ))
        let personGen = #gen(ageGen, .string()) {
            Person(age: $0, name: $1)
        }
        #exhaust(personGen) { value in
            materializeViaReflection(personGen, value) == value
        }
    }

    // MARK: - Idempotence

    @Test("Materializing the same sequence twice is idempotent")
    func materializeIdempotent() {
        let gen = #gen(.int(in: -10000 ... 10000))
        #exhaust(gen) { value in
            guard let tree = try? Interpreters.reflect(gen, with: value) else { return false }
            let sequence = ChoiceSequence.flatten(tree)
            guard let first = try? Interpreters.materialize(gen, with: tree, using: sequence),
                  let second = try? Interpreters.materialize(gen, with: tree, using: sequence)
            else { return false }
            return first == second
        }
    }

    // MARK: - Sequence mutation (materialize with modified sequences)

    @Test("Materialize empty array via sequence removal")
    func materializeEmptySequence() throws {
        // Use a variable-length generator so element deletion is valid
        let gen = #gen(.uint64(in: 0 ... 10)).array(length: 0 ... 10)
        let (_, tree) = try #require(
            Array(ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42).prefix(1)).first,
        )
        let flattened = ChoiceSequence.flatten(tree)
        // Keep only non-element tokens: strip values inside the sequence
        var emptySequence: ChoiceSequence = []
        var insideSequence = false
        for element in flattened {
            switch element {
            case .sequence(true, isLengthExplicit: _):
                emptySequence.append(element)
                insideSequence = true
            case .sequence(false, isLengthExplicit: _):
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

    @Test("Materialize sequence with shrunk elements", .disabled("Size scaling changed from logarithmic to linear"))
    func materializeSequenceShrunk() throws {
        // Use a variable-length generator so element deletion is valid
        let gen = #gen(.uint64(in: 0 ... 10)).array(length: 0 ... 10)
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

    @Test("Materialize with modified values reproduces modified output")
    func materializeModifiedValues() throws {
        let gen = #gen(.uint64(in: 0 ... 1000))
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
        let gen = #gen(.uint64(in: 0 ... 100)).array(length: 5)
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
}
