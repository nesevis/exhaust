//
//  PropertyTests.swift
//  ExhaustTests
//
//  Property-based tests covering core invariants of Exhaust's bidirectional
//  architecture, shrink ordering, and size-scaling math.
//

import Testing
@testable import Exhaust
@testable @_spi(ExhaustInternal) import ExhaustCore

// MARK: - Roundtrip Properties

@Suite("Generate-Reflect-Replay Roundtrip")
struct RoundtripPropertyTests {
    @Test("Primitive generators round-trip through reflect and replay")
    func primitiveRoundtrip() {
        let intGen = #gen(.int(in: -1000 ... 1000))
        #exhaust(intGen) { value in
            guard let tree = try? Interpreters.reflect(intGen, with: value),
                  let replayed = try? Interpreters.replay(intGen, using: tree)
            else { return false }
            return replayed == value
        }

        let doubleGen = #gen(.double(in: -1000.0 ... 1000.0))
        #exhaust(doubleGen) { value in
            guard let tree = try? Interpreters.reflect(doubleGen, with: value),
                  let replayed = try? Interpreters.replay(doubleGen, using: tree)
            else { return false }
            return replayed == value
        }

        let boolGen = #gen(.bool())
        #exhaust(boolGen, .maxIterations(50)) { value in
            guard let tree = try? Interpreters.reflect(boolGen, with: value),
                  let replayed = try? Interpreters.replay(boolGen, using: tree)
            else { return false }
            return replayed == value
        }

        let asciiGen = #gen(.asciiString(length: 1 ... 10))
        #exhaust(asciiGen) { value in
            guard let tree = try? Interpreters.reflect(asciiGen, with: value),
                  let replayed = try? Interpreters.replay(asciiGen, using: tree)
            else { return false }
            return replayed == value
        }

        let charGen = Character.arbitraryAscii
        #exhaust(charGen) { value in
            guard let tree = try? Interpreters.reflect(charGen, with: value),
                  let replayed = try? Interpreters.replay(charGen, using: tree)
            else { return false }
            return replayed == value
        }
    }

    @Test("Composed generators round-trip through reflect and replay")
    func composedRoundtrip() {
        // Array
        let arrayGen = #gen(.int(in: 0 ... 100).array(length: 1 ... 5))
        #exhaust(arrayGen) { value in
            guard let tree = try? Interpreters.reflect(arrayGen, with: value),
                  let replayed = try? Interpreters.replay(arrayGen, using: tree)
            else { return false }
            return replayed == value
        }

        // Optional
        let optionalGen = #gen(.int(in: 0 ... 100)).optional()
        #exhaust(optionalGen) { value in
            guard let tree = try? Interpreters.reflect(optionalGen, with: value),
                  let replayed = try? Interpreters.replay(optionalGen, using: tree)
            else { return false }
            return replayed == value
        }

        // Zip (tuple)
        let zipGen = #gen(.int(in: 0 ... 100), .int(in: 0 ... 100))
        #exhaust(zipGen) { value in
            guard let tree = try? Interpreters.reflect(zipGen, with: value),
                  let replayed = try? Interpreters.replay(zipGen, using: tree)
            else { return false }
            return replayed == value
        }

        // oneOf
        let oneOfGen: ReflectiveGenerator<Int> = .oneOf(
            .int(in: 0 ... 50),
            .int(in: 100 ... 200)
        )
        #exhaust(oneOfGen) { value in
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
    func scaledRangeMonotonicity() {
        let range = UInt64(0) ... UInt64(10000)
        let sizeGen = #gen(.uint64(in: 1 ... 99), .uint64(in: 1 ... 99))

        // Linear scaling
        #exhaust(sizeGen) { s1, s2 in
            let lo = min(s1, s2)
            let hi = max(s1, s2)
            guard lo < hi else { return true }
            let r1 = Gen.scaledRange(range, scaling: .linear, size: lo)
            let r2 = Gen.scaledRange(range, scaling: .linear, size: hi)
            return r2.lowerBound <= r1.lowerBound && r2.upperBound >= r1.upperBound
        }

        // Exponential scaling
        #exhaust(sizeGen) { s1, s2 in
            let lo = min(s1, s2)
            let hi = max(s1, s2)
            guard lo < hi else { return true }
            let r1 = Gen.scaledRange(range, scaling: .exponential, size: lo)
            let r2 = Gen.scaledRange(range, scaling: .exponential, size: hi)
            return r2.lowerBound <= r1.lowerBound && r2.upperBound >= r1.upperBound
        }

        // Constant scaling: range must equal input at all sizes
        #exhaust(#gen(.uint64(in: 0 ... 100))) { size in
            let r = Gen.scaledRange(range, scaling: .constant, size: size)
            return r == range
        }
    }

    @Test("scaledDistance is monotonically non-decreasing in fraction")
    func scaledDistanceMonotonicity() {
        let gen = #gen(.uint64(in: 1 ... 10000), .uint64(in: 0 ... 99), .uint64(in: 0 ... 99))

        // Linear
        #exhaust(gen) { distance, f1Raw, f2Raw in
            let fLo = Double(min(f1Raw, f2Raw)) / 100.0
            let fHi = Double(max(f1Raw, f2Raw)) / 100.0
            guard fLo < fHi else { return true }
            let d1 = Gen.scaledDistance(distance, fraction: fLo, isExponential: false)
            let d2 = Gen.scaledDistance(distance, fraction: fHi, isExponential: false)
            return d1 <= d2
        }

        // Exponential
        #exhaust(gen) { distance, f1Raw, f2Raw in
            let fLo = Double(min(f1Raw, f2Raw)) / 100.0
            let fHi = Double(max(f1Raw, f2Raw)) / 100.0
            guard fLo < fHi else { return true }
            let d1 = Gen.scaledDistance(distance, fraction: fLo, isExponential: true)
            let d2 = Gen.scaledDistance(distance, fraction: fHi, isExponential: true)
            return d1 <= d2
        }

        // Result is always <= distance
        #exhaust(#gen(.uint64(in: 0 ... 100000), .uint64(in: 0 ... 100))) { distance, fRaw in
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
    func simpleIntegerIdentity() {
        #exhaust(#gen(.uint64(in: 0 ... (1 << 20)))) { n in
            FloatShortlex.shortlexKey(for: Double(n)) == n
        }
    }

    @Test("Magnitude ordering preserved among simple non-negative integers")
    func magnitudeOrdering() {
        #exhaust(#gen(.uint64(in: 0 ... (1 << 20)), .uint64(in: 0 ... (1 << 20)))) { a, b in
            guard a < b else { return true }
            return FloatShortlex.shortlexKey(for: Double(a)) < FloatShortlex.shortlexKey(for: Double(b))
        }
    }

    @Test("reverseLowerBits is an involution")
    func reverseLowerBitsInvolution() {
        #exhaust(#gen(.uint64(in: 0 ... ((1 << 20) - 1)), .uint64(in: 1 ... 63))) { rawX, countRaw in
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
    func replayIdempotence() {
        let gen = #gen(.int(in: -10000 ... 10000))
        #exhaust(gen) { value in
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
    func semanticSimplestMinimalComplexity() {
        // Unsigned
        #exhaust(#gen(.uint64(in: 0 ... 100000))) { rawValue in
            let value = ChoiceValue.unsigned(rawValue, UInt64.self)
            return value.semanticSimplest.complexity <= value.complexity
        }

        // Signed
        #exhaust(#gen(.int64(in: -50000 ... 50000))) { rawValue in
            let value = ChoiceValue(rawValue, tag: .int64)
            return value.semanticSimplest.complexity <= value.complexity
        }

        // Floating
        #exhaust(#gen(.double(in: -1000.0 ... 1000.0))) { rawValue in
            let value = ChoiceValue(rawValue, tag: .double)
            return value.semanticSimplest.complexity <= value.complexity
        }
    }

    @Test("Unsigned ChoiceValue complexity strictly increases with value")
    func unsignedComplexityMonotonicity() {
        #exhaust(#gen(.uint64(in: 0 ... 100000), .uint64(in: 0 ... 100000))) { a, b in
            guard a < b else { return true }
            let va = ChoiceValue.unsigned(a, UInt64.self)
            let vb = ChoiceValue.unsigned(b, UInt64.self)
            return va.complexity < vb.complexity
        }
    }
}

