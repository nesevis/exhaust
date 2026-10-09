extension ReductionMachine {
    /// Returns a fresh scope only when its base or domains differ from the exhausted search.
    func pendingStagedNumericPairs() -> [NumericPairQuery.Pair]? {
        pendingStagedNumericSearchScope()?.pairs
    }

    /// Reuses one frontier snapshot for cache validation and execution, and avoids frontier preparation when there are no stalled pair sources.
    private func pendingStagedNumericSearchScope() -> (pairs: [NumericPairQuery.Pair], frontier: [NumericJointQuery.Entry])? {
        guard tuning.stagedJointProbeBudget > 0,
              isEncoderEnabled(.stagedJointSearch),
              convergence.deferBindInner == false
        else {
            return nil
        }
        let pairs = NumericPairQuery.build(graph: graph, gate: convergence.gate)
        guard pairs.isEmpty == false else { return nil }
        let frontier = numericJointFrontier()
        guard exhaustedStagedJointScope?.base != sequence
            || exhaustedStagedJointScope?.pairs != pairs
            || exhaustedStagedJointScope?.frontier != frontier
        else {
            return nil
        }
        return (pairs, frontier)
    }

    /// Starts the pair stage and retains its higher-arity frontier and remaining budgets across cooperative probes.
    mutating func startStagedJointPass(remaining: [ChoiceGraphScheduler.PostCycleAction]) -> Transition {
        guard let checkpoint = beginStagedJointSearch(),
              let session = makePostCycleSession(operation: checkpoint.operation, estimatedCost: checkpoint.budget)
        else {
            return .stagedJointPassCompleted(accepted: false)
        }
        activeSession = session
        phase = .postCycleProbing(pass: .stagedJoint(checkpoint.search), remaining: remaining)
        return .postCycleStarted(owner: .stagedJointPass)
    }

    /// Continues to the next arity only after the previous stage stalled and its sampled-work gate opened.
    mutating func advanceStagedJointPass(
        report: PassReport,
        search: inout StagedJointSearch,
        remaining: [ChoiceGraphScheduler.PostCycleAction]
    ) -> Transition {
        if report.anyAccepted {
            invalidateAfterCoupledAcceptance()
            resumePostCycle(remaining: remaining)
            return .stagedJointPassCompleted(accepted: true)
        }
        search.remaining -= report.probeCount
        guard let stage = nextStagedJointOperation(search: &search),
              let session = makePostCycleSession(operation: stage.operation, estimatedCost: stage.budget)
        else {
            resumePostCycle(remaining: remaining)
            return .stagedJointPassCompleted(accepted: false)
        }
        activeSession = session
        phase = .postCycleProbing(pass: .stagedJoint(search), remaining: remaining)
        return .postCycleStarted(owner: .stagedJointPass)
    }

    /// Runs a complete numeric checkpoint for direct callers, using the same stage preparation and report policy as cooperative stepping.
    mutating func runStagedJointSearch() -> Bool {
        guard let checkpoint = beginStagedJointSearch() else {
            return false
        }
        var search = checkpoint.search
        var stage: (operation: GraphOperation, budget: Int)? = (checkpoint.operation, checkpoint.budget)
        while let current = stage,
              let report = runPostCycleEncoder(operation: current.operation, estimatedCost: current.budget)
        {
            if report.anyAccepted {
                invalidateAfterCoupledAcceptance()
                return true
            }
            search.remaining -= report.probeCount
            stage = nextStagedJointOperation(search: &search)
        }
        return false
    }

    /// Marks the checkpoint exhausted before encoder startup, so deadline interruption does not repeat its original search scope.
    private mutating func beginStagedJointSearch() -> (search: StagedJointSearch, operation: GraphOperation, budget: Int)? {
        guard isDeadlineExceeded() == false, let scope = pendingStagedNumericSearchScope() else {
            return nil
        }
        exhaustedStagedJointScope = ExhaustedStagedJointScope(base: sequence, pairs: scope.pairs, frontier: scope.frontier)
        let canTryThree = NumericJointQuery.canEscalate(
            frontier: scope.frontier,
            arity: 3,
            workLimit: tuning.threeWayNumericWorkLimit
        )
        let budget = canTryThree ? max(1, tuning.stagedJointProbeBudget / 2) : tuning.stagedJointProbeBudget
        return (
            StagedJointSearch(
                frontier: scope.frontier,
                canTryThree: canTryThree,
                remaining: tuning.stagedJointProbeBudget,
                calculationsRemaining: tuning.numericJointGroupCalculationLimit
            ),
            .exchange(.stagedNumericPairs(scope.pairs, probeBudget: budget)),
            budget
        )
    }

    /// Prepares one higher-arity stage without changing the original reservation rules or rebuilding the frontier.
    private mutating func nextStagedJointOperation(search: inout StagedJointSearch) -> (operation: GraphOperation, budget: Int)? {
        guard search.nextArity <= 4,
              search.canTryThree,
              search.remaining > 0,
              search.calculationsRemaining > 0,
              isDeadlineExceeded() == false
        else {
            return nil
        }
        let arity = search.nextArity
        let threshold = arity == 3 ? tuning.threeWayNumericWorkLimit : tuning.fourWayNumericWorkLimit
        let scope = NumericJointQuery.build(
            frontier: search.frontier,
            graph: graph,
            arity: arity,
            workLimit: threshold,
            calculationLimit: search.calculationsRemaining,
            scopeLimit: tuning.numericJointScopeLimit
        )
        search.calculationsRemaining -= scope.calculations
        guard scope.groups.isEmpty == false else {
            return nil
        }
        let reserveFour = arity == 3 && search.calculationsRemaining > 0
            && NumericJointQuery.canEscalate(frontier: search.frontier, arity: 4, workLimit: tuning.fourWayNumericWorkLimit)
        let budget = reserveFour ? max(1, search.remaining / 2) : search.remaining
        search.nextArity += 1
        return (.exchange(.numericJoint(scope.groups, probeBudget: budget)), budget)
    }

    /// Avoids higher-order preparation entirely when escalation is disabled.
    private func numericJointFrontier() -> [NumericJointQuery.Entry] {
        guard tuning.threeWayNumericWorkLimit > 0,
              tuning.numericJointGroupCalculationLimit > 0,
              tuning.numericJointScopeLimit > 0
        else { return [] }
        return NumericJointQuery.frontier(graph: graph, gate: convergence.gate)
    }
}

/// Captures the exhausted checkpoint, including frontier changes that can unlock a higher-order stage.
struct ExhaustedStagedJointScope {
    let base: ChoiceSequence
    let pairs: [NumericPairQuery.Pair]
    let frontier: [NumericJointQuery.Entry]
}

/// Retains one checkpoint's frontier and reservation state while its current encoder is stepped.
struct StagedJointSearch {
    let frontier: [NumericJointQuery.Entry]
    let canTryThree: Bool
    var remaining: Int
    var calculationsRemaining: Int
    var nextArity: Int = 3
}
