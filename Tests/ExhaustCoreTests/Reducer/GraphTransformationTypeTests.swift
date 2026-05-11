//
//  GraphTransformationTypeTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Dispatch Priority Tests

@Suite("DispatchPriority")
struct DispatchPriorityTests {
    @Test("Ordering: structural benefit dominates value benefit")
    func structuralDominatesValue() {
        let highStructural = DispatchPriority(
            structuralBenefit: 10,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 100
        )
        let highValue = DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 100,
            reductionMagnitude: 0,
            estimatedCost: 1
        )
        #expect(highStructural > highValue)
    }

    @Test("Ordering: higher structural benefit is higher priority")
    func higherStructuralWins() {
        let larger = DispatchPriority(
            structuralBenefit: 20,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 5
        )
        let smaller = DispatchPriority(
            structuralBenefit: 5,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 5
        )
        #expect(larger > smaller)
    }

    @Test("Ordering: at equal structural benefit, higher value benefit wins")
    func valueBreaksTie() {
        let highValue = DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 15,
            reductionMagnitude: 0,
            estimatedCost: 5
        )
        let lowValue = DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 3,
            reductionMagnitude: 0,
            estimatedCost: 5
        )
        #expect(highValue > lowValue)
    }

    @Test("Ordering: at equal benefit, exact preferred over approximate")
    func exactPreferred() {
        let exact = DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 5,
            reductionMagnitude: 0,
            estimatedCost: 10
        )
        let approximate = DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 5,
            reductionMagnitude: 100,
            estimatedCost: 10
        )
        #expect(exact > approximate)
    }

    @Test("Ordering: at equal benefit, smaller reduction magnitude preferred")
    func closerDistancePreferred() {
        let close = DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 0,
            reductionMagnitude: 5,
            estimatedCost: 10
        )
        let far = DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 0,
            reductionMagnitude: 5000,
            estimatedCost: 10
        )
        #expect(close > far)
    }

    @Test("Ordering: at equal benefit and magnitude, lower cost wins")
    func lowerCostWins() {
        let cheap = DispatchPriority(
            structuralBenefit: 5,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 2
        )
        let expensive = DispatchPriority(
            structuralBenefit: 5,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 20
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
