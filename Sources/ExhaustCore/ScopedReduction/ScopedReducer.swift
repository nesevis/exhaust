//
//  ScopedReducer.swift
//  Exhaust
//

// MARK: - Results

/// The answer an interpreter gives a ``ScopedReducer`` request.
///
/// A closed vocabulary rather than `Any`: every value lives in the choice substrate, so the encoder's reducer is an ordinary value even while suspended, and can be copied at a `propose`. Authors never match these cases directly; the verbs on ``ScopedReducer`` match the case their request produces and trap on any other, which can only be an interpreter fault.
enum ScopedReductionResult {
    /// Answers `propose` with one branch's proposal.
    case proposal(LiftProposal)
    /// Answers `lift`. Nil when materialization produced no tree.
    case lifted(LiftResult?)
    /// Answers `search` once the search has finished.
    case outcome(ScopedSearchOutcome)
    /// The terminal value of the encoder's reducer.
    case finished
}

// MARK: - Operations

/// The requests the encoder's reducer can make.
///
/// `propose`, `fail`, and the per-branch cost follow Spivey's bunch operations (`⊕`, `zero`, `wrap`); `lift` and `search` are effects outside that algebra. The interpreter, not the encoder's reducer, decides the order in which `propose` branches are visited.
enum ScopedReductionOperation {
    /// Offers alternatives. The interpreter resumes the continuation once per branch it visits, so continuations must be re-entrant and capture only values.
    case propose([ScopedBranch], configuration: ScopedChoiceConfiguration)
    /// Materializes a prefix through the generator in guided mode, without running the property. `fallbackTree` resolves entries the prefix does not fix; a lift longer than `maximumSequenceCount` fails.
    case lift(ChoiceSequence, fallbackTree: ChoiceTree, maximumSequenceCount: Int?)
    /// Abandons the current branch. Never resumed.
    case fail(DownstreamBuildFailure)
    /// Runs a feedback-driven search until it finishes, then resumes with its outcome.
    case search(ScopedSearchBox, configuration: ScopedSearchConfiguration)
}

/// Holds a search inside the encoder's reducer.
///
/// A reference, so the operation, each `bind` that re-wraps it, and the interpreter's pattern match copy a pointer rather than the search's state, which runs to hundreds of bytes. Immutable, so the encoder's reducer stays a value: the interpreter copies the search out once before advancing it.
final class ScopedSearchBox {
    let search: ScopedSearchKind

    init(_ search: ScopedSearchKind) {
        self.search = search
    }
}

/// One alternative of a `propose`.
///
/// The cost orders a lawful traversal (one unit per position in the heuristic order gives diagonal order). The turn-based interpreter does not read it.
struct ScopedBranch {
    let proposal: LiftProposal
    let cost: Int
}

/// Scheduling limits for one `propose` level.
struct ScopedChoiceConfiguration {
    /// Probes a search emits per turn; nil runs each search to exhaustion before the next branch.
    let probesPerSearchTurn: Int?
    /// Constructed searches, counting empty ones but not failed builds; nil is unlimited.
    let searchBudget: Int?
    /// Probes emitted by the level across all searches, including those of nested levels; zero is unlimited. Reaching it ends the pass.
    let totalProbeCap: Int
    /// Build limits for one level of a nested bind chain; nil outside chains.
    var chainLimits: ScopedChainLimits?
    /// Gives this level's searches one undifferentiated rejection for every outcome, including acceptances that do not end the search. Required when branches can emit the same candidate, because a cached rejection would then depend on visiting order.
    var deliversUniformFeedback = false
}

/// Build limits for one level of a nested bind chain. The interpreter owns the shared pool: the outermost level with limits creates it, and every nested level draws from it.
struct ScopedChainLimits {
    /// Branches this level may build per start, counting builds that fail.
    let maxBuildsPerStart: Int
    /// Builds left to the whole chain. Read from the outermost level only.
    let poolCapacity: Int
}

