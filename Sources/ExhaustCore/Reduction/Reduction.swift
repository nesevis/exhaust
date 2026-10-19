//
//  Reduction.swift
//  Exhaust
//

// MARK: - Academic Background

//
// The split between offering alternatives and choosing their order follows Spivey, "Algebras for combinatorial search" (JFP 2009), which shows that depth-first, breadth-first, and depth-bounded search are interchangeable implementations of one set of search operators (`return`, bind, `zero`, `⊕`, and `wrap`). Encoders write programs with `propose` (`⊕`), `fail` (`zero`), and `bind` (▷), and the interpreter supplies the traversal, so turn-based and diagonal scheduling run the same encoder unchanged.
//
// `lift`, `search`, and the probe budgets are informed by Sepulveda-Jimenez, "Categories of Optimization Reductions" (2026), which formalizes reduce-solve-recover pipelines as composable encoder-decoder morphisms with effects and resource tracking. Here `lift` is the effectful encoding that discovers a downstream problem, `search` solves it, and resources are counted as they are spent rather than fixed in advance. Exhaust adapts the paper's certified reductions to speculative ones, where the property decides whether a recovered candidate is kept.

// MARK: - Reduction

/// The encoder's reduction in ``FreerMonad`` form over ``ReductionOperation``.
///
/// A separate type rather than `FreerMonad<ReductionOperation, Void>` so every answer stays in the closed ``ReductionResponse`` instead of `Any`.
indirect enum Reduction {
    case pure(ReductionResponse)
    case impure(ReductionOperation, continuation: (ReductionResponse) -> Reduction)
}

// MARK: - Verbs

extension Reduction {
    /// Offers the proposals `makeProposals` constructs and continues with whichever proposal the interpreter visits. The interpreter runs `next` once per branch it builds, and constructs each prefix only when its branch is selected. The factory runs once per reached pool execution, after deadline and build-budget checks.
    static func propose(
        _ makeProposals: @escaping ProposalFactory,
        configuration: ChoiceConfiguration,
        then next: @escaping (LiftProposal) -> Reduction
    ) -> Reduction {
        request(.propose(makeProposals, configuration: configuration))
            .bind { $0.proposal.map(next)! }
    }

    /// Lifts `prefix` and continues with the lifted tree and sequence, or nil when materialization failed.
    static func lift(
        _ prefix: ChoiceSequence,
        fallbackTree: ChoiceTree,
        maximumSequenceCount: Int? = nil,
        then next: @escaping (LiftResult?) -> Reduction
    ) -> Reduction {
        request(.lift(prefix, fallbackTree: fallbackTree, maximumSequenceCount: maximumSequenceCount))
            .bind { next($0.lifted) }
    }

    /// Runs `search` until it finishes and continues with its outcome.
    static func search(
        _ search: any ReductionSearch,
        configuration: SearchConfiguration,
        then next: @escaping (SearchOutcome) -> Reduction = { _ in .pure(.finished) }
    ) -> Reduction {
        request(.search(search, configuration: configuration))
            .bind { $0.outcome.map(next)! }
    }

    /// Abandons the current branch, recording why construction stopped.
    static func fail(_ reason: DownstreamBuildFailure) -> Reduction {
        .impure(.fail(reason)) { _ in
            preconditionFailure("A failed branch is never resumed")
        }
    }

    /// A one-step reduction whose result is the interpreter's answer to `operation`.
    private static func request(_ operation: ReductionOperation) -> Reduction {
        .impure(operation) { .pure($0) }
    }

    /// Sequences this reduction with one built from its result, as ``FreerMonad/bind(_:)`` does.
    private func bind(_ transform: @escaping (ReductionResponse) -> Reduction) -> Reduction {
        switch self {
            case let .pure(result):
                transform(result)
            case let .impure(operation, continuation):
                .impure(operation) { continuation($0).bind(transform) }
        }
    }
}

// MARK: - Operations

/// The requests the encoder's reduction can make.
///
/// `propose`, `fail`, and each branch's position-based starting grade follow Spivey's bunch operations (`⊕`, `zero`, `wrap`).
/// `lift` comes from SJ's effectful reduction composition, and `search` runs the downstream solver; both are effects outside Spivey's bunch algebra.
/// The interpreter, not the encoder's reduction, decides the order in which `propose` branches are visited.
enum ReductionOperation {
    /// Offers alternatives. The interpreter resumes the continuation once per branch it visits, so continuations must be re-entrant and capture only values.
    case propose(ProposalFactory, configuration: ChoiceConfiguration)
    /// Materializes a prefix through the generator in guided mode, without running the property. `fallbackTree` resolves entries the prefix does not fix; a lift longer than `maximumSequenceCount` fails.
    case lift(ChoiceSequence, fallbackTree: ChoiceTree, maximumSequenceCount: Int?)
    /// Abandons the current branch. Never resumed.
    case fail(DownstreamBuildFailure)
    /// Runs a feedback-driven search until it finishes, then resumes with its outcome.
    case search(any ReductionSearch, configuration: SearchConfiguration)
}

