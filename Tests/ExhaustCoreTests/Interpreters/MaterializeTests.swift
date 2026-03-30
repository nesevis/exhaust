//
//  MaterializeTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/2/2026.
//

import ExhaustCore
import Foundation
import Testing

@Suite("Materialize")
struct MaterializeTests {
    // MARK: - Helpers

    /// Reflects a value into a choice tree, flattens it, and materializes back.
    private func materializeViaReflection<Output>(
        _ gen: ReflectiveGenerator<Output>,
        _ value: Output
    ) -> Output? {
        guard let tree = try? Interpreters.reflect(gen, with: value) else { return nil }
        let sequence = ChoiceSequence.flatten(tree)
        switch ReductionMaterializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) {
        case let .success(output, _, _): return output
        case .rejected, .failed: return nil
        }
    }

    // MARK: - Round-trip properties

    @Test("Scalar generators round-trip through materialize")
    func scalarRoundtrip() throws {
        let uint64Gen = Gen.choose(in: UInt64(0) ... 1000)
        var uint64Iter = ValueInterpreter(uint64Gen, seed: 42, maxRuns: 200)
        while let value = try uint64Iter.next() {
            #expect(materializeViaReflection(uint64Gen, value) == value)
        }

        let intGen = Gen.choose(in: -10000 ... 10000) as ReflectiveGenerator<Int>
        var intIter = ValueInterpreter(intGen, seed: 42, maxRuns: 200)
        while let value = try intIter.next() {
            #expect(materializeViaReflection(intGen, value) == value)
        }

        let booleanGen = boolGen()
        var boolIter = ValueInterpreter(booleanGen, seed: 42, maxRuns: 10)
        while let value = try boolIter.next() {
            #expect(materializeViaReflection(booleanGen, value) == value)
        }

        let characterGen = charGen(from: .decimalDigits)
        var charIter = ValueInterpreter(characterGen, seed: 42, maxRuns: 200)
        while let value = try charIter.next() {
            #expect(materializeViaReflection(characterGen, value) == value)
        }

        let justIntGen = Gen.just(42)
        var justIntIter = ValueInterpreter(justIntGen, seed: 42, maxRuns: 10)
        while let value = try justIntIter.next() {
            #expect(materializeViaReflection(justIntGen, value) == value)
        }

        let justStrGen = Gen.just("hello")
        var justStrIter = ValueInterpreter(justStrGen, seed: 42, maxRuns: 10)
        while let value = try justStrIter.next() {
            #expect(materializeViaReflection(justStrGen, value) == value)
        }
    }

    @Test("Branching generators round-trip through materialize")
    func branchingRoundtrip() throws {
        let simpleGen = Gen.pick(choices: [
            (1, Gen.just("alpha")),
            (1, Gen.just("beta")),
            (1, Gen.just("gamma")),
        ])
        var simpleIter = ValueInterpreter(simpleGen, seed: 42, maxRuns: 200)
        while let value = try simpleIter.next() {
            #expect(materializeViaReflection(simpleGen, value) == value)
        }

        let withSubGen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.choose(in: UInt64(100) ... 200)),
        ])
        var withSubIter = ValueInterpreter(withSubGen, seed: 42, maxRuns: 200)
        while let value = try withSubIter.next() {
            #expect(materializeViaReflection(withSubGen, value) == value)
        }
    }

    @Test("Collection generators round-trip through materialize")
    func collectionRoundtrip() throws {
        let fixedGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 5 ... 5)
        var fixedIter = ValueInterpreter(fixedGen, seed: 42, maxRuns: 200)
        while let value = try fixedIter.next() {
            #expect(materializeViaReflection(fixedGen, value) == value)
        }

        let varGen = Gen.arrayOf(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling), within: 2 ... 8)
        var varIter = ValueInterpreter(varGen, seed: 42, maxRuns: 200)
        while let value = try varIter.next() {
            #expect(materializeViaReflection(varGen, value) == value)
        }

        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 3 ... 3)
        let nestedGen = Gen.arrayOf(innerGen, within: 2 ... 2)
        var nestedIter = ValueInterpreter(nestedGen, seed: 42, maxRuns: 200)
        while let value = try nestedIter.next() {
            #expect(materializeViaReflection(nestedGen, value) == value)
        }

        let strGen = stringGen()
        var strIter = ValueInterpreter(strGen, seed: 42, maxRuns: 200)
        while let value = try strIter.next() {
            #expect(materializeViaReflection(strGen, value) == value)
        }
    }

    @Test("Composite generators round-trip through materialize")
    func compositeRoundtrip() throws {
        let zip2Gen = Gen.zip(
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling),
            boolGen()
        )
        var zip2Iter = ValueInterpreter(zip2Gen, seed: 42, maxRuns: 200)
        while let value = try zip2Iter.next() {
            guard let mat = materializeViaReflection(zip2Gen, value) else {
                Issue.record("materializeViaReflection returned nil")
                continue
            }
            #expect(mat.0 == value.0 && mat.1 == value.1)
        }

        let zip3Gen = Gen.zip(
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling),
            Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling),
            boolGen()
        )
        var zip3Iter = ValueInterpreter(zip3Gen, seed: 42, maxRuns: 200)
        while let value = try zip3Iter.next() {
            guard let mat = materializeViaReflection(zip3Gen, value) else {
                Issue.record("materializeViaReflection returned nil")
                continue
            }
            #expect(mat.0 == value.0 && mat.1 == value.1 && mat.2 == value.2)
        }

        let zipArrayGen = Gen.zip(
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 1 ... 5),
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 1 ... 5)
        )
        var zipArrayIter = ValueInterpreter(zipArrayGen, seed: 42, maxRuns: 200)
        while let value = try zipArrayIter.next() {
            guard let mat = materializeViaReflection(zipArrayGen, value) else {
                Issue.record("materializeViaReflection returned nil")
                continue
            }
            #expect(mat.0 == value.0 && mat.1 == value.1)
        }

        let baseFilterGen = Gen.choose(in: UInt64(0) ... 100)
        let filterGen: ReflectiveGenerator<UInt64> = .impure(
            operation: .filter(gen: baseFilterGen.erase(), fingerprint: 0, filterType: .auto, predicate: { ($0 as! UInt64) % 2 == 0 }),
            continuation: { .pure($0 as! UInt64) }
        )
        var filterIter = ValueInterpreter(filterGen, seed: 42, maxRuns: 200)
        while let value = try filterIter.next() {
            #expect(materializeViaReflection(filterGen, value) == value)
        }

        let classifyGen = Gen.classify(
            Gen.choose(in: UInt64(0) ... 100),
            ("small", { $0 < 50 }),
            ("large", { $0 >= 50 })
        )
        var classifyIter = ValueInterpreter(classifyGen, seed: 42, maxRuns: 200)
        while let value = try classifyIter.next() {
            #expect(materializeViaReflection(classifyGen, value) == value)
        }

        let resizeGen = Gen.resize(50, Gen.arrayOf(Gen.choose(in: 1000 ... 10000) as ReflectiveGenerator<Int>))
        var resizeIter = ValueInterpreter(resizeGen, seed: 42, maxRuns: 200)
        while let value = try resizeIter.next() {
            #expect(materializeViaReflection(resizeGen, value) == value)
        }

        let pickArrayGen = Gen.pick(choices: [
            (1, Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 3 ... 3)),
            (1, Gen.arrayOf(Gen.choose(in: UInt64(100) ... 200), within: 2 ... 2)),
        ])
        var pickArrayIter = ValueInterpreter(pickArrayGen, seed: 42, maxRuns: 200)
        while let value = try pickArrayIter.next() {
            #expect(materializeViaReflection(pickArrayGen, value) == value)
        }

        let deepGen = Gen.zip(
            Gen.arrayOf(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling), within: 3 ... 3),
            Gen.choose(in: UInt64(0) ... 100)
        )
        var deepIter = ValueInterpreter(deepGen, seed: 42, maxRuns: 200)
        while let value = try deepIter.next() {
            guard let mat = materializeViaReflection(deepGen, value) else {
                Issue.record("materializeViaReflection returned nil")
                continue
            }
            #expect(mat.0 == value.0 && mat.1 == value.1)
        }

        let pickPart = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.choose(in: UInt64(11) ... 20)),
        ])
        let zipPickGen = Gen.zip(
            pickPart,
            Gen.arrayOf(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling), within: 3 ... 3)
        )
        var zipPickIter = ValueInterpreter(zipPickGen, seed: 42, maxRuns: 200)
        while let value = try zipPickIter.next() {
            guard let mat = materializeViaReflection(zipPickGen, value) else {
                Issue.record("materializeViaReflection returned nil")
                continue
            }
            #expect(mat.0 == value.0 && mat.1 == value.1)
        }
    }

    @Test("Mapped generators round-trip through materialize")
    func mappedRoundtrip() throws {
        let mappedGen = Gen.contramap(
            { (v: Int) -> UInt64 in UInt64(v) },
            Gen.choose(in: UInt64(0) ... 10000)._map { Int($0) }
        )
        var mappedIter = ValueInterpreter(mappedGen, seed: 42, maxRuns: 200)
        while let value = try mappedIter.next() {
            #expect(materializeViaReflection(mappedGen, value) == value)
        }

        struct Point: Equatable {
            let x: UInt64
            let y: UInt64
        }
        let pointGen = Gen.contramap(
            { (p: Point) -> (UInt64, UInt64) in (p.x, p.y) },
            Gen.zip(
                Gen.choose(in: UInt64(0) ... 100),
                Gen.choose(in: UInt64(0) ... 100)
            )._map { Point(x: $0.0, y: $0.1) }
        )
        var pointIter = ValueInterpreter(pointGen, seed: 42, maxRuns: 200)
        while let value = try pointIter.next() {
            #expect(materializeViaReflection(pointGen, value) == value)
        }

        struct Person: Equatable {
            let age: UInt64
            let name: String
        }
        let ageGen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.choose(in: UInt64(11) ... 84)),
        ])
        let personGen = Gen.contramap(
            { (p: Person) -> (UInt64, String) in (p.age, p.name) },
            Gen.zip(ageGen, stringGen())._map { Person(age: $0.0, name: $0.1) }
        )
        var personIter = ValueInterpreter(personGen, seed: 42, maxRuns: 200)
        while let value = try personIter.next() {
            #expect(materializeViaReflection(personGen, value) == value)
        }
    }

    // MARK: - Idempotence

    @Test("Materializing the same sequence twice is idempotent")
    func materializeIdempotent() throws {
        let gen = Gen.choose(in: -10000 ... 10000) as ReflectiveGenerator<Int>
        var iter = ValueInterpreter(gen, seed: 42, maxRuns: 200)
        while let value = try iter.next() {
            guard let tree = try? Interpreters.reflect(gen, with: value) else {
                Issue.record("reflect returned nil")
                continue
            }
            let sequence = ChoiceSequence.flatten(tree)
            guard case let .success(first, _, _) = ReductionMaterializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree),
                  case let .success(second, _, _) = ReductionMaterializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree)
            else {
                Issue.record("materialize returned nil")
                continue
            }
            #expect(first == second)
        }
    }

    // MARK: - Sequence mutation (materialize with modified sequences)

    @Test("Materialize empty array via sequence removal")
    func materializeEmptySequence() throws {
        // Use a variable-length generator so element deletion is valid
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 0 ... 10)
        var matIter1 = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42)
        let (_, tree) = try #require(matIter1.prefix(1).last)
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
        guard case let .success(materialized, _, _) = ReductionMaterializer.materialize(gen, prefix: emptySequence, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }
        #expect(materialized == [])
    }

    @Test("Materialize with modified values reproduces modified output")
    func materializeModifiedValues() throws {
        let gen = Gen.choose(in: UInt64(0) ... 1000)
        var matIter3 = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42)
        let (_, tree) = try #require(matIter3.prefix(1).last)
        let replacement = ChoiceSequenceValue.Value(choice: .unsigned(777, .uint64), validRange: 0 ... 1000)
        let modified: ChoiceSequence = [.value(replacement)]
        guard case let .success(materialized, _, _) = ReductionMaterializer.materialize(gen, prefix: modified, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }
        #expect(materialized == 777)
    }

    @Test("Materialize array with values set to minimum")
    func materializeArrayMinimized() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 5)
        var matIter4 = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42)
        let (_, tree) = try #require(matIter4.prefix(1).last)
        let flattened = ChoiceSequence.flatten(tree)
        let minimized = flattened.map { element -> ChoiceSequenceValue in
            guard case .value = element else { return element }
            return .value(.init(choice: .unsigned(0, .uint64), validRange: nil))
        }
        guard case let .success(materialized, _, _) = ReductionMaterializer.materialize(gen, prefix: ChoiceSequence(minimized), mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }
        #expect(materialized == [0, 0, 0, 0, 0])
    }
}
