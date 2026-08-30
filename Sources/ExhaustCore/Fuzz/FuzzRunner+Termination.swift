// The run-wide stop conditions of the fuzz loop.

extension FuzzRunner {
    // MARK: - Termination Checks

    /// The run-wide stop conditions every phase checks: wall clock and the testing attempt limit.
    func terminationDue() -> FuzzTermination? {
        if configuration.stopOnFirstFault, inventory.clusterCount > 0 {
            return .firstFaultFound
        }
        if let limit = configuration.attemptLimit, counts.totalAttempts >= limit {
            return .attemptLimitReached
        }
        if monotonicNanoseconds() - startNanoseconds >= configuration.budgetNanoseconds {
            return .budgetExhausted
        }
        // Fail fast rather than spend the budget: a run recording nothing is not searching, and the user asked for minutes. The threshold governs only how early the run stops; run() reports coverageUnreachable for any zero-edge run whatever ended it.
        if source.reportsLiveCoverage,
           sawAnyEdge == false,
           counts.totalAttempts >= FuzzTunables.coverageUnreachableAttemptThreshold
        {
            return .coverageUnreachable
        }
        return nil
    }

    /// Remaining attempts under the testing limit, as a screening budget bound.
    func remainingAttemptBudget() -> UInt64 {
        guard let limit = configuration.attemptLimit else {
            return UInt64.max
        }
        return UInt64(max(0, limit - counts.totalAttempts))
    }
}
