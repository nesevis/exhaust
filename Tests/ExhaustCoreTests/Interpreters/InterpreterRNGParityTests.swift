//
//  InterpreterRNGParityTests.swift
//  Exhaust
//
//  Created by Claude Code on 07/02/2026.
//
//  ValueInterpreter must consume PRNG entropy identically to ValueAndChoiceTreeInterpreter,
//  so a failing run found tree-free can be reproduced with full tree construction. Every test
//  is one call to `assertParity` with a distinct generator shape.
//

import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Interpreter RNG Parity")
struct InterpreterRNGParityTests {
    // MARK: - Basic Types

    @Test("Int generation parity")
    func intGenerationParity() throws {
        try assertParity(Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling), seed: 42, runs: 10)
    }

    @Test("UInt64 generation parity")
    func uInt64GenerationParity() throws {
        try assertParity(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling), seed: 12345, runs: 10)
    }

    @Test("Bool generation parity")
    func boolGenerationParity() throws {
        try assertParity(Gen.choose(from: [true, false]), seed: 999, runs: 20)
    }

    @Test("Float generation parity")
    func floatGenerationParity() throws {
        // Compare bit patterns so a NaN on both sides still counts as equal.
        try assertParity(
            Gen.choose(in: -Float.greatestFiniteMagnitude ... Float.greatestFiniteMagnitude, scaling: Float.defaultScaling),
            seed: 7777,
            runs: 10,
            equals: { $0.bitPattern == $1.bitPattern }
        )
    }

    @Test("Double generation parity")
    func doubleGenerationParity() throws {
        try assertParity(
            Gen.choose(in: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude, scaling: Double.defaultScaling),
            seed: 8888,
            runs: 10,
            equals: { $0.bitPattern == $1.bitPattern }
        )
    }

    // MARK: - Pick Operations

    @Test("Simple pick parity with equal weights")
    func simplePickParity() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.just(100)),
            (1, Gen.just(200)),
        ])
        try assertParity(gen, seed: 42, runs: 20)
    }

    @Test("Pick parity with weighted choices")
    func weightedPickParity() throws {
        let gen = Gen.pick(choices: [
            (3, Gen.just("A")),
            (1, Gen.just("B")),
            (2, Gen.just("C")),
        ])
        try assertParity(gen, seed: 555, runs: 30)
    }

    @Test("Pick parity with generated values")
    func pickWithGeneratedValuesParity() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling)),
            (1, Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling)),
        ])
        try assertParity(gen, seed: 4, runs: 15)
    }

    @Test("Nested pick parity")
    func nestedPickParity() throws {
        let innerPick = Gen.pick(choices: [
            (1, Gen.just(1)),
            (1, Gen.just(2)),
        ])
        let outerPick = Gen.pick(choices: [
            (1, innerPick),
            (1, Gen.just(10)),
        ])
        try assertParity(outerPick, seed: 333, runs: 20)
    }

    @Test("Single element pick parity")
    func singleElementPickParity() throws {
        try assertParity(Gen.pick(choices: [(1, Gen.just(42))]), seed: 12345, runs: 5)
    }

    // MARK: - Collections

    @Test("Array generation parity")
    func arrayGenerationParity() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling), exactly: 5)
        try assertParity(gen, seed: 1111, runs: 5, materializePicks: false)
    }

    @Test("Variable length array parity")
    func variableLengthArrayParity() throws {
        let gen = Gen.arrayOf(Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling), within: UInt64(2) ... 5)
        try assertParity(gen, seed: 2222, runs: 5)
    }

    @Test("Empty array generation parity")
    func emptyArrayParity() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling), exactly: 0)
        try assertParity(gen, seed: 54321, runs: 5)
    }

    // MARK: - Zip Operations

    @Test("Zip two generators parity")
    func zipTwoParity() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling),
            Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling)
        )
        try assertParity(gen, seed: 3333, runs: 10, equals: { $0 == $1 })
    }

    @Test("Zip three generators parity")
    func zipThreeParity() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling),
            Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling),
            Gen.choose(from: [true, false])
        )
        try assertParity(gen, seed: 4444, runs: 10, equals: { $0 == $1 })
    }

    // MARK: - Map and FlatMap

    @Test("Mapped generator parity")
    func mappedGeneratorParity() throws {
        let gen = Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling).map { $0 % 100 }
        try assertParity(gen, seed: 5555, runs: 10)
    }

    @Test("FlatMapped generator parity")
    func flatMappedGeneratorParity() throws {
        let gen = Gen.choose(in: 1 ... 10 as ClosedRange<Int>).bind { size in
            Gen.arrayOf(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling), exactly: UInt64(size))
        }
        try assertParity(gen, seed: 6666, runs: 5)
    }

    // MARK: - Complex Compositions

    @Test("Complex composition parity")
    func complexCompositionParity() throws {
        let gen = Gen.zip(
            Gen.pick(choices: [
                (2, Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling)),
                (1, Gen.just(UInt64(999))),
            ]),
            Gen.arrayOf(Gen.choose(from: [true, false]), exactly: 3),
            Gen.choose(in: 0 ... 100 as ClosedRange<Int>)
        )
        try assertParity(gen, seed: 9999, runs: 10, equals: { $0 == $1 })
    }

    @Test("Deeply nested composition parity")
    func deeplyNestedCompositionParity() throws {
        let innerGen = Gen.zip(
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling),
            Gen.choose(from: [true, false])
        )
        let middleGen = Gen.pick(choices: [
            (1, innerGen.map { ($0.0, $0.1, 1) }),
            (1, innerGen.map { ($0.0, $0.1, 2) }),
        ])
        let outerGen = Gen.arrayOf(middleGen, exactly: 3)
        try assertParity(outerGen, seed: 11111, runs: 5, equals: { lhs, rhs in
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0 == $1 }
        })
    }

    @Test("Many iterations parity stress test")
    func manyIterationsParity() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling),
            Gen.choose(from: [true, false]),
            Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling)
        )
        try assertParity(gen, seed: 99999, runs: 100, equals: { $0 == $1 })
    }

    @Test("Multiple seeds produce different but consistent results", arguments: [UInt64(1), 42, 100, 999, 12345])
    func multipleSeedsParity(seed: UInt64) throws {
        try assertParity(stringGen(), seed: seed, runs: 5)
    }

    // MARK: - Unique

    @Test("Choice-sequence unique parity")
    func choiceSequenceUniqueParity() throws {
        // The load-bearing case: VI.handleUnique builds an inline VACTI context to dedup by choice sequence, while VACTI.handleUnique flattens its own tree.
        // These structurally different implementations must nonetheless consume entropy identically.
        // The inner is high-cardinality and not size-scaled so uniqueness does not exhaust the retry budget within the run.
        let gen = uniqueGen(Gen.choose(in: UInt64(0) ... UInt64.max))
        try assertParity(gen, seed: 42, runs: 10)
    }

    @Test("Key-based unique parity")
    func keyBasedUniqueParity() throws {
        let gen = uniqueGen(Gen.choose(in: UInt64(0) ... UInt64.max), by: { AnyHashable($0) })
        try assertParity(gen, seed: 4242, runs: 10)
    }

    // MARK: - Filter

    @Test("Rejection-sampling filter parity")
    func filterParity() throws {
        let gen = filterGen(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling)) { $0 % 2 == 0 }
        try assertParity(gen, seed: 1234, runs: 10)
    }

    // MARK: - Classify

    @Test("Classify parity")
    func classifyParity() throws {
        // Classify is a generation-time passthrough in both interpreters; parity confirms the classifier evaluation does not perturb PRNG consumption.
        let gen = Gen.classify(
            Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling),
            ("negative", { $0 < 0 })
        )
        try assertParity(gen, seed: 246, runs: 10)
    }

    // MARK: - Resize

    @Test("Resize parity")
    func resizeParity() throws {
        let gen = Gen.resize(
            50,
            Gen.arrayOf(Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling), within: UInt64(0) ... 8)
        )
        try assertParity(gen, seed: 777, runs: 10)
    }

    // MARK: - Metamorphic

    @Test("Metamorphic parity")
    func metamorphicParity() throws {
        // Metamorphic saves PRNG state, generates the original, then restores and re-generates once per transform.
        // Both interpreters must save and restore the same state, or the copies diverge.
        let gen = metamorphicGen(Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling))
        try assertParity(gen, seed: 8080, runs: 10)
    }
}

