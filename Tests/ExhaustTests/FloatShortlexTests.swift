//
//  FloatShortlexTests.swift
//  ExhaustTests
//
//  Created by Codex on 21/2/2026.
//

import Testing
@testable import Exhaust
@_spi(ExhaustInternal) @testable import ExhaustCore

@Suite("FloatShortlex")
struct FloatShortlexTests {
    @Test("Zero and negative zero share the same key")
    func zeroAndNegativeZero() {
        #expect(FloatShortlex.shortlexKey(for: 0.0) == 0)
        #expect(FloatShortlex.shortlexKey(for: -0.0) == 0)
    }

    @Test("Opposite signs with same magnitude share key")
    func oppositeSignsSameMagnitude() {
        #expect(FloatShortlex.shortlexKey(for: 3.14) == FloatShortlex.shortlexKey(for: -3.14))
    }

    @Test("Simple non-negative integers use natural ordering")
    func simpleIntegerOrdering() {
        let twoTo53 = 9_007_199_254_740_992.0
        #expect(FloatShortlex.shortlexKey(for: 0.0) < FloatShortlex.shortlexKey(for: 1.0))
        #expect(FloatShortlex.shortlexKey(for: 1.0) < FloatShortlex.shortlexKey(for: 1000.0))
        #expect(FloatShortlex.shortlexKey(for: 1000.0) < FloatShortlex.shortlexKey(for: twoTo53))
    }

    @Test("Non-simple fractions are ranked after simple integers")
    func fractionalAfterSimpleInteger() {
        let twoTo53 = 9_007_199_254_740_992.0
        #expect(FloatShortlex.shortlexKey(for: 1.5) > FloatShortlex.shortlexKey(for: twoTo53))
    }

    @Test("Infinity is smaller than NaN in key space")
    func infinityBeforeNaN() {
        #expect(FloatShortlex.shortlexKey(for: Double.infinity) < FloatShortlex.shortlexKey(for: Double.nan))
    }

    @Test("Float overload is coherent with Double mapping")
    func floatOverloadCoherence() {
        let floatValue: Float = 0.125
        #expect(FloatShortlex.shortlexKey(for: floatValue) == FloatShortlex.shortlexKey(for: Double(floatValue)))
    }
}
