//
//  HypothesisFloatParityFilterTests.swift
//  ExhaustTests
//
//  Float parity tests that require .filter (Exhaust-only).
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
}

@Suite("Hypothesis Float Shrinking Parity — Filter Tests")
struct HypothesisFloatShrinkingFilterTests {
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
}

@Suite("Hypothesis Float Encoding Parity — Filter Tests")
struct HypothesisFloatEncodingFilterTests {
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
