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

    /// Runs sequential numeric stages under one checkpoint budget. A higher arity is discovered only after the previous stage stalls and its sampled-work gate opens. Every accepted probe precedes the current sequence, so it runs even after an earlier post-cycle action has accepted.
    ///
    /// An acceptance invalidates every convergence floor, cached rejection, and bind search history, not only those of the edited pair: the property can couple values the generator treats as independent.
    mutating func runStagedJointSearch() -> Bool {
        guard isDeadlineExceeded() == false,
              let scope = pendingStagedNumericSearchScope()
        else {
            return false
        }
        let pairs = scope.pairs
        let frontier = scope.frontier
        exhaustedStagedJointScope = ExhaustedStagedJointScope(base: sequence, pairs: pairs, frontier: frontier)
        let canTryThree = NumericJointQuery.canEscalate(
            frontier: frontier,
            arity: 3,
            workLimit: tuning.threeWayNumericWorkLimit
        )
        var remaining = tuning.stagedJointProbeBudget
        let pairBudget = canTryThree ? max(1, remaining / 2) : remaining
        guard let report = runPostCycleEncoder(
            operation: .exchange(.stagedNumericPairs(pairs, probeBudget: pairBudget)),
            estimatedCost: pairBudget
        ) else {
            return false
        }
        if report.anyAccepted {
            invalidateAfterCoupledAcceptance()
            return true
        }
        remaining -= report.probeCount
        var calculationsRemaining = tuning.numericJointGroupCalculationLimit
        for arity in 3 ... 4 {
            guard canTryThree, remaining > 0, calculationsRemaining > 0, isDeadlineExceeded() == false else { break }
            let threshold = arity == 3 ? tuning.threeWayNumericWorkLimit : tuning.fourWayNumericWorkLimit
            let scope = NumericJointQuery.build(
                frontier: frontier,
                graph: graph,
                arity: arity,
                workLimit: threshold,
                calculationLimit: calculationsRemaining,
                scopeLimit: tuning.numericJointScopeLimit
            )
            calculationsRemaining -= scope.calculations
            guard scope.groups.isEmpty == false else { break }
            let reserveFour = arity == 3 && calculationsRemaining > 0
                && NumericJointQuery.canEscalate(frontier: frontier, arity: 4, workLimit: tuning.fourWayNumericWorkLimit)
            let stageBudget = reserveFour ? max(1, remaining / 2) : remaining
            guard let jointReport = runPostCycleEncoder(
                operation: .exchange(.numericJoint(scope.groups, probeBudget: stageBudget)),
                estimatedCost: stageBudget
            ) else { break }
            remaining -= jointReport.probeCount
            if jointReport.anyAccepted {
                invalidateAfterCoupledAcceptance()
                return true
            }
        }
        return false
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
