//
//  ChoiceSequenceTests.swift
//  ExhaustTests
//
//  Tests for ChoiceSequence.flatten method
//

import ExhaustCore
import Testing

@Suite("Choice Sequence Tests")
struct ChoiceSequenceTests {
    @Test("Operative hash ignores generator-derived metadata")
    func operativeHashIgnoresMetadata() {
        let first: ChoiceSequence = [
            .sequence(true, validRange: 1 ... 3, isLengthExplicit: true),
            .branch(.init(id: 1, branchCount: 2, fingerprint: 11)),
            .value(.init(
                choice: ChoiceValue(UInt64(42), tag: .uint64),
                validRange: 0 ... 100,
                isRangeExplicit: true
            )),
            .sequence(false, validRange: 1 ... 3, isLengthExplicit: true),
        ]
        let second: ChoiceSequence = [
            .sequence(true, validRange: nil, isLengthExplicit: false),
            .branch(.init(id: 1, branchCount: 20, fingerprint: 99)),
            .value(.init(
                choice: ChoiceValue(UInt64(42), tag: .int64),
                validRange: nil,
                isRangeExplicit: false
            )),
            .sequence(false, validRange: nil, isLengthExplicit: false),
        ]

        #expect(first.operativeHash == second.operativeHash)
    }

    @Test("Operative hash includes replay decisions")
    func operativeHashIncludesReplayDecisions() {
        let original: ChoiceSequence = [
            .group(true),
            .branch(.init(id: 1, branchCount: 2, fingerprint: 11)),
            .value(.init(choice: ChoiceValue(UInt64(42), tag: .uint64), validRange: nil)),
            .group(false),
        ]
        let changedBranch: ChoiceSequence = [
            .group(true),
            .branch(.init(id: 0, branchCount: 2, fingerprint: 11)),
            .value(.init(choice: ChoiceValue(UInt64(42), tag: .uint64), validRange: nil)),
            .group(false),
        ]
        let changedValue: ChoiceSequence = [
            .group(true),
            .branch(.init(id: 1, branchCount: 2, fingerprint: 11)),
            .value(.init(choice: ChoiceValue(UInt64(43), tag: .uint64), validRange: nil)),
            .group(false),
        ]

        #expect(original.operativeHash != changedBranch.operativeHash)
        #expect(original.operativeHash != changedValue.operativeHash)
    }