// MARK: - shortlexKey / fromShortlexKey Properties

@Suite("ShortlexKey Roundtrip")
struct ShortlexKeyPropertyTests {
    @Test("fromShortlexKey inverts shortlexKey for signed integers")
    func signedShortlexRoundtrip() {
        #exhaust(#gen(.int64(in: -50000 ... 50000))) { rawValue in
            let value = ChoiceValue(rawValue, tag: .int64)
            let key = value.shortlexKey
            let recovered = ChoiceValue.fromShortlexKey(key, tag: .int64)
            return recovered == value
        }
    }

    @Test("shortlexKey orders signed integers by proximity to zero")
    func signedShortlexOrdering() {
        #exhaust(#gen(.int64(in: -50000 ... 50000), .int64(in: -50000 ... 50000))) { a, b in
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
    func materializeAgreesWithReplay() {
        let gen = #gen(.int(in: -1000 ... 1000))
        #exhaust(gen) { value in
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
    func reflectIdempotence() {
        let gen = #gen(.int(in: -1000 ... 1000))
        #exhaust(gen) { value in
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
    func chooseRangeContainment() {
        #exhaust(#gen(.int(in: -500 ... 500))) { value in
            value >= -500 && value <= 500
        }

        #exhaust(#gen(.uint64(in: 10 ... 10000))) { value in
            value >= 10 && value <= 10000
        }

        let doubleGen = #gen(.double(in: -1.0 ... 1.0))
        #exhaust(doubleGen) { value in
            value >= -1.0 && value <= 1.0
        }
    }

    @Test("Filtered generator only produces values satisfying the predicate")
    func filterPostCondition() {
        let gen = #gen(.int(in: -1000 ... 1000)).filter { $0 > 0 }
        #exhaust(gen) { value in
            value > 0
        }
    }

    @Test("Gen.just always produces its constant value")
    func justConstancy() {
        let gen = #gen(.just(42))
        #exhaust(gen) { value in
            value == 42
        }
    }
}

