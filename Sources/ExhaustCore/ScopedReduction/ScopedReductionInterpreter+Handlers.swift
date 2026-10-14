//
//  ScopedReductionInterpreter+Handlers.swift
//  Exhaust
//

// MARK: - Operation Handlers

extension ScopedReductionInterpreter {
    /// Lifts a top-level prefix. Lifts inside a `propose` go through ``buildBranch(_:depth:context:)``.
    static func handleLift(
        _ prefix: ChoiceSequence,
        fallbackTree: ChoiceTree,
        maximumSequenceCount: Int?,
        continuation: (ScopedReductionResult) -> ScopedReducer,
        context: inout Context
    ) -> ScopedStopReason? {
        let lifted = lift(
            prefix,
            fallbackTree: fallbackTree,
            maximumSequenceCount: maximumSequenceCount,
            context: &context
        )
        return interpret(continuation(.lifted(lifted)), context: &context)
    }

    static func handleFail(_ reason: DownstreamBuildFailure, context: inout Context) -> ScopedStopReason? {
        recordBuildOutcome(.failed(reason), depth: 0, context: &context)
        return nil
    }

    /// Runs a top-level search, keeping its report, and continues with its outcome unless it ended the pass.
    static func handleSearch(
        _ box: ScopedSearchBox,
        configuration: ScopedSearchConfiguration,
        continuation: (ScopedReductionResult) -> ScopedReducer,
        context: inout Context
    ) -> ScopedStopReason? {
        let stagedJointArity: Int? = switch box.search {
            case let .stagedJoint(search):
                search.arity
            default:
                nil
        }
        var pool = ScopedSearchPool(single: box.search, configuration: configuration)
        // A search that follows another one in the encoder's reducer is not started past the deadline, so no work is recorded for a stage that did not run. The runner checks the deadline before the first search of the encoder's reducer.
        if context.report.searchCounts.isEmpty == false, context.isExpired {
            finishAll(&pool, reason: .deadline, keepsSearchReports: true, context: &context)
            return .deadline
        }
        // Counts this search alone, then folds them back into the pass, so the encoder's reducer can branch on its search's work and the runner can attribute it.
        let passCounts = context.report.counts
        context.report.counts = ReductionProbeCounts()
        let driven = drive(&pool, keepsSearchReports: true, context: &context)
        let searchCounts = context.report.counts
        context.report.counts = passCounts
        context.report.counts.merge(searchCounts)
        context.report.searchCounts.append(ScopedSearchCounts(stagedJointArity: stagedJointArity, counts: searchCounts))
        if endsPass(driven.stopReason) {
            return driven.stopReason
        }
        let outcome = ScopedSearchOutcome(
            anyAccepted: driven.anyAccepted,
            stopReason: driven.stopReason,
            counts: searchCounts
        )
        return interpret(continuation(.outcome(outcome)), context: &context)
    }

    /// Schedules every branch of a top-level `propose`. The continuation runs once per branch as the search pool builds it, so nothing follows the `propose` itself.
    static func handlePropose(
        _ branches: [ScopedBranch],
        configuration: ScopedChoiceConfiguration,
        continuation: @escaping (ScopedReductionResult) -> ScopedReducer,
        context: inout Context
    ) -> ScopedStopReason? {
        var pool = ScopedSearchPool(branches: branches, continuation: continuation, configuration: configuration, depth: 0)
        let outcome = drive(&pool, keepsSearchReports: false, context: &context)
        return endsPass(outcome.stopReason) ? outcome.stopReason : nil
    }

    /// A deadline, or an acceptance that ends the search, ends the whole pass. Exhausting a pool or its budget ends only that pool.
    private static func endsPass(_ reason: ScopedStopReason) -> Bool {
        switch reason {
            case .accepted, .deadline:
                true
            case .exhausted, .budgetExhausted, .invalidated:
                false
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
}
