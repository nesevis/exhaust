extension ReductionMachine {
    /// Returns a fresh scope only when its base or domains differ from the exhausted search.
    func pendingNumericPairs() -> [NumericPairQuery.Pair]? {
        guard tuning.pairwiseNumericProbeBudget > 0,
              enabledEncoders?.contains(.pairwiseNumericSearch) != false,
              convergence.deferBindInner == false
        else {
            return nil
        }
        let pairs = NumericPairQuery.build(graph: graph, gate: convergence.gate)
        guard pairs.isEmpty == false,
              exhaustedNumericPairScope?.base != sequence || exhaustedNumericPairScope?.pairs != pairs
        else {
            return nil
        }
        return pairs
    }

    /// Runs the bounded numeric pair search as a post-cycle pass. Every accepted probe precedes the current sequence, so it runs even after an earlier post-cycle action has accepted.
    ///
    /// An acceptance invalidates every convergence floor, cached rejection, and bind search history, not only those of the edited pair: the property can couple values the generator treats as independent.
    mutating func runPairwiseNumericSearch() throws -> Bool {
        guard isDeadlineExceeded() == false,
              let pairs = pendingNumericPairs()
        else {
            return false
        }
        exhaustedNumericPairScope = ExhaustedNumericPairScope(base: sequence, pairs: pairs)
        guard let report = try runPostCycleEncoder(
            operation: .exchange(.numericPairs(pairs, probeBudget: tuning.pairwiseNumericProbeBudget)),
            estimatedCost: tuning.pairwiseNumericProbeBudget
        ) else {
            return false
        }
        guard report.anyAccepted else {
            return false
        }
        invalidateAfterCoupledAcceptance()
        return true
    }
}

/// The latest numeric pair scope searched. The search becomes eligible again once the counterexample or the eligible pair set changes.
struct ExhaustedNumericPairScope {
    let base: ChoiceSequence
    let pairs: [NumericPairQuery.Pair]
}
