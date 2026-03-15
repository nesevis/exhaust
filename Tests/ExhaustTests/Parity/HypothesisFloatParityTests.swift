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

import Foundation
import Testing
@testable import Exhaust

// MARK: - Shrinking parity tests
// NOTE: Float shrinking parity tests (HypothesisFloatShrinkingParityTests) and
// encoding parity tests (HypothesisFloatEncodingParityTests) have been moved to
// ExhaustCoreTests/Parity/ because they require Interpreters.reflect/reduce and
// FloatShortlex internal APIs.

// MARK: - Range and subnormal parity tests

@Suite("Hypothesis Float Range/Subnormal Parity")
struct HypothesisFloatRangeAndSubnormalParityTests {
    @Test("Generated doubles stay in very large finite ranges")
    func doublesAreInRangeForLargeBounds() throws {
        // Adjustment relative to `test_floats_are_in_range`:
        // uses sampled draws via `#extract` instead of Hypothesis `@given`.
        let ranges: [ClosedRange<Double>] = [
            9.9792015476736e291 ... Double.greatestFiniteMagnitude,
            -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude,
        ]

        for range in ranges {
            let values = #extract(#gen(.double(in: range)), count: 256, seed: 42)
            #expect(values.allSatisfy { range.contains($0) })
        }
    }

    @Test("Can generate both signed zeros when interval is [-0.0, 0.0]")
    func canGenerateBothZeros() throws {
        // Adjustment relative to `test_can_generate_both_zeros_when_in_interval`:
        // covers one canonical interval because Exhaust has no unconstrained float strategy
        // that includes NaN/Inf and Hypothesis-style assumptions.
        let values = #extract(#gen(.double(in: -0.0 ... 0.0)), count: 128, seed: 42)
        #expect(values.contains(where: { $0 == 0.0 && $0.sign == .plus }))
        #expect(values.contains(where: { $0 == 0.0 && $0.sign == .minus }))
    }

    @Test("Does not generate negative values when lower bound is +0.0")
    func nonNegativeRangeDoesNotGenerateNegativeSigns() throws {
        // Direct parity with `test_does_not_generate_negative_if_right_boundary_is_positive`.
        let values = #extract(#gen(.double(in: 0.0 ... 1.0)), count: 256, seed: 42)
        #expect(values.allSatisfy { $0.sign == .plus })
    }

    @Test("Does not generate positive values when upper bound is -0.0")
    func nonPositiveRangeDoesNotGeneratePositiveSigns() throws {
        // Direct parity with `test_does_not_generate_positive_if_right_boundary_is_negative`.
        let values = #extract(#gen(.double(in: -1.0 ... -0.0)), count: 256, seed: 42)
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

        let values = #extract(#gen(.double(in: lowerBound ... upperBound)), count: 256, seed: 42)
        #expect(values.allSatisfy { lowerBound <= $0 && $0 <= upperBound })
    }

    @Test("Can generate positive and negative subnormal doubles")
    func canGenerateSubnormalDoubles() throws {
        // Adjustment relative to `test_can_generate_subnormals`:
        // uses bounded positive/negative subnormal ranges to avoid half-bounded strategy APIs.
        let smallestNormal = Double.leastNormalMagnitude
        let largestSubnormal = smallestNormal.nextDown
        let smallestSubnormal = Double.leastNonzeroMagnitude

        let positives = #extract(#gen(.double(in: smallestSubnormal ... largestSubnormal)), count: 256, seed: 42)
        #expect(positives.allSatisfy { $0 > 0 && $0 < smallestNormal })

        let negatives = #extract(#gen(.double(in: -largestSubnormal ... -smallestSubnormal)), count: 256, seed: 42)
        #expect(negatives.allSatisfy { $0 < 0 && $0 > -smallestNormal })
    }

    @Test("Can generate positive and negative subnormal floats")
    func canGenerateSubnormalFloats() throws {
        // Adjustment relative to `test_can_generate_subnormals`:
        // same as Double case, but for 32-bit Float.
        let smallestNormal = Float.leastNormalMagnitude
        let largestSubnormal = smallestNormal.nextDown
        let smallestSubnormal = Float.leastNonzeroMagnitude

        let positives = #extract(#gen(.float(in: smallestSubnormal ... largestSubnormal)), count: 256, seed: 42)
        #expect(positives.allSatisfy { $0 > 0 && $0 < smallestNormal })

        let negatives = #extract(#gen(.float(in: -largestSubnormal ... -smallestSubnormal)), count: 256, seed: 42)
        #expect(negatives.allSatisfy { $0 < 0 && $0 > -smallestNormal })
    }
}