/// What the interpreter does with a search's candidates.
struct ScopedSearchConfiguration {
    let acceptance: ScopedAcceptance
    let requiresExactDecoder: Bool
    /// Replaces every candidate's mutation when set. A composition reports its upstream mutation, because the downstream search's node IDs refer to the lifted graph.
    let reportedMutation: EncoderProbe?
}

/// What a search does after one of its candidates is accepted.
enum ScopedAcceptance {
    /// Keeps searching. An acceptance whose mutation requires a full rebuild still ends the pass; the interpreter enforces that boundary.
    case `continue`
    /// Keeps searching after any acceptance, working from the recovered sequence.
    case rebuildAndContinue
    /// The first acceptance ends every search. Compositions use it because an accepted lift makes every other branch's lifted graph stale.
    case stop
}

/// Summarizes a finished search for the encoder's reducer that requested it.
struct ScopedSearchOutcome {
    let anyAccepted: Bool
    let stopReason: ScopedStopReason
    /// Probes this search alone spent.
    let counts: ReductionProbeCounts
}

// MARK: - Reducer

/// The encoder's reducer in ``FreerMonad`` form over ``ScopedReductionOperation``.
///
/// A separate type rather than `FreerMonad<ScopedReductionOperation, Void>` so every answer stays in the closed ``ScopedReductionResult`` instead of `Any`.
indirect enum ScopedReducer {
    case pure(ScopedReductionResult)
    case impure(ScopedReductionOperation, continuation: (ScopedReductionResult) -> ScopedReducer)
}

// MARK: - Verbs

extension ScopedReducer {
    /// Offers `branches` and continues with whichever proposal the interpreter visits. The interpreter runs `next` once per branch it builds.
    static func propose(
        _ branches: [ScopedBranch],
        configuration: ScopedChoiceConfiguration,
        then next: @escaping (LiftProposal) -> ScopedReducer
    ) -> ScopedReducer {
        request(.propose(branches, configuration: configuration)).bind { result in
            guard case let .proposal(proposal) = result else {
                preconditionFailure("A propose request must be answered with a proposal")
            }
            return next(proposal)
        }
    }

    /// Lifts `prefix` and continues with the lifted tree and sequence, or nil when materialization failed.
    static func lift(
        _ prefix: ChoiceSequence,
        fallbackTree: ChoiceTree,
        maximumSequenceCount: Int? = nil,
        then next: @escaping (LiftResult?) -> ScopedReducer
    ) -> ScopedReducer {
        request(.lift(prefix, fallbackTree: fallbackTree, maximumSequenceCount: maximumSequenceCount)).bind { result in
            guard case let .lifted(lifted) = result else {
                preconditionFailure("A lift request must be answered with a lift result")
            }
            return next(lifted)
        }
    }

    /// Runs `search` until it finishes and continues with its outcome.
    static func search(
        _ search: ScopedSearchKind,
        configuration: ScopedSearchConfiguration,
        then next: @escaping (ScopedSearchOutcome) -> ScopedReducer = { _ in .pure(.finished) }
    ) -> ScopedReducer {
        request(.search(ScopedSearchBox(search), configuration: configuration)).bind { result in
            guard case let .outcome(outcome) = result else {
                preconditionFailure("A search request must be answered with an outcome")
            }
            return next(outcome)
        }
    }

    /// Abandons the current branch, recording why construction stopped.
    static func fail(_ reason: DownstreamBuildFailure) -> ScopedReducer {
        .impure(.fail(reason)) { _ in
            preconditionFailure("A failed branch is never resumed")
        }
    }

    /// A one-step reducer whose result is the interpreter's answer to `operation`.
    private static func request(_ operation: ScopedReductionOperation) -> ScopedReducer {
        .impure(operation) { .pure($0) }
    }

    /// Sequences this reducer with one built from its result, as ``FreerMonad/bind(_:)`` does.
    private func bind(_ transform: @escaping (ScopedReductionResult) -> ScopedReducer) -> ScopedReducer {
        switch self {
            case let .pure(result):
                transform(result)
            case let .impure(operation, continuation):
                .impure(operation) { continuation($0).bind(transform) }
        }
    }
}
