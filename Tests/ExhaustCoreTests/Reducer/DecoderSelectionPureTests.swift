import Testing
@testable import ExhaustCore

@Suite("Decoder Selection (Pure)")
struct DecoderSelectionPureTests {
    @Test("Leaf-only mutation without reshape prefers exact decoder")
    func leafOnlyNoReshapePrefersExact() {
        let mutation: ProjectedMutation = .leafValues([
            LeafChange(leafNodeID: 0, newValue: ChoiceValue(0 as UInt64, tag: .uint64), mayReshape: false),
        ])
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: false
        )
        #expect(selection.preferExact == true)
        #expect(selection.materializePicks == false)
    }

    @Test("Leaf mutation with mayReshape prefers guided decoder and requires materializePicks")
    func leafWithReshapePrefersGuided() {
        let mutation: ProjectedMutation = .leafValues([
            LeafChange(leafNodeID: 0, newValue: ChoiceValue(0 as UInt64, tag: .uint64), mayReshape: true),
        ])
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: true
        )
        #expect(selection.preferExact == false)
        #expect(selection.materializePicks == true)
    }

    @Test("Branch selection requires materializePicks")
    func branchSelectionMaterializePicks() {
        let mutation: ProjectedMutation = .branchSelected(
            pickNodeID: 0,
            newSelectedID: 1
        )
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: false
        )
        #expect(selection.materializePicks == true)
    }

    @Test("Self-similar replacement requires materializePicks")
    func selfSimilarMaterializePicks() {
        let mutation: ProjectedMutation = .selfSimilarReplaced(
            targetNodeID: 0,
            donorNodeID: 1
        )
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: false
        )
        #expect(selection.materializePicks == true)
    }

    @Test("Descendant promotion requires materializePicks")
    func descendantPromotionMaterializePicks() {
        let mutation: ProjectedMutation = .descendantPromoted(
            ancestorPickNodeID: 0,
            descendantPickNodeID: 1
        )
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: false
        )
        #expect(selection.materializePicks == true)
    }

    @Test("requiresExactDecoder flag overrides to exact")
    func requiresExactDecoderOverrides() {
        let mutation: ProjectedMutation = .leafValues([
            LeafChange(leafNodeID: 0, newValue: ChoiceValue(0 as UInt64, tag: .uint64), mayReshape: true),
        ])
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: true,
            hasBind: true
        )
        #expect(selection.preferExact == true)
    }

    @Test("Sequence removal does not require materializePicks")
    func sequenceRemovalNoMaterializePicks() {
        let mutation: ProjectedMutation = .sequenceElementsRemoved([(seqNodeID: 0, removedNodeIDs: [1, 2])])
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: false
        )
        #expect(selection.materializePicks == false)
    }

    @Test("Sibling swap does not require materializePicks")
    func siblingSwapNoMaterializePicks() {
        let mutation: ProjectedMutation = .siblingsSwapped(
            parentNodeID: 0,
            lhs: 1,
            rhs: 2
        )
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: false
        )
        #expect(selection.materializePicks == false)
    }

    @Test("Structural mutation with hasBind prefers guided decoder")
    func structuralWithBindPrefersGuided() {
        let mutation: ProjectedMutation = .sequenceElementsRemoved([(seqNodeID: 0, removedNodeIDs: [1])])
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: true
        )
        #expect(selection.preferExact == false)
    }
}
