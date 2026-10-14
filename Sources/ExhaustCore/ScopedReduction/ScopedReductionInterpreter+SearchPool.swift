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
                    finishAll(&pool, reason: .deadline, keepsSearchReports: keepsSearchReports, context: &context)
                    return DriveOutcome(anyAccepted: acceptedInPool, stopReason: .deadline)
                case .budgetExhausted:
                    finishAll(&pool, reason: .budgetExhausted, keepsSearchReports: keepsSearchReports, context: &context)
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

    /// Emits and evaluates exactly one candidate from `pool`, recursing into nested levels. Only the outermost pull checks the deadline, once per candidate, so a nested level never checks it a second time for the same candidate.
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
                pool.active = nextMember(&pool, context: &context)
            }
            guard var member = pool.active else {
                return .exhausted
            }
            pool.active = nil

            let evaluation: Evaluation
            switch member.source {
                case let .search(slot):
                    guard let candidate = slot.search.next(slot.feedback, into: &context.candidateBuffer) else {
                        absorb(slot.search.finish(reason: .exhausted, undelivered: nil), keepsSearchReports: keepsSearchReports, context: &context)
                        continue
                    }
                    evaluation = evaluate(candidate, configuration: slot.configuration, context: &context)
                    slot.feedback = pool.deliversUniformFeedback ? uniform(evaluation.feedback) : evaluation.feedback
                case .level:
                    // Moving the level out leaves its storage uniquely referenced while it advances.
                    let source = member.source
                    member.source = .vacant
                    guard case var .level(child) = consume source else {
                        preconditionFailure("A level member must hold a level")
                    }
                    switch pull(&child, keepsSearchReports: keepsSearchReports, checksDeadline: false, context: &context) {
                        case .exhausted, .budgetExhausted, .deadline:
                            // A nested level that returns nothing has no candidates left, so it is dropped.
                            finishAll(&child, reason: .exhausted, keepsSearchReports: keepsSearchReports, context: &context)
                            continue
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
                finishMember(&member, reason: stop, keepsSearchReports: keepsSearchReports, context: &context)
                finishAll(&pool, reason: stop, keepsSearchReports: keepsSearchReports, context: &context)
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
    private static func nextMember(_ pool: inout ScopedSearchPool, context: inout Context) -> ScopedSearchPool.Member? {
        if let built = buildNextBranch(&pool, context: &context) {
            return built
        }
        guard pool.suspended.isEmpty == false else {
            return nil
        }
        var resumed = pool.suspended.removeFirst()
        resumed.probesRemainingInTurn = pool.turn
        return resumed
    }

    /// Advances branches until one constructs a search or a nested level. The search budget counts empty searches but not failed builds; chain limits count every attempted branch.
    private static func buildNextBranch(_ pool: inout ScopedSearchPool, context: inout Context) -> ScopedSearchPool.Member? {
        while pool.branchesExhausted == false, pool.constructed < pool.searchBudget {
            guard let continuation = pool.continuation, pool.nextBranch < pool.branches.count else {
                pool.branchesExhausted = true
                return nil
            }
            let branch = pool.branches[pool.nextBranch]
            pool.nextBranch += 1
            if let limits = pool.chainLimits {
                guard pool.buildsThisStart < limits.maxBuildsPerStart, consumeBuildPool(capacity: limits.poolCapacity, context: &context) else {
                    pool.branchesExhausted = true
                    return nil
                }
            }
            pool.buildsThisStart += 1
            guard let source = buildBranch(
                continuation(.proposal(branch.proposal)),
                depth: pool.depth,
                accountingStage: pool.accountingStage,
                context: &context
            ) else {
                continue
            }
            pool.constructed += 1
            if pool.depth == 0 {
                context.report.constructedSearches += 1
            } else {
                context.report.nestedConstructedSearches += 1
            }
            return ScopedSearchPool.Member(source: source, probesRemainingInTurn: pool.turn)
        }
        return nil
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
    private static func buildBranch(
        _ reducer: ScopedReducer,
        depth: Int,
        accountingStage: BoundValueStage?,
        context: inout Context
    ) -> ScopedSearchPool.Source? {
        switch reducer {
            case .pure:
                return nil
            case let .impure(.lift(prefix, fallbackTree, maximumSequenceCount), continuation):
                let lifted = lift(
                    prefix,
                    fallbackTree: fallbackTree,
                    maximumSequenceCount: maximumSequenceCount,
                    accountingStage: accountingStage,
                    context: &context
                )
                return buildBranch(continuation(.lifted(lifted)), depth: depth, accountingStage: accountingStage, context: &context)
            case let .impure(.fail(reason), _):
                recordFailure(reason, accountingStage: accountingStage, context: &context)
                return nil
            case let .impure(.search(box, configuration), _):
                recordBuildOutcome(.terminalSearch, accountingStage: accountingStage, context: &context)
                return .search(ScopedSearchPool.SearchSlot(search: box.search, configuration: configuration, feedback: .initial))
            case let .impure(.propose(branches, configuration), continuation):
                recordBuildOutcome(.nestedStage, accountingStage: accountingStage, context: &context)
                return .level(ScopedSearchPool(branches: branches, continuation: continuation, configuration: configuration, depth: depth + 1))
        }
    }

    // MARK: - Finishing

    static func finishAll(
        _ pool: inout ScopedSearchPool,
        reason: ScopedStopReason,
        keepsSearchReports: Bool,
        context: inout Context
    ) {
        if var active = pool.active {
            pool.active = nil
            finishMember(&active, reason: reason, keepsSearchReports: keepsSearchReports, context: &context)
        }
        var suspended = pool.suspended
        pool.suspended = []
        for index in suspended.indices {
            finishMember(&suspended[index], reason: reason, keepsSearchReports: keepsSearchReports, context: &context)
        }
    }

    private static func finishMember(
        _ member: inout ScopedSearchPool.Member,
        reason: ScopedStopReason,
        keepsSearchReports: Bool,
        context: inout Context
    ) {
        let source = member.source
        member.source = .vacant
        switch consume source {
            case let .search(slot):
                absorb(slot.search.finish(reason: reason, undelivered: slot.undeliveredFeedback), keepsSearchReports: keepsSearchReports, context: &context)
            case var .level(child):
                finishAll(&child, reason: reason, keepsSearchReports: keepsSearchReports, context: &context)
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
        var feedback: ScopedSearchFeedback

        init(search: ScopedSearchKind, configuration: ScopedSearchConfiguration, feedback: ScopedSearchFeedback) {
            self.search = search
            self.configuration = configuration
            self.feedback = feedback
        }

        /// The pending feedback, or nil when the search has nothing waiting.
        var undeliveredFeedback: ScopedSearchFeedback? {
            switch feedback {
                case .initial:
                    nil
                case .accepted, .rejected:
                    feedback
            }
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
    let accountingStage: BoundValueStage?
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
        accountingStage = configuration.accountingStage
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
        accountingStage = nil
        deliversUniformFeedback = false
        branchesExhausted = true
        active = Member(source: .search(SearchSlot(search: search, configuration: configuration, feedback: .initial)), probesRemainingInTurn: .max)
    }
}
