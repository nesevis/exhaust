// Central home for the sprawl search's tunable constants.
//
// Every value here is an eyeballed default pending empirical tuning against the ExploreHarness
// fixture (see the design document's Open Questions). Keeping them in one namespace makes the
// tuning surface visible and keeps magic numbers out of the search loop.

import Foundation

/// Tunable constants for `#explore(time:)` search dynamics.
package enum SprawlTunables {
    // MARK: - Corpus

    /// Convergence threshold τ separating the mutable tier from the discovery tier. Entries at or above it inherit enough choice-sequence structure to be worth mutating; entries below it would mostly hit PRNG fallback, paying mutation cost for what amounts to fresh sampling.
    package static let mutableTierConvergenceThreshold = 0.5

    /// Weight of the novelty bonus term (α) in parent selection.
    package static let noveltyBonusWeight = 1.0

    // MARK: - Failure Weights

    /// Multiplier applied to a parent's selection weight immediately when one of its children fails, before reduction classifies the failure. Densification begins around the failure region without waiting for the reduction Task.
    package static let provisionalFailureBoost = 4.0

    /// Multiplier when the completed reduction created a new cluster — a fresh fault region worth densifying aggressively.
    package static let newClusterFailureBoost = 8.0

    /// Multiplier when the completed reduction joined an existing cluster. Decays as the cluster's instance count grows, and drops to 1 entirely once the cluster's reduction cap is reached.
    package static let existingClusterFailureBoost = 2.0

    // MARK: - Sprawl Loop

    /// Mutations drawn from a picked parent before the loop re-picks. Amortises the weighted pick without letting one parent dominate.
    package static let childrenPerParent = 4

    /// Probability that a sprawl candidate is a bind-boundary splice with a random donor instead of a single-parent mutation. AFL's splicing yields roughly 10–15% of paths in extended runs; the starting weight matches.
    package static let spliceProbability = 0.125

    // MARK: - Phase 2 (Random Sampling) Stopping

    /// Consecutive samples without a novel edge before random sampling is considered saturated and sprawl begins.
    package static let samplingPlateauWindow = 1000

    /// Fraction of the wall-clock budget Phase 2 may consume before sprawl begins regardless of plateau — a trickle of novelty must not starve Phase 3.
    package static let samplingTimeBackstopFraction = 0.10

    // MARK: - Phase 3 (Sprawl) Stopping

    /// Fraction of the wall-clock budget without a single coverage-novel corpus admission (across all intensity bands including splice) before the run ends early and returns the unused budget.
    package static let sprawlPlateauBudgetFraction = 0.25

    // MARK: - Reduction Backpressure

    /// Reduced instances per cluster before further symptom-matched failures are recorded unreduced.
    package static let perClusterReductionCap = 5

    /// Every K-th symptom-matched failure is reduced anyway once the cap is reached, bounding the risk of a new bug hiding behind a familiar symptom.
    package static let reductionEscapeInterval = 50

    /// Upper bound on concurrently running reduction Tasks; overflow queues FIFO.
    package static var maxConcurrentReductions: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
    }
}
