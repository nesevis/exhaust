//
//  GraphTransformationTypeTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Affine Slack Tests

@Suite("AffineSlack")
struct AffineSlackTests {
    @Test("Exact is identity under composition")
    func exactIsIdentity() {
        let slack = AffineSlack(multiplicative: 1, additive: 5)
        let composed = AffineSlack.exact.composed(with: slack)
        #expect(composed.multiplicative == 1)
        #expect(composed.additive == 5)

        let composedReverse = slack.composed(with: .exact)
        #expect(composedReverse.multiplicative == 1)
        #expect(composedReverse.additive == 5)
    }

    @Test("Monoidal product accumulates additive with upstream scaling")
    func monoidalProduct() {
        let slackA = AffineSlack(multiplicative: 1, additive: 2)
        let slackB = AffineSlack(multiplicative: 1, additive: 3)
        let composed = slackA.composed(with: slackB)
        // (1, 2) (x) (1, 3) = (1*1, 2 + 1*3) = (1, 5)
        #expect(composed.multiplicative == 1)
        #expect(composed.additive == 5)
    }

    @Test("Ordering: exact precedes approximate")
    func orderingExactFirst() {
        let exact = AffineSlack.exact
        let approximate = AffineSlack(multiplicative: 1, additive: 5)
        #expect(exact < approximate)
    }

    @Test("Ordering: lower additive precedes higher")
    func orderingByAdditive() {
        let small = AffineSlack(multiplicative: 1, additive: 2)
        let large = AffineSlack(multiplicative: 1, additive: 10)
        #expect(small < large)
    }
}

// MARK: - Transformation Yield Tests

@Suite("TransformationYield")
struct TransformationYieldTests {
    @Test("Identity is neutral under composition")
    func identityIsNeutral() {
        let yield = TransformationYield(
            structural: 10,
            value: 5,
            slack: .exact,
            estimatedProbes: 3
        )
        let composed = TransformationYield.identity.composed(with: yield)
        #expect(composed.structural == 10)
        #expect(composed.value == 5)
        #expect(composed.slack == .exact)
        #expect(composed.estimatedProbes == 3)
    }

    @Test("Composition sums structural, maxes value, composes slack, sums probes")
    func compositionSemantics() {
        let yieldA = TransformationYield(
            structural: 5,
            value: 10,
            slack: AffineSlack(multiplicative: 1, additive: 2),
            estimatedProbes: 3
        )
        let yieldB = TransformationYield(
            structural: 8,
            value: 3,
            slack: .exact,
            estimatedProbes: 7
        )
        let composed = yieldA.composed(with: yieldB)
        #expect(composed.structural == 13)
        #expect(composed.value == 10)
        #expect(composed.slack.additive == 2)
        #expect(composed.estimatedProbes == 10)
    }

    @Test("Ordering: structural yield dominates value yield")
    func structuralDominatesValue() {
        let highStructural = TransformationYield(
            structural: 10,
            value: 0,
            slack: .exact,
            estimatedProbes: 100
        )
        let highValue = TransformationYield(
            structural: 0,
            value: 100,
            slack: .exact,
            estimatedProbes: 1
        )
        // highStructural should be higher priority (less than in sort order).
        #expect(highStructural < highValue)
    }

    @Test("Ordering: higher structural yield is higher priority")
    func higherStructuralWins() {
        let larger = TransformationYield(
            structural: 20,
            value: 0,
            slack: .exact,
            estimatedProbes: 5
        )
        let smaller = TransformationYield(
            structural: 5,
            value: 0,
            slack: .exact,
            estimatedProbes: 5
        )
        #expect(larger < smaller)
    }

    @Test("Ordering: at equal structural, higher value yield wins")
    func valueBreaksTie() {
        let highValue = TransformationYield(
            structural: 0,
            value: 15,
            slack: .exact,
            estimatedProbes: 5
        )
        let lowValue = TransformationYield(
            structural: 0,
            value: 3,
            slack: .exact,
            estimatedProbes: 5
        )
        #expect(highValue < lowValue)
    }

    @Test("Ordering: at equal yield, exact preferred over approximate")
    func exactPreferred() {
        let exact = TransformationYield(
            structural: 0,
            value: 5,
            slack: .exact,
            estimatedProbes: 10
        )
        let approximate = TransformationYield(
            structural: 0,
            value: 5,
            slack: AffineSlack(multiplicative: 1, additive: 3),
            estimatedProbes: 10
        )
        #expect(exact < approximate)
    }

