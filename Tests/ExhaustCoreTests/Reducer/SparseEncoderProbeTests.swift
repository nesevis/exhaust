import Testing
@testable import ExhaustCore

@Suite("Sparse leaf probe contract")
struct SparseEncoderProbeTests {
    @Test("Sparse hashing and restoration support character and control leaves independently of numeric admission", arguments: [
        TypeTag.character, .bits, .date, .depthControl, .laneControl,
    ], [2, 3, 4])
    func nonNumericLeaves(tag: TypeTag, arity: Int) throws {
        let patterns: [UInt64] = [75, 100, 0, 125, 175]
        let tree = ChoiceTree.group(patterns.map { pattern in
            .choice(ChoiceValue(pattern, tag: tag), .init(validRange: tag.bitPatternRange, isRangeExplicit: true))
        })
        let base = ChoiceSequence(tree)
        let graph = ChoiceGraph.build(from: tree)
        let leaves = try graph.leafNodes.prefix(arity).map { nodeID in
            let position = try #require(graph.nodes[nodeID].positionRange).lowerBound
            let value = try #require(base[position].value)
            return ReductionLeaf(
                nodeID: nodeID,
                position: position,
                path: graph.nodes[nodeID].choicePath,
                choice: value.choice,
                range: tag.bitPatternRange,
                bindFingerprints: [],
                mayReshapeOnAcceptance: false
            )
        }
        let probe = SparseEncoderProbe(leaves: leaves, patterns: Array(repeating: 0, count: arity))
        var candidate = base
        probe.write(into: &candidate)
        #expect(probe.hash(baseHash: ZobristHash.hash(of: base), baseSequence: base) == ZobristHash.hash(of: candidate))
        let untouchedPositions = try graph.leafNodes.dropFirst(arity).map { nodeID in
            try #require(graph.nodes[nodeID].positionRange).lowerBound
        }
        #expect(untouchedPositions.allSatisfy { candidate[$0] == base[$0] })
        #expect(base == ChoiceSequence(tree))
        guard case let .leafValues(changes) = probe.mutation else {
            Issue.record("Sparse leaf edits must report their projected value changes")
            return
        }
        #expect(changes.count == patterns.prefix(arity).count(where: { $0 != 0 }))
        #expect(changes.allSatisfy { $0.newValue.tag == tag && $0.newValue.bitPattern64 == 0 })
        probe.restore(into: &candidate, baseSequence: base)
        #expect(candidate == base)

        let untouchedPosition = try #require(untouchedPositions.last)
        candidate[untouchedPosition] = candidate[untouchedPosition].withBitPattern(1)
        let prepared = PreparedEncoderProbe.sparse(probe, baseSequence: base)
        _ = prepared.write(into: &candidate)
        #expect(candidate[untouchedPosition] == base[untouchedPosition])
        #expect(probe.hash(baseHash: ZobristHash.hash(of: base), baseSequence: base) == ZobristHash.hash(of: candidate))
    }
}
