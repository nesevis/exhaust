/// Edits a stalled numeric source and a compensating partner together, walking each pair's candidate grid diagonal by diagonal.
///
/// Stops after the first accepted pair, because every pair's addresses and domain samples belong to the original checkpoint.
struct NumericPairEncoder: GraphEncoder {
    let name: EncoderName = .pairwiseNumericSearch
    private var base = ChoiceSequence()
    private var cursor: NumericPairSearchCursor?
    private var probeBudget = 0
    private var emitted = 0
    /// Admission for the most recent probe. ``ProbeSession`` folds it into the probe's decoder selection.
    private(set) var admission: DecoderAdmission = .standard

    mutating func start(scope: EncoderInput) {
        base = scope.baseSequence
        emitted = 0
        guard case let .exchange(.numericPairs(pairs, probeBudget)) = scope.transformation.operation else {
            cursor = nil
            probeBudget = 0
            return
        }
        cursor = NumericPairSearchCursor(pairs: pairs)
        self.probeBudget = probeBudget
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard lastAccepted == false, emitted < probeBudget else {
            return nil
        }
        candidate = base
        guard let proposal = cursor?.next(into: &candidate) else {
            return nil
        }
        emitted += 1
        admission = .numericPair(proposal.pair)
        return .leafValues([
            LeafChange(
                leafNodeID: proposal.pair.source.nodeID,
                newValue: ChoiceValue(proposal.sourceBitPattern, tag: proposal.pair.source.choice.tag),
                mayReshape: true
            ),
            LeafChange(
                leafNodeID: proposal.pair.sink.nodeID,
                newValue: ChoiceValue(proposal.sinkBitPattern, tag: proposal.pair.sink.choice.tag),
                mayReshape: true
            ),
        ])
    }
}
