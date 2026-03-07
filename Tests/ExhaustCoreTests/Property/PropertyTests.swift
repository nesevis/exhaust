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

import Foundation
import Testing
@testable import ExhaustCore

// MARK: - Roundtrip Properties

@Suite("Generate-Reflect-Replay Roundtrip")
struct RoundtripPropertyTests {
    @Test("Primitive generators round-trip through reflect and replay")
    func primitiveRoundtrip() throws {
        let intGen: ReflectiveGenerator<Int> = Gen.choose(in: -1000 ... 1000)
        try exhaustCheck(intGen) { value in
            guard let tree = try? Interpreters.reflect(intGen, with: value),
                  let replayed = try? Interpreters.replay(intGen, using: tree)
            else { return false }
            return replayed == value
        }

        let doubleGen: ReflectiveGenerator<Double> = Gen.choose(in: -1000.0 ... 1000.0)
        try exhaustCheck(doubleGen) { value in
            guard let tree = try? Interpreters.reflect(doubleGen, with: value),
                  let replayed = try? Interpreters.replay(doubleGen, using: tree)
            else { return false }
            return replayed == value
        }

        let boolGen = Gen.choose(from: [true, false])
        try exhaustCheck(boolGen, maxIterations: 50) { value in
            guard let tree = try? Interpreters.reflect(boolGen, with: value),
                  let replayed = try? Interpreters.replay(boolGen, using: tree)
            else { return false }
            return replayed == value
        }

        let asciiGen = asciiStringGen(length: 1 ... 10)
        try exhaustCheck(asciiGen) { value in
            guard let tree = try? Interpreters.reflect(asciiGen, with: value),
                  let replayed = try? Interpreters.replay(asciiGen, using: tree)
            else { return false }
            return replayed == value
        }

        let charGen = characterGen(from: .decimalDigits)
        try exhaustCheck(charGen) { value in
            guard let tree = try? Interpreters.reflect(charGen, with: value),
                  let replayed = try? Interpreters.replay(charGen, using: tree)
            else { return false }
            return replayed == value
        }
    }

    @Test("Composed generators round-trip through reflect and replay")
    func composedRoundtrip() throws {
        // Array
        let arrayGen = Gen.arrayOf(Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>, within: 1 ... 5)
        try exhaustCheck(arrayGen) { value in
            guard let tree = try? Interpreters.reflect(arrayGen, with: value),
                  let replayed = try? Interpreters.replay(arrayGen, using: tree)
            else { return false }
            return replayed == value
        }

        // Optional — .optional() is Exhaust-only, using Gen.pick equivalent
        let innerIntGen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 100)
        let optionalGen: ReflectiveGenerator<Int?> = Gen.pick(choices: [
            (1, Gen.just(Optional<Int>.none)),
            (5, innerIntGen._map { Optional($0) }),
        ])
        try exhaustCheck(optionalGen) { value in
            guard let tree = try? Interpreters.reflect(optionalGen, with: value),
                  let replayed = try? Interpreters.replay(optionalGen, using: tree)
            else { return false }
            return replayed == value
        }

        // Zip (tuple)
        let zipGen = Gen.zip(
            Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>,
            Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>,
        )
        try exhaustCheck(zipGen) { value in
            guard let tree = try? Interpreters.reflect(zipGen, with: value),
                  let replayed = try? Interpreters.replay(zipGen, using: tree)
            else { return false }
            return replayed == value
        }

        // oneOf → Gen.pick
        let oneOfGen: ReflectiveGenerator<Int> = Gen.pick(choices: [
            (1, Gen.choose(in: 0 ... 50)),
            (1, Gen.choose(in: 100 ... 200)),
        ])
        try exhaustCheck(oneOfGen) { value in
            guard let tree = try? Interpreters.reflect(oneOfGen, with: value),
                  let replayed = try? Interpreters.replay(oneOfGen, using: tree)
            else { return false }
            return replayed == value
        }
    }
}

// MARK: - Size Scaling Properties

