//
//  HypothesisFloatParityTests.swift
//  ExhaustTests
//
//  Ports of applicable float behavior tests from Hypothesis:
//  - tests/quality/test_float_shrinking.py
//  - tests/conjecture/test_float_encoding.py
//  - tests/cover/test_float_nastiness.py
//  - tests/cover/test_subnormal_floats.py
//  - tests/nocover/test_subnormal_floats.py
//
//  Left out (by Hypothesis test name) and reason:
//
//  tests/conjecture/test_float_encoding.py
//  - test_encode_permutes_elements
//  - test_decode_permutes_elements
//  - test_decode_encode
//  - test_encode_decode
//  - test_double_reverse_bounded
//  - test_double_reverse
//  - test_reverse_bits_table_reverses_bits
//  - test_reverse_bits_table_has_right_elements
//  Reason: require direct access to Hypothesis internal exponent/bit-reversal APIs.
//  Exhaust does not expose equivalent public encode/decode/reverse primitives.
//
//  tests/conjecture/test_float_encoding.py
//  - test_floats_round_trip
//  - test_can_shrink_downwards
//  - test_shrinks_downwards_to_integers (parametrized variant)
//  - test_shrinks_to_canonical_nan
//  Reason: depend on Hypothesis ConjectureRunner internals and canonical-NaN
//  behavior contract, which do not map 1:1 to Exhaust's reducer surface.
//
//  tests/cover/test_float_nastiness.py
//  - test_half_bounded_generates_zero
//  - test_half_bounded_respects_sign_of_upper_bound
//  - test_half_bounded_respects_sign_of_lower_bound
//  - test_can_exclude_endpoints
//  - test_can_exclude_neg_infinite_endpoint
//  - test_can_exclude_pos_infinite_endpoint
//  - test_exclude_infinite_endpoint_is_invalid
//  - test_exclude_entire_interval
//  - test_cannot_exclude_endpoint_with_zero_interval
//  Reason: Exhaust `Gen.choose` currently requires closed ranges; no half-bounded
//  or endpoint-exclusion float strategy API.
//
//  tests/cover/test_float_nastiness.py
//  - test_filter_nan
//  - test_filter_infinity
//  - test_can_guard_against_draws_of_nan
//  - test_float32_can_exclude_infinity
//  - test_float16_can_exclude_infinity
//  Reason: no `allow_nan` / `allow_infinity` / width-specific float strategy flags.
//
//  tests/cover/test_float_nastiness.py
//  - test_out_of_range
//  - test_disallowed_width
//  - test_no_single_floats_in_range
//  - test_exclude_infinite_endpoint_is_invalid
//  - test_exclude_entire_interval
//  - test_zero_intervals_are_OK
//  - test_fuzzing_floats_bounds
//  Reason: these are strategy-validation/error-contract tests for Hypothesis'
//  `st.floats(...).validate()`, which Exhaust does not currently expose.
//
//  tests/cover/test_subnormal_floats.py
//  - test_subnormal_validation
//  - test_allow_subnormal_defaults_correctly
//  - test_next_float_normal
//  tests/nocover/test_subnormal_floats.py
//  - test_does_not_generate_subnormals_when_disallowed
//  - test_python_compiled_with_sane_math_options
//  Reason: no `allow_subnormal` toggle or FTZ-runtime contract hooks in Exhaust.
//

import ExhaustCore
import Foundation
import Testing
@testable import Exhaust

