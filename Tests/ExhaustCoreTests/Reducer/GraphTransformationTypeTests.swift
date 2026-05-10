//
//  GraphTransformationTypeTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Transformation Yield Tests

@Suite("TransformationYield")
struct TransformationYieldTests {
    @Test("Ordering: structural yield dominates value yield")
    func structuralDominatesValue() {
        let highStructural = TransformationYield(
            structural: 10,
            value: 0,
            maxSourceDistance: 0,
            estimatedProbes: 100
        )
        let highValue = TransformationYield(
            structural: 0,
            value: 100,
            maxSourceDistance: 0,
            estimatedProbes: 1
        )
        #expect(highStructural > highValue)
    }

    @Test("Ordering: higher structural yield is higher priority")
    func higherStructuralWins() {
        let larger = TransformationYield(
            structural: 20,
            value: 0,
            maxSourceDistance: 0,
            estimatedProbes: 5
        )
        let smaller = TransformationYield(
            structural: 5,
            value: 0,
            maxSourceDistance: 0,
            estimatedProbes: 5
        )
        #expect(larger > smaller)
    }

    @Test("Ordering: at equal structural, higher value yield wins")
    func valueBreaksTie() {
        let highValue = TransformationYield(
            structural: 0,
            value: 15,
            maxSourceDistance: 0,
            estimatedProbes: 5
        )
        let lowValue = TransformationYield(
            structural: 0,
            value: 3,
            maxSourceDistance: 0,
            estimatedProbes: 5
        )
        #expect(highValue > lowValue)
    }

    @Test("Ordering: at equal yield, exact preferred over approximate")
    func exactPreferred() {
        let exact = TransformationYield(
            structural: 0,
            value: 5,
            maxSourceDistance: 0,
            estimatedProbes: 10
        )
        let approximate = TransformationYield(
            structural: 0,
            value: 5,
            maxSourceDistance: 100,
            estimatedProbes: 10
        )
        #expect(exact > approximate)
    }

    @Test("Ordering: at equal yield, closer source distance preferred")
    func closerDistancePreferred() {
        let close = TransformationYield(
            structural: 0,
            value: 0,
            maxSourceDistance: 5,
            estimatedProbes: 10
        )
        let far = TransformationYield(
            structural: 0,
            value: 0,
            maxSourceDistance: 5000,
            estimatedProbes: 10
        )
        #expect(close > far)
    }

    @Test("Ordering: at equal yield and distance, lower cost wins")
    func lowerCostWins() {
        let cheap = TransformationYield(
            structural: 5,
            value: 0,
            maxSourceDistance: 0,
            estimatedProbes: 2
        )
        let expensive = TransformationYield(
            structural: 5,
            value: 0,
            maxSourceDistance: 0,
            estimatedProbes: 20
        )
        #expect(cheap > expensive)
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
