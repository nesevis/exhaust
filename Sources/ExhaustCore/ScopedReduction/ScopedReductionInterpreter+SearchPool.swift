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

    /// Emits and evaluates at most one candidate from `pool`, recursing into nested levels. Returns without a candidate when the pool is exhausted, its probe cap is reached, or the deadline passes. Only the outermost call checks the deadline per candidate, so a nested level never checks it a second time for the same candidate. Building a branch checks it too, before each build and each lift, at every level.
    static func next(
        _ pool: ScopedSearchPool,
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
                switch nextMember(pool, context: &context) {
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
                        // The branch keeps its grade and remaining turn across sequential searches. Exhausting a search emits no candidate.
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
                case let .level(child):
                    switch next(child, checksDeadline: false, context: &context) {
                        case .exhausted, .budgetExhausted:
                            // A nested level that returns nothing has no candidates left, so it is dropped.
                            finishAll(child, context: &context)
                            continue
                        case .deadline:
                            // A nested level reaches the deadline only while building, which ends the whole pool.
                            finishAll(child, context: &context)
                            return .deadline
                        case let .emitted(childEvaluation):
                            evaluation = childEvaluation
                    }
                case .unbuilt:
                    preconditionFailure("A selected branch must be built before requesting a candidate")
            }

            member.probesRemainingInTurn -= 1
            pool.emitted += 1
            if evaluation.stop != nil {
                finishMember(member, context: &context)
                finishAll(pool, context: &context)
                return .emitted(evaluation)
            }
            if pool.scheduling == .diagonal {
                member.emitted += 1
                pool.diagonalQueue.insert(member)
            } else if member.probesRemainingInTurn == 0 {
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

    /// Selects the next member under the pool's policy. Diagonal scheduling compares unopened branches with suspended members before spending a build; failed builds return to selection rather than immediately building a more expensive branch.
    private static func nextMember(_ pool: ScopedSearchPool, context: inout Context) -> BuildResult<ScopedSearchPool.Member> {
        if pool.scheduling == .diagonal {
            while let member = pool.diagonalQueue.popFirst() {
                guard case .unbuilt = member.source else {
                    return .built(member)
                }
                switch buildMember(pool: pool, context: &context) {
                    case let .built(built):
                        return .built(built)
                    case .deadline:
                        return .deadline
                    case .nothing:
                        continue
                }
            }
            return .nothing
        }
        switch buildNextBranch(pool, context: &context) {
            case let .built(member):
                return .built(member)
            case .deadline:
                return .deadline
            case .nothing:
                break
        }
        guard pool.suspendedHead < pool.suspended.count else {
            return .nothing
        }
        var resumed = pool.suspended[pool.suspendedHead]
        pool.suspendedHead += 1
        if pool.suspendedHead * 2 >= pool.suspended.count {
            pool.suspended.removeFirst(pool.suspendedHead)
            pool.suspendedHead = 0
        }
        resumed.probesRemainingInTurn = pool.turn
        return .built(resumed)
    }

    /// Advances branches until one constructs a search or a nested level. The search budget counts empty searches but not failed builds; chain limits count every attempted branch.
    ///
    /// Branches that fail construction are built back to back without a candidate evaluated in between, so the deadline is checked before each build.
    private static func buildNextBranch(_ pool: ScopedSearchPool, context: inout Context) -> BuildResult<ScopedSearchPool.Member> {
        while pool.branchesExhausted == false, pool.constructed < pool.searchBudget {
            switch buildMember(pool: pool, context: &context) {
                case let .built(member):
                    return .built(member)
                case .deadline:
                    return .deadline
                case .nothing:
                    continue
            }
        }
        return .nothing
    }

    /// Builds one selected branch within the existing search and chain budgets. Empty searches count as constructed; failed builds consume only build limits.
    private static func buildMember(
        pool: ScopedSearchPool,
        context: inout Context
    ) -> BuildResult<ScopedSearchPool.Member> {
        guard pool.branchesExhausted == false, pool.constructed < pool.searchBudget else {
            return .nothing
        }
        guard let continuation = pool.continuation else {
            preconditionFailure("Only the root pool has no continuation, and it starts with its branches exhausted")
        }
        guard context.isExpired == false else {
            return .deadline
        }
        if let limits = pool.chainLimits {
            guard pool.buildsThisStart < limits.maxBuildsPerStart,
                  (context.buildPoolRemaining ?? limits.poolCapacity) > 0
            else {
                pool.branchesExhausted = true
                return .nothing
            }
        }
        guard let branchIndex = pool.branches.nextIndex, let proposal = pool.branches.next() else {
            pool.branchesExhausted = true
            return .nothing
        }
        if let limits = pool.chainLimits {
            context.buildPoolRemaining = (context.buildPoolRemaining ?? limits.poolCapacity) - 1
        }
        pool.buildsThisStart += 1
        if pool.scheduling == .diagonal {
            pool.enqueueNextBranch()
        }
        let built = buildBranch(continuation(.proposal(proposal)), depth: pool.depth, context: &context)
        let source: ScopedSearchPool.Source
        switch built {
            case let .built(builtSource):
                source = builtSource
            case .nothing:
                return .nothing
            case .deadline:
                return .deadline
        }
        pool.constructed += 1
        if pool.depth == 0 {
            context.report.constructedSearches += 1
        } else {
            context.report.nestedConstructedSearches += 1
        }
        return .built(ScopedSearchPool.Member(
            source: source,
            probesRemainingInTurn: pool.turn,
            branchIndex: branchIndex
        ))
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

    /// Finishes every member the pool still holds. Suspended members before ``ScopedSearchPool/suspendedHead`` were already resumed, so they are skipped.
    static func finishAll(_ pool: ScopedSearchPool, context: inout Context) {
        if let active = pool.active {
            pool.active = nil
            finishMember(active, context: &context)
        }
        let suspended = pool.suspended[pool.suspendedHead...]
        pool.suspended = []
        pool.suspendedHead = 0
        for member in suspended {
            finishMember(member, context: &context)
        }
        while let member = pool.diagonalQueue.popFirst() {
            finishMember(member, context: &context)
        }
    }

    private static func finishMember(_ member: ScopedSearchPool.Member, context: inout Context) {
        switch member.source {
            case let .search(slot):
                finishSearch(slot, pending: slot.feedback, context: &context)
            case let .level(child):
                finishAll(child, context: &context)
            case .unbuilt:
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
///
/// A class, so a nested level advances in place inside its parent's member, as a search does inside its slot.
final class ScopedSearchPool {
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
            ScopedSearchOutcome(anyAccepted: anyAccepted, counts: counts)
        }
    }

    /// Where a member's candidates come from. A search's slot and a nested level are references, each held only by its member.
    enum Source {
        /// The next unopened branch, whose prefix and lift are constructed only when its grade is selected.
        case unbuilt
        case search(SearchSlot)
        case level(ScopedSearchPool)
    }

    struct Member {
        var source: Source
        var probesRemainingInTurn: Int
        /// The branch's position, which is also its starting grade under diagonal scheduling.
        let branchIndex: Int
        /// Candidates this member has emitted under diagonal scheduling.
        var emitted = 0

        static func precedes(_ first: Self, _ second: Self) -> Bool {
            let firstGrade = first.branchIndex + first.emitted
            let secondGrade = second.branchIndex + second.emitted
            if firstGrade != secondGrade {
                return firstGrade < secondGrade
            }
            return first.branchIndex < second.branchIndex
        }
    }

    var branches: ScopedBranchCursor
    /// The `propose`'s continuation, applied once per branch; nil for the root pool.
    let continuation: ((ScopedReductionResult) -> ScopedReducer)?
    /// How many `propose` levels enclose this level, or nil for the root pool, which holds the root branch alone.
    let depth: Int?
    /// Probes a member emits before it is suspended behind the others.
    let turn: Int
    let scheduling: ScopedChoiceScheduling
    let searchBudget: Int
    let totalProbeCap: Int
    let chainLimits: ScopedChainLimits?
    let deliversUniformFeedback: Bool
    var branchesExhausted = false
    var constructed = 0
    /// Branches this level has built, counted against ``ScopedChainLimits/maxBuildsPerStart``. A level is created afresh each time its parent's branch reaches it, so the count starts at zero for each one.
    var buildsThisStart = 0
    var emitted = 0
    var active: Member?
    /// Members waiting for another turn, oldest first from ``suspendedHead``. Entries before the head were resumed; that prefix is dropped once it fills half the storage, so storage stays proportional to live members while resuming stays amortized constant time.
    var suspended: [Member] = []
    var suspendedHead = 0
    /// Suspended branches and at most one unopened frontier. Nested levels carry their parent's local grade, not their own next grade.
    var diagonalQueue = ScopePriorityQueue<Member>(precedes: Member.precedes)

    init(
        branches: @escaping ScopedProposalFactory,
        continuation: @escaping (ScopedReductionResult) -> ScopedReducer,
        configuration: ScopedChoiceConfiguration,
        depth: Int
    ) {
        self.branches = ScopedBranchCursor(branches)
        self.continuation = continuation
        self.depth = depth
        scheduling = configuration.scheduling
        turn = scheduling == .diagonal ? 1 : configuration.probesPerSearchTurn ?? .max
        searchBudget = configuration.searchBudget ?? .max
        totalProbeCap = configuration.totalProbeCap
        chainLimits = configuration.chainLimits
        deliversUniformFeedback = configuration.deliversUniformFeedback
        if scheduling == .diagonal {
            enqueueNextBranch()
        }
    }

    /// Keeps only the next unopened branch in the queue. Its prefix is not needed to compare its grade with suspended searches.
    func enqueueNextBranch() {
        guard let branchIndex = branches.nextIndex else {
            return
        }
        diagonalQueue.insert(Member(source: .unbuilt, probesRemainingInTurn: 1, branchIndex: branchIndex))
    }

    /// A pool holding only the root branch, built from the encoder's reducer.
    init(root: Source) {
        branches = ScopedBranchCursor { nil }
        continuation = nil
        depth = nil
        turn = .max
        scheduling = .turnBased
        searchBudget = 0
        totalProbeCap = 0
        chainLimits = nil
        deliversUniformFeedback = false
        branchesExhausted = true
        active = Member(source: root, probesRemainingInTurn: .max, branchIndex: 0)
    }
}
