//
//  InterpreterRNGParityTests.swift
//  Exhaust
//
//  Created by Claude Code on 07/02/2026.
//
//  Focused parity tests for numeric boundary domains and interpreter paths that the
//  table-driven MetaFuzz operation suite cannot represent directly.
//

import ExhaustCore
import Testing

@Suite("Interpreter RNG Parity")
struct InterpreterRNGParityTests {
    // MARK: - Basic Types

    @Test("Int generation parity")
    func intGenerationParity() throws {
        try assertParity(
            Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling),
            seed: 42,
            runs: 10
        )
    }

    @Test("UInt64 generation parity")
    func uInt64GenerationParity() throws {
        try assertParity(
            Gen.choose(
                in: UInt64.min ... UInt64.max,
                scaling: UInt64.defaultScaling
            ),
            seed: 12345,
            runs: 10
        )
    }

    @Test("Float generation parity")
    func floatGenerationParity() throws {
        // Compare bit patterns so a NaN on both sides still counts as equal.
        try assertParity(
            Gen.choose(
                in: -Float.greatestFiniteMagnitude ... Float.greatestFiniteMagnitude,
                scaling: Float.defaultScaling
            ),
            seed: 7777,
            runs: 10,
            equals: { $0.bitPattern == $1.bitPattern }
        )
    }

    @Test("Double generation parity")
    func doubleGenerationParity() throws {
        try assertParity(
            Gen.choose(
                in: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude,
                scaling: Double.defaultScaling
            ),
            seed: 8888,
            runs: 10,
            equals: { $0.bitPattern == $1.bitPattern }
        )
    }

    // MARK: - Collection Boundary

    @Test("Empty array generation parity")
    func emptyArrayParity() throws {
        let generator = Gen.arrayOf(
            Gen.choose(
                in: UInt64.min ... UInt64.max,
                scaling: UInt64.defaultScaling
            ),
            exactly: 0
        )
        try assertParity(generator, seed: 54321, runs: 5)
    }

    // MARK: - Unique

    @Test("Key-based unique parity")
    func keyBasedUniqueParity() throws {
        let generator = uniqueGen(
            Gen.choose(in: UInt64(0) ... UInt64.max),
            by: { AnyHashable($0) }
        )
        try assertParity(generator, seed: 4242, runs: 10)
    }

    @Test("Failure-tree reproduction preserves the first unique value")
    func uniqueFailureTreeReproductionPreservesValue() throws {
        let generator = uniqueGen(Gen.choose(in: UInt64(0) ... UInt64.max))
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator,
            seed: 42,
            maxRuns: 1
        )

        let originalValue = try #require(try interpreter.nextValueOnly())
        let failureTree = try interpreter.reproduceFailureTree()
        let replayedValue = try #require(try Interpreters.replay(
            generator,
            using: failureTree
        ))

        #expect(replayedValue == originalValue)
    }

    @Test("Failure-tree reproduction preserves a key-based unique value")
    func keyBasedUniqueFailureTreeReproductionPreservesValue() throws {
        let generator = uniqueGen(
            Gen.choose(in: UInt64(0) ... UInt64.max),
            by: { AnyHashable($0) }
        )
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator,
            seed: 42,
            maxRuns: 1
        )

        let originalValue = try #require(try interpreter.nextValueOnly())
        let failureTree = try interpreter.reproduceFailureTree()
        let replayedValue = try #require(try Interpreters.replay(
            generator,
            using: failureTree
        ))

        #expect(replayedValue == originalValue)
    }

    @Test("Failure-tree reproduction preserves sequence uniqueness history")
    func uniqueFailureTreeReproductionPreservesPriorHistory() throws {
        let generator = uniqueGen(Gen.choose(from: [0, 1]))
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator,
            seed: 42,
            maxRuns: 2
        )

        let firstValue = try #require(try interpreter.nextValueOnly())
        let originalValue = try #require(try interpreter.nextValueOnly())
        let failureTree = try interpreter.reproduceFailureTree()
        let replayedValue = try #require(try Interpreters.replay(
            generator,
            using: failureTree
        ))

        #expect(originalValue != firstValue)
        #expect(replayedValue == originalValue)
    }

    @Test("Failure-tree reproduction preserves unique returned from bind")
    func bindReturnedUniqueFailureTreeReproductionPreservesValue() throws {
        let generator = Gen.choose(from: [false, true]).bind { _ in
            uniqueGen(Gen.choose(in: UInt64(0) ... UInt64.max))
        }
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator,
            seed: 42,
            maxRuns: 1
        )

        let originalValue = try #require(try interpreter.nextValueOnly())
        let failureTree = try interpreter.reproduceFailureTree()
        let replayedValue = try #require(try Interpreters.replay(
            generator,
            using: failureTree
        ))

        #expect(replayedValue == originalValue)
    }

    // MARK: - Filter

    @Test("Rejection-sampling filter parity")
    func filterParity() throws {
        let generator = filterGen(
            Gen.choose(
                in: UInt64.min ... UInt64.max,
                scaling: UInt64.defaultScaling
            )
        ) { $0 % 2 == 0 }
        try assertParity(generator, seed: 1234, runs: 10)
    }

    // MARK: - Resize

    @Test("Resize applies to every size read in its lexical scope")
    func resizeScopesEverySizeRead() throws {
        let generator = Gen.resize(
            37,
            Gen.zip(Gen.rawGetSize(), Gen.rawGetSize())
        )
        var valueInterpreter = ValueInterpreter(generator, seed: 777, maxRuns: 1)
        var treeInterpreter = ValueAndChoiceTreeInterpreter(
            generator,
            seed: 777,
            maxRuns: 1
        )

        let valueOnlyResult = try #require(try valueInterpreter.next())
        let valueAndTreeResult = try #require(try treeInterpreter.next()).value

        #expect(valueOnlyResult == (37, 37))
        #expect(valueAndTreeResult == (37, 37))
    }

    @Test("Nested resize restores its enclosing scope")
    func nestedResizeRestoresEnclosingScope() throws {
        let generator = Gen.resize(
            10,
            Gen.zip(
                Gen.rawGetSize(),
                Gen.resize(3, Gen.rawGetSize()),
                Gen.rawGetSize()
            )
        )
        var valueInterpreter = ValueInterpreter(generator, seed: 777, maxRuns: 1)
        var treeInterpreter = ValueAndChoiceTreeInterpreter(
            generator,
            seed: 777,
            maxRuns: 1
        )

        let valueOnlyResult = try #require(try valueInterpreter.next())
        let valueAndTreeResult = try #require(try treeInterpreter.next()).value

        #expect(valueOnlyResult == (10, 3, 10))
        #expect(valueAndTreeResult == (10, 3, 10))
    }

    @Test("Resize restores the ambient size before its continuation")
    func resizeRestoresAmbientSizeBeforeContinuation() throws {
        let generator = Gen.resize(10, Gen.rawGetSize()).bind { scopedSize in
            Gen.zip(Gen.just(scopedSize), Gen.rawGetSize())
        }
        var valueInterpreter = ValueInterpreter(
            generator,
            seed: 777,
            maxRuns: 1,
            sizeOverride: 50
        )
        var treeInterpreter = ValueAndChoiceTreeInterpreter(
            generator,
            seed: 777,
            maxRuns: 1,
            sizeOverride: 50
        )

        let valueOnlyResult = try #require(try valueInterpreter.next())
        let valueAndTreeResult = try #require(try treeInterpreter.next()).value

        #expect(valueOnlyResult == (10, 50))
        #expect(valueAndTreeResult == (10, 50))
    }

    @Test("Resize remains active in a choice-sequence unique sub-interpreter")
    func resizeScopeSurvivesChoiceSequenceUnique() throws {
        let generator = Gen.resize(
            19,
            uniqueGen(Gen.rawGetSize())
        )
        var valueInterpreter = ValueInterpreter(generator, seed: 777, maxRuns: 1)
        var treeInterpreter = ValueAndChoiceTreeInterpreter(
            generator,
            seed: 777,
            maxRuns: 1
        )

        let valueOnlyResult = try #require(try valueInterpreter.next())
        let valueAndTreeResult = try #require(try treeInterpreter.next()).value

        #expect(valueOnlyResult == 19)
        #expect(valueAndTreeResult == 19)
    }

    @Test("Resize applies to every materialized pick alternative")
    func resizeScopeAppliesToMaterializedPickAlternatives() throws {
        let generator = Gen.resize(
            17,
            Gen.pick(choices: [
                (1, Gen.rawGetSize()),
                (1, Gen.rawGetSize()),
            ])
        )
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator,
            materializePicks: true,
            seed: 777,
            maxRuns: 1
        )

        let (_, tree) = try #require(try interpreter.next())
        guard case let .resize(newSize, resizeChoices) = tree else {
            Issue.record("Expected a resize tree")
            return
        }
        #expect(newSize == 17)
        #expect(resizeChoices.count == 1)

        let innerTree = try #require(resizeChoices.first)
        guard case let .group(branches, _) = innerTree else {
            Issue.record("Expected a materialized pick group")
            return
        }

        var recordedSizes = [UInt64]()
        for branch in branches {
            guard case let .branch(branchData) = branch,
                  case let .getSize(size) = branchData.choice
            else {
                Issue.record("Expected each pick branch to contain a size read")
                return
            }
            recordedSizes.append(size)
        }

        #expect(recordedSizes == [17, 17])
    }

    // MARK: - CGS Derivative

    @Test("Derivative sampling uses the generation interpreter's floating-point mapping")
    func derivativeFloatingPointMappingParity() throws {
        let generator = Gen.choose(in: Double(0) ... 100)
        var valueInterpreter = ValueInterpreter(
            generator,
            seed: 1234,
            maxRuns: 1,
            sizeOverride: 50
        )
        var derivativeRandomNumberGenerator = Xoshiro256.derive(
            from: 1234,
            at: 0
        )

        let generatedValue = try #require(try valueInterpreter.next())
        let derivativeValue = try #require(try CGSDerivativeInterpreter.sample(
            generator,
            using: &derivativeRandomNumberGenerator,
            size: 50
        ))

        #expect(generatedValue.bitPattern == derivativeValue.bitPattern)
    }

    @Test("Derivative sampling enforces the common sequence length limit")
    func derivativeSequenceLengthLimit() {
        let oversizedLength = UInt64(SharedInterpreterHelpers.maximumSequenceLength + 1)
        let generator = Gen.arrayOf(
            Gen.just(0),
            Gen.just(oversizedLength)
        )
        var randomNumberGenerator = Xoshiro256(seed: 42)

        #expect(throws: GeneratorError.self) {
            _ = try CGSDerivativeInterpreter.sample(
                generator,
                using: &randomNumberGenerator
            )
        }
    }
}

