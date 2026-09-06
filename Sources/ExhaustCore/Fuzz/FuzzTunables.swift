// Central home for the fuzz search's tunable constants.
//
// Values land as eyeballed defaults and graduate as they are measured; several below carry their own measurement provenance (the plateau floor's worked example, the spec command limit's calibration sweep, the splice probability's AFL citation). A constant without such a note is still an eyeballed default. Keeping them in one namespace makes the tuning surface visible and keeps magic numbers out of the search loop.

import Foundation

/// Houses the tunable constants governing `#explore(time:)` search dynamics.
package enum FuzzTunables {
    // MARK: - Corpus

    /// Convergence threshold τ separating the mutable tier from the discovery tier.
    ///
    /// The tier is a length guard for the champion archive, not a judgement of the entry as a parent. A child that resolved mostly through the PRNG is short, the archive orders champions by shortlex, and a short entry claims many cells at once and evicts the longer incumbents holding them. Measured 2026-09-06 (`fuzz-loop-experiments-2026-09-06.md`): admitting every entry as a parent cost IFC 3.1% of covered edges and 4.5% of its parent pool while the corpus stayed flat, with parent length down 4.1%. Keeping low-convergence entries out of the archive holds the pool off the shortlex floor.
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

    // MARK: - Phase 1 (Screening)

    /// Rows the screening pass may draw from the covering array before sampling begins. The pass has never detected a fault on the Etna register machine, but its boundary rows seed the only fully populated memories the corpus sees, so the number trades a few hundred milliseconds against reach into memory-operation faults; 1,000 keeps most of that reach at a tenth of the original 10,000's cost. `EXHAUST_SCREENING_BUDGET` overrides it for measurement.
    package static let screeningBudget: UInt64 = ProcessInfo.processInfo.environment["EXHAUST_SCREENING_BUDGET"].flatMap(UInt64.init) ?? 1000

    // MARK: - Phase 2 (Random Sampling) Stopping

    /// Consecutive samples without a novel edge before random sampling is considered saturated and the mutation phase begins.
    package static let samplingPlateauWindow = 1000

    /// Fraction of the wall-clock budget Phase 2 may consume before the mutation phase begins regardless of plateau — a trickle of novelty must not starve Phase 3.
    package static let samplingTimeBackstopFraction = 0.10

    // MARK: - Phase 3 (Mutation) Stopping

    /// Per-attempt probability of covering a new edge below which an opt-in run is considered saturated and ends early. At 1e-4, the run stops once the next attempt has worse than a 1 in 10,000 chance of reaching an edge nothing has reached yet.
    ///
    /// Denominated per attempt, the same unit the report prints as "estimated chance the next attempt covers a new edge", so the setting and the line a reader acts on cannot disagree. The underlying estimator is per incidence; the conversion multiplies by the mean edges an attempt covers.
    ///
    /// Böhme's STADS (§2.1) is why an estimate replaced a stopwatch here. Time since the last discovery swings by four orders of magnitude within a single campaign and is not a consistent estimator of anything; this form is consistent as the sample grows.
    ///
    /// Calibrated against a scheduled MetaFuzz run that catalogued no fault clusters in 1,519,713 evaluated attempts and reported 1 in 10,064, with 676 of 9,381 reachable edges still uncovered. That run sits just inside the threshold, which is the intended reading: a campaign that unproductive should hand its remaining budget back.
    package static let saturationNextEdgeProbability = 1e-4

    /// Attempts between saturation checks. The estimate scans the per-edge incidence counters, which is O(edges), so it is sampled rather than computed per iteration.
    package static let saturationCheckInterval = 50000

    /// Attempts before the first saturation check. Below it the incidence sample is too small for the estimator to mean anything, and an empty incidence matrix reads as zero discovery probability, which would end a run on its first iteration.
    package static let saturationMinimumAttempts = 200_000

    /// Parent-selection weight multiplier for corpus entries the property discarded. FuzzChick (Lampropoulos, Hicks, Pierce 2019, §3.1) gives discards one third of a valid seed's energy: mutations of a near-miss are still the likeliest route to a valid input on a sparse precondition, but valid seeds are preferred because their mutations are likelier to stay valid.
    package static let discardParentEnergy = 1.0 / 3.0

    /// Maximum slots one comparand-substitution candidate may overwrite with the drawn operand. The count is drawn uniformly in 1...min(span, compatible slots): 1 preserves the single-slot magic-gate move, larger counts perform the agreement move for preconditions that require many positions to match at once. Kept small: each extra slot halves the chance that every overwritten position was one the comparison actually constrained.
    package static let comparandSubstitutionSlotSpan = 8

    /// Barren draws a comparand-substitution key gets before it is retired, and the allowance a yielding draw restores it to. A yield is a corpus admission or a failure: the arm can be worth its attempts through faults that light no new edge, so admission alone would retire it too early.
    package static let comparandOperandEnergy: UInt8 = 16

    /// Floor of the adaptive fresh-draw mixture: the probability that a mutation-loop iteration spends one fresh generator draw instead of a parent pick while the corpus is admitting. Fresh draws restore ergodicity the corpus cannot (they reach basins no entry has visited) at fresh-generation cost, so a healthy corpus keeps only a background rate.
    package static let freshMixtureFloor = 0.05

    /// Cap of the adaptive fresh-draw mixture, reached when the corpus has admitted nothing for a full ramp. The default sits at the measured dose-response knee: on basin-fragmented workloads a starved run climbs to spending most of its budget on fresh draws, matching the exploration share FuzzChick reaches through queue starvation.
    package static let freshMixtureCap = 0.6

    /// Attempts without a corpus admission over which the mixture climbs linearly from floor to cap.
    package static let freshMixtureRampAttempts = 2000.0

    // MARK: - Crash Recovery

    /// Interval between progress-log checkpoints. A crash loses at most this window of corpus growth; discovered clusters additionally force a checkpoint on classification.
    package static let checkpointIntervalNanoseconds: UInt64 = 30_000_000_000

    /// Progress logs older than this are ignored at resume: long enough to survive overnight runs, short enough not to surprise a user a week later.
    package static let progressLogStalenessSeconds: Double = 86400

    // MARK: - Report-Time Discrimination

    /// Discriminating source locations reported per cluster. Beyond a handful, the ranking's tail is noise against small failing samples.
    package static let discriminatingEdgeLimit = 5

    /// Ranked edges handed to the report per cluster before it folds them by source location and keeps ``discriminatingEdgeLimit``. One function usually ranks at several offsets (one IFC cluster ranked a single getter at five), so the pool has to be wider than the printed list for the list to name more than one or two functions.
    package static let discriminatingEdgeCandidateLimit = 40

    // MARK: - Reduction Backpressure

    /// Reduced instances per cluster before further symptom-matched failures are recorded unreduced.
    package static let perClusterReductionCap = 5

    /// Starting escape interval: the first symptom-matched failure past the cap that is reduced anyway, bounding the risk of a new bug hiding behind a familiar symptom. Later escapes widen it geometrically up to ``reductionEscapeIntervalCap``.
    package static let reductionEscapeInterval = 50

    /// Upper bound on the adaptive escape interval. The interval doubles each time an escape reduction lands in an existing cluster, so without a cap a long run would stop escaping entirely, and the escape hatch exists precisely because symptom matching is a weak signal.
    package static let reductionEscapeIntervalCap = 3200

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

    // MARK: - Graph Mutation (Experiment: graphMutation)

    /// Exclusive upper bound on the log-uniform exponent draw for the lockstep delta: `delta = 1 + next(2^exponent)` with `exponent < 11`, so most deltas are small agreement-preserving steps and the occasional draw jumps by up to ~2^10.
    package static let lockstepDeltaExponentLimit: UInt64 = 11

    // MARK: - Crash Recovery

    /// Budget at or above which the crash breadcrumb records each candidate's own choice sequence, so a resumed run can show the trapping input instead of naming it by hash and quarantining its parent.
    ///
    /// The recording costs about 8% of candidate throughput at any budget, because the encode and the copy into the slot run inside every property invocation's bracket (on the Etna IFC type-based workload, property time went from 0.8 to 4.1 microseconds per evaluated case). What the budget changes is the value of having the input: a short run is cheap to reproduce by running it again, and a long campaign is not.
    ///
    /// - Note: Throughput therefore steps down at this boundary. A run just under it searches about 8% faster than one just over.
    package static let trapCandidateBudgetFloor: UInt64 = 10 * 60 * 1_000_000_000

    // MARK: - Coverage Reachability

    /// Attempts to allow before concluding that an instrumented build is recording nothing.
    ///
    /// Comfortably past the screening phase, so a run is judged on evaluations spanning all three phases rather than on a handful of covering-array rows.
    package static let coverageUnreachableAttemptThreshold = 1000
}

