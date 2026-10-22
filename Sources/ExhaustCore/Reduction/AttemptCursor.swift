// MARK: - Proposal Construction

/// Constructs one prefix at a time from a fixed snapshot of a scope. Copies must advance independently so a reduction can be interpreted more than once.
protocol ProposalCursor {
    mutating func next(into buffer: inout ChoiceSequence) -> LiftProposal?
    mutating func next() -> LiftProposal?
}

extension ProposalCursor {
    mutating func next() -> LiftProposal? {
        var buffer = ChoiceSequence()
        return next(into: &buffer)
    }
}

extension LeafProposalCursor: ProposalCursor {}
extension BoundExchangeProposalCursor: ProposalCursor {}

/// Creates a `propose` level's cursor when the interpreter first selects an unopened attempt, after deadline and build-budget checks. Nil when the level has no proposals.
typealias ProposalFactory = () -> (any ProposalCursor)?

/// Owns one pool execution's proposals, setting up the cursor and constructing each prefix only when an attempt is selected.
///
/// An attempt's position is its index and its starting grade under diagonal scheduling, so only the next unopened attempt needs a scheduling entry.
struct AttemptCursor {
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

    /// The next attempt's index, without constructing its prefix. The cursor discovers exhaustion only when asked for a proposal, so this can name an attempt that does not exist.
    var nextIndex: Int? {
        switch storage {
            case .unstarted, .started:
                position
            case .exhausted:
                nil
        }
    }

    /// Advances only after deadline and build-budget checks. Exhaustion constructs no attempt and spends no build allowance.
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
                guard let proposal = proposals.next() else {
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
