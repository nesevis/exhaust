//
//  ReducerFloatShrinkingTests.swift
//  ExhaustTests
//
//  Focused tests for floating-point shrinking behavior through Interpreters.reduce.
//

import Testing
import ExhaustCore

@Suite("Reducer Float Shrinking")
struct ReducerFloatShrinkingTests {
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

    @Test("Double truncation finds coarse fractional boundary")
    func doubleTruncationBoundary() throws {
        let gen = Gen.choose(in: 0.0 ... 10.0)
        let property: (Double) -> Bool = { value in
            // Failing window starts at a dyadic fraction that truncation can discover.
            !(value >= 3.125 && value < 3.2)
        }

        let output = try reduce(gen, startingAt: 3.14159, property: property)

        #expect(property(output) == false)
        #expect(output == 3.125)
    }

    @Test("Double special-values phase shrinks NaN to max finite")
    func doubleSpecialValuesPhase() throws {
        let gen = Gen.choose(in: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude, scaling: Double.defaultScaling)
        let property: (Double) -> Bool = { value in
            !(value.isNaN || value == Double.greatestFiniteMagnitude)
        }

        let output = try reduce(gen, startingAt: Double.nan, property: property)

        #expect(property(output) == false)
        #expect(output == Double.greatestFiniteMagnitude)
    }

    @Test("Double as_integer_ratio phase reduces integer part while preserving fraction")
    func doubleAsIntegerRatioPhase() throws {
        let gen = Gen.choose(in: 0.0 ... 10.0)
        let property: (Double) -> Bool = { value in
            let fraction = value.truncatingRemainder(dividingBy: 1.0)
            return !(value >= 0.75 && fraction == 0.75)
        }

        let output = try reduce(gen, startingAt: 3.75, property: property)

        #expect(property(output) == false)
        #expect(output == 1.75)
    }

    @Test("Float as_integer_ratio phase reduces integer part while preserving fraction")
    func floatAsIntegerRatioPhase() throws {
        let gen = Gen.choose(in: Float(0) ... Float(10))
        let property: (Float) -> Bool = { value in
            let fraction = value.truncatingRemainder(dividingBy: 1)
            return !(value >= 0.75 && fraction == 0.75)
        }

        let output = try reduce(gen, startingAt: Float(3.75), property: property)

        #expect(property(output) == false)
        #expect(output == Float(1.75))
    }

    @Test("Already-minimal Double half-ULP cancellation value is preserved")
    func alreadyMinimalHalfULPCancellationBoundaryIsStable() throws {
        let gen = Gen.choose(in: 1.0 ... 1e16)
        let property: (Double) -> Bool = { a in
            (a + 0.5) - a == 0.5
        }

        let minimalFailing = 4_503_599_627_370_496.0 // 2^52
        let output = try reduce(gen, startingAt: minimalFailing, property: property)

        #expect(property(output) == false)
        #expect(output == minimalFailing)
    }

    @Test("Double shrinking reaches semantic minimum when all values fail")
    func doubleShrinksToSemanticMinimumWhenAlwaysFailing() throws {
        let gen = Gen.choose(in: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude, scaling: Double.defaultScaling)
        let property: (Double) -> Bool = { _ in
            false
        }

        let output = try reduce(gen, startingAt: 7.75, property: property)

        #expect(property(output) == false)
        #expect(output == 0.0)
    }

    @Test("Float shrinking reaches semantic minimum when all values fail")
    func floatShrinksToSemanticMinimumWhenAlwaysFailing() throws {
        let gen = Gen.choose(in: -Float.greatestFiniteMagnitude ... Float.greatestFiniteMagnitude, scaling: Float.defaultScaling)
        let property: (Float) -> Bool = { _ in
            false
        }

        let output = try reduce(gen, startingAt: Float(7.75), property: property)

        #expect(property(output) == false)
        #expect(output == 0.0)
    }
}