// MARK: - Experiment Knobs

/// Per-run switches for the mechanisms a benchmark arm can still hold off.
///
/// A knob exists only while its off path is worth measuring against: the arm inventory (bandit, graph, and pair operators) and the swarm rewrite. Mechanisms whose off path lost its last measurement (uniform parent selection, the binary swarm mask, the power schedule, campaigns, the reseed burst, the fixed escape cadence, and the knob-off variants of normalization, candidate dedup, and the champion archive) were deleted rather than left switchable. In-package tests reach the knobs through the `configure:` option on `runExploreTimeCore`; cross-package benchmark arms ride the `EXHAUST_FUZZ_EXPERIMENT` environment variable, which debug builds parse once at run start via ``parse(environmentValue:)``.
package struct FuzzExperiments: Sendable, Equatable {
    /// Bandit-tuned mutation band weights over the enabled arm inventory, rewarded by corpus admission.
    package var banditBands = true

    /// Graph-targeted mutation operators (sibling-span swap, shuffle, and move plus the tandem lockstep delta) drawn from the admission-time scope caches. Adds the four arms to the pick inventory: the bandit's when `banditBands` is on, the fixed distribution's otherwise.
    package var graphMutation = true

    /// Pair mutation operators: the twin splice (copy one zip twin's span over its sibling's, creating structural agreement) and the typed crossover (replace a pick subtree with a same-fingerprint span from a different corpus entry). Adds the two arms to the pick inventory the same way `graphMutation` adds its four.
    package var pairMutation = true

    /// How swarm generation rewrites a mutated child's branch selections.
    package enum SwarmMode: String, Sendable {
        /// No swarm rewrite: mutated children keep the uniform branch mix.
        case off
        /// Per-attempt continuous activation weights: each branch is thinned by a weight rather than excluded, so mutated children reach command mixes at specific ratios a binary mask cannot.
        case activated
    }

    /// The swarm generation mode. Defaults to ``SwarmMode/activated`` — the diversity gain over no swarm is robust (~1.7x more distinct fault shapes) at no measurable throughput cost. Set `swarmMode=off` to disable swarm generation. See ADR 0006.
    package var swarmMode: SwarmMode = .activated

    /// Creates the default knob set, which is ``shipped``.
    package init() {}

    /// The configuration a release actually runs: every knob on.
    ///
    /// The knobs are independent, so the type describes more configurations than anyone runs. Name the configuration a claim is about and point at this: it is the one the defaults produce and the one an unqualified statement means. ``parse(environmentValue:)`` reads as a delta from here.
    package static let shipped = FuzzExperiments()

    /// Every knob off: the baseline a benchmark arm measures a mechanism against.
    ///
    /// Written through ``knobs`` rather than field by field, so a knob added to one and forgotten in the other is not possible.
    package static let legacy: FuzzExperiments = {
        var experiments = FuzzExperiments()
        for (_, keyPath) in knobs {
            experiments[keyPath: keyPath] = false
        }
        experiments.swarmMode = .off
        return experiments
    }()

    /// The on/off knobs by their `EXHAUST_FUZZ_EXPERIMENT` name. ``swarmMode`` is absent: it is the one multi-state knob and parses off its enum.
    ///
    /// Computed rather than stored: a `WritableKeyPath` is not `Sendable`, so a stored static of these is rejected as shared mutable state. It is read twice per run, at parse and when ``legacy`` is built, so the rebuild costs nothing that matters.
    package static var knobs: [(name: String, keyPath: WritableKeyPath<FuzzExperiments, Bool>)] {
        [
            ("banditBands", \.banditBands),
            ("graphMutation", \.graphMutation),
            ("pairMutation", \.pairMutation),
        ]
    }

    /// A parse failure with the offending fragment, rendered into the run's configuration error. Silent typos would invalidate benchmark arms, so unknown knobs are a hard error rather than a warning.
    package struct ParseError: Error, CustomStringConvertible {
        package let description: String
    }

    /// Parses an `EXHAUST_FUZZ_EXPERIMENT` value like `graphMutation=on,banditBands=off` as a delta from ``shipped``.
    ///
    /// - Throws: ``ParseError`` on an unknown knob name or a value other than `on`/`off`.
    package static func parse(environmentValue: String) throws -> FuzzExperiments {
        var experiments = FuzzExperiments.shipped
        let assignments = knobs
        for fragment in environmentValue.split(separator: ",") {
            let parts = fragment.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                throw ParseError(description: "EXHAUST_FUZZ_EXPERIMENT fragment '\(fragment)' is not of the form knob=value.")
            }
            // swarmMode is the one multi-state knob, so it parses off the enum rather than the on/off table.
            if parts[0] == "swarmMode" {
                guard let mode = SwarmMode(rawValue: parts[1]) else {
                    throw ParseError(description: "EXHAUST_FUZZ_EXPERIMENT knob 'swarmMode' has value '\(parts[1])'; expected off or activated.")
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
