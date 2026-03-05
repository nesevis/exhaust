//
//  ChoiceSequenceTests.swift
//  ExhaustTests
//
//  Tests for ChoiceSequence.flatten method
//

import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("Choice Sequence Tests")
struct ChoiceSequenceTests {
    @Test("Flatten simple choice")
    func flattenSimpleChoice() {
        let tree = ChoiceTree.choice(
            .unsigned(42, .uint64),
            ChoiceMetadata(validRange: 0 ... 100),
        )

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.count == 1)
        guard case let .value(value) = flattened[0] else {
            Issue.record("Expected value, got group marker")
            return
        }
        #expect(value.choice == .unsigned(42, .uint64))
        #expect(value.validRange == (0 ... 100 as ClosedRange<UInt64>))
    }

    @Test("Flatten just returns empty")
    func flattenJust() {
        let tree = ChoiceTree.just("constant")

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.isEmpty)
    }

    @Test("Flatten getSize returns empty")
    func flattenGetSize() {
        let tree = ChoiceTree.getSize(100)

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.isEmpty)
    }

    @Test("Flatten sequence with group markers")
    func flattenSequence() {
        let tree = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(.unsigned(5, .uint64), ChoiceMetadata(validRange: 0 ... 10)),
                .choice(.unsigned(8, .uint64), ChoiceMetadata(validRange: 0 ... 10)),
            ],
            ChoiceMetadata(validRange: 0 ... 10),
        )

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.shortString == "[VV]")
    }

    @Test("Flatten nested sequence")
    func flattenNestedSequence() {
        // Create: [[5, 8], [3]]
        let tree = ChoiceTree.sequence(
            length: 2,
            elements: [
                .sequence(
                    length: 2,
                    elements: [
                        .choice(.unsigned(5, .uint64), ChoiceMetadata(validRange: 0 ... 10)),
                        .choice(.unsigned(8, .uint64), ChoiceMetadata(validRange: 0 ... 10)),
                    ],
                    ChoiceMetadata(validRange: 0 ... 10),
                ),
                .sequence(
                    length: 1,
                    elements: [
                        .choice(.unsigned(3, .uint64), ChoiceMetadata(validRange: 0 ... 10)),
                    ],
                    ChoiceMetadata(validRange: 0 ... 10),
                ),
            ],
            ChoiceMetadata(validRange: 0 ... 10),
        )

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.shortString == "[[VV][V]]")
    }

    @Test("Flatten group")
    func flattenGroup() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), ChoiceMetadata(validRange: 0 ... 10)),
            .choice(.unsigned(2, .uint64), ChoiceMetadata(validRange: 0 ... 10)),
            .choice(.unsigned(3, .uint64), ChoiceMetadata(validRange: 0 ... 10)),
        ])

        let flattened = ChoiceSequence.flatten(tree)

        // Should be: group(true), value(1), value(2), value(3), group(false)
        #expect(flattened.count == 5)

        guard case .group(true) = flattened[0] else {
            Issue.record("Expected opening group marker")
            return
        }

        for i in 1 ... 3 {
            guard case let .value(value) = flattened[i] else {
                Issue.record("Expected value at index \(i)")
                return
            }
            #expect(value.choice == .unsigned(UInt64(i), .uint64))
        }

        guard case .group(false) = flattened[4] else {
            Issue.record("Expected closing group marker")
            return
        }
    }

    @Test("Flatten resize")
    func flattenResize() {
        let tree = ChoiceTree.resize(
            newSize: 100,
            choices: [
                .choice(.unsigned(42, .uint64), ChoiceMetadata(validRange: 0 ... 100)),
            ],
        )

        let flattened = ChoiceSequence.flatten(tree)

        // Should be: group(true), value(42), group(false)
        #expect(flattened.count == 3)

        guard case .group(true) = flattened[0] else {
            Issue.record("Expected opening group marker")
            return
        }

        guard case let .value(value) = flattened[1] else {
            Issue.record("Expected value")
            return
        }
        #expect(value.choice == .unsigned(42, .uint64))

        guard case .group(false) = flattened[2] else {
            Issue.record("Expected closing group marker")
            return
        }
    }

    @Test("Flatten selected marker is transparent")
    func flattenSelected() {
        let tree = ChoiceTree.selected(
            .choice(.unsigned(42, .uint64), ChoiceMetadata(validRange: 0 ... 100)),
        )

        let flattened = ChoiceSequence.flatten(tree)

        // Selected wrapper should be transparent
        #expect(flattened.count == 1)
        guard case let .value(value) = flattened[0] else {
            Issue.record("Expected value")
            return
        }
        #expect(value.choice == .unsigned(42, .uint64))
    }

    @Test("Flatten mixed tree with non-choices")
    func flattenMixedTree() {
        let tree = ChoiceTree.group([
            .just("constant"),
            .getSize(100),
            .choice(.unsigned(42, .uint64), ChoiceMetadata(validRange: 0 ... 100)),
            .just("another constant"),
        ])

        let flattened = ChoiceSequence.flatten(tree)

        // Should be: group(true), value(42), group(false)
        // just and getSize are skipped
        #expect(flattened.count == 3)

        guard case .group(true) = flattened[0] else {
            Issue.record("Expected opening group marker")
            return
        }

        guard case let .value(value) = flattened[1] else {
            Issue.record("Expected value")
            return
        }
        #expect(value.choice == .unsigned(42, .uint64))

        guard case .group(false) = flattened[2] else {
            Issue.record("Expected closing group marker")
            return
        }
    }

    @Test("Flatten empty sequence")
    func flattenEmptySequence() {
        let tree = ChoiceTree.sequence(
            length: 0,
            elements: [],
            ChoiceMetadata(validRange: 0 ... 10),
        )

        let flattened = ChoiceSequence.flatten(tree)

        // Should be: sequence(true), sequence(false)
        #expect(flattened.shortString == "[]")
    }

    @Test("Flatten preserves valid range")
    func flattenPreservesValidRange() {
        let customRange: ClosedRange<UInt64> = 0 ... 200
        let tree = ChoiceTree.choice(
            .unsigned(42, .uint64),
            ChoiceMetadata(validRange: customRange),
        )

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.count == 1)
        guard case let .value(value) = flattened[0] else {
            Issue.record("Expected value")
            return
        }
        #expect(value.validRange == customRange)
    }

    @Test("Flatten with different choice value types")
    func flattenDifferentTypes() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(42, .uint64), ChoiceMetadata(validRange: 0 ... 100)),
            .choice(.signed(-10, Int64(-10).bitPattern64, .int64), ChoiceMetadata(validRange: 0 ... 100)),
            .choice(.floating(3.14, Double(3.14).bitPattern64, .double), ChoiceMetadata(validRange: 0 ... 100)),
        ])

        let flattened = ChoiceSequence.flatten(tree)

        // Should be: group(true), value(42), value(-10), value(3.14), group(false)
        #expect(flattened.count == 5)

        guard case .group(true) = flattened[0] else {
            Issue.record("Expected opening group marker")
            return
        }

        guard case let .value(value1) = flattened[1],
              case .unsigned(42, _) = value1.choice
        else {
            Issue.record("Expected unsigned value")
            return
        }

        guard case let .value(value2) = flattened[2],
              case .signed(-10, _, _) = value2.choice
        else {
            Issue.record("Expected signed value")
            return
        }

        guard case let .value(value3) = flattened[3],
              case .floating(3.14, _, _) = value3.choice
        else {
            Issue.record("Expected floating value")
            return
        }

        guard case .group(false) = flattened[4] else {
            Issue.record("Expected closing group marker")
            return
        }
    }

    @Test("Verify group markers are balanced")
    func verifyGroupMarkersBalanced() {
        let tree = ChoiceTree.sequence(
            length: 1,
            elements: [
                .group([
                    .choice(.unsigned(1, .uint64), ChoiceMetadata(validRange: 0 ... 10)),
                ]),
            ],
            ChoiceMetadata(validRange: 0 ... 10),
        )

        let flattened = ChoiceSequence.flatten(tree)

        // Count opening and closing markers
        var openCount = 0
        var closeCount = 0

        for element in flattened {
            switch element {
            case .group(true), .sequence(true, isLengthExplicit: _):
                openCount += 1
            case .group(false), .sequence(false, isLengthExplicit: _):
                closeCount += 1
            default:
                continue
            }
        }

        #expect(openCount == closeCount)
        #expect(openCount == 2) // One for sequence, one for inner group
    }
}
