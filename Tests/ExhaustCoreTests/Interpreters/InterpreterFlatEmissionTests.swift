//
//  InterpreterFlatEmissionTests.swift
//  Exhaust
//
//  Property: for the same seed and run, the flat draw produces the same value and PRNG state as the tree-building draw, its sequence equals the tree's flattening entry for entry, and replaying the run afterwards rebuilds a tree with that flattening. One test per generator shape so a failure names the operation that broke.
//

import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Interpreter flat emission")
struct InterpreterFlatEmissionTests {
    // MARK: - Scalars and composites

    @Test("Scalar zip matches flattened tree")
    func scalarZip() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(0) ... 1000),
            Gen.choose(in: -500 ... 500) as Generator<Int>,
            Gen.choose(from: [true, false])
        )
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    @Test("Variable-length array matches flattened tree")
    func variableLengthArray() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling),
            within: 0 ... 12
        )
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    @Test("Nested arrays match flattened tree")
    func nestedArrays() throws {
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 0 ... 4)
        let gen = Gen.arrayOf(innerGen, within: 0 ... 4)
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    @Test("String matches flattened tree")
    func string() throws {
        try assertFlatDrawMatchesTreeDraw(stringGen())
    }

    @Test("Zip of arrays matches flattened tree")
    func zipOfArrays() throws {
        let gen = Gen.zip(
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 1 ... 5),
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 1 ... 5)
        )
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    // MARK: - Branching

    @Test("Pick with sub-generators matches flattened tree")
    func pickWithSubGenerators() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (2, Gen.choose(in: UInt64(100) ... 200)),
            (1, Gen.just(UInt64(7))),
        ])
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    @Test("Array of picks matches flattened tree")
    func arrayOfPicks() throws {
        let elementGen = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 10)),
            (1, Gen.arrayOf(Gen.choose(in: UInt64(0) ... 5), within: 1 ... 3).map { $0.reduce(0, &+) }),
        ])
        let gen = Gen.arrayOf(elementGen, within: 0 ... 6)
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    @Test("Backtrack with a withdrawing arm matches flattened tree")
    func backtrackWithWithdrawingArm() throws {
        // The first arm withdraws on odd draws, so about half the runs audition a failed arm whose flat entries must be truncated before the winner's are kept.
        let gen: Generator<Int> = Gen.backtrack(always: [
            (3, Gen.choose(in: 0 ... 9).map { $0.isMultiple(of: 2) ? $0 : nil }),
            (1, Gen.choose(in: 100 ... 109).liftToOptional()),
        ])
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    @Test("Array of backtracks with a continuation matches flattened tree")
    func arrayOfBacktracks() throws {
        let elementGen: Generator<Int> = Gen.backtrack(always: [
            (1, Gen.choose(in: 0 ... 9).map { $0 < 5 ? $0 : nil }),
            (1, Gen.arrayOf(Gen.choose(in: UInt64(0) ... 5), within: 1 ... 3).map { Int($0.reduce(0, &+)) }.liftToOptional()),
        ])
        let gen = Gen.zip(Gen.arrayOf(elementGen, within: 0 ... 6), Gen.choose(in: UInt64(0) ... 100))
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    @Test("Failable backtrack whose arms all withdraw matches flattened tree")
    func failableBacktrackExhausted() throws {
        let gen: Generator<Int?> = Gen.backtrack(failable: [
            (1, Gen.just(Int?.none)),
            (1, Gen.choose(in: 0 ... 9).map { _ in Int?.none }),
        ])
        try assertFlatDrawMatchesTreeDraw(gen, runs: 5)
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
        try assertFlatDrawMatchesTreeDraw(gen)
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
        try assertFlatDrawMatchesTreeDraw(gen)
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
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    @Test("Filter under a length bind matches flattened tree")
    func filterUnderLengthBind() throws {
        let elementGen = AnyGenerator.impure(
            operation: .filter(
                gen: (Gen.choose(in: 0 ... 1) as Generator<Int>).erase(),
                fingerprint: Gen.sourceFingerprint(fileID: #fileID, line: #line, column: #column),
                filterType: .auto,
                predicate: { ($0 as? Int).map { $0 > 0 } ?? false },
                sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
            ),
            continuation: { .pure($0) }
        )
        let boundArrayGen = Gen.choose(in: UInt64(0) ... 1).bind { length in
            Gen.arrayOf(elementGen, exactly: length)
        }.erase()
        let gen = Gen.classify(boundArrayGen, ("recipe", { _ in true }))
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    @Test("Classified generator matches flattened tree")
    func classified() throws {
        let gen = Gen.classify(
            Gen.choose(in: UInt64(0) ... 100),
            ("small", { $0 < 50 }),
            ("large", { $0 >= 50 })
        )
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    @Test("Resized generator matches flattened tree")
    func resized() throws {
        let gen = Gen.resize(50, Gen.arrayOf(Gen.choose(in: 1000 ... 10000) as Generator<Int>))
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    @Test("Raw Freer pure matches flattened tree")
    func rawPure() throws {
        let gen = Generator<Int>.pure(42)
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    @Test("Zip containing a raw Freer pure matches flattened tree")
    func zipWithRawPure() throws {
        let gen = Gen.zip(
            Generator<Int>.pure(7),
            Gen.choose(in: UInt64(0) ... 100),
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 1 ... 3)
        )
        try assertFlatDrawMatchesTreeDraw(gen)
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
        try assertFlatDrawMatchesTreeDraw(gen)
    }

    // MARK: - Dedup and metamorphic sites

    @Test("Unique over a sequence hash matches flattened tree and keeps its retry path")
    func uniqueSequenceHash() throws {
        // A four-value domain over many runs: later runs retry through dedup rejections, so the flat draw's per-attempt truncation and its rebased subtree hash are both exercised.
        let gen = buildGenerator(from: .combinator(.unique(.leaf(.int(0 ... 3)))))
        try assertFlatDrawMatchesTreeDraw(gen, runs: 4)
    }

    @Test("Metamorphic over unique matches flattened tree")
    func metamorphicOverUnique() throws {
        let gen = buildGenerator(from: .combinator(.metamorphed(
            .combinator(.unique(.leaf(.int(-1 ... 0)))),
            .identity
        )))
        try assertFlatDrawMatchesTreeDraw(gen, runs: 2)
    }

    @Test("Metamorphic over an array matches flattened tree")
    func metamorphicOverArray() throws {
        let gen = buildGenerator(from: .combinator(.metamorphed(
            .combinator(.array(.leaf(.int(0 ... 9)), lengthRange: 0 ... 5)),
            .identity
        )))
        try assertFlatDrawMatchesTreeDraw(gen)
    }
}

// MARK: - Helpers

/// Drives two interpreters over the same seed in lockstep, one through `next()` and one through `nextFlat()`, and asserts value, sequence, and PRNG-state parity per run, then that `reproduceWithTree()` after the flat draw rebuilds the tree.
private func assertFlatDrawMatchesTreeDraw(
    _ generator: Generator<some Any>,
    runs: UInt64 = 40,
    seed: UInt64 = 0xF1A7_D0A5,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    var treeInterpreter = ValueAndChoiceTreeInterpreter(generator, seed: seed, maxRuns: runs)
    var flatInterpreter = ValueAndChoiceTreeInterpreter(generator, seed: seed, maxRuns: runs)
    var checked = 0
    while true {
        let treeDraw = try treeInterpreter.next()
        let flatDraw = try flatInterpreter.nextFlat()
        switch (treeDraw, flatDraw) {
            case let (treeDraw?, flatDraw?):
                let flattened = ChoiceSequence.flatten(treeDraw.tree)
                #expect(
                    flatDraw.sequence == flattened,
                    "run \(checked): flat draw \(flatDraw.sequence.shortString) diverged from flattened tree \(flattened.shortString)",
                    sourceLocation: sourceLocation
                )
                // Description equality: the values are tuples and arrays of Any as often as not, and both draws consume one PRNG stream, so a rendered mismatch is the only way they can differ.
                #expect(
                    String(describing: flatDraw.value) == String(describing: treeDraw.value),
                    "run \(checked): flat draw produced \(flatDraw.value), tree draw produced \(treeDraw.value)",
                    sourceLocation: sourceLocation
                )
                #expect(
                    flatInterpreter.randomNumberGeneratorSnapshot.state == treeInterpreter.randomNumberGeneratorSnapshot.state,
                    "run \(checked): PRNG consumption diverged between the flat and tree draws",
                    sourceLocation: sourceLocation
                )
                let rebuilt = try flatInterpreter.reproduceWithTree()
                #expect(
                    rebuilt.map { ChoiceSequence.flatten($0.tree) } == flatDraw.sequence,
                    "run \(checked): tree rebuilt after the flat draw does not flatten to the draw's sequence",
                    sourceLocation: sourceLocation
                )
                checked += 1
            case (nil, nil):
                #expect(checked > 0, "no run was checked", sourceLocation: sourceLocation)
                return
            default:
                Issue.record(
                    "run \(checked): one draw path exhausted before the other",
                    sourceLocation: sourceLocation
                )
                return
        }
    }
}
