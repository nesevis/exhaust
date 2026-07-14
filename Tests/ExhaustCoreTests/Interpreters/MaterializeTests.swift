//
//  MaterializeTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/2/2026.
//
//  Round-trip tests: generate, reflect into a choice tree, flatten, and materialize back.
//  One test per generator shape so a failure names the operation that broke.
//

import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Materialize")
struct MaterializeTests {
    // MARK: - Scalar round-trips

    @Test("UInt64 choose round-trips through materialize")
    func uint64Roundtrip() throws {
        try assertMaterializeRoundTrip(Gen.choose(in: UInt64(0) ... 1000), runs: 200)
    }

    @Test("Int choose round-trips through materialize")
    func intRoundtrip() throws {
        try assertMaterializeRoundTrip(Gen.choose(in: -10000 ... 10000) as Generator<Int>, runs: 200)
    }

    @Test("Bool round-trips through materialize")
    func boolRoundtrip() throws {
        try assertMaterializeRoundTrip(Gen.choose(from: [true, false]), runs: 10)
    }

    @Test("Character round-trips through materialize")
    func characterRoundtrip() throws {
        try assertMaterializeRoundTrip(charGen(from: .decimalDigits), runs: 200)
    }

    @Test("Just values round-trip through materialize")
    func justRoundtrip() throws {
        try assertMaterializeRoundTrip(Gen.just(42), runs: 10)
        try assertMaterializeRoundTrip(Gen.just("hello"), runs: 10)
    }

    // MARK: - Branching round-trips

