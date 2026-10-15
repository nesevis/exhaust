//
//  ScopedReductionInterpreter+SearchPool.swift
//  Exhaust
//

// MARK: - Search Pool

extension ScopedReductionInterpreter {
    /// What building a branch or choosing the next member produced. Building stops at the deadline, because each build can lift.
    enum BuildResult<Value> {
        case built(Value)
        case nothing
        case deadline
    }

    /// What one call to ``next(_:checksDeadline:context:)`` on a search pool produced.
    enum NextResult {
        case emitted(Evaluation)
        case exhausted
        case budgetExhausted
        case deadline
    }

    // MARK: - Next Candidate

    /// Emits and evaluates exactly one candidate from `pool`, recursing into nested levels. Only the outermost call checks the deadline per candidate, so a nested level never checks it a second time for the same candidate. Building a branch checks it too, before each build and each lift, at every level.
    static func next(
        _ pool: inout ScopedSearchPool,
        checksDeadline: Bool,
        context: inout Context
    ) -> NextResult {
        if checksDeadline, context.isExpired {
            return .deadline
        }
        while true {
            if pool.totalProbeCap > 0, pool.emitted >= pool.totalProbeCap {
                return .budgetExhausted
            }
            if pool.active == nil {
                switch nextMember(&pool, context: &context) {
                    case let .built(member):
                        pool.active = member
                    case .nothing:
                        break
                    case .deadline:
                        return .deadline
                }
            }
            guard var member = pool.active else {
                return .exhausted
            }
            pool.active = nil

            let evaluation: Evaluation
            switch member.source {
                case let .search(slot):
                    slot.wasAskedForCandidate = true
                    guard let candidate = slot.search.next(slot.feedback, into: &context.candidateBuffer) else {
                        finishSearch(slot, pending: .initial, context: &context)
                        // The continuation's next search would otherwise draw its first candidate under the deadline check that preceded this exhaustion.
                        guard context.isExpired == false else {
                            return .deadline
                        }
                        // The branch continues with the search's outcome, in the same member, so its turn carries on.
                        switch buildBranch(slot.continuation(.outcome(slot.outcome)), depth: pool.depth, context: &context) {
                            case let .built(next):
                                member.source = next
                                pool.active = member
                            case .nothing:
                                break
                            case .deadline:
                                return .deadline
                        }
                        continue
                    }
                    evaluation = evaluateCounting(candidate, in: slot, context: &context)
                    if evaluation.isAccepted {
                        slot.anyAccepted = true
                    }
                    slot.feedback = pool.deliversUniformFeedback ? uniform(evaluation.feedback) : evaluation.feedback
                case .level:
                    // Moving the level out leaves its storage uniquely referenced while it advances.
                    let source = member.source
                    member.source = .vacant
                    guard case var .level(child) = consume source else {
                        preconditionFailure("A level member must hold a level")
                    }
                    switch next(&child, checksDeadline: false, context: &context) {
                        case .exhausted, .budgetExhausted:
                            // A nested level that returns nothing has no candidates left, so it is dropped.
                            finishAll(&child, context: &context)
                            continue
                        case .deadline:
                            // A nested level reaches the deadline only while building, which ends the whole pool.
                            finishAll(&child, context: &context)
                            return .deadline
                        case let .emitted(childEvaluation):
                            evaluation = childEvaluation
                            member.source = .level(child)
                    }
                case .vacant:
                    preconditionFailure("A search pool member must hold a search or a level")
            }

            member.probesRemainingInTurn -= 1
            pool.emitted += 1
            if let stop = evaluation.stop {
                finishMember(&member, context: &context)
                finishAll(&pool, context: &context)
                return .emitted(evaluation)
            }
            if member.probesRemainingInTurn == 0 {
                pool.suspended.append(member)
            } else {
                pool.active = member
            }
            return .emitted(evaluation)
        }
    }

