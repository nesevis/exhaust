import Testing
@testable import ExhaustCore

@Suite("Sparse staged joint probes")
struct StagedJointSparseProbeTests {
    @Test("Sparse hashes match complete candidate hashes across integer and floating tags", arguments: [
        TypeTag.int, .int8, .int16, .int32, .int64,
        .uint, .uint8, .uint16, .uint32, .uint64, .float16, .float, .double,
    ])
    func sparseHash(tag: TypeTag) {
        let values = tag.isFloatingPoint
            ? [75.0, 100.0, 0.0, 175.0].map { ChoiceValue($0, tag: tag) }
            : [UInt64(75), 100, 0, 125].map { ChoiceValue($0, tag: tag) }
        let tree = ChoiceTree.group(values.map { .choice($0, .init(validRange: tag.bitPatternRange, isRangeExplicit: true)) })
        let base = ChoiceSequence(tree)
        let leaves = StagedJointQuery.eligibleLeaves(graph: ChoiceGraph.build(from: tree), tuning: .init())
        let hash = ZobristHash.hash(of: base)
        for arity in 2 ... 4 {
            let selected = Array(leaves.prefix(arity))
            let patterns = selected.map { leaf in NumericPairCandidates.values(for: leaf, simplifying: true).first ?? leaf.choice.bitPattern64 }
            let probe = SparseEncoderProbe(leaves: selected, patterns: patterns)
            var candidate = base
            probe.write(into: &candidate)
            #expect(probe.hash(baseHash: hash, baseSequence: base) == ZobristHash.hash(of: candidate))
            #expect(base == ChoiceSequence(tree))
        }
    }
}
