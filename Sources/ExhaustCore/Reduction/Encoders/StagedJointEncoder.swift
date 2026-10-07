/// Consumes the sequential two-, three-, and four-way scopes of staged joint search.
///
/// Stops after the first acceptance, because every group's addresses and domain samples belong to the original checkpoint. The scheduler unlocks each higher-order scope only after the lower stage stalls.
struct StagedJointEncoder: GraphEncoder {
    let name: EncoderName = .stagedJointSearch
    private var base = ChoiceSequence()
    private var cursor: StagedPairSearchCursor?
    private var jointCursor: NumericJointSearchCursor?
    private var probeBudget = 0
    private var emitted = 0
    /// Admission for the most recent probe. ``ProbeSession`` folds it into the probe's decoder selection.
    private(set) var admission: DecoderAdmission = .standard

    mutating func start(scope: EncoderInput) {
        base = scope.baseSequence
        emitted = 0
        cursor = nil
        jointCursor = nil
        switch scope.transformation.operation {
            case let .exchange(.stagedNumericPairs(pairs, probeBudget)):
                cursor = StagedPairSearchCursor(pairs: pairs)
                self.probeBudget = probeBudget
            case let .exchange(.numericJoint(groups, probeBudget)):
                jointCursor = NumericJointSearchCursor(groups: groups)
                self.probeBudget = probeBudget
            default:
                probeBudget = 0
        }
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard lastAccepted == false, emitted < probeBudget else {
            return nil
        }
        candidate = base
        if jointCursor != nil {
            guard let proposal = jointCursor?.next(into: &candidate) else { return nil }
            emitted += 1
            admission = .numericJoint(proposal.leaves)
            return .leafValues(leafChanges(leaves: proposal.leaves, patterns: proposal.patterns))
        }
        guard let proposal = cursor?.next(into: &candidate) else {
            return nil
        }
        emitted += 1
        admission = .numericPair(proposal.pair)
        return .leafValues(leafChanges(
            leaves: [proposal.pair.source, proposal.pair.sink],
            patterns: [proposal.sourceBitPattern, proposal.sinkBitPattern]
        ))
    }

    /// Zero stays zero under rescaling, so only actual movements enter acceptance handling and coupling history. Admission still checks every leaf in the coordinated scope.
    private func leafChanges(leaves: [NumericPairQuery.Leaf], patterns: [UInt64]) -> [LeafChange] {
        leaves.indices.compactMap { index in
            let leaf = leaves[index]
            guard patterns[index] != leaf.choice.bitPattern64 else { return nil }
            return LeafChange(
                leafNodeID: leaf.nodeID,
                newValue: ChoiceValue(patterns[index], tag: leaf.choice.tag),
                mayReshape: leaf.mayReshapeOnAcceptance
            )
        }
    }
}