    /// Evaluates `candidate`, adding its probe counts to the slot's own as well as to the pass's.
    private static func evaluateCounting(
        _ candidate: ScopedCandidate,
        in slot: ScopedSearchPool.SearchSlot,
        context: inout Context
    ) -> Evaluation {
        let passCounts = context.report.counts
        context.report.counts = ReductionProbeCounts()
        let evaluation = evaluate(candidate, configuration: slot.configuration, context: &context)
        let candidateCounts = context.report.counts
        context.report.counts = passCounts
        context.report.counts.merge(candidateCounts)
        slot.counts.merge(candidateCounts)
        return evaluation
    }

    /// Withholds the outcome, keeping only whether a candidate was evaluated at all.
    private static func uniform(_ feedback: ScopedSearchFeedback) -> ScopedSearchFeedback {
        switch feedback {
            case .initial:
                .initial
            case .accepted, .rejected:
                .rejected(.undifferentiated)
        }
    }

    // MARK: - Branches

    /// Builds the next branch's member, or resumes the oldest suspended member once branches are exhausted or over budget.
    private static func nextMember(_ pool: inout ScopedSearchPool, context: inout Context) -> BuildResult<ScopedSearchPool.Member> {
        switch buildNextBranch(&pool, context: &context) {
            case let .built(member):
                return .built(member)
            case .deadline:
                return .deadline
            case .nothing:
                break
        }
        guard pool.suspended.isEmpty == false else {
            return .nothing
        }
        var resumed = pool.suspended.removeFirst()
        resumed.probesRemainingInTurn = pool.turn
        return .built(resumed)
    }

    /// Advances branches until one constructs a search or a nested level. The search budget counts empty searches but not failed builds; chain limits count every attempted branch.
    ///
    /// Branches that fail construction are built back to back without a candidate evaluated in between, so the deadline is checked before each build.
    private static func buildNextBranch(_ pool: inout ScopedSearchPool, context: inout Context) -> BuildResult<ScopedSearchPool.Member> {
        while pool.branchesExhausted == false, pool.constructed < pool.searchBudget {
            guard let continuation = pool.continuation, pool.nextBranch < pool.branches.count else {
                pool.branchesExhausted = true
                return .nothing
            }
            guard context.isExpired == false else {
                return .deadline
            }
            let branch = pool.branches[pool.nextBranch]
            pool.nextBranch += 1
            if let limits = pool.chainLimits {
                guard pool.buildsThisStart < limits.maxBuildsPerStart, consumeBuildPool(capacity: limits.poolCapacity, context: &context) else {
                    pool.branchesExhausted = true
                    return .nothing
                }
            }
            pool.buildsThisStart += 1
            let built = buildBranch(continuation(.proposal(branch.proposal)), depth: pool.depth, context: &context)
            if case .deadline = built {
                return .deadline
            }
            guard case let .built(source) = built else {
                continue
            }
            pool.constructed += 1
            if pool.depth == 0 {
                context.report.constructedSearches += 1
            } else {
                context.report.nestedConstructedSearches += 1
            }
            return .built(ScopedSearchPool.Member(source: source, probesRemainingInTurn: pool.turn))
        }
        return .nothing
    }

    /// Takes one build from the chain's shared build pool, creating it on first use.
    private static func consumeBuildPool(capacity: Int, context: inout Context) -> Bool {
        let remaining = context.buildPoolRemaining ?? capacity
        guard remaining > 0 else {
            context.buildPoolRemaining = remaining
            return false
        }
        context.buildPoolRemaining = remaining - 1
        return true
    }

