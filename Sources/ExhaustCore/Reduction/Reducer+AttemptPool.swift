//
//  Reducer+AttemptPool.swift
//  Exhaust
//

// MARK: - Attempt Pool

extension Reducer {
    /// What building an attempt or choosing the next attempt produced. Building stops at the deadline, because each build can lift.
    enum BuildResult<Value> {
        case built(Value)
        case nothing
        case deadline
    }

    /// What one call to ``next(_:checksDeadline:context:)`` on an attempt pool produced.
    enum NextResult {
        case emitted(Evaluation)
        case exhausted
        case budgetExhausted
        case deadline
    }

    // MARK: - Next Candidate

    /// Emits and evaluates at most one candidate from `pool`, recursing into nested levels. Returns without a candidate when the pool is exhausted, its probe cap is reached, or the deadline passes. Only the outermost call checks the deadline per candidate, so a nested level never checks it a second time for the same candidate. Building an attempt checks it too, before each build and each lift, at every level.
    static func next(
        _ pool: AttemptPool,
        checksDeadline: Bool,
        context: inout Context
    ) -> NextResult {
        if checksDeadline, context.isExpired {
            return .deadline
        }
        while true {
            if pool.totalProbeCap > 0, pool.emittedProbes >= pool.totalProbeCap {
                return .budgetExhausted
            }
            if pool.active == nil {
                switch nextAttempt(pool, context: &context) {
                    case let .built(attempt):
                        pool.active = attempt
                    case .nothing:
                        break
                    case .deadline:
                        return .deadline
                }
            }
            guard var attempt = pool.active else {
                return .exhausted
            }
            pool.active = nil

            let evaluation: Evaluation
            switch attempt.source {
                case let .search(slot):
                    slot.wasAskedForCandidate = true
                    guard let candidate = slot.search.next(slot.feedback, into: &context.candidateBuffer) else {
                        finishSearch(slot, pending: .initial, context: &context)
                        // The continuation's next search would otherwise draw its first candidate under the deadline check that preceded this exhaustion.
                        guard context.isExpired == false else {
                            return .deadline
                        }
                        // The attempt keeps its grade and remaining turn across sequential searches. Exhausting a search emits no candidate.
                        switch buildAttempt(slot.continuation(.outcome(slot.outcome)), depth: pool.depth, recoveryMutation: slot.recoveryMutation, context: &context) {
                            case let .built(next):
                                attempt.source = next
                                pool.active = attempt
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
                    preconditionFailure("A selected attempt must be built before requesting a candidate")
            }

            attempt.probesRemainingInTurn -= 1
            pool.emittedProbes += 1
            if evaluation.stop != nil {
                finishAttempt(attempt, context: &context)
                finishAll(pool, context: &context)
                return .emitted(evaluation)
            }
            if pool.scheduling == .diagonal {
                attempt.emittedProbes += 1
                pool.diagonalQueue.insert(attempt)
            } else if attempt.probesRemainingInTurn == 0 {
                pool.suspended.append(attempt)
            } else {
                pool.active = attempt
            }
            return .emitted(evaluation)
        }
    }

    /// Evaluates `candidate`, adding its probe counts to the slot's own as well as to the pass's.
    private static func evaluateCounting(
        _ candidate: ReductionCandidate,
        in slot: AttemptPool.SearchSlot,
        context: inout Context
    ) -> Evaluation {
        let passCounts = context.report.counts
        context.report.counts = ReductionProbeCounts()
        let evaluation = evaluateAndCommit(candidate, configuration: slot.configuration, recoveryMutation: slot.recoveryMutation, context: &context)
        let candidateCounts = context.report.counts
        context.report.counts = passCounts
        context.report.counts.merge(candidateCounts)
        slot.counts.merge(candidateCounts)
        return evaluation
    }

    /// Withholds the outcome, keeping only whether a candidate was evaluated at all.
    private static func uniform(_ feedback: SearchFeedback) -> SearchFeedback {
        switch feedback {
            case .initial:
                .initial
            case .accepted, .rejected:
                .rejected(.undifferentiated)
        }
    }

    // MARK: - Attempts

    /// Selects the next attempt under the pool's policy. Diagonal scheduling compares unopened attempts with suspended attempts before spending a build; failed builds return to selection rather than immediately building a more expensive attempt.
    private static func nextAttempt(_ pool: AttemptPool, context: inout Context) -> BuildResult<ReductionAttempt> {
        if pool.scheduling == .diagonal {
            while let attempt = pool.diagonalQueue.popFirst() {
                guard case .unbuilt = attempt.source else {
                    return .built(attempt)
                }
                switch buildSelectedAttempt(pool: pool, context: &context) {
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
        switch buildNextAttempt(pool, context: &context) {
            case let .built(attempt):
                return .built(attempt)
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
        resumed.probesRemainingInTurn = pool.probesPerAttemptTurn
        return .built(resumed)
    }

    /// Advances proposals until one attempt reaches a search or a nested level. The constructed-attempt limit counts that attempt even if it emits no probes; chain limits also count failed build attempts.
    ///
    /// Attempts that fail construction are built back to back without a candidate evaluated in between, so the deadline is checked before each build.
    private static func buildNextAttempt(_ pool: AttemptPool, context: inout Context) -> BuildResult<ReductionAttempt> {
        while pool.attemptsExhausted == false, pool.constructedAttempts < pool.constructedAttemptLimit {
            switch buildSelectedAttempt(pool: pool, context: &context) {
                case let .built(attempt):
                    return .built(attempt)
                case .deadline:
                    return .deadline
                case .nothing:
                    continue
            }
        }
        return .nothing
    }

    /// Builds one selected attempt within the construction and chain limits. Reaching a search or nested level counts once, even if it emits no probes; failed builds consume only chain build limits.
    private static func buildSelectedAttempt(
        pool: AttemptPool,
        context: inout Context
    ) -> BuildResult<ReductionAttempt> {
        guard pool.attemptsExhausted == false, pool.constructedAttempts < pool.constructedAttemptLimit else {
            return .nothing
        }
        guard let continuation = pool.continuation else {
            preconditionFailure("Only the root pool has no continuation, and it starts with its attempts exhausted")
        }
        guard context.isExpired == false else {
            return .deadline
        }
        if let limits = pool.chainLimits {
            guard pool.attemptBuildsThisStart < limits.maxBuildsPerStart,
                  (context.buildPoolRemaining ?? limits.poolCapacity) > 0
            else {
                pool.attemptsExhausted = true
                return .nothing
            }
        }
        guard let attemptIndex = pool.attempts.nextIndex, let proposal = pool.attempts.next() else {
            pool.attemptsExhausted = true
            return .nothing
        }
        if let limits = pool.chainLimits {
            context.buildPoolRemaining = (context.buildPoolRemaining ?? limits.poolCapacity) - 1
        }
        pool.attemptBuildsThisStart += 1
        if pool.scheduling == .diagonal {
            pool.enqueueNextAttempt()
        }
        let built = buildAttempt(continuation(.proposal(proposal)), depth: pool.depth, recoveryMutation: pool.recoveryMutation, context: &context)
        let source: AttemptPool.Source
        switch built {
            case let .built(builtSource):
                source = builtSource
            case .nothing:
                return .nothing
            case .deadline:
                return .deadline
        }
        pool.constructedAttempts += 1
        if pool.depth == 0 {
            context.report.constructedAttempts += 1
        } else {
            context.report.nestedConstructedAttempts += 1
        }
        return .built(ReductionAttempt(
            source: source,
            probesRemainingInTurn: pool.probesPerAttemptTurn,
            attemptIndex: attemptIndex
        ))
    }

    /// Interprets one attempt's pipeline until it reaches a search, a nested `propose`, or a failure, answering its lifts. The search or level is returned unstarted, so the attempt pool can interleave it with other attempts.
    ///
    /// A search keeps its continuation: when it exhausts, the pool resumes the attempt with the search's outcome. An acceptance that ends the search, the level's probe cap, or the deadline ends every attempt in the level, so no continuation runs after them.
    ///
    /// The deadline is checked before each lift, because an attempt can lift more than once before it reaches a search.
    ///
    /// - Parameter depth: How many `propose` levels enclose the attempt's level, or nil for the root, whose builds are not recorded.
    /// - Parameter recoveryMutation: The first successful lift's mutation, inherited through continuations and nested pools. Nil before any lift succeeds.
    static func buildAttempt(
        _ reduction: Reduction,
        depth: Int?,
        recoveryMutation: ProjectedMutation? = nil,
        context: inout Context
    ) -> BuildResult<AttemptPool.Source> {
        switch reduction {
            case .pure:
                return .nothing
            case let .impure(.lift(proposal, fallbackTree, maximumSequenceCount), continuation):
                guard context.isExpired == false else {
                    return .deadline
                }
                let lifted = lift(
                    proposal.prefix,
                    fallbackTree: fallbackTree,
                    maximumSequenceCount: maximumSequenceCount,
                    context: &context
                )
                let inheritedMutation = recoveryMutation ?? lifted.map { _ in reshaping(proposal.mutation) }
                return buildAttempt(continuation(.lifted(lifted)), depth: depth, recoveryMutation: inheritedMutation, context: &context)
            case let .impure(.fail(reason), _):
                if let depth {
                    recordBuildOutcome(.failed(reason), depth: depth + 1, context: &context)
                }
                return .nothing
            case let .impure(.search(search, configuration), continuation):
                if let depth {
                    recordBuildOutcome(.terminalSearch, depth: depth + 1, context: &context)
                }
                return .built(.search(AttemptPool.SearchSlot(
                    search: search,
                    configuration: configuration,
                    continuation: continuation,
                    recoveryMutation: recoveryMutation
                )))
            case let .impure(.propose(attempts, configuration), continuation):
                let nextDepth = depth.map { $0 + 1 } ?? 0
                if depth != nil {
                    recordBuildOutcome(.nestedLevel, depth: nextDepth, context: &context)
                }
                return .built(.level(AttemptPool(attempts: attempts, continuation: continuation, configuration: configuration, depth: nextDepth, recoveryMutation: recoveryMutation)))
        }
    }

    // MARK: - Lift

    /// The first lift can change graph structure, so its mutation must select a decoder that can recover that change. Nested mutations address lifted graphs and cannot replace it.
    private static func reshaping(_ mutation: ProjectedMutation) -> ProjectedMutation {
        guard case let .leafValues(changes) = mutation else {
            return mutation
        }
        return .leafValues(changes.map { change in
            LeafChange(leafNodeID: change.leafNodeID, newValue: change.newValue, mayReshape: true)
        })
    }

    static func lift(
        _ prefix: EditedChoiceSequence,
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

    /// Finishes every attempt the pool still holds. Suspended attempts before ``AttemptPool/suspendedHead`` were already resumed, so they are skipped.
    static func finishAll(_ pool: AttemptPool, context: inout Context) {
        if let active = pool.active {
            pool.active = nil
            finishAttempt(active, context: &context)
        }
        let suspended = pool.suspended[pool.suspendedHead...]
        pool.suspended = []
        pool.suspendedHead = 0
        for attempt in suspended {
            finishAttempt(attempt, context: &context)
        }
        while let attempt = pool.diagonalQueue.popFirst() {
            finishAttempt(attempt, context: &context)
        }
    }

    private static func finishAttempt(_ attempt: ReductionAttempt, context: inout Context) {
        switch attempt.source {
            case let .search(slot):
                finishSearch(slot, pending: slot.feedback, context: &context)
            case let .level(child):
                finishAll(child, context: &context)
            case .unbuilt:
                break
        }
    }

    /// Finishes the search. Only unlifted searches export reports and individual counts: lifted reports address another graph, regardless of how many `propose` levels surround the search.
    private static func finishSearch(_ slot: AttemptPool.SearchSlot, pending: SearchFeedback, context: inout Context) {
        let searchReport = slot.search.finish(pending: pending)
        guard slot.recoveryMutation == nil else {
            return
        }
        context.report.searchReport.convergenceRecords.merge(searchReport.convergenceRecords) { _, new in new }
        if searchReport.hadUnresolvedReplacement {
            context.report.searchReport.hadUnresolvedReplacement = true
        }
        if slot.wasAskedForCandidate {
            context.report.searchCounts.append(SearchCounts(stagedJointArity: searchReport.stagedJointArity, counts: slot.counts))
        }
    }
}

// MARK: - Reduction Attempt

/// Keeps scheduling progress for one reduction pipeline across its searches and nested levels. Changing the source does not start a new attempt.
struct ReductionAttempt {
    var source: AttemptPool.Source
    var probesRemainingInTurn: Int
    /// The attempt's position, which is also its starting grade under diagonal scheduling.
    let attemptIndex: Int
    /// Candidates this attempt has emitted under diagonal scheduling.
    var emittedProbes = 0

    /// Orders attempts by their diagonal grade, preserving proposal order when grades tie.
    static func precedes(_ first: Self, _ second: Self) -> Bool {
        let firstGrade = first.attemptIndex + first.emittedProbes
        let secondGrade = second.attemptIndex + second.emittedProbes
        if firstGrade != secondGrade {
            return firstGrade < secondGrade
        }
        return first.attemptIndex < second.attemptIndex
    }
}

// MARK: - Attempt Pool State

/// Schedules the attempts of one `propose` level, or the root attempt alone. Each attempt keeps its turn and grade across sequential searches and can delegate candidate production to a nested pool.
///
/// A class, so a nested level advances in place inside its parent's attempt, as a search does inside its slot.
final class AttemptPool {
    /// A search with the outcome of its last candidate, delivered when it is next asked for a candidate, including after a suspension.
    ///
    /// A class, so asking for a candidate advances the search in place: a search's state runs to hundreds of bytes, and a value slot would be copied in and out of its attempt on every candidate.
    final class SearchSlot {
        var search: any ReductionSearch
        let configuration: SearchConfiguration
        var feedback: SearchFeedback = .initial
        /// What the attempt does after the search exhausts.
        let continuation: (ReductionResponse) -> Reduction
        /// The first successful lift's mutation, in the incumbent graph. Nil while searches still address that graph directly.
        let recoveryMutation: ProjectedMutation?
        /// Whether any of the search's candidates was accepted, for its outcome.
        var anyAccepted = false
        /// Whether the search was asked for a candidate. An unlifted search stopped before then, by the deadline, records no counts.
        var wasAskedForCandidate = false
        /// Probes this search alone spent, for its outcome.
        var counts = ReductionProbeCounts()

        init(
            search: any ReductionSearch,
            configuration: SearchConfiguration,
            continuation: @escaping (ReductionResponse) -> Reduction,
            recoveryMutation: ProjectedMutation?
        ) {
            self.search = search
            self.configuration = configuration
            self.continuation = continuation
            self.recoveryMutation = recoveryMutation
        }

        /// The outcome of a search that ran out of candidates.
        var outcome: SearchOutcome {
            SearchOutcome(anyAccepted: anyAccepted, counts: counts)
        }
    }

    /// Where an attempt's candidates come from. A search's slot and a nested level are references, each held only by its attempt.
    enum Source {
        /// The next unopened attempt, whose prefix and lift are constructed only when its grade is selected.
        case unbuilt
        case search(SearchSlot)
        case level(AttemptPool)
    }

    var attempts: AttemptCursor
    /// The `propose`'s continuation, applied once per attempt; nil for the root pool.
    let continuation: ((ReductionResponse) -> Reduction)?
    /// How many `propose` levels enclose this level, or nil for the root pool, which holds the root attempt alone.
    let depth: Int?
    /// The lifted context inherited by every attempt this pool builds. Each attempt can establish its own context without changing its siblings.
    let recoveryMutation: ProjectedMutation?
    /// Probes an attempt emits before it is suspended behind the others.
    let probesPerAttemptTurn: Int
    let scheduling: ChoiceScheduling
    let constructedAttemptLimit: Int
    let totalProbeCap: Int
    let chainLimits: ChainLimits?
    let deliversUniformFeedback: Bool
    var attemptsExhausted = false
    /// Attempts that reached a search or nested level, including those that emit no probes. Sequential searches do not increment this count.
    var constructedAttempts = 0
    /// Construction calls, including failures, counted against ``ChainLimits/maxBuildsPerStart``. A level is created afresh each time its parent's attempt reaches it, so the count starts at zero for each one.
    var attemptBuildsThisStart = 0
    var emittedProbes = 0
    var active: ReductionAttempt?
    /// Attempts waiting for another turn, oldest first from ``suspendedHead``. Entries before the head were resumed; that prefix is dropped once it fills half the storage, so storage stays proportional to live attempts while resuming stays amortized constant time.
    var suspended: [ReductionAttempt] = []
    var suspendedHead = 0
    /// Suspended attempts and at most one unopened frontier. Nested levels carry their parent's local grade, not their own next grade.
    var diagonalQueue = ScopePriorityQueue<ReductionAttempt>(precedes: ReductionAttempt.precedes)

    init(
        attempts: @escaping ProposalFactory,
        continuation: @escaping (ReductionResponse) -> Reduction,
        configuration: ChoiceConfiguration,
        depth: Int,
        recoveryMutation: ProjectedMutation?
    ) {
        self.attempts = AttemptCursor(attempts)
        self.continuation = continuation
        self.depth = depth
        self.recoveryMutation = recoveryMutation
        scheduling = configuration.scheduling
        probesPerAttemptTurn = scheduling == .diagonal ? 1 : configuration.probesPerAttemptTurn ?? .max
        constructedAttemptLimit = configuration.constructedAttemptLimit ?? .max
        totalProbeCap = configuration.totalProbeCap
        chainLimits = configuration.chainLimits
        deliversUniformFeedback = configuration.deliversUniformFeedback
        if scheduling == .diagonal {
            enqueueNextAttempt()
        }
    }

    /// Keeps only the next unopened attempt in the queue. Its prefix is not needed to compare its grade with suspended attempts.
    func enqueueNextAttempt() {
        guard let attemptIndex = attempts.nextIndex else {
            return
        }
        diagonalQueue.insert(ReductionAttempt(source: .unbuilt, probesRemainingInTurn: 1, attemptIndex: attemptIndex))
    }

    /// A pool holding only the root attempt, built from the encoder's reduction.
    init(root: Source) {
        attempts = AttemptCursor { nil }
        continuation = nil
        depth = nil
        recoveryMutation = nil
        probesPerAttemptTurn = .max
        scheduling = .turnBased
        constructedAttemptLimit = 0
        totalProbeCap = 0
        chainLimits = nil
        deliversUniformFeedback = false
        attemptsExhausted = true
        active = ReductionAttempt(source: root, probesRemainingInTurn: .max, attemptIndex: 0)
    }
}
