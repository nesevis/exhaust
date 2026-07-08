//
//  PropertyTests.swift
//  ExhaustTests
//
//  Property-based tests covering core invariants of Exhaust's bidirectional
//  architecture, shrink ordering, and size-scaling math.
//
//  NOTE: #exhaust, .bool(), .asciiString(), .character(from:), .optional(), .oneOf, .filter
//  are Exhaust-only. Converted to ExhaustCore Gen.* API equivalents.
//  .filter and .optional() tests noted where they use Exhaust-only features.
//

import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

// MARK: - Size Scaling Properties

@Suite("Size Scaling")
struct SizeScalingPropertyTests {
    @Test("scaledRange monotonically expands as size increases")
    func scaledRangeMonotonicity() throws {
        let range = UInt64(0) ... UInt64(10000)
        let sizeGen = Gen.zip(
            Gen.choose(in: UInt64(1) ... 99),
            Gen.choose(in: UInt64(1) ... 99)
        )

        // Linear scaling
        try exhaustCheck(sizeGen) { s1, s2 in
            let lo = min(s1, s2)
            let hi = max(s1, s2)
            guard lo < hi else { return true }
            let r1 = Gen.scaledRange(range, scaling: .linear, size: lo)
            let r2 = Gen.scaledRange(range, scaling: .linear, size: hi)
            return r2.lowerBound <= r1.lowerBound && r2.upperBound >= r1.upperBound
        }

        // Exponential scaling
        try exhaustCheck(sizeGen) { s1, s2 in
            let lo = min(s1, s2)
            let hi = max(s1, s2)
            guard lo < hi else { return true }
            let r1 = Gen.scaledRange(range, scaling: .exponential, size: lo)
            let r2 = Gen.scaledRange(range, scaling: .exponential, size: hi)
            return r2.lowerBound <= r1.lowerBound && r2.upperBound >= r1.upperBound
        }

        // Constant scaling: range must equal input at all sizes
        try exhaustCheck(Gen.choose(in: UInt64(0) ... 100)) { size in
            let r = Gen.scaledRange(range, scaling: .constant, size: size)
            return r == range
        }
    }

    @Test("scaledDistance is monotonically non-decreasing in fraction")
    func scaledDistanceMonotonicity() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(1) ... 10000),
            Gen.choose(in: UInt64(0) ... 99),
            Gen.choose(in: UInt64(0) ... 99)
        )

        // Linear
        try exhaustCheck(gen) { distance, f1Raw, f2Raw in
            let fLo = Double(min(f1Raw, f2Raw)) / 100.0
            let fHi = Double(max(f1Raw, f2Raw)) / 100.0
            guard fLo < fHi else { return true }
            let d1 = Gen.scaledDistance(distance, fraction: fLo, isExponential: false)
            let d2 = Gen.scaledDistance(distance, fraction: fHi, isExponential: false)
            return d1 <= d2
        }

        // Exponential
        try exhaustCheck(gen) { distance, f1Raw, f2Raw in
            let fLo = Double(min(f1Raw, f2Raw)) / 100.0
            let fHi = Double(max(f1Raw, f2Raw)) / 100.0
            guard fLo < fHi else { return true }
            let d1 = Gen.scaledDistance(distance, fraction: fLo, isExponential: true)
            let d2 = Gen.scaledDistance(distance, fraction: fHi, isExponential: true)
            return d1 <= d2
        }

        // Result is always <= distance
        try exhaustCheck(Gen.zip(
            Gen.choose(in: UInt64(0) ... 100_000),
            Gen.choose(in: UInt64(0) ... 100)
        )) { distance, fRaw in
            let fraction = Double(fRaw) / 100.0
            let linear = Gen.scaledDistance(distance, fraction: fraction, isExponential: false)
            let exponential = Gen.scaledDistance(distance, fraction: fraction, isExponential: true)
            return linear <= distance && exponential <= distance
        }
    }
}

// MARK: - FloatShortlex Properties

@Suite("FloatShortlex")
struct FloatShortlexPropertyTests {
    @Test("Simple non-negative integers have shortlexKey equal to their value")
    func simpleIntegerIdentity() throws {
        try exhaustCheck(Gen.choose(in: UInt64(0) ... (1 << 20))) { n in
            FloatShortlex.shortlexKey(for: Double(n)) == n
        }
    }

