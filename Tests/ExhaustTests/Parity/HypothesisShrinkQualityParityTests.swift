//
//  HypothesisShrinkQualityParityTests.swift
//  ExhaustTests
//
//  Targeted parity ports from Hypothesis
//  tests/quality/test_shrink_quality.py.
//

import ExhaustCore
import Testing
@testable import Exhaust

@Suite("Hypothesis Shrink Quality Parity")
struct HypothesisShrinkQualityParityTests {
    private func reduce<Output>(
        _ gen: ReflectiveGenerator<Output>,
        startingAt value: Output,
        config: Interpreters.TCRConfiguration = .fast,
        property: (Output) -> Bool,
    ) throws -> Output {
        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let (_, output) = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: config, property: property),
        )
        return output
    }

    private func startPair(
        range: ClosedRange<Int>,
        gap: Int,
    ) -> (Int, Int) {
        for lhs in stride(from: range.upperBound, through: range.lowerBound, by: -1) {
            let rhs = lhs + gap
            if range.contains(rhs) {
                return (lhs, rhs)
            }
        }
        return (0, gap)
    }

    @Test("Hypothesis::test_sum_of_pair_mixed")
    func sumOfPairMixed() throws {
        let floatIntGen = #gen(
            .double(in: 0.0 ... 1000.0),
            .int(in: 0 ... 1000),
        )
        let floatIntProperty: ((Double, Int)) -> Bool = { pair in
            guard pair.0 >= 0.0, pair.0 <= 1000.0,
                  pair.1 >= 0, pair.1 <= 1000
            else {
                return true
            }
            return pair.0 + Double(pair.1) <= 1000.0
        }
        let floatIntOutput = try reduce(
            floatIntGen,
            startingAt: (700.75, 400),
            property: floatIntProperty,
        )
        #expect(floatIntProperty(floatIntOutput) == false)
        #expect(floatIntOutput == (1.0, 1000))

        let intFloatGen = #gen(
            .int(in: 0 ... 1000),
            .double(in: 0.0 ... 1000.0),
        )
        let intFloatProperty: ((Int, Double)) -> Bool = { pair in
            guard pair.0 >= 0, pair.0 <= 1000,
                  pair.1 >= 0.0, pair.1 <= 1000.0
            else {
                return true
            }
            return Double(pair.0) + pair.1 <= 1000.0
        }
        let intFloatOutput = try reduce(
            intFloatGen,
            startingAt: (400, 700.75),
            property: intFloatProperty,
        )
        #expect(intFloatProperty(intFloatOutput) == false)
        #expect(intFloatOutput == (1, 1000.0))
    }

    @Test("Hypothesis::test_sum_of_pair_separated_int")
    func sumOfPairSeparatedInt() throws {
        let separatedIntGen = #gen(
            .int(in: 0 ... 1000),
            .asciiString(),
            .bool(),
            .int(),
            .int(in: 0 ... 1000),
        )
        .mapped(
            forward: { tuple in
                (tuple.0, tuple.4)
            },
            backward: { pair in
                (pair.0, "seed", false, 123, pair.1)
            },
        )

        let property: ((Int, Int)) -> Bool = { pair in
            guard pair.0 >= 0, pair.0 <= 1000,
                  pair.1 >= 0, pair.1 <= 1000
            else {
                return true
            }
            return pair.0 + pair.1 <= 1000
        }
        let output = try reduce(
            separatedIntGen,
            startingAt: (800, 300),
            property: property,
        )

        #expect(property(output) == false)
        #expect(output == (1, 1000))
    }

    @Test("Hypothesis::test_sum_of_pair_separated_float")
    func sumOfPairSeparatedFloat() throws {
        let separatedFloatGen = #gen(
            .double(in: 0.0 ... 1000.0),
            .asciiString(),
            .bool(),
            .int(),
            .double(in: 0.0 ... 1000.0),
        )
        .mapped(
            forward: { tuple in
                (tuple.0, tuple.4)
            },
            backward: { pair in
                (pair.0, "seed", false, 123, pair.1)
            },
        )

        let property: ((Double, Double)) -> Bool = { pair in
            pair.0 + pair.1 <= 1000.0
        }
        let output = try reduce(
            separatedFloatGen,
            startingAt: (800.25, 300.5),
            property: property,
        )

        #expect(property(output) == false)
        #expect(output == (1.0, 1000.0))
    }

    @Test("Hypothesis::test_perfectly_shrinks_integers")
    func perfectlyShrinksIntegers() throws {
        let gen = #gen(.int())
        let cases: [Int] = [
            -(1 << 32), -(1 << 20), -1, 0, 1, 1 << 20, 1 << 32,
        ]

        for n in cases {
            let start: Int
            if n >= 0 {
                let maxDelta = Int.max - n
                start = n + min(1_000_000, maxDelta)
            } else {
                let maxDelta = n - Int.min
                start = n - min(1_000_000, maxDelta)
            }

            let property: (Int) -> Bool = if n >= 0 {
                { $0 < n }
            } else {
                { $0 > n }
            }

            let output = try reduce(gen, startingAt: start, property: property)
            #expect(property(output) == false)
            #expect(output == n)
        }
    }

    @Test("Hypothesis::test_lowering_together_positive")
    func loweringTogetherPositive() throws {
        let gen = #gen(
            .int(in: 0 ... 20),
            .int(in: 0 ... 20),
        )
        for gap in 0 ... 20 {
            let start = startPair(range: 0 ... 20, gap: gap)
            let property: ((Int, Int)) -> Bool = { pair in
                pair.0 + gap != pair.1
            }
//            ExhaustLog.setConfiguration(.init(isEnabled: true, minimumLevel: .info, categoryMinimumLevels: [.reducer: .debug], format: .human))
            let output = try reduce(gen, startingAt: start, property: property)
            #expect(property(output) == false)
            #expect(output == (0, gap))
        }
    }

    @Test("Hypothesis::test_lowering_together_negative")
    func loweringTogetherNegative() throws {
        let gen = #gen(
            .int(in: -20 ... 0),
            .int(in: -20 ... 0),
        )
        for gap in -20 ... 0 {
            let start = startPair(range: -20 ... 0, gap: gap)
            let property: ((Int, Int)) -> Bool = { pair in
                pair.0 + gap != pair.1
            }
            let output = try reduce(gen, startingAt: start, property: property)
            #expect(property(output) == false)
            #expect(output == (0, gap))
        }
    }

    @Test("Hypothesis::test_lowering_together_mixed")
    func loweringTogetherMixed() throws {
        let gen = #gen(
            .int(in: -10 ... 10),
            .int(in: -10 ... 10),
        )
        for gap in -10 ... 10 {
            let start = startPair(range: -10 ... 10, gap: gap)
            let property: ((Int, Int)) -> Bool = { pair in
                pair.0 + gap != pair.1
            }
            let output = try reduce(gen, startingAt: start, property: property)
            #expect(property(output) == false)
            #expect(output == (0, gap))
        }
    }

    @Test("Hypothesis::test_lowering_together_with_gap")
    func loweringTogetherWithGap() throws {
        let gen = #gen(
            .int(in: -10 ... 10),
            .asciiString(),
            .double(in: -1000.0 ... 1000.0),
            .int(in: -10 ... 10),
        )

        for gap in -10 ... 10 {
            let (lhs, rhs) = startPair(range: -10 ... 10, gap: gap)
            let property: ((Int, String, Double, Int)) -> Bool = { tuple in
                tuple.0 + gap != tuple.3
            }
            let output = try reduce(
                gen,
                startingAt: (lhs, "seed", 123.75, rhs),
                property: property,
            )

            #expect(property(output) == false)
            #expect(output.0 == 0)
            #expect(output.1 == "")
            #expect(output.2 == 0.0)
            #expect(output.3 == gap)
        }
    }
}
