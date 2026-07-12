// Central home for the sprawl search's tunable constants.
//
// Every value here is an eyeballed default pending empirical tuning against the ExploreHarness fixtures. Keeping them in one namespace makes the tuning surface visible and keeps magic numbers out of the search loop.

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

    /// Wall-clock deadline for one concurrent reduction. Mirrors #exhaust's scaling but is bounded: sprawl reductions run concurrently with exploration and must not outlive the end-of-run drain.
    package static let reductionDeadlineNanoseconds: UInt64 = 5_000_000_000

    /// End-of-run wait for outstanding reduction tasks: twice ``reductionDeadlineNanoseconds``, so a reduction dispatched at the moment the budget expired can run its full deadline and still drain, with equal slack for classification hand-back. Leftovers are cancelled and reported as unreduced.
    package static let reductionDrainTimeoutNanoseconds: UInt64 = reductionDeadlineNanoseconds * 2

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

    // MARK: - Crash Recovery

    /// Interval between progress-log checkpoints. A crash loses at most this window of corpus growth; discovered clusters additionally force a checkpoint on classification.
    package static let checkpointIntervalNanoseconds: UInt64 = 30_000_000_000

    /// Progress logs older than this are ignored at resume: long enough to survive overnight runs, short enough not to surprise a user a week later.
    package static let progressLogStalenessSeconds: Double = 86400

    // MARK: - Report-Time Discrimination

    /// Discriminating edges reported per cluster. Beyond a handful, the ranking's tail is noise against small failing samples.
    package static let discriminatingEdgeLimit = 5

    /// Passing signatures (highest Jaccard similarity to the cluster's necessary edges) compared in the near-miss differential.
    package static let nearMissComparisonCount = 3

    // MARK: - Reduction Backpressure

    /// Reduced instances per cluster before further symptom-matched failures are recorded unreduced.
    package static let perClusterReductionCap = 5

    /// Every K-th symptom-matched failure is reduced anyway once the cap is reached, bounding the risk of a new bug hiding behind a familiar symptom.
    package static let reductionEscapeInterval = 50

    /// Upper bound on concurrently running reduction Tasks; overflow queues FIFO.
    package static var maxConcurrentReductions: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
    }

    // MARK: - Power Schedule (Experiment: powerSchedule)

    /// Upper bound on the children one parent pick may spawn under the power schedule. AFLFast's energy formula grows exponentially with revisits; the cap keeps a favored parent from monopolizing whole plateau windows.
    package static let powerScheduleEnergyCap = 16

    /// Bound on the exponent in the power schedule's `2^s` term, so the arithmetic saturates at the cap instead of overflowing on long runs.
    package static let powerScheduleExponentLimit = 10

    // MARK: - Swarm Generation (Experiment: swarm)

    /// Sprawl attempts per swarm epoch. Attempts-based rather than wall-clock so the epoch schedule replays deterministically under a pinned seed regardless of machine load.
    package static let swarmEpochAttempts = 2048

    // MARK: - Spec-Specific Defaults

    /// Consecutive samples without a novel edge before random sampling is considered saturated for spec runs. Lower than the value path because spec attempts are orders of magnitude more expensive.
    package static let specSamplingPlateauWindow = 200

    /// Wall-clock deadline for one spec reduction. Higher than the value path because a spec reduction probe replays a whole command sequence against a fresh SUT.
    package static let specReductionDeadlineNanoseconds: UInt64 = reductionDeadlineNanoseconds * 4

    /// Maximum commands per generated sequence when `#execute(time:)` is not given an explicit `.commandLimit`. Sequence length is half the trigger for accumulation faults — a short default silently suppresses the class this mode targets — so the default is a fixed, visible constant rather than a heuristic, matching the length the SW2a calibration sweep ran at.
    package static let specDefaultCommandLimit = 40

    // MARK: - Escape-Hatch Backoff (Experiment: escapeBackoff)

    /// Upper bound on the adaptive escape interval. The interval doubles each time an escape reduction lands in an existing cluster, so without a cap a long run would stop escaping entirely — and the escape hatch exists precisely because symptom matching is a weak signal.
    package static let reductionEscapeIntervalCap = 3200
}