    @Test("Magnitude ordering preserved among simple non-negative integers")
    func magnitudeOrdering() throws {
        try exhaustCheck(Gen.zip(
            Gen.choose(in: UInt64(0) ... (1 << 20)),
            Gen.choose(in: UInt64(0) ... (1 << 20))
        )) { a, b in
            guard a < b else { return true }
            return FloatShortlex.shortlexKey(for: Double(a)) < FloatShortlex.shortlexKey(for: Double(b))
        }
    }

    @Test("reverseLowerBits is an involution")
    func reverseLowerBitsInvolution() throws {
        try exhaustCheck(Gen.zip(
            Gen.choose(in: UInt64(0) ... ((1 << 20) - 1)),
            Gen.choose(in: UInt64(1) ... 63)
        )) { rawX, countRaw in
            let count = Int(countRaw)
            let mask: UInt64 = countRaw >= 64 ? UInt64.max : (UInt64(1) << countRaw) - 1
            let x = rawX & mask
            let reversed = FloatShortlex.reverseLowerBits(x, count: count)
            let doubleReversed = FloatShortlex.reverseLowerBits(reversed, count: count)
            return doubleReversed == x
        }
    }
}

// MARK: - Replay vs Materializer Equivalence

@Suite("Replay-Materializer Equivalence")
struct ReplayMaterializerEquivalenceTests {
    @Test("Replay and Materializer produce identical values for integer generators")
    func integerEquivalence() throws {
        let gen: Generator<Int> = Gen.choose(in: -1000 ... 1000)
        try assertReplayMaterializerEquivalence(gen)
    }

    @Test("Replay and Materializer produce identical values for array generators")
    func arrayEquivalence() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: 0 ... 100) as Generator<Int>,
            within: 1 ... 5
        )
        try assertReplayMaterializerEquivalence(gen)
    }

    @Test("Replay and Materializer produce identical values for pick generators")
    func pickEquivalence() throws {
        let gen: Generator<Int> = Gen.pick(choices: [
            (1, Gen.choose(in: 0 ... 50)),
            (1, Gen.choose(in: 100 ... 200)),
        ])
        try assertReplayMaterializerEquivalence(gen)
    }

    @Test("Replay and Materializer produce identical values for zip generators")
    func zipEquivalence() throws {
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 100) as Generator<Int>,
            Gen.choose(in: -50 ... 50) as Generator<Int>
        )
        try assertReplayMaterializerEquivalence(gen, isEqual: { $0.0 == $1.0 && $0.1 == $1.1 })
    }

    @Test("Replay and Materializer produce identical values for nested generators")
    func nestedEquivalence() throws {
        let gen = Gen.arrayOf(
            Gen.pick(choices: [
                (1, Gen.choose(in: 0 ... 10) as Generator<Int>),
                (1, Gen.choose(in: 100 ... 110)),
            ]),
            within: 1 ... 3
        )
        try assertReplayMaterializerEquivalence(gen)
    }
}

private func assertReplayMaterializerEquivalence(
    _ gen: Generator<some Equatable>,
    maxIterations: Int = 200
) throws {
    try assertReplayMaterializerEquivalence(gen, maxIterations: maxIterations, isEqual: ==)
}

private func assertReplayMaterializerEquivalence<Output>(
    _ gen: Generator<Output>,
    maxIterations: Int = 200,
    isEqual: @escaping (Output, Output) -> Bool
) throws {
    try exhaustCheck(gen, maxIterations: UInt64(maxIterations)) { value in
        guard let tree = try? Interpreters.reflect(gen, with: value) else { return true }
        guard let replayed: Output = try? Interpreters.replay(gen, using: tree) else { return false }

        // Reproduction is `.exact` mode: it reads every choice — including branch selection — from the flattened prefix. `.guided` re-selects pick branches from its seed (it is for exploration, not reproduction), so it agrees with replay only for branch-free generators.
        let materializeResult = Materializer.materialize(
            gen,
            prefix: ChoiceSequence.flatten(tree),
            mode: .exact,
            fallbackTree: tree
        )
        guard case let .success(materialized, _, _) = materializeResult else { return false }

        return isEqual(replayed, materialized)
    }
}

