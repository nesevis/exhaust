/// Iterates proposals without acceptance feedback. Indirect cases keep operation-specific cursor payloads out of the composition's per-probe copies.
indirect enum LiftProposalSource {
    case leaf(LeafProposalCursor)

    mutating func next(into candidate: inout ChoiceSequence) -> LiftProposal? {
        switch self {
            case var .leaf(cursor):
                let proposal = cursor.next(into: &candidate)
                self = .leaf(cursor)
                return proposal
        }
    }
}
