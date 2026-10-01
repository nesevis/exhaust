/// Iterates proposals without acceptance feedback. Indirect cases keep operation-specific cursor payloads out of the composition's per-probe copies.
indirect enum LiftProposalSource {
    case leaf(LeafProposalCursor)
    case exchange(BoundExchangeProposalCursor)
    case seeds(SeedProposalCursor)

    mutating func next(into candidate: inout ChoiceSequence) -> LiftProposal? {
        switch self {
            case var .leaf(cursor):
                let proposal = cursor.next(into: &candidate)
                self = .leaf(cursor)
                return proposal
            case var .exchange(cursor):
                let proposal = cursor.next(into: &candidate)
                self = .exchange(cursor)
                return proposal
            case var .seeds(cursor):
                let proposal = cursor.next(into: &candidate)
                self = .seeds(cursor)
                return proposal
        }
    }
}

/// Visits pivot and transplant seeds in their construction order, without assigning a budget event to the finite list.
struct SeedProposalCursor {
    private var seeds: [ChoiceSequence]
    private let mutation: EncoderProbe

    init(seeds: [ChoiceSequence], mutation: EncoderProbe) {
        self.seeds = seeds
        self.mutation = mutation
    }

    mutating func next(into candidate: inout ChoiceSequence) -> LiftProposal? {
        guard seeds.isEmpty == false else {
            return nil
        }
        candidate = seeds.removeFirst()
        return LiftProposal(prefix: candidate, mutation: mutation)
    }
}