/// Chooses how one pool interleaves its branches, independently of any nested pool's priorities.
enum ChoiceScheduling {
    /// Selects the smallest branch index plus emitted candidate count, breaking ties by branch index.
    case diagonal
    /// Builds new branches before resuming suspended searches in FIFO order, with a fresh turn on each resumption.
    case turnBased
}

/// Scheduling limits for one `propose` level.
struct ChoiceConfiguration {
    /// Probes a search emits per turn under ``ChoiceScheduling/turnBased``; nil runs each search to exhaustion before the next branch. Diagonal scheduling selects again after every candidate.
    let probesPerSearchTurn: Int?
    /// Constructed searches, counting empty ones but not failed builds; nil is unlimited.
    let searchBudget: Int?
    /// Probes emitted by the level across all searches, including those of nested levels; zero is unlimited. Reaching it ends the pass.
    let totalProbeCap: Int
    /// Build limits for one level of a nested bind chain; nil outside chains.
    var chainLimits: ChainLimits?
    /// Gives this level's searches one undifferentiated rejection for every outcome, including acceptances that do not end the search. Required when branches can emit the same candidate, because a cached rejection would then depend on visiting order.
    var deliversUniformFeedback = false
    /// Diagonal by default; the turn-based policy remains available for comparing exploration under the same budgets.
    var scheduling: ChoiceScheduling = .diagonal
}

/// Build limits for one level of a nested bind chain. The interpreter owns the shared pool: the outermost level with limits creates it, and every nested level draws from it.
struct ChainLimits {
    /// Branches this level may build each time its parent's branch reaches it, counting builds that fail.
    let maxBuildsPerStart: Int
    /// Builds left to the whole chain. Read from the outermost level only.
    let poolCapacity: Int
}

/// What the interpreter does with a search's candidates.
struct SearchConfiguration {
    let acceptance: AcceptancePolicy
    /// Forces exact decoding, whatever decoder the candidate's mutation would otherwise select.
    let requiresExactDecoder: Bool
    /// Replaces every candidate's mutation when set. A composition reports its upstream mutation, because the downstream search's node IDs refer to the lifted graph.
    let reportedMutation: ProjectedMutation?

    /// Keeps searching after an acceptance, decodes as the candidate's mutation allows, and reports each candidate's own mutation.
    static let standard = SearchConfiguration(acceptance: .continue, requiresExactDecoder: false, reportedMutation: nil)
}

/// What a search does after one of its candidates is accepted.
enum AcceptancePolicy {
    /// Applies each acceptance to the graph in place and keeps searching. An acceptance whose mutation the graph cannot apply in place ends the pass with a rebuild.
    case `continue`
    /// Keeps searching after any acceptance without applying it to the graph, and rebuilds once the pass ends. For searches whose acceptances the graph cannot apply in place but whose later candidates need only the recovered sequence.
    case rebuildAndContinue
    /// The first acceptance ends every search. Compositions use it because an accepted lift makes every other branch's lifted graph stale.
    case stop
}

/// Summarizes a search that ran out of candidates, for the encoder's reduction that requested it. Only exhaustion resumes the reduction; an acceptance that stops the search, a probe cap, or the deadline ends the pass instead.
struct SearchOutcome {
    let anyAccepted: Bool
    /// Probes this search alone spent.
    let counts: ReductionProbeCounts
}

// MARK: - Results

/// The answer an interpreter gives a ``Reduction`` request.
///
/// A closed vocabulary rather than `Any`: every value lives in the choice substrate, so the encoder's reduction is an ordinary value even while suspended, and can be copied at a `propose`. Authors never match these cases directly; the verbs on ``Reduction`` match the case their request produces and trap on any other, which can only be an interpreter fault.
enum ReductionResponse {
    /// Answers `propose` with one branch's proposal.
    case proposal(LiftProposal)
    /// Answers `lift`. Nil when materialization produced no tree.
    case lifted(LiftResult?)
    /// Answers `search` once the search has finished.
    case outcome(SearchOutcome)
    /// The terminal value of the encoder's reduction.
    case finished

    // MARK: - Conveniences

    var proposal: LiftProposal? {
        guard case let .proposal(proposal) = self else {
            return nil
        }
        return proposal
    }

    var lifted: LiftResult? {
        guard case let .lifted(lifted) = self else {
            return nil
        }
        return lifted
    }

    var outcome: SearchOutcome? {
        guard case let .outcome(outcome) = self else {
            return nil
        }
        return outcome
    }
}