// MARK: - Shrinking Properties

@Suite("Shrinking Invariants")
struct ShrinkingPropertyTests {
    @Test("Shrinking preserves counterexample status")
    func shrinkingPreservesFailure() throws {
        let gen = #gen(.int(in: 0 ... 10000))
        let property: (Int) -> Bool = { $0 < 50 }

        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 50)
        while let (value, tree) = iterator.next() {
            guard !property(value) else { continue }
            guard let (_, shrunk) = try Interpreters.reduce(
                gen: gen, tree: tree, config: .fast, property: property
            ) else { continue }
            #expect(!property(shrunk), "Shrunk value \(shrunk) no longer fails the property")
        }
    }

    @Test("Shrinking produces simpler choice sequences")
    func shrinkingReducesComplexity() throws {
        let gen = #gen(.int(in: 0 ... 10000))
        let property: (Int) -> Bool = { $0 < 50 }

        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 50)
        while let (value, tree) = iterator.next() {
            guard !property(value) else { continue }
            let originalSequence = ChoiceSequence.flatten(tree)
            guard let (shrunkSequence, _) = try Interpreters.reduce(
                gen: gen, tree: tree, config: .fast, property: property
            ) else { continue }
            #expect(
                shrunkSequence.shortLexPrecedes(originalSequence) || shrunkSequence == originalSequence,
                "Shrunk sequence is not simpler than the original"
            )
        }
    }
}

// MARK: - ChoiceValue Comparable Consistency

@Suite("ChoiceValue Comparable")
struct ChoiceValueComparablePropertyTests {
    @Test("Unsigned ChoiceValue ordering agrees with natural UInt64 ordering")
    func unsignedComparableConsistency() {
        #exhaust(#gen(.uint64(in: 0 ... 100000), .uint64(in: 0 ... 100000))) { a, b in
            let va = ChoiceValue.unsigned(a, UInt64.self)
            let vb = ChoiceValue.unsigned(b, UInt64.self)
            if a < b { return va < vb }
            if a > b { return vb < va }
            return va == vb
        }
    }
}