// MARK: - Experiment Knobs

/// Per-run switches for mechanisms that land benchmark-gated.
///
/// Every new search-side mechanism ships behind one of these knobs, default-off, and flips on only when its measured gate passes (the knob-gate-default pattern). In-package tests reach them through the `configure:` seam on `runExploreTimeCore`; cross-package benchmark arms ride the `EXHAUST_SPRAWL_EXPERIMENT` environment variable, which debug builds parse once at run start via ``parse(environmentValue:)``.
package struct SprawlExperiments: Sendable, Equatable {
    /// Post-reduction cluster normalization: re-drive each value of a would-be-new cluster's reduced form toward its minimal still-failing bit pattern before minting the cluster. Default-on; the knob stays one release for A/B.
    package var normalization = true

    /// Adaptive reduction-gate escape interval: coverage-novel failures escape immediately; periodic escapes that land in an existing cluster widen the interval geometrically, and new-cluster escapes reset it. Default-on; the knob stays one release for A/B.
    package var escapeBackoff = true

    /// Stacked mutation: one sprawl child may compose several mutation operators instead of exactly one.
    package var stackedMutation = false

    /// Bandit-tuned mutation band weights over {low, medium, high, splice}, rewarded by corpus admission.
    package var banditBands = false

    /// AFLFast-style power schedule for the number of children drawn per picked parent.
    package var powerSchedule = false

    /// Per-edge shortlex champion archive as the parent-selection domain. Default-on; the knob stays one release for A/B.
    package var championArchive = true

    /// Swarm generation: per-epoch deterministic branch masks pivot mutated children's disallowed branch selections, reaching command mixes the uniform distribution statistically suppresses.
    package var swarm = false

    /// Creates the default knob set: gated mechanisms off until their gates pass.
    package init() {}

    /// A parse failure with the offending fragment, rendered into the run's configuration error. Silent typos would invalidate benchmark arms, so unknown knobs are a hard error rather than a warning.
    package struct ParseError: Error, CustomStringConvertible {
        package let description: String
    }

    /// Parses an `EXHAUST_SPRAWL_EXPERIMENT` value like `stackedMutation=on,banditBands=off` on top of the defaults.
    ///
    /// - Throws: ``ParseError`` on an unknown knob name or a value other than `on`/`off`.
    package static func parse(environmentValue: String) throws -> SprawlExperiments {
        var experiments = SprawlExperiments()
        let assignments: [(String, WritableKeyPath<SprawlExperiments, Bool>)] = [
            ("normalization", \.normalization),
            ("escapeBackoff", \.escapeBackoff),
            ("stackedMutation", \.stackedMutation),
            ("banditBands", \.banditBands),
            ("powerSchedule", \.powerSchedule),
            ("championArchive", \.championArchive),
            ("swarm", \.swarm),
        ]
        for fragment in environmentValue.split(separator: ",") {
            let parts = fragment.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                throw ParseError(description: "EXHAUST_SPRAWL_EXPERIMENT fragment '\(fragment)' is not of the form knob=on|off.")
            }
            guard let keyPath = assignments.first(where: { $0.0 == parts[0] })?.1 else {
                let known = assignments.map(\.0).joined(separator: ", ")
                throw ParseError(description: "EXHAUST_SPRAWL_EXPERIMENT names unknown knob '\(parts[0])'. Known knobs: \(known).")
            }
            switch parts[1] {
                case "on":
                    experiments[keyPath: keyPath] = true
                case "off":
                    experiments[keyPath: keyPath] = false
                default:
                    throw ParseError(description: "EXHAUST_SPRAWL_EXPERIMENT knob '\(parts[0])' has value '\(parts[1])'; expected on or off.")
            }
        }
        return experiments
    }
}