    @Test("Pick of constants round-trips through materialize")
    func pickOfConstantsRoundtrip() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.just("alpha")),
            (1, Gen.just("beta")),
            (1, Gen.just("gamma")),
        ])
        try assertMaterializeRoundTrip(gen, runs: 200)
    }

    @Test("Pick with sub-generators round-trips through materialize")
    func pickWithSubGeneratorsRoundtrip() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.choose(in: UInt64(100) ... 200)),
        ])
        try assertMaterializeRoundTrip(gen, runs: 200)
    }

    // MARK: - Collection round-trips

    @Test("Fixed-length array round-trips through materialize")
    func fixedLengthArrayRoundtrip() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 5 ... 5)
        try assertMaterializeRoundTrip(gen, runs: 200)
    }

    @Test("Variable-length array round-trips through materialize")
    func variableLengthArrayRoundtrip() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling), within: 2 ... 8)
        try assertMaterializeRoundTrip(gen, runs: 200)
    }

    @Test("Nested arrays round-trip through materialize")
    func nestedArrayRoundtrip() throws {
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 3 ... 3)
        let gen = Gen.arrayOf(innerGen, within: 2 ... 2)
        try assertMaterializeRoundTrip(gen, runs: 200)
    }

    @Test("Strings round-trip through materialize")
    func stringRoundtrip() throws {
        try assertMaterializeRoundTrip(stringGen(), runs: 200)
    }

    // MARK: - Composite round-trips

    @Test("Zip of two generators round-trips through materialize")
    func zipTwoRoundtrip() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling),
            Gen.choose(from: [true, false])
        )
        try assertMaterializeRoundTrip(gen, runs: 200, equals: { $0 == $1 })
    }

    @Test("Zip of three generators round-trips through materialize")
    func zipThreeRoundtrip() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling),
            Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling),
            Gen.choose(from: [true, false])
        )
        try assertMaterializeRoundTrip(gen, runs: 200, equals: { $0 == $1 })
    }

    @Test("Zip of two arrays round-trips through materialize")
    func zipOfArraysRoundtrip() throws {
        let gen = Gen.zip(
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 1 ... 5),
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 1 ... 5)
        )
        try assertMaterializeRoundTrip(gen, runs: 200, equals: { $0 == $1 })
    }

    @Test("Filtered generator round-trips through materialize")
    func filterRoundtrip() throws {
        let baseGen = Gen.choose(in: UInt64(0) ... 100)
        let gen: Generator<UInt64> = .impure(
            operation: .filter(
                gen: baseGen.erase(),
                fingerprint: Gen.sourceFingerprint(fileID: #fileID, line: #line, column: #column),
                filterType: .auto,
                predicate: { ($0 as! UInt64) % 2 == 0 },
                sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
            ),
            continuation: { .pure($0 as! UInt64) }
        )
        try assertMaterializeRoundTrip(gen, runs: 200)
    }

    @Test("Classified generator round-trips through materialize")
    func classifyRoundtrip() throws {
        let gen = Gen.classify(
            Gen.choose(in: UInt64(0) ... 100),
            ("small", { $0 < 50 }),
            ("large", { $0 >= 50 })
        )
        try assertMaterializeRoundTrip(gen, runs: 200)
    }

    @Test("Resized generator round-trips through materialize")
    func resizeRoundtrip() throws {
        let gen = Gen.resize(50, Gen.arrayOf(Gen.choose(in: 1000 ... 10000) as Generator<Int>))
        try assertMaterializeRoundTrip(gen, runs: 200)
    }

    @Test("Materializer preserves nested resize scopes")
    func nestedResizeScopes() throws {
        let generator = Gen.resize(
            10,
            Gen.zip(
                Gen.rawGetSize(),
                Gen.resize(3, Gen.rawGetSize()),
                Gen.rawGetSize()
            )
        )
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator,
            seed: 42,
            maxRuns: 1
        )
        let (_, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence.flatten(tree)

        guard case let .success(materialized, _, _) = Materializer.materialize(
            generator,
            prefix: sequence,
            mode: .exact,
            fallbackTree: tree
        ) else {
            Issue.record("Materialization failed")
            return
        }

        #expect(materialized == (10, 3, 10))
    }

    @Test("Materializer restores its ambient size before a resize continuation")
    func resizeContinuationUsesAmbientSize() throws {
        let generator = Gen.resize(10, Gen.rawGetSize()).bind { scopedSize in
            Gen.zip(Gen.just(scopedSize), Gen.rawGetSize())
        }
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator,
            seed: 42,
            maxRuns: 1
        )
        let (_, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence.flatten(tree)

        guard case let .success(materialized, _, _) = Materializer.materialize(
            generator,
            prefix: sequence,
            mode: .exact,
            fallbackTree: tree
        ) else {
            Issue.record("Materialization failed")
            return
        }

        #expect(materialized == (10, 100))
    }

    @Test("Pick of arrays round-trips through materialize")
    func pickOfArraysRoundtrip() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 3 ... 3)),
            (1, Gen.arrayOf(Gen.choose(in: UInt64(100) ... 200), within: 2 ... 2)),
        ])
        try assertMaterializeRoundTrip(gen, runs: 200)
    }

    @Test("Zip of array and scalar round-trips through materialize")
    func zipOfArrayAndScalarRoundtrip() throws {
        let gen = Gen.zip(
            Gen.arrayOf(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling), within: 3 ... 3),
            Gen.choose(in: UInt64(0) ... 100)
        )
        try assertMaterializeRoundTrip(gen, runs: 200, equals: { $0 == $1 })
    }

    @Test("Zip of pick and array round-trips through materialize")
    func zipOfPickAndArrayRoundtrip() throws {
        let pickPart = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.choose(in: UInt64(11) ... 20)),
        ])
        let gen = Gen.zip(
            pickPart,
            Gen.arrayOf(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling), within: 3 ... 3)
        )
        try assertMaterializeRoundTrip(gen, runs: 200, equals: { $0 == $1 })
    }

    // MARK: - Mapped round-trips

    @Test("Contramapped scalar round-trips through materialize")
    func contramappedScalarRoundtrip() throws {
        let gen = Gen.contramap(
            { (v: Int) -> UInt64 in UInt64(v) },
            Gen.choose(in: UInt64(0) ... 10000).map { Int($0) }
        )
        try assertMaterializeRoundTrip(gen, runs: 200)
    }

    @Test("Contramapped struct round-trips through materialize")
    func contramappedStructRoundtrip() throws {
        struct Point: Equatable {
            let x: UInt64
            let y: UInt64
        }
        let gen = Gen.contramap(
            { (p: Point) -> (UInt64, UInt64) in (p.x, p.y) },
            Gen.zip(
                Gen.choose(in: UInt64(0) ... 100),
                Gen.choose(in: UInt64(0) ... 100)
            ).map { Point(x: $0.0, y: $0.1) }
        )
        try assertMaterializeRoundTrip(gen, runs: 200)
    }

    @Test("Contramapped struct with pick and string round-trips through materialize")
    func contramappedPickStringStructRoundtrip() throws {
        struct Person: Equatable {
            let age: UInt64
            let name: String
        }
        let ageGen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.choose(in: UInt64(11) ... 84)),
        ])
        let gen = Gen.contramap(
            { (p: Person) -> (UInt64, String) in (p.age, p.name) },
            Gen.zip(ageGen, stringGen()).map { Person(age: $0.0, name: $0.1) }
        )
        try assertMaterializeRoundTrip(gen, runs: 200)
    }

    // MARK: - Idempotence

    @Test("Materializing the same sequence twice is idempotent")
    func materializeIdempotent() throws {
        let gen = Gen.choose(in: -10000 ... 10000) as Generator<Int>
        var iter = ValueInterpreter(gen, seed: 42, maxRuns: 200)
        while let value = try iter.next() {
            guard let tree = try? Interpreters.reflect(gen, with: value) else {
                Issue.record("reflect returned nil")
                continue
            }
            let sequence = ChoiceSequence.flatten(tree)
            guard case let .success(first, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree),
                  case let .success(second, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree)
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
                case .sequence(true, validRange: _, isLengthExplicit: _):
                    emptySequence.append(element)
                    insideSequence = true
                case .sequence(false, validRange: _, isLengthExplicit: _):
                    emptySequence.append(element)
                    insideSequence = false
                default:
                    if insideSequence == false {
                        emptySequence.append(element)
                    }
            }
        }
        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: emptySequence, mode: .exact, fallbackTree: tree) else {
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
        let replacement = ChoiceSequenceValue.Value(choice: ChoiceValue(UInt64(777), tag: .uint64), validRange: 0 ... 1000)
        let modified: ChoiceSequence = [.value(replacement)]
        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: modified, mode: .exact, fallbackTree: tree) else {
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
            return .value(.init(choice: ChoiceValue(UInt64(0), tag: .uint64), validRange: nil))
        }
        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: ChoiceSequence(minimized), mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }
        #expect(materialized == [0, 0, 0, 0, 0])
    }

    // MARK: - Sequence continuation tree completeness

    @Test("Sequence with non-pure continuation preserves continuation tree (VACTI)")
    func sequenceContinuationTreeVACTI() throws {
        // Gen.shuffled chains a FreerMonad.bind after an arrayOf (.sequence),
        // making the sequence's continuation non-pure. The continuation produces
        // a second .sequence (sort keys) whose tree nodes must be preserved.
        let gen = Gen.shuffled(Gen.arrayOf(
            Gen.choose(in: UInt64(0) ... 100),
            exactly: 3
        ))
        var iter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42, maxRuns: 20)
        var roundTripFailures = 0
        var total = 0
        while let (value, tree) = try iter.next() {
            total += 1
            let sequence = ChoiceSequence.flatten(tree)
            switch Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) {
                case let .success(materialized, _, _):
                    if materialized != value {
                        roundTripFailures += 1
                    }
                case .rejected, .failed:
                    roundTripFailures += 1
            }
        }
        #expect(total > 0)
        #expect(roundTripFailures == 0, "VACTI tree missing continuation nodes: \(roundTripFailures)/\(total) round-trips failed")
    }

    @Test("Sequence with non-pure continuation preserves continuation tree (direct bind)")
    func sequenceContinuationTreeDirectBind() throws {
        // Directly exercise FreerMonad.bind after a .sequence operation:
        // generate a 2-element array, then bind to choose an index into it.
        let arrayGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 50), exactly: 2)
        let gen: Generator<UInt64> = arrayGen.bind { array in
            Gen.choose(in: UInt64(0) ... UInt64(array.count))
        }
        var iter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 99, maxRuns: 20)
        var roundTripFailures = 0
        var total = 0
        while let (value, tree) = try iter.next() {
            total += 1
            let sequence = ChoiceSequence.flatten(tree)
            switch Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) {
                case let .success(materialized, _, _):
                    if materialized != value {
                        roundTripFailures += 1
                    }
                case .rejected, .failed:
                    roundTripFailures += 1
            }
        }
        #expect(total > 0)
        #expect(roundTripFailures == 0, "VACTI tree missing continuation nodes: \(roundTripFailures)/\(total) round-trips failed")
    }
}