    /// Interprets one branch's pipeline until it reaches a search, a nested `propose`, or a failure, answering its lifts. The search or level is returned unstarted, so the search pool can interleave it with other branches.
    ///
    /// A search keeps its continuation: when it exhausts, the pool resumes the branch with the search's outcome. An acceptance that ends the search, the level's probe cap, or the deadline ends every branch in the level, so no continuation runs after them.
    ///
    /// The deadline is checked before each lift, because a branch can lift more than once before it reaches a search.
    ///
    /// - Parameter depth: How many `propose` levels enclose the branch's level, or nil for the root, whose builds are not recorded.
    static func buildBranch(
        _ reducer: ScopedReducer,
        depth: Int?,
        context: inout Context
    ) -> BuildResult<ScopedSearchPool.Source> {
        switch reducer {
            case .pure:
                return .nothing
            case let .impure(.lift(prefix, fallbackTree, maximumSequenceCount), continuation):
                guard context.isExpired == false else {
                    return .deadline
                }
                let lifted = lift(
                    prefix,
                    fallbackTree: fallbackTree,
                    maximumSequenceCount: maximumSequenceCount,
                    context: &context
                )
                return buildBranch(continuation(.lifted(lifted)), depth: depth, context: &context)
            case let .impure(.fail(reason), _):
                if let depth {
                    recordBuildOutcome(.failed(reason), depth: depth + 1, context: &context)
                }
                return .nothing
            case let .impure(.search(search, configuration), continuation):
                if let depth {
                    recordBuildOutcome(.terminalSearch, depth: depth + 1, context: &context)
                }
                return .built(.search(ScopedSearchPool.SearchSlot(
                    search: search,
                    configuration: configuration,
                    continuation: continuation,
                    isRoot: depth == nil
                )))
            case let .impure(.propose(branches, configuration), continuation):
                guard let depth else {
                    return .built(.level(ScopedSearchPool(branches: branches, continuation: continuation, configuration: configuration, depth: 0)))
                }
                recordBuildOutcome(.nestedLevel, depth: depth + 1, context: &context)
                return .built(.level(ScopedSearchPool(branches: branches, continuation: continuation, configuration: configuration, depth: depth + 1)))
        }
    }

    // MARK: - Lift

    static func lift(
        _ prefix: ChoiceSequence,
        fallbackTree: ChoiceTree,
        maximumSequenceCount: Int?,
        context: inout Context
    ) -> LiftResult? {
        context.report.liftAttempts += 1
        return context.decoder.lift(prefix, fallbackTree: fallbackTree, maximumSequenceCount: maximumSequenceCount)
    }

    // MARK: - Accounting

    /// - Parameter depth: How many `propose` levels enclose the build.
    static func recordBuildOutcome(_ outcome: CompositionBuildOutcome, depth: Int, context: inout Context) {
        context.report.buildOutcomes[CompositionBuildRecord(depth: depth, outcome: outcome), default: 0] += 1
    }

    // MARK: - Finishing

    static func finishAll(_ pool: inout ScopedSearchPool, context: inout Context) {
        if var active = pool.active {
            pool.active = nil
            finishMember(&active, context: &context)
        }
        var suspended = pool.suspended
        pool.suspended = []
        for index in suspended.indices {
            finishMember(&suspended[index], context: &context)
        }
    }

    private static func finishMember(_ member: inout ScopedSearchPool.Member, context: inout Context) {
        let source = member.source
        member.source = .vacant
        switch consume source {
            case let .search(slot):
                finishSearch(slot, pending: slot.feedback, context: &context)
            case var .level(child):
                finishAll(&child, context: &context)
            case .vacant:
                break
        }
    }

    /// Finishes the search. A root search keeps its report and, once asked for a candidate, records its own counts; a search inside a `propose` discards its report, since its node IDs belong to a lifted graph.
    private static func finishSearch(_ slot: ScopedSearchPool.SearchSlot, pending: ScopedSearchFeedback, context: inout Context) {
        let searchReport = slot.search.finish(pending: pending)
        guard slot.isRoot else {
            return
        }
        context.report.searchReport.convergenceRecords.merge(searchReport.convergenceRecords) { _, new in new }
        if searchReport.hadUnresolvedReplacement {
            context.report.searchReport.hadUnresolvedReplacement = true
        }
        if slot.wasAskedForCandidate {
            context.report.searchCounts.append(ScopedSearchCounts(stagedJointArity: slot.stagedJointArity, counts: slot.counts))
        }
    }
}