@Suite("Size Scaling")
struct SizeScalingPropertyTests {
    @Test("scaledRange monotonically expands as size increases")
    func scaledRangeMonotonicity() throws {
        let range = UInt64(0) ... UInt64(10000)
        let sizeGen = Gen.zip(
            Gen.choose(in: UInt64(1) ... 99),
            Gen.choose(in: UInt64(1) ... 99),
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
            Gen.choose(in: UInt64(0) ... 99),
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
            Gen.choose(in: UInt64(0) ... 100),
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
            Gen.choose(in: UInt64(0) ... (1 << 20)),
        )) { a, b in
            guard a < b else { return true }
            return FloatShortlex.shortlexKey(for: Double(a)) < FloatShortlex.shortlexKey(for: Double(b))
        }
    }

    @Test("reverseLowerBits is an involution")
    func reverseLowerBitsInvolution() throws {
        try exhaustCheck(Gen.zip(
            Gen.choose(in: UInt64(0) ... ((1 << 20) - 1)),
            Gen.choose(in: UInt64(1) ... 63),
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

// MARK: - Replay Idempotence

@Suite("Replay Idempotence")
struct ReplayIdempotencePropertyTests {
    @Test("Replaying the same tree always produces the same value")
    func replayIdempotence() throws {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: -10000 ... 10000)
        try exhaustCheck(gen) { value in
            guard let tree = try? Interpreters.reflect(gen, with: value),
                  let replay1 = try? Interpreters.replay(gen, using: tree),
                  let replay2 = try? Interpreters.replay(gen, using: tree),
                  let replay3 = try? Interpreters.replay(gen, using: tree)
            else { return false }
            return replay1 == replay2 && replay2 == replay3
        }
    }
}

// MARK: - ChoiceValue Properties

@Suite("ChoiceValue Complexity")
struct ChoiceValuePropertyTests {
    @Test("semanticSimplest always has complexity <= the original value")
    func semanticSimplestMinimalComplexity() throws {
        // Unsigned
        try exhaustCheck(Gen.choose(in: UInt64(0) ... 100_000)) { rawValue in
            let value = ChoiceValue.unsigned(rawValue, .uint64)
            return value.semanticSimplest.complexity <= value.complexity
        }

        // Signed
        try exhaustCheck(Gen.choose(in: Int64(-50000) ... 50000)) { rawValue in
            let value = ChoiceValue(rawValue, tag: .int64)
            return value.semanticSimplest.complexity <= value.complexity
        }

        // Floating
        try exhaustCheck(Gen.choose(in: -1000.0 ... 1000.0) as ReflectiveGenerator<Double>) { rawValue in
            let value = ChoiceValue(rawValue, tag: .double)
            return value.semanticSimplest.complexity <= value.complexity
        }
    }

    @Test("Unsigned ChoiceValue complexity strictly increases with value")
    func unsignedComplexityMonotonicity() throws {
        try exhaustCheck(Gen.zip(
            Gen.choose(in: UInt64(0) ... 100_000),
            Gen.choose(in: UInt64(0) ... 100_000),
        )) { a, b in
            guard a < b else { return true }
            let va = ChoiceValue.unsigned(a, .uint64)
            let vb = ChoiceValue.unsigned(b, .uint64)
            return va.complexity < vb.complexity
        }
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
            Gen.choose(in: Int64(-50000) ... 50000),
        )) { a, b in
            guard abs(a) < abs(b) else { return true }
            let va = ChoiceValue(a, tag: .int64)
            let vb = ChoiceValue(b, tag: .int64)
            return va.shortlexKey < vb.shortlexKey
        }
    }
}

// MARK: - Materialize / Replay Agreement

@Suite("Interpreter Agreement")
struct InterpreterAgreementPropertyTests {
    @Test("Materialize with flattened tree agrees with replay")
    func materializeAgreesWithReplay() throws {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: -1000 ... 1000)
        try exhaustCheck(gen) { value in
            guard let tree = try? Interpreters.reflect(gen, with: value),
                  let replayed = try? Interpreters.replay(gen, using: tree)
            else { return false }
            let sequence = ChoiceSequence.flatten(tree)
            guard let materialized = try? Interpreters.materialize(gen, with: tree, using: sequence)
            else { return false }
            return materialized == replayed
        }
    }

    @Test("Reflect stabilizes after one round")
    func reflectIdempotence() throws {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: -1000 ... 1000)
        try exhaustCheck(gen) { value in
            guard let tree1 = try? Interpreters.reflect(gen, with: value),
                  let replayed = try? Interpreters.replay(gen, using: tree1),
                  let tree2 = try? Interpreters.reflect(gen, with: replayed)
            else { return false }
            // The replayed value should produce an equivalent tree
            guard let replayed2 = try? Interpreters.replay(gen, using: tree2)
            else { return false }
            return replayed == replayed2
        }
    }
}

