// Central home for the fuzz search's tunable constants.
//
// Values land as eyeballed defaults and graduate as they are measured; several below carry their own measurement provenance (the plateau floor's worked example, the spec command limit's calibration sweep, the splice probability's AFL citation). A constant without such a note is still an eyeballed default. Keeping them in one namespace makes the tuning surface visible and keeps magic numbers out of the search loop.

import Foundation

/// Houses the tunable constants governing `#explore(time:)` search dynamics.
package enum FuzzTunables {
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

    // MARK: - Fuzz Loop

    /// Wall-clock deadline for one inline reduction. Mirrors #exhaust's scaling but is bounded: reductions run inline on the loop's lane and displace attempts, so one pathological reduction must not eat the budget.
    package static let reductionDeadlineNanoseconds: UInt64 = 3_000_000_000

    /// Mutations drawn from a picked parent before the loop re-picks. Amortises the weighted pick without letting one parent dominate.
    package static let childrenPerParent = 4

    /// Probability that a mutation candidate is a bind-boundary splice with a random donor instead of a single-parent mutation. AFL's splicing yields roughly 10–15% of paths in extended runs; the starting weight matches.
    package static let spliceProbability = 0.125

    // MARK: - Phase 2 (Random Sampling) Stopping

    /// Consecutive samples without a novel edge before random sampling is considered saturated and the mutation phase begins.
    package static let samplingPlateauWindow = 1000

    /// Fraction of the wall-clock budget Phase 2 may consume before the mutation phase begins regardless of plateau — a trickle of novelty must not starve Phase 3.
    package static let samplingTimeBackstopFraction = 0.10

    // MARK: - Phase 3 (Mutation) Stopping

    /// Fraction of the wall-clock budget without a discovery before the run ends early and returns the unused budget.
    ///
    /// A discovery is a new edge or a newly classified fault cluster, not a corpus admission. Admission also fires on a new hit-count bucket for an already-covered edge, which is right for keeping a mutation parent and wrong for deciding a run is finished: on a fixed generator the last new edge can arrive within a second while admissions trickle in for minutes afterwards.
    package static let plateauBudgetFraction = 0.25

    /// Floor on the plateau window, whatever the budget.
    ///
    /// Without it the window is purely proportional, so a short budget is impatient exactly when it can least afford to be. A 60-second run allowed 15 seconds and abandoned a fault that arrived at 15.14; the same seed under a 300-second budget found it. Faults also outlive coverage by a wide margin — one target's last new edge landed at 0.65 seconds and its last new cluster at 18.98 — so the floor is set above the largest such gap observed rather than tuned to a single case.
    /// Capped at half the budget where that is smaller, so the rule stays able to fire on short runs.
    package static let plateauFloorNanoseconds: UInt64 = 30_000_000_000

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

    // MARK: - Power Schedule (Experiment: powerSchedule)

    /// Upper bound on the children one parent pick may spawn under the power schedule. AFLFast's energy formula grows exponentially with revisits; the cap keeps a favored parent from monopolizing whole plateau windows.
    package static let powerScheduleEnergyCap = 16

    /// Bound on the exponent in the power schedule's `2^s` term, so the arithmetic saturates at the cap instead of overflowing on long runs.
    package static let powerScheduleExponentLimit = 10

    // MARK: - Swarm Generation (Experiment: swarmMode)

    /// Fuzz attempts per swarm epoch. Attempts-based rather than wall-clock so the epoch schedule replays deterministically under a pinned seed regardless of machine load.
    package static let swarmEpochAttempts = 2048

    // MARK: - Comparison Injection

    /// Component positions the field graft may target on a composite. trace-cmp reports the operand and its call site but not which field the comparison read, so the graft sprays positions; an out-of-range or non-reconstructable position is a cheap miss. Kept small: most initializer-shaped composites have few fields, and a wide span dilutes the graft with positions that never fit.
    package static let reflectionGraftPositionSpan = 8

    // MARK: - Spec-Specific Defaults

    /// Consecutive samples without a novel edge before random sampling is considered saturated for spec runs. Lower than the value path because spec attempts are orders of magnitude more expensive.
    package static let specSamplingPlateauWindow = 200

    /// Wall-clock deadline for one spec reduction. Higher than the value path because a spec reduction probe replays a whole command sequence against a fresh SUT.
    package static let specReductionDeadlineNanoseconds: UInt64 = reductionDeadlineNanoseconds * 4

    /// Maximum commands per generated sequence when `#explore(Spec.self, time:)` is not given an explicit `.commandLimit`. Sequence length is half the trigger for accumulation faults — a short default silently suppresses the class this mode targets — so the default is a fixed, visible constant rather than a heuristic, matching the length the SW2a calibration sweep ran at.
    package static let specDefaultCommandLimit = 40

    // MARK: - Escape-Hatch Backoff (Experiment: escapeBackoff)

    /// Upper bound on the adaptive escape interval. The interval doubles each time an escape reduction lands in an existing cluster, so without a cap a long run would stop escaping entirely — and the escape hatch exists precisely because symptom matching is a weak signal.
    package static let reductionEscapeIntervalCap = 3200

    // MARK: - Coverage Reachability

    /// Attempts to allow before concluding that an instrumented build is recording nothing.
    ///
    /// Comfortably past the screening phase, so a run is judged on evaluations spanning all three phases rather than on a handful of covering-array rows.
    package static let coverageUnreachableAttemptThreshold = 1000
}

