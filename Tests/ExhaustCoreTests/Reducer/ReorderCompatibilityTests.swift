import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Reorder sibling type compatibility")
struct ReorderCompatibilityTests {
    @Test("Mixed suffix categories are rejected in every sibling order", arguments: SuffixPair.allCases, siblingOrders)
    private func incompatibleSuffixes(pair: SuffixPair, order: [Int]) throws {
        for prefixLength in [1, 3] {
            let prefix = Array(repeating: ChoiceValue(UInt64(1), tag: .uint64), count: prefixLength)
            let tails = pair.values
            let keys = [prefix, prefix + [tails.0], prefix + [tails.1]]
            let fixture = try outerGroupFixture(keys: order.map { keys[$0] })
            var encoder = GraphReorderEncoder()
            encoder.start(scope: fixture.scope)
            var candidate = fixture.sequence
            let probe = encoder.nextProbe(into: &candidate, lastAccepted: false)
            #expect(probe == nil)
            #expect(candidate == fixture.sequence)
        }
    }

    @Test("Empty keys do not hide incompatible tails after the first nonempty key")
    func emptyPrefixDoesNotHideConflict() throws {
        let prefix = [ChoiceValue(UInt64(1), tag: .uint64)]
        let fixture = try outerGroupFixture(keys: [
            [],
            prefix,
            prefix + [ChoiceValue(UInt64(9), tag: .uint64)],
            prefix + [ChoiceValue(Int64(-2), tag: .int64)],
        ])
        var encoder = GraphReorderEncoder()
        encoder.start(scope: fixture.scope)
        var candidate = fixture.sequence
        #expect(encoder.nextProbe(into: &candidate, lastAccepted: false) == nil)
        #expect(candidate == fixture.sequence)
    }

    @Test("Empty sibling keys remain an unchanged compatible group")
    func allEmptyKeysAreUnchanged() throws {
        let fixture = try outerGroupFixture(keys: [[], [], []])
        var encoder = GraphReorderEncoder()
        encoder.start(scope: fixture.scope)
        var candidate = fixture.sequence
        #expect(encoder.nextProbe(into: &candidate, lastAccepted: false) == nil)
        #expect(candidate == fixture.sequence)
    }

    @Test("Compatible variable-length keys sort naturally across bit widths", arguments: NumericCategory.allCases)
    private func compatibleWidthsAndLengths(category: NumericCategory) throws {
        let prefix = [ChoiceValue(UInt64(1), tag: .uint64)]
        let tails = category.values
        let keys = [prefix + [tails.0], [], prefix, prefix + [tails.1]]
        let fixture = try outerGroupFixture(keys: keys)
        var encoder = GraphReorderEncoder()
        encoder.start(scope: fixture.scope)
        var candidate = fixture.sequence
        let probe = encoder.nextProbe(into: &candidate, lastAccepted: false)
        #expect(probe != nil)
        let expected = tree(keys: [[], prefix, prefix + [tails.1], prefix + [tails.0]])
        #expect(candidate == ChoiceSequence(expected))
        #expect(ChoiceSequence.validate(candidate))
        #expect(encoder.nextProbe(into: &candidate, lastAccepted: false) == nil)
    }

    @Test("Skipping an incompatible group still allows the next eligible group to reorder")
    func skipsConflictAndContinues() throws {
        let prefix = [ChoiceValue(UInt8(1), tag: .uint8)]
        let badKeys = [
            prefix,
            prefix + [ChoiceValue(UInt64(9), tag: .uint64)],
            prefix + [ChoiceValue(Int64(-2), tag: .int64)],
        ]
        let badGroup = tree(keys: badKeys)
        let initialTree = ChoiceTree.group([.uint64Zip([30, 10]), badGroup])
        let graph = ChoiceGraph.build(from: initialTree)
        let sequence = ChoiceSequence(initialTree)
        let reordering = try #require(ReorderingQuery.build(graph: graph))
        let firstGroup = try #require(reordering.groups.first)
        #expect(firstGroup.ranges.map { ChoiceSequence.siblingComparisonKey(from: sequence, range: $0) } == badKeys)
        var encoder = GraphReorderEncoder()
        encoder.start(scope: encoderInput(tree: initialTree, graph: graph, reordering: reordering))
        var candidate = sequence
        let probe = encoder.nextProbe(into: &candidate, lastAccepted: false)
        #expect(probe != nil)
        let expected = ChoiceTree.group([.uint64Zip([10, 30]), badGroup])
        #expect(candidate == ChoiceSequence(expected))
        #expect(ChoiceSequence.validate(candidate))
    }
}

// MARK: - Test Helpers

private let siblingOrders = [
    [0, 1, 2], [0, 2, 1],
    [1, 0, 2], [1, 2, 0],
    [2, 0, 1], [2, 1, 0],
]

/// Covers every pair of numeric categories at an index absent from the short reference key.
private enum SuffixPair: CaseIterable {
    case unsignedSigned
    case unsignedFloating
    case signedFloating

    var values: (ChoiceValue, ChoiceValue) {
        switch self {
            case .unsignedSigned:
                (ChoiceValue(UInt64(9), tag: .uint64), ChoiceValue(Int64(-2), tag: .int64))
            case .unsignedFloating:
                (ChoiceValue(UInt64(9), tag: .uint64), ChoiceValue(-2.5, tag: .double))
            case .signedFloating:
                (ChoiceValue(Int64(9), tag: .int64), ChoiceValue(-2.5, tag: .double))
        }
    }
}

/// Uses differing widths within one category to ensure compatibility is not narrowed to exact type tags.
private enum NumericCategory: CaseIterable {
    case unsigned
    case signed
    case floating

    var values: (ChoiceValue, ChoiceValue) {
        switch self {
            case .unsigned:
                (ChoiceValue(UInt64(9), tag: .uint64), ChoiceValue(UInt8(2), tag: .uint8))
            case .signed:
                (ChoiceValue(Int64(9), tag: .int64), ChoiceValue(Int8(-2), tag: .int8))
            case .floating:
                (ChoiceValue(9.0, tag: .double), ChoiceValue(Float(-2.5), tag: .float))
        }
    }
}

/// Uses real query groups with the same outer kind, isolating the parent from unrelated inner leaf groups.
private func outerGroupFixture(keys: [[ChoiceValue]]) throws -> (sequence: ChoiceSequence, scope: EncoderInput) {
    let choiceTree = tree(keys: keys)
    let graph = ChoiceGraph.build(from: choiceTree)
    let sequence = ChoiceSequence(choiceTree)
    let queried = try #require(ReorderingQuery.build(graph: graph))
    let group = try #require(queried.groups.first { $0.depth == 0 && $0.ranges.count == keys.count })
    #expect(group.ranges.map { ChoiceSequence.siblingComparisonKey(from: sequence, range: $0) } == keys)
    return (sequence, encoderInput(tree: choiceTree, graph: graph, reordering: ReorderingScope(groups: [group])))
}

private func tree(keys: [[ChoiceValue]]) -> ChoiceTree {
    .group(keys.map { key in
        .group(key.map { value in
            .choice(value, .init(validRange: nil, isRangeExplicit: false))
        })
    })
}

private func encoderInput(tree: ChoiceTree, graph: ChoiceGraph, reordering: ReorderingScope) -> EncoderInput {
    EncoderInput(
        transformation: GraphTransformation(operation: .reorder(reordering), priority: .zeroBenefit),
        baseSequence: ChoiceSequence(tree),
        tree: tree,
        graph: graph,
        warmStartRecords: [:]
    )
}