// MARK: - Generator Contract Properties

@Suite("Generator Contracts")
struct GeneratorContractPropertyTests {
    @Test("Gen.choose always produces values within the specified range")
    func chooseRangeContainment() throws {
        try exhaustCheck(Gen.choose(in: -500 ... 500) as ReflectiveGenerator<Int>) { value in
            value >= -500 && value <= 500
        }

        try exhaustCheck(Gen.choose(in: UInt64(10) ... 10000)) { value in
            value >= 10 && value <= 10000
        }

        let doubleGen: ReflectiveGenerator<Double> = Gen.choose(in: -1.0 ... 1.0)
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
}

// MARK: - Shrinking Properties

@Suite("Shrinking Invariants")
struct ShrinkingPropertyTests {
    @Test("Shrinking preserves counterexample status")
    func shrinkingPreservesFailure() throws {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 10000)
        let property: (Int) -> Bool = { $0 < 50 }

        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 50)
        while let (value, tree) = try iterator.next() {
            guard !property(value) else { continue }
            guard let (_, shrunk) = try Interpreters.reduce(
                gen: gen, tree: tree, config: .fast, property: property,
            ) else { continue }
            #expect(!property(shrunk), "Shrunk value \(shrunk) no longer fails the property")
        }
    }

    @Test("Shrinking produces simpler choice sequences")
    func shrinkingReducesComplexity() throws {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 10000)
        let property: (Int) -> Bool = { $0 < 50 }

        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 50)
        while let (value, tree) = try iterator.next() {
            guard !property(value) else { continue }
            let originalSequence = ChoiceSequence.flatten(tree)
            guard let (shrunkSequence, _) = try Interpreters.reduce(
                gen: gen, tree: tree, config: .fast, property: property,
            ) else { continue }
            #expect(
                shrunkSequence.shortLexPrecedes(originalSequence) || shrunkSequence == originalSequence,
                "Shrunk sequence is not simpler than the original",
            )
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
            Gen.choose(in: UInt64(0) ... 100_000),
        )) { a, b in
            let va = ChoiceValue.unsigned(a, .uint64)
            let vb = ChoiceValue.unsigned(b, .uint64)
            if a < b { return va < vb }
            if a > b { return vb < va }
            return va == vb
        }
    }
}

// MARK: - Helpers

/// Replacement for `#exhaust` macro.
private func exhaustCheck<T>(
    _ gen: ReflectiveGenerator<T>,
    maxIterations: UInt64 = 100,
    seed: UInt64 = 42,
    property: (T) -> Bool,
) throws {
    var iter = ValueInterpreter(gen, seed: seed, maxRuns: maxIterations)
    while let value = try iter.next() {
        #expect(property(value), "Property failed for value: \(value)")
    }
}

/// Character generator from CharacterSet using ExhaustCore primitives.
private func characterGen(from characterSet: CharacterSet) -> ReflectiveGenerator<Character> {
    let srs = characterSet.scalarRangeSet()
    return Gen.contramap(
        { (char: Character) throws -> Int in
            guard let scalar = char.unicodeScalars.first else {
                throw Interpreters.ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars",
                )
            }
            return srs.index(of: scalar)
        },
        Gen.choose(in: 0 ... srs.scalarCount - 1)
            ._map { Character(srs.scalar(at: $0)) },
    )
}

/// ASCII string generator using ExhaustCore primitives.
private func asciiStringGen(
    length: ClosedRange<UInt64>? = nil,
) -> ReflectiveGenerator<String> {
    let srs = CharacterSet(charactersIn: Unicode.Scalar(0x0020)! ... Unicode.Scalar(0x007E)!).scalarRangeSet()
    let charGen = Gen.contramap(
        { (char: Character) throws -> Int in
            guard let scalar = char.unicodeScalars.first else {
                throw Interpreters.ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars",
                )
            }
            return srs.index(of: scalar)
        },
        Gen.choose(in: 0 ... srs.scalarCount - 1)
            ._map { Character(srs.scalar(at: $0)) },
    )
    if let length {
        return Gen.contramap(
            { (s: String) throws -> [Character] in s.unicodeScalars.map { Character($0) } },
            Gen.arrayOf(charGen, within: length)._map { String($0) },
        )
    }
    return Gen.contramap(
        { (s: String) throws -> [Character] in s.unicodeScalars.map { Character($0) } },
        Gen.arrayOf(charGen)._map { String($0) },
    )
}
