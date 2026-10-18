// MARK: - Proposal Construction

/// Constructs one prefix at a time from a fixed snapshot of a scope. Copies must advance independently so a reduction can be interpreted more than once.
protocol ProposalCursor {
    mutating func next(into buffer: inout ChoiceSequence) -> LiftProposal?
}

extension LeafProposalCursor: ProposalCursor {}
extension BoundExchangeProposalCursor: ProposalCursor {}

/// Creates a `propose` level's cursor when the interpreter first selects an unopened branch, after deadline and build-budget checks. Nil when the level has no proposals.
typealias ProposalFactory = () -> (any ProposalCursor)?

/// Owns one pool execution's proposals, setting up the cursor and constructing each prefix only when a branch is selected.
///
/// A branch's position is its index and its starting grade under diagonal scheduling, so only the next unopened branch needs a scheduling entry.
struct BranchCursor {
    private enum Storage {
        case unstarted(ProposalFactory)
        case started(any ProposalCursor)
        case exhausted
    }

    private var storage: Storage
    private var position = 0

    init(_ makeProposals: @escaping ProposalFactory) {
        storage = .unstarted(makeProposals)
    }

    /// The next branch's index, without constructing its prefix. The cursor discovers exhaustion only when asked for a proposal, so this can name a branch that does not exist.
    var nextIndex: Int? {
        switch storage {
            case .unstarted, .started:
                position
            case .exhausted:
                nil
        }
    }

    /// Advances only after deadline and build-budget checks. Exhaustion constructs no branch and spends no build allowance.
    mutating func next() -> LiftProposal? {
        switch storage {
            case let .unstarted(makeProposals):
                guard let proposals = makeProposals() else {
                    storage = .exhausted
                    return nil
                }
                storage = .started(proposals)
                return next()
            case var .started(proposals):
                var buffer = ChoiceSequence()
                guard let proposal = proposals.next(into: &buffer) else {
                    storage = .exhausted
                    return nil
                }
                storage = .started(proposals)
                position += 1
                return proposal
            case .exhausted:
                return nil
        }
    }
}
