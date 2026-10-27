import Testing
@testable import ExhaustCore

@Suite("Permutation scope coverage")
struct PermutationScopeCoverageTests {
    @Test("Every shape group is independently searchable and dispatched", arguments: [false, true])
    func everyShapeGroupIsSearched(firstGroupNeedsSwap: Bool) throws {
        let leaf = Gen.choose(in: UInt64(0) ... 10)
        let array = Gen.arrayOf(leaf, exactly: 1)
        let generator = Gen.zip(leaf, leaf, array, array)
        let start = (firstGroupNeedsSwap ? UInt64(2) : 0, UInt64(1), [UInt64(2)], [UInt64(1)])
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let scopes = PermutationQuery.build(graph: graph)
        try #require(scopes.count == 2)
        #expect(scopes[0].parentNodeID == scopes[1].parentNodeID)
        #expect(scopes.allSatisfy { $0.siblings.count == 2 })
        #expect(Set(scopes.flatMap(\.siblings)).count == 4)

        for (index, scope) in scopes.enumerated() {
            var search = SwapSearch(scope: scope, sequence: sequence, graph: graph)
            var buffer = sequence
            let candidate = search.next(.initial, into: &buffer)
            #expect((candidate != nil) == (index == 1 || firstGroupNeedsSwap))
            if candidate != nil {
                #expect(buffer.shortLexPrecedes(sequence))
            }
        }

        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 1, enabledEncoders: [.siblingSwap]),
            collectStats: false,
            property: { _ in false }
        )
        runner.run()
        let output = try #require(runner.incumbent.output as? (UInt64, UInt64, [UInt64], [UInt64]))
        #expect(output.0 == (firstGroupNeedsSwap ? 1 : 0))
        #expect(output.1 == (firstGroupNeedsSwap ? 2 : 1))
        #expect(output.2 == [1])
        #expect(output.3 == [2])
    }

    @Test("Nested permutation groups are ordered globally by their first sibling position")
    func nestedGroupsFollowPositionOrder() throws {
        let leaf = Gen.choose(in: UInt64(0) ... 10)
        let array = Gen.arrayOf(leaf, exactly: 1)
        let generator = Gen.zip(Gen.zip(leaf, leaf), array, array)
        let start = ((UInt64(2), UInt64(1)), [UInt64(4)], [UInt64(3)])
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        let graph = ChoiceGraph.build(from: tree)

        let scopes = PermutationQuery.build(graph: graph)

        try #require(scopes.count == 2)
        let positions = try scopes.map { scope in
            let firstSibling = try #require(scope.siblings.first)
            return try #require(graph.nodes[firstSibling].positionRange).lowerBound
        }
        #expect(positions[0] < positions[1])
        #expect(scopes.allSatisfy { $0.siblings.count >= 2 })
        guard case .chooseBits = graph.nodes[scopes[0].siblings[0]].kind,
              case .sequence = graph.nodes[scopes[1].siblings[0]].kind
        else {
            Issue.record("The nested scalar group must precede the outer array group")
            return
        }
    }
}
