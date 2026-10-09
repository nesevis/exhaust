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
        prepareProbe(into: &candidate, lastAccepted: lastAccepted)?.write(into: &candidate)
    }

    /// Keeps the candidate buffer untouched until the session has checked the sparse hash against its rejection cache.
    mutating func prepareProbe(into _: inout ChoiceSequence, lastAccepted: Bool) -> PreparedEncoderProbe? {
        nextSparseProbe(lastAccepted: lastAccepted).map { .sparse($0, baseSequence: base) }
    }

    /// Advances the same probe stream without constructing a sequence. The session checks its hash before writing uncached edits.
    mutating func nextSparseProbe(lastAccepted: Bool) -> SparseEncoderProbe? {
        guard lastAccepted == false, emitted < probeBudget else {
            return nil
        }
        if jointCursor != nil {
            guard let proposal = jointCursor?.next() else { return nil }
            emitted += 1
            admission = .numericJoint(proposal.leaves)
            return SparseEncoderProbe(leaves: proposal.leaves, patterns: proposal.patterns)
        }
        guard let proposal = cursor?.next() else {
            return nil
        }
        emitted += 1
        admission = .numericPair(proposal.pair)
        return SparseEncoderProbe(
            leaves: [proposal.pair.source, proposal.pair.sink],
            patterns: [proposal.sourceBitPattern, proposal.sinkBitPattern]
        )
    }
}
