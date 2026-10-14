//
//  ScopedReductionInterpreter+SearchPool.swift
//  Exhaust
//

// MARK: - Search Pool

extension ScopedReductionInterpreter {
    /// How a search pool ended, before a top-level search's counts are attached.
    struct DriveOutcome {
        let anyAccepted: Bool
        let stopReason: ScopedStopReason
    }

    /// What building a branch or choosing the next member produced. Building stops at the deadline, because each build can lift.
    enum BuildResult<Value> {
        case built(Value)
        case nothing
        case deadline
    }

    /// What one pull from a search pool produced.
    enum PullResult {
        case emitted(Evaluation)
        case exhausted
        case budgetExhausted
        case deadline
    }

    // MARK: - Drive

    /// Pulls candidates until the search pool is exhausted, a budget stops it, or an acceptance ends the search.
    static func drive(_ pool: inout ScopedSearchPool, keepsSearchReports: Bool, context: inout Context) -> DriveOutcome {
        var acceptedInPool = false
        while true {
            switch pull(&pool, keepsSearchReports: keepsSearchReports, checksDeadline: true, context: &context) {
                case .exhausted:
                    return DriveOutcome(anyAccepted: acceptedInPool, stopReason: .exhausted)
                case .deadline:
                    finishAll(&pool, keepsSearchReports: keepsSearchReports, context: &context)
                    return DriveOutcome(anyAccepted: acceptedInPool, stopReason: .deadline)
                case .budgetExhausted:
                    finishAll(&pool, keepsSearchReports: keepsSearchReports, context: &context)
                    return DriveOutcome(anyAccepted: acceptedInPool, stopReason: .budgetExhausted)
                case let .emitted(evaluation):
                    if evaluation.isAccepted {
                        acceptedInPool = true
                    }
                    if let stop = evaluation.stop {
                        return DriveOutcome(anyAccepted: acceptedInPool, stopReason: stop)
                    }
            }
        }
    }

