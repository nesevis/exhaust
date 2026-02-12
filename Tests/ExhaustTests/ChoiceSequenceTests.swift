//
//  ChoiceSequenceTests.swift
//  ExhaustTests
//
//  Tests for ChoiceSequence.flatten method
//

import Testing
@testable import Exhaust

@Suite("Choice Sequence Tests")
struct ChoiceSequenceTests {

    @Test("Flatten simple choice")
    func flattenSimpleChoice() throws {
        let tree = ChoiceTree.choice(
            .unsigned(42),
            ChoiceMetadata(validRanges: [0...100])
        )

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.count == 1)
        guard case let .value(value) = flattened[0] else {
            Issue.record("Expected value, got group marker")
            return
        }
        #expect(value.choice == .unsigned(42))
        #expect(value.validRanges == [0...100])
    }

    @Test("Flatten just returns empty")
    func flattenJust() throws {
        let tree = ChoiceTree.just("constant")

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.isEmpty)
    }

    @Test("Flatten getSize returns empty")
    func flattenGetSize() throws {
        let tree = ChoiceTree.getSize(100)

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.isEmpty)
    }

    @Test("Flatten sequence with group markers")
    func flattenSequence() throws {
        let tree = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(.unsigned(5), ChoiceMetadata(validRanges: [0...10])),
                .choice(.unsigned(8), ChoiceMetadata(validRanges: [0...10]))
            ],
            ChoiceMetadata(validRanges: [0...10])
        )

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.shortString == "[VV]")
    }

    @Test("Flatten nested sequence")
    func flattenNestedSequence() throws {
        // Create: [[5, 8], [3]]
        let tree = ChoiceTree.sequence(
            length: 2,
            elements: [
                .sequence(
                    length: 2,
                    elements: [
                        .choice(.unsigned(5), ChoiceMetadata(validRanges: [0...10])),
                        .choice(.unsigned(8), ChoiceMetadata(validRanges: [0...10]))
                    ],
                    ChoiceMetadata(validRanges: [0...10])
                ),
                .sequence(
                    length: 1,
                    elements: [
                        .choice(.unsigned(3), ChoiceMetadata(validRanges: [0...10]))
                    ],
                    ChoiceMetadata(validRanges: [0...10])
                )
            ],
            ChoiceMetadata(validRanges: [0...10])
        )

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.shortString == "[[VV][V]]")
    }

    @Test("Flatten group")
    func flattenGroup() throws {
        let tree = ChoiceTree.group([
            .choice(.unsigned(1), ChoiceMetadata(validRanges: [0...10])),
            .choice(.unsigned(2), ChoiceMetadata(validRanges: [0...10])),
            .choice(.unsigned(3), ChoiceMetadata(validRanges: [0...10]))
        ])

        let flattened = ChoiceSequence.flatten(tree)

        // Should be: group(true), value(1), value(2), value(3), group(false)
        #expect(flattened.count == 5)

        guard case .group(true) = flattened[0] else {
            Issue.record("Expected opening group marker")
            return
        }

        for i in 1...3 {
            guard case let .value(value) = flattened[i] else {
                Issue.record("Expected value at index \(i)")
                return
            }
            #expect(value.choice == .unsigned(UInt64(i)))
        }

        guard case .group(false) = flattened[4] else {
            Issue.record("Expected closing group marker")
            return
        }
    }

    @Test("Flatten resize")
    func flattenResize() throws {
        let tree = ChoiceTree.resize(
            newSize: 100,
            choices: [
                .choice(.unsigned(42), ChoiceMetadata(validRanges: [0...100]))
            ]
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
        #expect(value.choice == .unsigned(42))

        guard case .group(false) = flattened[2] else {
            Issue.record("Expected closing group marker")
            return
        }
    }

    @Test("Flatten important marker is transparent")
    func flattenImportant() throws {
        let tree = ChoiceTree.important(
            .choice(.unsigned(42), ChoiceMetadata(validRanges: [0...100]))
        )

        let flattened = ChoiceSequence.flatten(tree)

        // Important wrapper should be transparent
        #expect(flattened.count == 1)
        guard case let .value(value) = flattened[0] else {
            Issue.record("Expected value")
            return
        }
        #expect(value.choice == .unsigned(42))
    }

    @Test("Flatten selected marker is transparent")
    func flattenSelected() throws {
        let tree = ChoiceTree.selected(
            .choice(.unsigned(42), ChoiceMetadata(validRanges: [0...100]))
        )

        let flattened = ChoiceSequence.flatten(tree)

        // Selected wrapper should be transparent
        #expect(flattened.count == 1)
        guard case let .value(value) = flattened[0] else {
            Issue.record("Expected value")
            return
        }
        #expect(value.choice == .unsigned(42))
    }

    @Test("Flatten mixed tree with non-choices")
    func flattenMixedTree() throws {
        let tree = ChoiceTree.group([
            .just("constant"),
            .getSize(100),
            .choice(.unsigned(42), ChoiceMetadata(validRanges: [0...100])),
            .just("another constant")
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
        #expect(value.choice == .unsigned(42))

        guard case .group(false) = flattened[2] else {
            Issue.record("Expected closing group marker")
            return
        }
    }

    @Test("Flatten empty sequence")
    func flattenEmptySequence() throws {
        let tree = ChoiceTree.sequence(
            length: 0,
            elements: [],
            ChoiceMetadata(validRanges: [0...10])
        )

        let flattened = ChoiceSequence.flatten(tree)

        // Should be: sequence(true), sequence(false)
        #expect(flattened.shortString == "[]")
    }

    @Test("Flatten preserves valid ranges")
    func flattenPreservesValidRanges() throws {
        let customRanges: [ClosedRange<UInt64>] = [0...50, 100...200]
        let tree = ChoiceTree.choice(
            .unsigned(42),
            ChoiceMetadata(validRanges: customRanges)
        )

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.count == 1)
        guard case let .value(value) = flattened[0] else {
            Issue.record("Expected value")
            return
        }
        #expect(value.validRanges == customRanges)
    }

    @Test("Flatten with different choice value types")
    func flattenDifferentTypes() throws {
        let tree = ChoiceTree.group([
            .choice(.unsigned(42), ChoiceMetadata(validRanges: [0...100])),
            .choice(.signed(-10, 0, Int64.self), ChoiceMetadata(validRanges: [0...100])),
            .choice(.floating(3.14, 0, Double.self), ChoiceMetadata(validRanges: [0...100])),
            .choice(.character("A"), ChoiceMetadata(validRanges: [0...100]))
        ])

        let flattened = ChoiceSequence.flatten(tree)

        // Should be: group(true), value(42), value(-10), value(3.14), value('A'), group(false)
        #expect(flattened.count == 6)

        guard case .group(true) = flattened[0] else {
            Issue.record("Expected opening group marker")
            return
        }

        guard case let .value(value1) = flattened[1],
              case .unsigned(42) = value1.choice else {
            Issue.record("Expected unsigned value")
            return
        }

        guard case let .value(value2) = flattened[2],
              case .signed(-10, _, _) = value2.choice else {
            Issue.record("Expected signed value")
            return
        }

        guard case let .value(value3) = flattened[3],
              case .floating(3.14, _, _) = value3.choice else {
            Issue.record("Expected floating value")
            return
        }

        guard case let .value(value4) = flattened[4],
              case .character("A") = value4.choice else {
            Issue.record("Expected character value")
            return
        }

        guard case .group(false) = flattened[5] else {
            Issue.record("Expected closing group marker")
            return
        }
    }

    @Test("Verify group markers are balanced")
    func verifyGroupMarkersBalanced() throws {
        let tree = ChoiceTree.sequence(
            length: 1,
            elements: [
                .group([
                    .choice(.unsigned(1), ChoiceMetadata(validRanges: [0...10]))
                ])
            ],
            ChoiceMetadata(validRanges: [0...10])
        )

        let flattened = ChoiceSequence.flatten(tree)

        // Count opening and closing markers
        var openCount = 0
        var closeCount = 0

        for element in flattened {
            switch element {
            case .group(true), .sequence(true):
                openCount += 1
            case .group(false), .sequence(false):
                closeCount += 1
            default:
                continue
            }
        }

        #expect(openCount == closeCount)
        #expect(openCount == 2) // One for sequence, one for inner group
    }
}