// MARK: - Helpers

/// Draws `runs` values from a `ValueInterpreter` and a `ValueAndChoiceTreeInterpreter` with the same seed and asserts pairwise equality via `equals`.
private func assertParity<Value>(
    _ generator: Generator<Value>,
    seed: UInt64,
    runs: Int,
    materializePicks: Bool = true,
    equals: (Value, Value) -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    var valueInterpreter = ValueInterpreter(
        generator,
        seed: seed,
        maxRuns: UInt64(runs)
    )
    var treeInterpreter = ValueAndChoiceTreeInterpreter(
        generator,
        materializePicks: materializePicks,
        seed: seed,
        maxRuns: UInt64(runs)
    )

    for iteration in 0 ..< runs {
        let valueOnly = try #require(
            try valueInterpreter.next(),
            sourceLocation: sourceLocation
        )
        let (valueAndTree, _) = try #require(
            try treeInterpreter.next(),
            sourceLocation: sourceLocation
        )
        #expect(
            equals(valueOnly, valueAndTree),
            "Iteration \(iteration): ValueInterpreter=\(valueOnly), ValueAndChoiceTreeInterpreter=\(valueAndTree)",
            sourceLocation: sourceLocation
        )
    }
}

/// Equatable convenience overload.
private func assertParity(
    _ generator: Generator<some Equatable>,
    seed: UInt64,
    runs: Int,
    materializePicks: Bool = true,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    try assertParity(
        generator,
        seed: seed,
        runs: runs,
        materializePicks: materializePicks,
        equals: { $0 == $1 },
        sourceLocation: sourceLocation
    )
}

// MARK: - Operation Constructors

/// Wraps a generator with a choice-sequence `.unique` operation (no key extractor).
private func uniqueGen<Value>(
    _ generator: Generator<Value>
) -> Generator<Value> {
    .impure(
        operation: .unique(
            gen: generator.erase(),
            fingerprint: 0,
            keyExtractor: nil
        ),
        continuation: { .pure($0 as! Value) }
    )
}

/// Wraps a generator with a key-based `.unique` operation.
private func uniqueGen<Value>(
    _ generator: Generator<Value>,
    by keyExtractor: @escaping (Value) -> AnyHashable
) -> Generator<Value> {
    .impure(
        operation: .unique(
            gen: generator.erase(),
            fingerprint: 0,
            keyExtractor: { keyExtractor($0 as! Value) }
        ),
        continuation: { .pure($0 as! Value) }
    )
}

/// Wraps a generator with a rejection-sampling `.filter` operation.
private func filterGen<Value>(
    _ generator: Generator<Value>,
    predicate: @escaping (Value) -> Bool
) -> Generator<Value> {
    Gen.filter(
        generator,
        type: .rejectionSampling,
        predicate: predicate,
        sourceLocation: FilterSourceLocation(
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
    )
}