    /// Emits and evaluates exactly one candidate from `pool`, recursing into nested levels. Only the outermost pull checks the deadline per candidate, so a nested level never checks it a second time for the same candidate. Building a branch checks it too, before each build and each lift, at every level.
    static func pull(
        _ pool: inout ScopedSearchPool,
        keepsSearchReports: Bool,
        checksDeadline: Bool,
        context: inout Context
    ) -> PullResult {
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
                    guard let candidate = slot.search.next(slot.feedback, into: &context.candidateBuffer) else {
                        absorb(slot.search.finish(pending: .initial), keepsSearchReports: keepsSearchReports, context: &context)
                        // The branch continues with the search's outcome, in the same member, so its turn carries on.
                        if let continuation = slot.continuation {
                            switch buildBranch(continuation(.outcome(slot.outcome)), depth: pool.depth, context: &context) {
                                case let .built(next):
                                    member.source = next
                                    pool.active = member
                                case .nothing:
                                    break
                                case .deadline:
                                    return .deadline
                            }
                        }
                        continue
                    }
                    // Only a branch search continues with its outcome, so only it pays to count its own work.
                    evaluation = slot.continuation == nil
                        ? evaluate(candidate, configuration: slot.configuration, context: &context)
                        : evaluateCounting(candidate, in: slot, context: &context)
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
                    switch pull(&child, keepsSearchReports: keepsSearchReports, checksDeadline: false, context: &context) {
                        case .exhausted, .budgetExhausted:
                            // A nested level that returns nothing has no candidates left, so it is dropped.
                            finishAll(&child, keepsSearchReports: keepsSearchReports, context: &context)
                            continue
                        case .deadline:
                            // A nested level reaches the deadline only while building, which ends the whole pool.
                            finishAll(&child, keepsSearchReports: keepsSearchReports, context: &context)
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
                finishMember(&member, keepsSearchReports: keepsSearchReports, context: &context)
                finishAll(&pool, keepsSearchReports: keepsSearchReports, context: &context)
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
    /// Branches that fail construction are built back to back without a pull in between, so the deadline is checked before each build.
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
    /// A search keeps its continuation: when it exhausts, the pool resumes the branch with the search's outcome, as a top-level search does. An acceptance that ends the search, the level's probe cap, or the deadline ends every branch in the level, so no continuation runs after them.
    ///
    /// The deadline is checked before each lift, because a branch can lift more than once before it reaches a search.
    private static func buildBranch(
        _ reducer: ScopedReducer,
        depth: Int,
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
                recordBuildOutcome(.failed(reason), depth: depth + 1, context: &context)
                return .nothing
            case let .impure(.search(box, configuration), continuation):
                recordBuildOutcome(.terminalSearch, depth: depth + 1, context: &context)
                return .built(.search(ScopedSearchPool.SearchSlot(search: box.search, configuration: configuration, continuation: continuation)))
            case let .impure(.propose(branches, configuration), continuation):
                recordBuildOutcome(.nestedLevel, depth: depth + 1, context: &context)
                return .built(.level(ScopedSearchPool(branches: branches, continuation: continuation, configuration: configuration, depth: depth + 1)))
        }
    }

    // MARK: - Finishing

    static func finishAll(
        _ pool: inout ScopedSearchPool,
        keepsSearchReports: Bool,
        context: inout Context
    ) {
        if var active = pool.active {
            pool.active = nil
            finishMember(&active, keepsSearchReports: keepsSearchReports, context: &context)
        }
        var suspended = pool.suspended
        pool.suspended = []
        for index in suspended.indices {
            finishMember(&suspended[index], keepsSearchReports: keepsSearchReports, context: &context)
        }
    }

    private static func finishMember(
        _ member: inout ScopedSearchPool.Member,
        keepsSearchReports: Bool,
        context: inout Context
    ) {
        let source = member.source
        member.source = .vacant
        switch consume source {
            case let .search(slot):
                absorb(slot.search.finish(pending: slot.feedback), keepsSearchReports: keepsSearchReports, context: &context)
            case var .level(child):
                finishAll(&child, keepsSearchReports: keepsSearchReports, context: &context)
            case .vacant:
                break
        }
    }

    private static func absorb(_ searchReport: ScopedSearchReport, keepsSearchReports: Bool, context: inout Context) {
        guard keepsSearchReports else {
            return
        }
        context.report.searchReport.convergenceRecords.merge(searchReport.convergenceRecords) { _, new in new }
        if searchReport.hadUnresolvedReplacement {
            context.report.searchReport.hadUnresolvedReplacement = true
        }
    }
}

// MARK: - Search Pool State

/// The members one `propose` level, or one top-level search, is pulling from.
struct ScopedSearchPool {
    /// A search with the outcome of its last candidate, delivered when it is next pulled, including after a suspension.
    ///
    /// A class, so a pull advances the search in place: a search's state runs to hundreds of bytes, and a value slot would be copied in and out of its member on every candidate.
    final class SearchSlot {
        var search: ScopedSearchKind
        let configuration: ScopedSearchConfiguration
        var feedback: ScopedSearchFeedback = .initial
        /// What the branch does after the search exhausts; nil for a top-level search, whose handler resumes the continuation itself.
        let continuation: ((ScopedReductionResult) -> ScopedReducer)?
        /// Whether any of the search's candidates was accepted, for its outcome.
        var anyAccepted = false
        /// Probes this search alone spent, for its outcome. Counted only when the search has a continuation.
        var counts = ReductionProbeCounts()

        init(
            search: ScopedSearchKind,
            configuration: ScopedSearchConfiguration,
            continuation: ((ScopedReductionResult) -> ScopedReducer)?
        ) {
            self.search = search
            self.configuration = configuration
            self.continuation = continuation
        }

        /// The outcome of a search that ran out of candidates.
        var outcome: ScopedSearchOutcome {
            ScopedSearchOutcome(anyAccepted: anyAccepted, stopReason: .exhausted, counts: counts)
        }
    }

    /// What a member pulls from. A search's slot is a reference that is only ever held by its member; a nested level is boxed.
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
    /// The `propose`'s continuation, applied once per branch; nil for a top-level search.
    let continuation: ((ScopedReductionResult) -> ScopedReducer)?
    let depth: Int
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

    init(single search: ScopedSearchKind, configuration: ScopedSearchConfiguration) {
        branches = []
        continuation = nil
        depth = 0
        turn = .max
        searchBudget = 0
        totalProbeCap = 0
        chainLimits = nil
        deliversUniformFeedback = false
        branchesExhausted = true
        active = Member(source: .search(SearchSlot(search: search, configuration: configuration, continuation: nil)), probesRemainingInTurn: .max)
    }
}