    @Test("Flatten simple choice")
    func flattenSimpleChoice() {
        let tree = ChoiceTree.choice(
            ChoiceValue(UInt64(42), tag: .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.count == 1)
        guard case let .value(value) = flattened[0] else {
            Issue.record("Expected value, got group marker")
            return
        }
        #expect(value.choice == ChoiceValue(UInt64(42), tag: .uint64))
        #expect(value.validRange == (0 ... 100 as ClosedRange<UInt64>))
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
            elements: [
                .choice(ChoiceValue(UInt64(5), tag: .uint64), ChoiceMetadata(validRange: 0 ... 10)),
                .choice(ChoiceValue(UInt64(8), tag: .uint64), ChoiceMetadata(validRange: 0 ... 10)),
            ],
            metadata: ChoiceMetadata(validRange: 0 ... 10)
        )

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.shortString == "[VV]")
    }

    @Test("Flatten nested sequence")
    func flattenNestedSequence() {
        // Create: [[5, 8], [3]]
        let tree = ChoiceTree.sequence(
            elements: [
                .sequence(
                    elements: [
                        .choice(ChoiceValue(UInt64(5), tag: .uint64), ChoiceMetadata(validRange: 0 ... 10)),
                        .choice(ChoiceValue(UInt64(8), tag: .uint64), ChoiceMetadata(validRange: 0 ... 10)),
                    ],
                    metadata: ChoiceMetadata(validRange: 0 ... 10)
                ),
                .sequence(
                    elements: [
                        .choice(ChoiceValue(UInt64(3), tag: .uint64), ChoiceMetadata(validRange: 0 ... 10)),
                    ],
                    metadata: ChoiceMetadata(validRange: 0 ... 10)
                ),
            ],
            metadata: ChoiceMetadata(validRange: 0 ... 10)
        )

        let flattened = ChoiceSequence.flatten(tree)

        #expect(flattened.shortString == "[[VV][V]]")
    }

    @Test("Flatten group")
    func flattenGroup() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(UInt64(1), tag: .uint64), ChoiceMetadata(validRange: 0 ... 10)),
            .choice(ChoiceValue(UInt64(2), tag: .uint64), ChoiceMetadata(validRange: 0 ... 10)),
            .choice(ChoiceValue(UInt64(3), tag: .uint64), ChoiceMetadata(validRange: 0 ... 10)),
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
            #expect(value.choice == ChoiceValue(UInt64(i), tag: .uint64))
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
                .choice(ChoiceValue(UInt64(42), tag: .uint64), ChoiceMetadata(validRange: 0 ... 100)),
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
        #expect(value.choice == ChoiceValue(UInt64(42), tag: .uint64))

        guard case .group(false) = flattened[2] else {
            Issue.record("Expected closing group marker")
            return
        }
    }

    @Test("Flatten selected branch is transparent")
    func flattenSelected() {
        let tree = ChoiceTree.branch(
            fingerprint: 0, weight: 1, id: 0, branchCount: 1,
            choice: .choice(ChoiceValue(UInt64(42), tag: .uint64), ChoiceMetadata(validRange: 0 ... 100)),
            isSelected: true
        )

        let flattened = ChoiceSequence.flatten(tree)

        // Selected wrapper should be transparent
        #expect(flattened.count == 1)
        guard case let .value(value) = flattened[0] else {
            Issue.record("Expected value")
            return
        }
        #expect(value.choice == ChoiceValue(UInt64(42), tag: .uint64))
    }

    @Test("Flatten mixed tree with non-choices")
    func flattenMixedTree() {
        let tree = ChoiceTree.group([
            .just,
            .getSize(100),
            .choice(ChoiceValue(UInt64(42), tag: .uint64), ChoiceMetadata(validRange: 0 ... 100)),
            .just,
        ])

        let flattened = ChoiceSequence.flatten(tree)

        // Should be: group(true), just, value(42), just, group(false)
        // getSize is skipped, just emits a marker
        #expect(flattened.count == 5)

        guard case .group(true) = flattened[0] else {
            Issue.record("Expected opening group marker")
            return
        }

        #expect(flattened[1] == .just)

        guard case let .value(value) = flattened[2] else {
            Issue.record("Expected value")
            return
        }
        #expect(value.choice == ChoiceValue(UInt64(42), tag: .uint64))

        #expect(flattened[3] == .just)

        guard case .group(false) = flattened[4] else {
            Issue.record("Expected closing group marker")
            return
        }
    }

    @Test("Flatten empty sequence")
    func flattenEmptySequence() {
        let tree = ChoiceTree.sequence(
            elements: [],
            metadata: ChoiceMetadata(validRange: 0 ... 10)
        )

        let flattened = ChoiceSequence.flatten(tree)

        // Should be: sequence(true), sequence(false)
        #expect(flattened.shortString == "[]")
    }

    @Test("Flatten preserves valid range")
    func flattenPreservesValidRange() {
        let customRange: ClosedRange<UInt64> = 0 ... 200
        let tree = ChoiceTree.choice(
            ChoiceValue(UInt64(42), tag: .uint64),
            ChoiceMetadata(validRange: customRange)
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
            .choice(ChoiceValue(UInt64(42), tag: .uint64), ChoiceMetadata(validRange: 0 ... 100)),
            .choice(ChoiceValue(Int64(-10), tag: .int64), ChoiceMetadata(validRange: 0 ... 100)),
            .choice(ChoiceValue(Double(3.14), tag: .double), ChoiceMetadata(validRange: 0 ... 100)),
        ])

        let flattened = ChoiceSequence.flatten(tree)

        // Should be: group(true), value(42), value(-10), value(3.14), group(false)
        #expect(flattened.count == 5)

        guard case .group(true) = flattened[0] else {
            Issue.record("Expected opening group marker")
            return
        }

        guard case let .value(value1) = flattened[1] else {
            Issue.record("Expected unsigned value")
            return
        }
        #expect(value1.choice.bitPattern64 == 42)

        guard case let .value(value2) = flattened[2] else {
            Issue.record("Expected signed value")
            return
        }
        #expect(value2.choice.decodedSignedValue == -10)

        guard case let .value(value3) = flattened[3] else {
            Issue.record("Expected floating value")
            return
        }
        #expect(value3.choice.decodedDoubleValue == 3.14)

        guard case .group(false) = flattened[4] else {
            Issue.record("Expected closing group marker")
            return
        }
    }

    @Test("flatten().count equals flattenedEntryCount for mixed branch group")
    func flattenCountMatchesFlattenedEntryCountMixedGroup() {
        let sibling: ChoiceTree = .sequence(
            elements: [.just, .just],
            metadata: ChoiceMetadata(validRange: nil)
        )
        let mixed: ChoiceTree = .group([
            .branch(
                fingerprint: 1, weight: 1, id: 0, branchCount: 2,
                choice: .just,
                isSelected: true
            ),
            sibling,
        ])
        let flatCount = ChoiceSequence.flatten(mixed).count
        let predicted = mixed.flattenedEntryCount
        #expect(
            flatCount == predicted,
            "flatten().count=\(flatCount) but flattenedEntryCount=\(predicted)"
        )
    }

    @Test("flatten().count equals flattenedEntryCount for all-branch pick group")
    func flattenCountMatchesFlattenedEntryCountAllBranch() {
        let group: ChoiceTree = .group([
            .branch(
                fingerprint: 1, weight: 1, id: 0, branchCount: 2,
                choice: .choice(
                    ChoiceValue(0, tag: .uint8),
                    ChoiceMetadata(validRange: 0 ... 255)
                ),
                isSelected: true
            ),
            .branch(
                fingerprint: 1, weight: 1, id: 1, branchCount: 2,
                choice: .just,
                isSelected: false
            ),
        ])
        #expect(ChoiceSequence.flatten(group).count == group.flattenedEntryCount)
    }

    @Test("Verify group markers are balanced")
    func verifyGroupMarkersBalanced() {
        let tree = ChoiceTree.sequence(
            elements: [
                .group([
                    .choice(ChoiceValue(UInt64(1), tag: .uint64), ChoiceMetadata(validRange: 0 ... 10)),
                ]),
            ],
            metadata: ChoiceMetadata(validRange: 0 ... 10)
        )

        let flattened = ChoiceSequence.flatten(tree)

        // Count opening and closing markers
        var openCount = 0
        var closeCount = 0

        for element in flattened {
            switch element {
                case .group(true), .sequence(true, validRange: _, isLengthExplicit: _):
                    openCount += 1
                case .group(false), .sequence(false, validRange: _, isLengthExplicit: _):
                    closeCount += 1
                default:
                    continue
            }
        }

        #expect(openCount == closeCount)
        #expect(openCount == 2) // One for sequence, one for inner group
    }
}
