//
//  HypothesisFloatShrinkingParityTests.swift
//  ExhaustCoreTests
//
//  Moved from ExhaustTests — these tests require Interpreters.reflect/reduce
//  and FloatShortlex internal APIs.
//

import ExhaustCore
import Foundation
import Testing

private enum Helpers {
    static func reduce<Output>(
        _ gen: ReflectiveGenerator<Output>,
        startingAt value: Output,
        config: Interpreters.TCRConfiguration = .fast,
        property: (Output) -> Bool
    ) throws -> Output {
        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let (_, output) = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: config, property: property)
        )
        return output
    }

    static func minimalDouble(
        from start: Double,
        in range: ClosedRange<Double>? = nil,
        where condition: (Double) -> Bool
    ) throws -> Double {
        let gen: ReflectiveGenerator<Double> = if let range {
            Gen.choose(in: range)
        } else {
            Gen.choose(in: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude, scaling: Double.defaultScaling)
        }

        return try reduce(gen, startingAt: start) { value in
            !condition(value)
        }
    }
}

@Suite("Hypothesis Float Shrinking Parity")
struct HypothesisFloatShrinkingParityTests {
    @Test("Shrinks > 1 to 2.0")
    func shrinksGreaterThanOneToTwo() throws {
        let output = try Helpers.minimalDouble(
            from: 3.14159,
            where: { $0 > 1 }
        )
        #expect(output == 2.0)
    }

    @Test("Shrinks > 0 to 1.0")
    func shrinksGreaterThanZeroToOne() throws {
        let output = try Helpers.minimalDouble(
            from: 3.14159,
            where: { $0 > 0 }
        )
        #expect(output == 1.0)
    }

    @Test("Can shrink in fixed-length list context")
    func canShrinkInFixedLengthContext() throws {
        for n in [1, 2, 3, 8, 10] {
            let gen = Gen.arrayOf(Gen.choose(in: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude, scaling: Double.defaultScaling), exactly: UInt64(n))
            let start = Array(repeating: 2.0, count: n)

            let output = try Helpers.reduce(
                gen,
                startingAt: start
            ) { value in
                value.count != n || !value.contains(where: { $0 != 0.0 })
            }

            #expect(output.count == n)
            #expect(output.count(where: { $0 == 0.0 }) == n - 1)
            #expect(output.contains(1.0))
        }
    }

    @Test("Shrinks bounded values down to ceil(minValue)")
    func shrinksDownwardToIntegersForBoundedRange() throws {
        let cases: [Double] = [0.1, 1.5, 3.125, 9.99]
        for minValue in cases {
            let output = try Helpers.minimalDouble(
                from: 100.125,
                in: minValue ... 1000.0,
                where: { $0 >= minValue }
            )
            #expect(output == ceil(minValue))
        }
    }

    @Test("Shrinks fractional lower-bound case to b + 0.5")
    func shrinksFractionalLowerBoundCaseToHalfStep() throws {
        let upper = 9_007_199_254_740_992.0 // 2^53
        for b in [1, 2, 3, 8, 10] {
            let lower = Double(b)
            let innerGen = Gen.choose(in: lower ... upper as ClosedRange<Double>)
            let gen: ReflectiveGenerator<Double> = .impure(
                operation: .filter(
                    gen: innerGen.erase(),
                    fingerprint: 0,
                    filterType: .auto,
                    predicate: { value in
                        let v = value as! Double
                        return v > lower && v < upper && v.rounded(.towardZero) != v
                    }
                ),
                continuation: { .pure($0 as! Double) }
            )

            let output = try Helpers.reduce(
                gen,
                startingAt: lower + 0.875
            ) { _ in
                false
            }

            #expect(output == lower + 0.5)
        }
    }

    @Test("Shrinks to integer upper bound in interval")
    func shrinkToIntegerUpperBound() throws {
        let output = try Helpers.minimalDouble(
            from: 1.1,
            where: { $0 > 1 && $0 <= 2 }
        )
        #expect(output == 2.0)
    }

    @Test("Shrinks up to one in mixed interval")
    func shrinkUpToOne() throws {
        let output = try Helpers.minimalDouble(
            from: 0.5,
            where: { $0 >= 0.5 && $0 <= 1.5 }
        )
        #expect(output == 1.0)
    }

    @Test("Shrinks down to one-half for (0, 1) interval")
    func shrinkDownToHalf() throws {
        let output = try Helpers.minimalDouble(
            from: 0.75,
            where: { $0 > 0 && $0 < 1 }
        )
        #expect(output == 0.5)
    }

    @Test("Shrinks fractional-part condition to 1.5")
    func shrinkFractionalPart() throws {
        let output = try Helpers.minimalDouble(
            from: 2.5,
            where: { $0.truncatingRemainder(dividingBy: 1.0) == 0.5 }
        )
        #expect(output == 1.5)
    }

    @Test("Does not shrink across one")
    func doesNotShrinkAcrossOne() throws {
        let output = try Helpers.minimalDouble(
            from: 1.1,
            where: { $0 == 1.1 || ($0 > 0 && $0 < 1) }
        )
        #expect(output == 1.1)
    }

    @Test("Respects min bound while shrinking in bounded range")
    func rejectOutOfBoundsWhileShrinking() throws {
        let output = try Helpers.minimalDouble(
            from: 103.1,
            in: 103.0 ... 200.0,
            where: { $0 >= 103.0 }
        )
        #expect(output == 103.0)
    }
}

@Suite("Hypothesis Float Encoding Parity")
struct HypothesisFloatEncodingParityTests {
    @Test("Integral floats order as integers")
    func integralFloatsOrderAsIntegers() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(0) ... (1 << 20)),
            Gen.choose(in: UInt64(0) ... (1 << 20))
        )
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 200)
        while let value = try iterator.next() {
            let (a, b) = value
            guard a < b else { continue }
            #expect(FloatShortlex.shortlexKey(for: Double(a)) < FloatShortlex.shortlexKey(for: Double(b)))
        }
    }

    @Test("Fractional floats in (0, 1) are ordered after one")
    func fractionalFloatsWorseThanOne() throws {
        let gen = Gen.choose(in: Double.leastNonzeroMagnitude ... 1.0.nextDown as ClosedRange<Double>)
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 200)
        while let value = try iterator.next() {
            #expect(FloatShortlex.shortlexKey(for: value) > FloatShortlex.shortlexKey(for: 1.0))
        }
    }
}
