//
//  HypothesisFloatParityFilterTests.swift
//  ExhaustCoreTests
//
//  Float parity tests that use filter operations.
//

import ExhaustCore
import Foundation
import Testing

private enum HypothesisFloatParityHelpers {
    static func reduce<Output>(
        _ gen: ReflectiveGenerator<Output>,
        startingAt value: Output,
        config: Interpreters.ReducerConfiguration = .fast,
        property: (Output) -> Bool
    ) throws -> Output {
        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: config, property: property)
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
            let gen = filtered(
                Gen.choose(in: lower ... upper)
            ) { value in
                value > lower && value < upper && value.rounded(.towardZero) != value
            }

            let output = try HypothesisFloatParityHelpers.reduce(
                gen,
                startingAt: lower + 0.875
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
    func nonIntegralWorseThanIntegralPart() throws {
        let posGen = filtered(
            Gen.choose(in: 1.0 ... 1000.0)
        ) { $0.truncatingRemainder(dividingBy: 1.0) != 0 }

        var posIterator = ValueInterpreter(posGen, seed: 42, maxRuns: 200)
        while let value = try posIterator.next() {
            #expect(FloatShortlex.shortlexKey(for: floor(value)) < FloatShortlex.shortlexKey(for: value))
        }

        let negGen = filtered(
            Gen.choose(in: -1000.0 ... -1.0)
        ) { $0.truncatingRemainder(dividingBy: 1.0) != 0 }

        var negIterator = ValueInterpreter(negGen, seed: 42, maxRuns: 200)
        while let value = try negIterator.next() {
            #expect(FloatShortlex.shortlexKey(for: ceil(value)) < FloatShortlex.shortlexKey(for: value))
        }
    }
}

// MARK: - Helpers

/// Constructs a filtered generator at the ExhaustCore level (the `.filter` instance method lives in the Exhaust module).
private func filtered<Output>(
    _ gen: ReflectiveGenerator<Output>,
    _ predicate: @Sendable @escaping (Output) -> Bool,
    fileID: String = #fileID,
    line: UInt = #line
) -> ReflectiveGenerator<Output> {
    let fingerprint = fileID.hashValue.bitPattern64 &+ line.bitPattern64
    return .impure(
        operation: .filter(
            gen: gen.erase(),
            fingerprint: fingerprint,
            filterType: .auto,
            predicate: { predicate($0 as! Output) }
        ),
        continuation: { .pure($0 as! Output) }
    )
}