// MARK: - shortlexKey / fromShortlexKey Properties

@Suite("ShortlexKey Roundtrip")
struct ShortlexKeyPropertyTests {
    @Test("fromShortlexKey inverts shortlexKey for signed integers")
    func signedShortlexRoundtrip() throws {
        try exhaustCheck(Gen.choose(in: Int64(-50000) ... 50000)) { rawValue in
            let value = ChoiceValue(rawValue, tag: .int64)
            let key = value.shortlexKey
            let recovered = ChoiceValue.fromShortlexKey(key, tag: .int64)
            return recovered == value
        }
    }

    @Test("shortlexKey orders signed integers by proximity to zero")
    func signedShortlexOrdering() throws {
        try exhaustCheck(Gen.zip(
            Gen.choose(in: Int64(-50000) ... 50000),
            Gen.choose(in: Int64(-50000) ... 50000)
        )) { a, b in
            guard abs(a) < abs(b) else { return true }
            let va = ChoiceValue(a, tag: .int64)
            let vb = ChoiceValue(b, tag: .int64)
            return va.shortlexKey < vb.shortlexKey
        }
    }
}

// MARK: - Generator Contract Properties

@Suite("Generator Contracts")
struct GeneratorContractPropertyTests {
    @Test("Gen.choose always produces values within the specified range")
    func chooseRangeContainment() throws {
        try exhaustCheck(Gen.choose(in: -500 ... 500) as Generator<Int>) { value in
            value >= -500 && value <= 500
        }

        try exhaustCheck(Gen.choose(in: UInt64(10) ... 10000)) { value in
            value >= 10 && value <= 10000
        }

        let doubleGen: Generator<Double> = Gen.choose(in: -1.0 ... 1.0)
        try exhaustCheck(doubleGen) { value in
            value >= -1.0 && value <= 1.0
        }
    }

    @Test("Gen.just always produces its constant value")
    func justConstancy() throws {
        let gen = Gen.just(42)
        try exhaustCheck(gen) { value in
            value == 42
        }
    }

    @Test("A sequence length above the maximum throws rather than trapping or over-allocating")
    func oversizedSequenceLengthThrows() {
        let tooLong = UInt64(SharedInterpreterHelpers.maximumSequenceLength) + 1
        let gen = Gen.arrayOf(Gen.choose(in: 0 ... 10) as Generator<Int>, exactly: tooLong)

        var treeInterpreter = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 1)
        #expect(throws: GeneratorError.self) {
            _ = try treeInterpreter.next()
        }

        var valueInterpreter = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 1)
        #expect(throws: GeneratorError.self) {
            _ = try valueInterpreter.nextValueOnly()
        }
    }
}

// MARK: - Shrinking Properties

@Suite("Shrinking Invariants")
struct ShrinkingPropertyTests {
    @Test("Shrinking preserves counterexample status")
    func shrinkingPreservesFailure() throws {
        let gen: Generator<Int> = Gen.choose(in: 0 ... 10000)
        let property: (Int) -> Bool = { $0 < 50 }

        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 50)
        while let (value, tree) = try iterator.next() {
            guard property(value) == false else { continue }
            guard case let .reduced(_, _, shrunk) = try Interpreters.choiceGraphReduce(
                gen: gen, tree: tree, config: .init(maxStalls: 2), property: property
            ) else { continue }
            #expect(property(shrunk) == false, "Shrunk value \(shrunk) no longer fails the property")
        }
    }
}

// MARK: - ChoiceValue Comparable Consistency

@Suite("ChoiceValue Comparable")
struct ChoiceValueComparablePropertyTests {
    @Test("Unsigned ChoiceValue ordering agrees with natural UInt64 ordering")
    func unsignedComparableConsistency() throws {
        try exhaustCheck(Gen.zip(
            Gen.choose(in: UInt64(0) ... 100_000),
            Gen.choose(in: UInt64(0) ... 100_000)
        )) { a, b in
            let va = ChoiceValue(a, tag: .uint64)
            let vb = ChoiceValue(b, tag: .uint64)
            if a < b { return va < vb }
            if a > b { return vb < va }
            return va == vb
        }
    }
}
