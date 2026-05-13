import Testing
@testable import ExhaustCore

@Suite("DecoderSelection")
struct DecoderSelectionTests {

    // MARK: - requiresExactDecoder

    @Test("requiresExactDecoder forces exact regardless of other flags",
          arguments: [true, false], [true, false])
    func exactDecoderForced(hasBind: Bool, mayReshape: Bool) {
        let mutation = ProjectedMutation.leafValues([
            LeafChange(leafNodeID: 0, newValue: ChoiceValue(0 as UInt64, tag: .uint64), mayReshape: mayReshape),
        ])
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: true,
            hasBind: hasBind
        )
        #expect(selection.preferExact)
    }

    // MARK: - Value-only mutations (no reshape)

    @Test("Value-only leaf changes without reshape use exact decoder")
    func valueOnlyNoReshape() {
        let mutation = ProjectedMutation.leafValues([
            LeafChange(leafNodeID: 0, newValue: ChoiceValue(0 as UInt64, tag: .uint64), mayReshape: false),
        ])
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: true
        )
        #expect(selection.preferExact)
        #expect(selection.materializePicks == false)
    }

    // MARK: - Reshape mutations

    @Test("Leaf change with mayReshape uses guided decoder when hasBind is true")
    func reshapeLeafUsesGuided() {
        let mutation = ProjectedMutation.leafValues([
            LeafChange(leafNodeID: 0, newValue: ChoiceValue(0 as UInt64, tag: .uint64), mayReshape: true),
        ])
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: true
        )
        #expect(selection.preferExact == false)
        #expect(selection.materializePicks)
    }

    // MARK: - Path-changing mutations

    @Test("Branch selection sets materializePicks")
    func branchSelectionMaterializesPicks() {
        let mutation = ProjectedMutation.branchSelected(pickNodeID: 0, newSelectedID: 1)
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: true
        )
        #expect(selection.materializePicks)
    }

    @Test("Self-similar replacement sets materializePicks")
    func selfSimilarMaterializesPicks() {
        let mutation = ProjectedMutation.selfSimilarReplaced(targetNodeID: 0, donorNodeID: 1)
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: true
        )
        #expect(selection.materializePicks)
    }

    @Test("Descendant promotion sets materializePicks")
    func descendantPromotionMaterializesPicks() {
        let mutation = ProjectedMutation.descendantPromoted(
            ancestorPickNodeID: 0,
            descendantPickNodeID: 1
        )
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: true
        )
        #expect(selection.materializePicks)
    }

    // MARK: - Structural non-path-changing mutations

    @Test("Sequence removal does not set materializePicks")
    func sequenceRemovalDoesNotMaterializePicks() {
        let mutation = ProjectedMutation.sequenceElementsRemoved([
            (seqNodeID: 0, removedNodeIDs: [1]),
        ])
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: true
        )
        #expect(selection.materializePicks == false)
    }

    @Test("Sibling swap does not set materializePicks")
    func siblingSwapDoesNotMaterializePicks() {
        let mutation = ProjectedMutation.siblingsSwapped(parentNodeID: 0, lhs: 1, rhs: 2)
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: true
        )
        #expect(selection.materializePicks == false)
    }

    // MARK: - hasBind interaction

    @Test("Structural mutation without bind uses exact decoder")
    func structuralMutationNoBind() {
        let mutation = ProjectedMutation.sequenceElementsRemoved([
            (seqNodeID: 0, removedNodeIDs: [1]),
        ])
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: false
        )
        #expect(selection.preferExact)
    }

    @Test("Structural mutation with bind uses guided decoder")
    func structuralMutationWithBind() {
        let mutation = ProjectedMutation.sequenceElementsRemoved([
            (seqNodeID: 0, removedNodeIDs: [1]),
        ])
        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: true
        )
        #expect(selection.preferExact == false)
    }
}