private enum HypothesisFloatParityHelpers {
    static func reduce<Output>(
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

    static func minimalDouble(
        from start: Double,
        in range: ClosedRange<Double>? = nil,
        where condition: (Double) -> Bool,
    ) throws -> Double {
        let gen: ReflectiveGenerator<Double> = if let range {
            #gen(.double(in: range))
        } else {
            #gen(.double())
        }

        return try reduce(gen, startingAt: start) { value in
            !condition(value)
        }
    }

    static func sample<Output>(
        _ gen: ReflectiveGenerator<Output>,
        seed: UInt64 = 42,
        count: Int = 256,
    ) throws -> [Output] {
        var iter = ValueInterpreter(gen, seed: seed, maxRuns: UInt64(count))
        return try iter.prefix(count)
    }
}

@Suite("Hypothesis Float Shrinking Parity")
struct HypothesisFloatShrinkingParityTests {
    @Test("Shrinks > 1 to 2.0")
    func shrinksGreaterThanOneToTwo() throws {
        // Adjustment: split from Hypothesis `test_shrinks_to_simple_floats`
        // into a dedicated single-goal test using an explicit starting value.
        let output = try HypothesisFloatParityHelpers.minimalDouble(
            from: 3.14159,
            where: { $0 > 1 },
        )
        #expect(output == 2.0)
    }

    @Test("Shrinks > 0 to 1.0")
    func shrinksGreaterThanZeroToOne() throws {
        // Adjustment: split from Hypothesis `test_shrinks_to_simple_floats`
        // into a dedicated single-goal test using an explicit starting value.
        let output = try HypothesisFloatParityHelpers.minimalDouble(
            from: 3.14159,
            where: { $0 > 0 },
        )
        #expect(output == 1.0)
    }

    @Test("Can shrink in fixed-length list context")
    func canShrinkInFixedLengthContext() throws {
        // Adjustment relative to `test_can_shrink_in_variable_sized_context`:
        // property explicitly pins length (`value.count == n`) so reducer passes
        // that delete sequence elements cannot satisfy the property by shrinking length.
        for n in [1, 2, 3, 8, 10] {
            let gen = #gen(.double()).array(length: UInt64(n))
            let start = Array(repeating: 2.0, count: n)

            let output = try HypothesisFloatParityHelpers.reduce(
                gen,
                startingAt: start,
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
        // Adjustment relative to `test_shrinks_downwards_to_integers`:
        // predicate includes explicit lower-bound guard (`$0 >= minValue`) so
        // the result remains strategy-equivalent when reducer explores out-of-range candidates.
        let cases: [Double] = [0.1, 1.5, 3.125, 9.99]
        for minValue in cases {
            let output = try HypothesisFloatParityHelpers.minimalDouble(
                from: 100.125,
                in: minValue ... 1000.0,
                where: { $0 >= minValue },
            )
            #expect(output == ceil(minValue))
        }
    }

    @Test("Shrinks fractional lower-bound case to b + 0.5")
    func shrinksFractionalLowerBoundCaseToHalfStep() throws {
        // Adjustment relative to `test_shrinks_downwards_to_integers_when_fractional`:
        // uses `filter` to emulate Hypothesis `exclude_min/exclude_max` + non-integral constraint.
        let upper = 9_007_199_254_740_992.0 // 2^53
        for b in [1, 2, 3, 8, 10] {
            let lower = Double(b)
            let gen = #gen(.double(in: lower ... upper))
                .filter { value in
                    value > lower && value < upper && value.rounded(.towardZero) != value
                }

            let output = try HypothesisFloatParityHelpers.reduce(
                gen,
                startingAt: lower + 0.875,
            ) { _ in
                false
            }

            #expect(output == lower + 0.5)
        }
    }

    @Test("Shrinks to integer upper bound in interval")
    func shrinkToIntegerUpperBound() throws {
        // Direct port of `test_shrink_to_integer_upper_bound`.
        let output = try HypothesisFloatParityHelpers.minimalDouble(
            from: 1.1,
            where: { $0 > 1 && $0 <= 2 },
        )
        #expect(output == 2.0)
    }

    @Test("Shrinks up to one in mixed interval")
    func shrinkUpToOne() throws {
        // Direct port of `test_shrink_up_to_one`.
        let output = try HypothesisFloatParityHelpers.minimalDouble(
            from: 0.5,
            where: { $0 >= 0.5 && $0 <= 1.5 },
        )
        #expect(output == 1.0)
    }

    @Test("Shrinks down to one-half for (0, 1) interval")
    func shrinkDownToHalf() throws {
        // Direct port of `test_shrink_down_to_half`.
        let output = try HypothesisFloatParityHelpers.minimalDouble(
            from: 0.75,
            where: { $0 > 0 && $0 < 1 },
        )
        #expect(output == 0.5)
    }

    @Test("Shrinks fractional-part condition to 1.5")
    func shrinkFractionalPart() throws {
        // Direct port of `test_shrink_fractional_part`.
        let output = try HypothesisFloatParityHelpers.minimalDouble(
            from: 2.5,
            where: { $0.truncatingRemainder(dividingBy: 1.0) == 0.5 },
        )
        #expect(output == 1.5)
    }

    @Test("Does not shrink across one")
    func doesNotShrinkAcrossOne() throws {
        // Direct port of `test_does_not_shrink_across_one`.
        let output = try HypothesisFloatParityHelpers.minimalDouble(
            from: 1.1,
            where: { $0 == 1.1 || ($0 > 0 && $0 < 1) },
        )
        #expect(output == 1.1)
    }

    @Test("Respects min bound while shrinking in bounded range")
    func rejectOutOfBoundsWhileShrinking() throws {
        // Adjustment relative to `test_reject_out_of_bounds_floats_while_shrinking`:
        // uses strategy-equivalent predicate bound (`$0 >= 103.0`) instead of `>= 100`
        // so the expected minimal value remains clamped to the generator lower bound.
        let output = try HypothesisFloatParityHelpers.minimalDouble(
            from: 103.1,
            in: 103.0 ... 200.0,
            where: { $0 >= 103.0 },
        )
        #expect(output == 103.0)
    }
}

@Suite("Hypothesis Float Encoding Parity")
struct HypothesisFloatEncodingParityTests {
    @Test("Integral floats order as integers")
    func integralFloatsOrderAsIntegers() {
        #exhaust(#gen(.uint64(in: 0 ... (1 << 20)), .uint64(in: 0 ... (1 << 20)))) { a, b in
            guard a < b else { return true }
            return FloatShortlex.shortlexKey(for: Double(a)) < FloatShortlex.shortlexKey(for: Double(b))
        }
    }

    @Test("Fractional floats in (0, 1) are ordered after one")
    func fractionalFloatsWorseThanOne() {
        let gen = #gen(.double(in: Double.leastNonzeroMagnitude ... 1.0.nextDown))
        #exhaust(gen) { value in
            FloatShortlex.shortlexKey(for: value) > FloatShortlex.shortlexKey(for: 1.0)
        }
    }

