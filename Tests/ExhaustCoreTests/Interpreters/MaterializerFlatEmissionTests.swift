//
//  MaterializerFlatEmissionTests.swift
//  Exhaust
//
//  Property: for identical inputs, flat-emission materialization produces the same outcome as tree-building materialization, and its sequence equals the fresh tree's flattening entry for entry. One test per generator shape so a failure names the operation that broke.
//

import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Materializer flat emission")
struct MaterializerFlatEmissionTests {
    // MARK: - Scalars and composites

    @Test("Scalar zip matches flattened tree")
    func scalarZip() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(0) ... 1000),
            Gen.choose(in: -500 ... 500) as Generator<Int>,
            Gen.choose(from: [true, false])
        )
        try assertFlatEmissionMatchesFlatten(gen)
    }

    @Test("Variable-length array matches flattened tree")
    func variableLengthArray() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling),
            within: 0 ... 12
        )
        try assertFlatEmissionMatchesFlatten(gen)
    }

    @Test("Nested arrays match flattened tree")
    func nestedArrays() throws {
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 0 ... 4)
        let gen = Gen.arrayOf(innerGen, within: 0 ... 4)
        try assertFlatEmissionMatchesFlatten(gen)
    }

    @Test("String matches flattened tree")
    func string() throws {
        try assertFlatEmissionMatchesFlatten(stringGen())
    }

    @Test("Zip of arrays matches flattened tree")
    func zipOfArrays() throws {
        let gen = Gen.zip(
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 1 ... 5),
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 1 ... 5)
        )
        try assertFlatEmissionMatchesFlatten(gen)
    }

    // MARK: - Branching

    @Test("Pick with sub-generators matches flattened tree")
    func pickWithSubGenerators() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (2, Gen.choose(in: UInt64(100) ... 200)),
            (1, Gen.just(UInt64(7))),
        ])
        try assertFlatEmissionMatchesFlatten(gen)
    }

    @Test("Array of picks matches flattened tree")
    func arrayOfPicks() throws {
        let elementGen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.arrayOf(Gen.choose(in: UInt64(0) ... 5), within: 1 ... 3).map { $0.reduce(0, &+) }),
        ])
        let gen = Gen.arrayOf(elementGen, within: 0 ... 6)
        try assertFlatEmissionMatchesFlatten(gen)
    }

    // MARK: - Binds

    @Test("Reified bind matches flattened tree")
    func reifiedBind() throws {
        let lengthGen = Gen.choose(in: UInt64(0) ... 8)
        let gen: Generator<[UInt64]> = Gen.liftF(.transform(
            kind: .bind(
                fingerprint: Gen.sourceFingerprint(fileID: #fileID, line: #line, column: #column),
                forward: { lengthValue in
                    let length = lengthValue as! UInt64
                    return Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: length ... length).erase()
                },
                backward: nil,
                inputType: UInt64.self,
                outputType: [UInt64].self
            ),
            inner: lengthGen.erase()
        ))
        try assertFlatEmissionMatchesFlatten(gen)
    }

    @Test("getSize-bind matches flattened tree")
    func getSizeBind() throws {
        let gen: Generator<[UInt64]> = Gen.liftF(.transform(
            kind: .bind(
                fingerprint: Gen.sourceFingerprint(fileID: #fileID, line: #line, column: #column),
                forward: { sizeValue in
                    let length = min(sizeValue as! UInt64, 5)
                    return Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: length ... length).erase()
                },
                backward: nil,
                inputType: UInt64.self,
                outputType: [UInt64].self
            ),
            inner: Gen.rawGetSize().erase()
        ))
        try assertFlatEmissionMatchesFlatten(gen)
    }

    // MARK: - Wrappers

    @Test("Filtered generator matches flattened tree")
    func filtered() throws {
        let baseGen = Gen.choose(in: UInt64(0) ... 100)
        let gen: Generator<UInt64> = .impure(
            operation: .filter(
                gen: baseGen.erase(),
                fingerprint: Gen.sourceFingerprint(fileID: #fileID, line: #line, column: #column),
                filterType: .rejectionSampling,
                predicate: { ($0 as! UInt64) % 2 == 0 },
                sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
            ),
            continuation: { .pure($0 as! UInt64) }
        )
        try assertFlatEmissionMatchesFlatten(gen)
    }

    @Test("Classified generator matches flattened tree")
    func classified() throws {
        let gen = Gen.classify(
            Gen.choose(in: UInt64(0) ... 100),
            ("small", { $0 < 50 }),
            ("large", { $0 >= 50 })
        )
        try assertFlatEmissionMatchesFlatten(gen)
    }

    @Test("Resized generator matches flattened tree")
    func resized() throws {
        let gen = Gen.resize(50, Gen.arrayOf(Gen.choose(in: 1000 ... 10000) as Generator<Int>))
        try assertFlatEmissionMatchesFlatten(gen)
    }

    @Test("Reified map matches flattened tree")
    func reifiedMap() throws {
        let gen: Generator<Int> = Gen.liftF(.transform(
            kind: .map(
                forward: { Int($0 as! UInt64) * 2 },
                backward: nil,
                inputType: UInt64.self,
                outputType: Int.self
            ),
            inner: Gen.arrayOf(Gen.choose(in: UInt64(0) ... 20), within: 1 ... 4).map { $0.reduce(0, &+) }.erase()
        ))
        try assertFlatEmissionMatchesFlatten(gen)
    }
}