    @Test("Ordering: at equal yield and slack, lower cost wins")
    func lowerCostWins() {
        let cheap = TransformationYield(
            structural: 5,
            value: 0,
            slack: .exact,
            estimatedProbes: 2
        )
        let expensive = TransformationYield(
            structural: 5,
            value: 0,
            slack: .exact,
            estimatedProbes: 20
        )
        #expect(cheap < expensive)
    }
}

// MARK: - withBitPattern Tests

@Suite("ChoiceSequenceValue.withBitPattern")
struct WithBitPatternTests {
    @Test("Replaces unsigned value preserving tag and range")
    func unsignedReplacement() {
        let original = ChoiceSequenceValue.value(.init(
            choice: ChoiceValue(UInt64(42), tag: .uint64),
            validRange: 0 ... 100,
            isRangeExplicit: true
        ))
        let result = original.withBitPattern(7)
        guard case let .value(resultValue) = result else {
            Issue.record("Expected .value, got \(result)")
            return
        }
        #expect(resultValue.choice.bitPattern64 == 7)
        #expect(resultValue.choice.tag == .uint64)
        #expect(resultValue.validRange == 0 ... 100)
        #expect(resultValue.isRangeExplicit)
    }

    @Test("Replaces signed value preserving tag")
    func signedReplacement() {
        let int16Value = Int16(-100)
        let original = ChoiceSequenceValue.value(.init(
            choice: ChoiceValue(int16Value, tag: .int16),
            validRange: nil,
            isRangeExplicit: false
        ))
        let targetBitPattern = Int16(0).bitPattern64
        let result = original.withBitPattern(targetBitPattern)
        guard case let .value(resultValue) = result else {
            Issue.record("Expected .value, got \(result)")
            return
        }
        #expect(resultValue.choice.tag == .int16)
        #expect(resultValue.choice.bitPattern64 == targetBitPattern)
    }

    @Test("Converts .reduced to .value on replacement")
    func reducedBecomesValue() {
        let original = ChoiceSequenceValue.reduced(.init(
            choice: ChoiceValue(UInt64(50), tag: .uint64),
            validRange: 0 ... 100,
            isRangeExplicit: true
        ))
        let result = original.withBitPattern(0)
        guard case .value = result else {
            Issue.record("Expected .value after replacing .reduced, got \(result)")
            return
        }
    }

    @Test("Preserves valid range through replacement")
    func preservesValidRange() {
        let original = ChoiceSequenceValue.value(.init(
            choice: ChoiceValue(UInt64(99), tag: .uint16),
            validRange: 10 ... 200,
            isRangeExplicit: true
        ))
        let result = original.withBitPattern(15)
        guard case let .value(resultValue) = result else {
            Issue.record("Expected .value")
            return
        }
        #expect(resultValue.validRange == 10 ... 200)
    }
}

// MARK: - Compound Transformation Tests

@Suite("CompoundTransformation")
struct CompoundTransformationTests {
    @Test("Composed yield reduces steps correctly")
    func composedYield() {
        let stepA = CompoundStep(
            transformation: GraphTransformation(
                operation: .exchange(.redistribution(RedistributionScope(pairs: []))),
                yield: TransformationYield(
                    structural: 0,
                    value: 0,
                    slack: AffineSlack(multiplicative: 1, additive: 50),
                    estimatedProbes: 24
                ),
                precondition: .unconditional,
                postcondition: TransformationPostcondition(
                    isStructural: false,
                    invalidatesConvergence: [],
                    enablesRemoval: []
                )
            ),
            required: true
        )
        let stepB = CompoundStep(
            transformation: GraphTransformation(
                operation: .remove(.subtree(SubtreeRemovalScope(nodeID: 0, yield: 20))),
                yield: TransformationYield(
                    structural: 20,
                    value: 0,
                    slack: .exact,
                    estimatedProbes: 6
                ),
                precondition: .unconditional,
                postcondition: TransformationPostcondition(
                    isStructural: true,
                    invalidatesConvergence: [],
                    enablesRemoval: []
                )
            ),
            required: true
        )

        let compound = CompoundTransformation(
            steps: [stepA, stepB],
            executionModel: .sequential
        )
        let composed = compound.composedYield

        #expect(composed.structural == 20)
        #expect(composed.value == 0)
        #expect(composed.slack.additive == 50)
        #expect(composed.estimatedProbes == 30)
    }
}