// MARK: - Search Pool State

/// The members of one `propose` level, or of the root branch, that the interpreter asks for candidates.
struct ScopedSearchPool {
    /// A search with the outcome of its last candidate, delivered when it is next asked for a candidate, including after a suspension.
    ///
    /// A class, so asking for a candidate advances the search in place: a search's state runs to hundreds of bytes, and a value slot would be copied in and out of its member on every candidate.
    final class SearchSlot {
        var search: any ScopedSearch
        let configuration: ScopedSearchConfiguration
        var feedback: ScopedSearchFeedback = .initial
        /// What the branch does after the search exhausts.
        let continuation: (ScopedReductionResult) -> ScopedReducer
        /// Whether the search was built outside any `propose`, so it keeps its report and records its own counts.
        let isRoot: Bool
        /// The number of leaves each candidate moves for a staged joint stage, which its recorded counts are attributed to.
        let stagedJointArity: Int?
        /// Whether any of the search's candidates was accepted, for its outcome.
        var anyAccepted = false
        /// Whether the search was asked for a candidate. A root search stopped before then, by the deadline, records no counts.
        var wasAskedForCandidate = false
        /// Probes this search alone spent, for its outcome.
        var counts = ReductionProbeCounts()

        init(
            search: any ScopedSearch,
            configuration: ScopedSearchConfiguration,
            continuation: @escaping (ScopedReductionResult) -> ScopedReducer,
            isRoot: Bool
        ) {
            self.search = search
            self.configuration = configuration
            self.continuation = continuation
            self.isRoot = isRoot
            stagedJointArity = (search as? ScopedStagedJointSearch)?.arity
        }

        /// The outcome of a search that ran out of candidates.
        var outcome: ScopedSearchOutcome {
            ScopedSearchOutcome(anyAccepted: anyAccepted, stopReason: .exhausted, counts: counts)
        }
    }

    /// Where a member's candidates come from. A search's slot is a reference that is only ever held by its member; a nested level is boxed.
    enum Source {
        case search(SearchSlot)
        indirect case level(ScopedSearchPool)
        /// Held only while the member's source is moved out to advance it.
        case vacant
    }

    struct Member {
        var source: Source
        var probesRemainingInTurn: Int
    }

    let branches: [ScopedBranch]
    /// The `propose`'s continuation, applied once per branch; nil for the root pool.
    let continuation: ((ScopedReductionResult) -> ScopedReducer)?
    /// How many `propose` levels enclose this level, or nil for the root pool, which holds the root branch alone.
    let depth: Int?
    let turn: Int
    let searchBudget: Int
    let totalProbeCap: Int
    let chainLimits: ScopedChainLimits?
    let deliversUniformFeedback: Bool
    var nextBranch = 0
    var branchesExhausted = false
    var constructed = 0
    var buildsThisStart = 0
    var emitted = 0
    var active: Member?
    var suspended: [Member] = []

    init(
        branches: [ScopedBranch],
        continuation: @escaping (ScopedReductionResult) -> ScopedReducer,
        configuration: ScopedChoiceConfiguration,
        depth: Int
    ) {
        self.branches = branches
        self.continuation = continuation
        self.depth = depth
        turn = configuration.probesPerSearchTurn ?? .max
        searchBudget = configuration.searchBudget ?? .max
        totalProbeCap = configuration.totalProbeCap
        chainLimits = configuration.chainLimits
        deliversUniformFeedback = configuration.deliversUniformFeedback
    }

    /// A pool holding only the root branch, built from the encoder's reducer.
    init(root: Source) {
        branches = []
        continuation = nil
        depth = nil
        turn = .max
        searchBudget = 0
        totalProbeCap = 0
        chainLimits = nil
        deliversUniformFeedback = false
        branchesExhausted = true
        active = Member(source: root, probesRemainingInTurn: .max)
    }
}
