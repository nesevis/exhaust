import Testing
@testable import ExhaustCore

@Suite("Scoped decoder selection")
struct ScopedDecoderSelectionTests {
    @Test("History-sensitive numeric admission forces exact decoding for a reshaping probe")
    func numericAdmissionForcesExact() {
        let mutation = ProjectedMutation.sequenceElementsRemoved([(seqNodeID: 0, removedNodeIDs: [1])])
        let selection = selectDecoder(for: mutation, requiresExactDecoder: false, hasBind: true, admission: .numericJoint([]))
        #expect(selection.preferExact)
        guard case let .exact(_, admission) = selection else {
            Issue.record("Numeric admission requires the exact decoder")
            return
        }
        #expect(admission.inspectsDecodedHistory)
    }

    @Test("An unordered guided pass delegates ordering to the interpreter")
    func unorderedGuidedPassSkipsShortlex() {
        let mutation = ProjectedMutation.sequenceReordered
        let selection = selectDecoder(for: mutation, requiresExactDecoder: false, hasBind: true, admissionOrder: .unordered)
        guard case let .guided(materializePicks, skipsShortlexCheck) = selection else {
            Issue.record("A reorder under a bind requires guided decoding")
            return
        }
        #expect(materializePicks == false)
        #expect(skipsShortlexCheck)
    }

    // MARK: - requiresExactDecoder

    @Test("requiresExactDecoder forces exact regardless of other flags",
          arguments: [true, false], [true, false])
    func exactDecoderForced(hasBind: Bool, mayReshape: Bool) {
        let mutation = ProjectedMutation.leafValues([
            LeafChange(leafNodeID: 0, newValue: ChoiceValue(0 as UInt64, tag: .uint64), mayReshape: mayReshape),
        ])
        let selection = selectDecoder(
            for: mutation,
            requiresExactDecoder: true,
            hasBind: hasBind
        )
        #expect(selection.preferExact)
    }

    // MARK: - Value-only mutations (no reshape)

    @Test("Value-only leaf changes without reshape use exact decoder regardless of hasBind",
          arguments: [true, false])
    func valueOnlyNoReshape(hasBind: Bool) {
        let mutation = ProjectedMutation.leafValues([
            LeafChange(leafNodeID: 0, newValue: ChoiceValue(0 as UInt64, tag: .uint64), mayReshape: false),
        ])
        let selection = selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: hasBind
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
        let selection = selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: true
        )
        #expect(selection.preferExact == false)
        #expect(selection.materializePicks)
    }

    // MARK: - Path-changing mutations

    @Test("Branch selection sets materializePicks regardless of hasBind",
          arguments: [true, false])
    func branchSelectionMaterializesPicks(hasBind: Bool) {
        let mutation = ProjectedMutation.branchSelected(pickNodeID: 0, newSelectedID: 1)
        let selection = selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: hasBind
        )
        #expect(selection.materializePicks)
    }

    @Test("Self-similar replacement sets materializePicks regardless of hasBind",
          arguments: [true, false])
    func selfSimilarMaterializesPicks(hasBind: Bool) {
        let mutation = ProjectedMutation.selfSimilarReplaced(targetNodeID: 0, donorNodeID: 1)
        let selection = selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: hasBind
        )
        #expect(selection.materializePicks)
    }

    @Test("Descendant promotion sets materializePicks regardless of hasBind",
          arguments: [true, false])
    func descendantPromotionMaterializesPicks(hasBind: Bool) {
        let mutation = ProjectedMutation.descendantPromoted(
            ancestorPickNodeID: 0,
            descendantPickNodeID: 1
        )
        let selection = selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: hasBind
        )
        #expect(selection.materializePicks)
    }

    // MARK: - Structural non-path-changing mutations

    @Test("Sequence removal does not set materializePicks regardless of hasBind",
          arguments: [true, false])
    func sequenceRemovalDoesNotMaterializePicks(hasBind: Bool) {
        let mutation = ProjectedMutation.sequenceElementsRemoved([
            (seqNodeID: 0, removedNodeIDs: [1]),
        ])
        let selection = selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: hasBind
        )
        #expect(selection.materializePicks == false)
    }

    @Test("Sibling swap does not set materializePicks regardless of hasBind",
          arguments: [true, false])
    func siblingSwapDoesNotMaterializePicks(hasBind: Bool) {
        let mutation = ProjectedMutation.siblingsSwapped(parentNodeID: 0, lhs: 1, rhs: 2)
        let selection = selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: hasBind
        )
        #expect(selection.materializePicks == false)
    }

    // MARK: - hasBind interaction

    @Test("Structural mutation without bind uses exact decoder")
    func structuralMutationNoBind() {
        let mutation = ProjectedMutation.sequenceElementsRemoved([
            (seqNodeID: 0, removedNodeIDs: [1]),
        ])
        let selection = selectDecoder(
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
        let selection = selectDecoder(
            for: mutation,
            requiresExactDecoder: false,
            hasBind: true
        )
        #expect(selection.preferExact == false)
    }
}

// MARK: - Helpers

/// Exercises selection through the decoder boundary without materializing a candidate.
private func selectDecoder(
    for mutation: ProjectedMutation,
    requiresExactDecoder: Bool,
    hasBind: Bool,
    admission: DecoderAdmission = .standard,
    admissionOrder: ReductionOrder = .notLarger
) -> ScopedDecoder.Selection {
    let decoder = ScopedDecoder(generator: Gen.just(0).erase(), property: { _ in true }, probeWrapper: nil, hasBind: hasBind)
    return decoder.selection(for: ScopedDecodingRequirement(
        requiresExactDecoder: requiresExactDecoder,
        mutation: mutation,
        admission: admission,
        admissionOrder: admissionOrder
    ))
}
