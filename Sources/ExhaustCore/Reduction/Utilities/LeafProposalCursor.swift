/// Applies a fixed candidate order using the dispatched leaf's complete choice metadata. Domain enumeration and rejected binary search differ only in the supplied bit patterns.
struct LeafProposalCursor {
    private let leafNodeID: Int
    private let sequenceIndex: Int
    private let typeTag: TypeTag
    private let validRange: ClosedRange<UInt64>?
    private let isRangeExplicit: Bool
    private let mayReshape: Bool
    private let baseSequence: ChoiceSequence
    private let candidates: [UInt64]
    private var candidateIndex = 0

    /// Reads type and range metadata from the graph because candidate bit patterns do not carry decoding constraints. The graph's leaf position must address a value in the dispatched sequence; proposals do not repair malformed scopes.
    init?(
        graph: ChoiceGraph,
        baseSequence: ChoiceSequence,
        leafNodeID: Int,
        candidates: [UInt64],
        mayReshape: Bool = false
    ) {
        guard graph.nodes.indices.contains(leafNodeID),
              case let .chooseBits(metadata) = graph.nodes[leafNodeID].kind,
              let range = graph.nodes[leafNodeID].positionRange,
              baseSequence.indices.contains(range.lowerBound),
              baseSequence[range.lowerBound].value != nil
        else {
            return nil
        }
        self.leafNodeID = leafNodeID
        sequenceIndex = range.lowerBound
        typeTag = metadata.typeTag
        validRange = metadata.validRange
        isRangeExplicit = metadata.isRangeExplicit
        self.mayReshape = mayReshape
        self.baseSequence = baseSequence
        self.candidates = candidates
    }

    /// Replaces only the controller's value entry so surrounding bind and group markers survive each proposal.
    mutating func next(into candidate: inout ChoiceSequence) -> LiftProposal? {
        guard let proposal = next() else {
            return nil
        }
        candidate = proposal.prefix.materialized()
        return LiftProposal(prefix: .init(candidate), mutation: proposal.mutation)
    }

    /// Retains the scope's sequence and records the single edit, avoiding a full copy for every unopened attempt.
    mutating func next() -> LiftProposal? {
        guard candidateIndex < candidates.count else {
            return nil
        }
        let bitPattern = candidates[candidateIndex]
        candidateIndex += 1
        let choice = ChoiceValue(typeTag.makeConvertible(bitPattern64: bitPattern), tag: typeTag)
        let value = ChoiceSequenceValue.Value(
            choice: choice,
            validRange: validRange,
            isRangeExplicit: isRangeExplicit
        )
        return LiftProposal(
            prefix: .init(baseSequence, replacement: .init(index: sequenceIndex, value: value)),
            mutation: .leafValues([LeafChange(leafNodeID: leafNodeID, newValue: choice, mayReshape: mayReshape)])
        )
    }
}