// MARK: - Helpers

/// Generates parents with VACTI, then compares tree-building and flat-emission materialization on the parent's own flattening (exact mode) and on mutated candidates (guided mode).
private func assertFlatEmissionMatchesFlatten(
    _ generator: Generator<some Any>,
    runs: UInt64 = 30,
    mutationsPerRun: Int = 8,
    seed: UInt64 = 0xF1A7_E815,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let erased = generator.erase()
    var interpreter = ValueAndChoiceTreeInterpreter(generator, seed: seed, maxRuns: runs)
    var prng = Xoshiro256(seed: seed ^ 0x5EED)

    while let (_, tree) = try interpreter.next() {
        let parentSequence = ChoiceSequence.flatten(tree)
        assertBothPathsAgree(
            erased,
            prefix: parentSequence,
            mode: .exact,
            fallbackTree: tree,
            sourceLocation: sourceLocation
        )

        for _ in 0 ..< mutationsPerRun {
            let intensity = MutationIntensity.allCases[Int(prng.next(upperBound: 3))]
            let candidate = FuzzMutator.mutate(parentSequence, intensity: intensity, prng: &prng)
            assertBothPathsAgree(
                erased,
                prefix: candidate,
                mode: .guided(seed: prng.next(), fallbackTree: tree),
                fallbackTree: tree,
                sourceLocation: sourceLocation
            )
        }
    }
}

/// Runs both materialization paths on identical inputs and asserts outcome parity, sequence equality against the fresh tree's flattening, and convergence equality.
private func assertBothPathsAgree(
    _ erased: AnyGenerator,
    prefix: ChoiceSequence,
    mode: Materializer.Mode,
    fallbackTree: ChoiceTree,
    sourceLocation: SourceLocation
) {
    let treeResult = Materializer.materializeAny(erased, prefix: prefix, mode: mode, fallbackTree: fallbackTree)
    let flatResult = Materializer.materializeAnyFlat(erased, prefix: prefix, mode: mode, fallbackTree: fallbackTree)
    switch (treeResult, flatResult) {
        case let (.success(_, freshTree, treeReport), .success(_, flatSequence, flatReport)):
            let flattened = ChoiceSequence.flatten(freshTree)
            #expect(
                flatSequence == flattened,
                "flat emission \(flatSequence.shortString) diverged from flattened tree \(flattened.shortString) for prefix \(prefix.shortString)",
                sourceLocation: sourceLocation
            )
            #expect(
                treeReport?.convergence == flatReport?.convergence,
                "convergence diverged between paths for prefix \(prefix.shortString)",
                sourceLocation: sourceLocation
            )
        case (.rejected, .rejected), (.failed, .failed):
            break
        default:
            Issue.record(
                "flat emission outcome diverged from tree materialization for prefix \(prefix.shortString)",
                sourceLocation: sourceLocation
            )
    }
}