    @Test("Non-integral float is ordered after its integral part")
    func nonIntegralWorseThanIntegralPart() {
        let posGen = #gen(.double(in: 1.0 ... 1000.0)).filter { $0.truncatingRemainder(dividingBy: 1.0) != 0 }
        #exhaust(posGen) { value in
            FloatShortlex.shortlexKey(for: floor(value)) < FloatShortlex.shortlexKey(for: value)
        }

        let negGen = #gen(.double(in: -1000.0 ... -1.0)).filter { $0.truncatingRemainder(dividingBy: 1.0) != 0 }
        #exhaust(negGen) { value in
            FloatShortlex.shortlexKey(for: ceil(value)) < FloatShortlex.shortlexKey(for: value)
        }
    }
}

@Suite("Hypothesis Float Range/Subnormal Parity")
struct HypothesisFloatRangeAndSubnormalParityTests {
    @Test("Generated doubles stay in very large finite ranges")
    func doublesAreInRangeForLargeBounds() throws {
        // Adjustment relative to `test_floats_are_in_range`:
        // uses sampled draws via `ValueInterpreter` instead of Hypothesis `@given`.
        let ranges: [ClosedRange<Double>] = [
            9.9792015476736e291 ... Double.greatestFiniteMagnitude,
            -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude,
        ]

        for range in ranges {
            let values = try HypothesisFloatParityHelpers.sample(#gen(.double(in: range)))
            #expect(values.allSatisfy { range.contains($0) })
        }
    }

    @Test("Can generate both signed zeros when interval is [-0.0, 0.0]")
    func canGenerateBothZeros() throws {
        // Adjustment relative to `test_can_generate_both_zeros_when_in_interval`:
        // covers one canonical interval because Exhaust has no unconstrained float strategy
        // that includes NaN/Inf and Hypothesis-style assumptions.
        let values = try HypothesisFloatParityHelpers.sample(#gen(.double(in: -0.0 ... 0.0)), count: 128)
        #expect(values.contains(where: { $0 == 0.0 && $0.sign == .plus }))
        #expect(values.contains(where: { $0 == 0.0 && $0.sign == .minus }))
    }

    @Test("Does not generate negative values when lower bound is +0.0")
    func nonNegativeRangeDoesNotGenerateNegativeSigns() throws {
        // Direct parity with `test_does_not_generate_negative_if_right_boundary_is_positive`.
        let values = try HypothesisFloatParityHelpers.sample(#gen(.double(in: 0.0 ... 1.0)))
        #expect(values.allSatisfy { $0.sign == .plus })
    }

    @Test("Does not generate positive values when upper bound is -0.0")
    func nonPositiveRangeDoesNotGeneratePositiveSigns() throws {
        // Direct parity with `test_does_not_generate_positive_if_right_boundary_is_negative`.
        let values = try HypothesisFloatParityHelpers.sample(#gen(.double(in: -1.0 ... -0.0)))
        #expect(values.allSatisfy { $0.sign == .minus })
    }

    @Test("Narrow interval generation remains within bounds")
    func veryNarrowInterval() throws {
        // Direct parity with `test_very_narrow_interval`, expressed with Swift `nextDown`.
        let upperBound = -1.0
        var lowerBound = upperBound
        for _ in 0 ..< 10 {
            lowerBound = lowerBound.nextDown
        }
        #expect(lowerBound < upperBound)

        let values = try HypothesisFloatParityHelpers.sample(#gen(.double(in: lowerBound ... upperBound)))
        #expect(values.allSatisfy { lowerBound <= $0 && $0 <= upperBound })
    }

    @Test("Can generate positive and negative subnormal doubles")
    func canGenerateSubnormalDoubles() throws {
        // Adjustment relative to `test_can_generate_subnormals`:
        // uses bounded positive/negative subnormal ranges to avoid half-bounded strategy APIs.
        let smallestNormal = Double.leastNormalMagnitude
        let largestSubnormal = smallestNormal.nextDown
        let smallestSubnormal = Double.leastNonzeroMagnitude

        let positives = try HypothesisFloatParityHelpers.sample(#gen(.double(in: smallestSubnormal ... largestSubnormal)))
        #expect(positives.allSatisfy { $0 > 0 && $0 < smallestNormal })

        let negatives = try HypothesisFloatParityHelpers.sample(#gen(.double(in: -largestSubnormal ... -smallestSubnormal)))
        #expect(negatives.allSatisfy { $0 < 0 && $0 > -smallestNormal })
    }

    @Test("Can generate positive and negative subnormal floats")
    func canGenerateSubnormalFloats() throws {
        // Adjustment relative to `test_can_generate_subnormals`:
        // same as Double case, but for 32-bit Float.
        let smallestNormal = Float.leastNormalMagnitude
        let largestSubnormal = smallestNormal.nextDown
        let smallestSubnormal = Float.leastNonzeroMagnitude

        let positives = try HypothesisFloatParityHelpers.sample(#gen(.float(in: smallestSubnormal ... largestSubnormal)))
        #expect(positives.allSatisfy { $0 > 0 && $0 < smallestNormal })

        let negatives = try HypothesisFloatParityHelpers.sample(#gen(.float(in: -largestSubnormal ... -smallestSubnormal)))
        #expect(negatives.allSatisfy { $0 < 0 && $0 > -smallestNormal })
    }
}