// MARK: - Helpers

/// Reflects a value into a choice tree, flattens it, and materializes back.
private func materializeViaReflection<Output>(
    _ gen: Generator<Output>,
    _ value: Output
) -> Output? {
    guard let tree = try? Interpreters.reflect(gen, with: value) else { return nil }
    let sequence = ChoiceSequence.flatten(tree)
    switch Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) {
        case let .success(output, _, _): return output
        case .rejected, .failed: return nil
    }
}

/// Generates `runs` values and asserts each one survives reflect → flatten → materialize unchanged.
private func assertMaterializeRoundTrip<Output>(
    _ gen: Generator<Output>,
    seed: UInt64 = 42,
    runs: UInt64,
    equals: (Output, Output) -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    var iterator = ValueInterpreter(gen, seed: seed, maxRuns: runs)
    while let value = try iterator.next() {
        guard let materialized = materializeViaReflection(gen, value) else {
            Issue.record("materializeViaReflection returned nil for \(value)", sourceLocation: sourceLocation)
            continue
        }
        #expect(equals(materialized, value), "Materialized \(materialized) != original \(value)", sourceLocation: sourceLocation)
    }
}

/// Equatable convenience overload.
private func assertMaterializeRoundTrip(
    _ gen: Generator<some Equatable>,
    seed: UInt64 = 42,
    runs: UInt64,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    try assertMaterializeRoundTrip(gen, seed: seed, runs: runs, equals: { $0 == $1 }, sourceLocation: sourceLocation)
}