// MARK: - Helpers

/// Draws `runs` values from a `ValueInterpreter` and a `ValueAndChoiceTreeInterpreter` with the same seed and asserts pairwise equality via `equals`.
private func assertParity<Value>(
    _ gen: Generator<Value>,
    seed: UInt64,
    runs: Int,
    materializePicks: Bool = true,
    equals: (Value, Value) -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    var vi = ValueInterpreter(gen, seed: seed, maxRuns: UInt64(runs))
    var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: materializePicks, seed: seed, maxRuns: UInt64(runs))

    for iteration in 0 ..< runs {
        let viValue = try #require(try vi.next(), sourceLocation: sourceLocation)
        let (vactValue, _) = try #require(try vact.next(), sourceLocation: sourceLocation)
        #expect(
            equals(viValue, vactValue),
            "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)",
            sourceLocation: sourceLocation
        )
    }
}

/// Equatable convenience overload.
private func assertParity(
    _ gen: Generator<some Equatable>,
    seed: UInt64,
    runs: Int,
    materializePicks: Bool = true,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    try assertParity(gen, seed: seed, runs: runs, materializePicks: materializePicks, equals: { $0 == $1 }, sourceLocation: sourceLocation)
}

// MARK: - Operation Constructors

/// Wraps a generator with a choice-sequence `.unique` operation (no key extractor).
private func uniqueGen<Value>(_ gen: Generator<Value>) -> Generator<Value> {
    .impure(
        operation: .unique(gen: gen.erase(), fingerprint: 0, keyExtractor: nil),
        continuation: { .pure($0 as! Value) }
    )
}

/// Wraps a generator with a key-based `.unique` operation.
private func uniqueGen<Value>(
    _ gen: Generator<Value>,
    by keyExtractor: @escaping (Value) -> AnyHashable
) -> Generator<Value> {
    .impure(
        operation: .unique(gen: gen.erase(), fingerprint: 0, keyExtractor: { keyExtractor($0 as! Value) }),
        continuation: { .pure($0 as! Value) }
    )
}

/// Wraps a generator with a rejection-sampling `.filter` operation.
private func filterGen<Value>(
    _ gen: Generator<Value>,
    predicate: @escaping (Value) -> Bool
) -> Generator<Value> {
    Gen.filter(
        gen,
        type: .rejectionSampling,
        predicate: predicate,
        sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
    )
}

/// Wraps an `Int` generator with a `.metamorphic` transform, projecting `(original, +1, ×2)` to `[Int]`.
private func metamorphicGen(_ gen: Generator<Int>) -> Generator<[Int]> {
    .impure(
        operation: .transform(
            kind: .metamorphic(
                transforms: [
                    { (($0 as! Int) + 1) as Any },
                    { (($0 as! Int) * 2) as Any },
                ],
                inputType: Int.self
            ),
            inner: gen.erase()
        ),
        continuation: { .pure(($0 as! [Any]).map { $0 as! Int }) }
    )
}
