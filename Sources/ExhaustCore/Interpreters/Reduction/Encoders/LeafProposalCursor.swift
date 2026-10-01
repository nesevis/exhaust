/// Applies a fixed candidate order using the dispatched leaf's complete choice metadata. Domain enumeration and rejected binary search differ only in the supplied bit patterns.
struct LeafProposalCursor {
    private let leafNodeID: Int
    private let sequenceIndex: Int
    private let typeTag: TypeTag
    private let validRange: ClosedRange<UInt64>?
    private let isRangeExplicit: Bool
    private let baseSequence: ChoiceSequence
    private let candidates: [UInt64]
    private var candidateIndex = 0

    /// Reads type and range metadata from the graph because candidate bit patterns do not carry decoding constraints. The graph's leaf position must address a value in the dispatched sequence; proposals do not repair malformed scopes.
    init?(
        scope: EncoderInput,
        leafNodeID: Int,
        candidates: [UInt64]
    ) {
        guard scope.graph.nodes.indices.contains(leafNodeID),
              case let .chooseBits(metadata) = scope.graph.nodes[leafNodeID].kind,
              let range = scope.graph.nodes[leafNodeID].positionRange,
              scope.baseSequence.indices.contains(range.lowerBound),
              scope.baseSequence[range.lowerBound].value != nil
        else {
            return nil
        }
        self.leafNodeID = leafNodeID
        sequenceIndex = range.lowerBound
        typeTag = metadata.typeTag
        validRange = metadata.validRange
        isRangeExplicit = metadata.isRangeExplicit
        baseSequence = scope.baseSequence
        self.candidates = candidates
    }

    /// Replaces only the controller's value entry so surrounding bind and group markers survive each proposal.
    mutating func next(into candidate: inout ChoiceSequence) -> LiftProposal? {
        guard candidateIndex < candidates.count else {
            return nil
        }
        let bitPattern = candidates[candidateIndex]
        candidateIndex += 1
        let choice = ChoiceValue(typeTag.makeConvertible(bitPattern64: bitPattern), tag: typeTag)
        candidate = baseSequence
        candidate[sequenceIndex] = .value(.init(
            choice: choice,
            validRange: validRange,
            isRangeExplicit: isRangeExplicit
        ))
        return LiftProposal(
            prefix: candidate,
            mutation: .leafValues([LeafChange(leafNodeID: leafNodeID, newValue: choice, mayReshape: false)])
        )
    }
}