// MARK: - Experiment Knobs

/// Per-run switches for mechanisms that land benchmark-gated.
///
/// Every new search-side mechanism ships behind one of these knobs, default-off, and flips on only when its measured gate passes (the knob-gate-default pattern). In-package tests reach them through the `configure:` seam on `runExploreTimeCore`; cross-package benchmark arms ride the `EXHAUST_FUZZ_EXPERIMENT` environment variable, which debug builds parse once at run start via ``parse(environmentValue:)``.
package struct FuzzExperiments: Sendable, Equatable {
    /// Post-reduction cluster normalization: re-drive each value of a would-be-new cluster's reduced form toward its minimal still-failing bit pattern before minting the cluster. Default-on; the knob stays one release for A/B.
    package var normalization = true

    /// Adaptive reduction-gate escape interval: coverage-novel failures escape immediately; periodic escapes that land in an existing cluster widen the interval geometrically, and new-cluster escapes reset it. Default-on; the knob stays one release for A/B.
    package var escapeBackoff = true

    /// Stacked mutation: one mutation-phase child may compose several mutation operators instead of exactly one.
    package var stackedMutation = false

    /// Bandit-tuned mutation band weights over {low, medium, high, splice}, rewarded by corpus admission.
    package var banditBands = false

    /// AFLFast-style power schedule for the number of children drawn per picked parent.
    package var powerSchedule = false

    /// Per-edge shortlex champion archive as the parent-selection domain. Default-on; the knob stays one release for A/B.
    package var championArchive = true

    /// How swarm generation rewrites a mutated child's branch selections.
    package enum SwarmMode: String, Sendable {
        /// No swarm rewrite: mutated children keep the uniform branch mix.
        case off
        /// Legacy per-epoch binary mask: each pick site's branches are hard-allowed or hard-excluded for an epoch, and a disallowed selection is pivoted to an allowed one.
        case binary
        /// Per-attempt continuous activation weights: each branch is thinned by a weight rather than excluded, so mutated children reach command mixes at specific ratios a binary mask cannot.
        case activated
    }

    /// The swarm generation mode. Defaults to ``SwarmMode/activated`` — the diversity gain over no swarm is robust (~1.7x more distinct fault shapes) at no measurable throughput cost. Set `swarmMode=off` to disable swarm generation, or `swarmMode=binary` for the legacy per-epoch mask. See ADR 0006.
    package var swarmMode: SwarmMode = .activated

    /// Creates the default knob set: mechanisms whose gates passed default on (`normalization`, `escapeBackoff`, `championArchive`, and the activated swarm mode); the rest stay off until theirs do.
    package init() {}

    /// A parse failure with the offending fragment, rendered into the run's configuration error. Silent typos would invalidate benchmark arms, so unknown knobs are a hard error rather than a warning.
    package struct ParseError: Error, CustomStringConvertible {
        package let description: String
    }

    /// Parses an `EXHAUST_FUZZ_EXPERIMENT` value like `stackedMutation=on,banditBands=off` on top of the defaults.
    ///
    /// - Throws: ``ParseError`` on an unknown knob name or a value other than `on`/`off`.
    package static func parse(environmentValue: String) throws -> FuzzExperiments {
        var experiments = FuzzExperiments()
        let assignments: [(String, WritableKeyPath<FuzzExperiments, Bool>)] = [
            ("normalization", \.normalization),
            ("escapeBackoff", \.escapeBackoff),
            ("stackedMutation", \.stackedMutation),
            ("banditBands", \.banditBands),
            ("powerSchedule", \.powerSchedule),
            ("championArchive", \.championArchive),
        ]
        for fragment in environmentValue.split(separator: ",") {
            let parts = fragment.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                throw ParseError(description: "EXHAUST_FUZZ_EXPERIMENT fragment '\(fragment)' is not of the form knob=value.")
            }
            // swarmMode is the one multi-state knob, so it parses off the enum rather than the on/off table.
            if parts[0] == "swarmMode" {
                guard let mode = SwarmMode(rawValue: parts[1]) else {
                    throw ParseError(description: "EXHAUST_FUZZ_EXPERIMENT knob 'swarmMode' has value '\(parts[1])'; expected off, binary, or activated.")
                }
                experiments.swarmMode = mode
                continue
            }
            guard let keyPath = assignments.first(where: { $0.0 == parts[0] })?.1 else {
                let known = (assignments.map { $0.0 } + ["swarmMode"]).joined(separator: ", ")
                throw ParseError(description: "EXHAUST_FUZZ_EXPERIMENT names unknown knob '\(parts[0])'. Known knobs: \(known).")
            }
            switch parts[1] {
                case "on":
                    experiments[keyPath: keyPath] = true
                case "off":
                    experiments[keyPath: keyPath] = false
                default:
                    throw ParseError(description: "EXHAUST_FUZZ_EXPERIMENT knob '\(parts[0])' has value '\(parts[1])'; expected on or off.")
            }
        }
        return experiments
    }
}
