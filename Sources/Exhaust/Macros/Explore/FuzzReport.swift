// The public result type of a `#explore(time:)` run.

import ExhaustCore

/// The outcome of a `#explore(time:)` coverage-guided run: a clustered fault inventory plus throughput and coverage statistics.
///
/// A `time:` run catalogues failures instead of stopping at the first one, so the report carries every distinct fault cluster the run discovered. Assert on ``clusters`` when a run is expected to find bugs (combine with `.suppress(.issueReporting)`), or on ``termination`` and the attempt counts when validating search behavior.
///
/// - Important: This mode is experimental. Its settings, report format, and search behavior may change in any release; every call site emits a build warning until the mode stabilizes.
public struct FuzzReport: Sendable {
    /// One distinct fault the run discovered: a unique reduced counterexample with its membership counts.
    ///
    /// Cluster identity is a canonical structural key over the reduced counterexample, so two failures that reduce to the same minimal form are the same cluster even when their surface symptoms differ, and distinct reduced forms are distinct clusters even when their symptoms match. ``isLikelySplit`` marks the middle taxonomy tier — one reduced form observed through more than one coverage signature.
    public struct Cluster: Sendable {
        /// Stable identifier in discovery order, starting at 0.
        public let id: Int

        /// A rendered description of the canonical reduced counterexample.
        public let reducedDescription: String

        /// The symptoms observed across this cluster's members: thrown error type names, or `"returnedFalse"` for properties that returned `false`.
        public let symptoms: [String]

        /// Total failures attributed to this cluster, reduced or not.
        public let instanceCount: Int

        /// Members that went through reduction. Bounded by the per-cluster reduction cap, so a hot fault reads "214 instances, 5 reduced".
        public let reducedCount: Int

        /// Members whose own reduced form stalled short of the canonical one (an uncleared flag bit, an unclamped byte) and joined this cluster through the normalization pass. Without normalization each distinct stall would appear as its own spurious cluster; a high count relative to ``reducedCount`` means reduction stalls often on this fault, not that more faults exist.
        public let unnormalizedMemberCount: Int

        /// True when the reduced form was reached through more than one coverage signature — the same surface bug, possibly via different code paths. Worth a glance; a distinct cluster is worth an investigation.
        public let isLikelySplit: Bool

        /// The phase that first created this cluster. A cluster only the mutation phase could find is evidence the coverage guidance earned its budget.
        public let discoveringPhase: Phase

        /// Elapsed run time at the first failure attributed to this cluster.
        public let firstSeen: TimeBudget

        /// The attempt index (1-based, counted across all phases) of the first failure attributed to this cluster.
        ///
        /// Use this rather than ``firstSeen`` when comparing discovery speed across runs or machines: wall-clock timing moves with machine load, while the attempt index depends only on the search's decisions under its seed. Zero for clusters restored from a progress log written before the index was recorded.
        public let firstSeenAttempt: Int

        /// Elapsed run time at the most recent failure attributed to this cluster.
        public let lastSeen: TimeBudget

        /// Edges ranked by discriminative power against passing runs, strongest first. The top entry is the best single lead on the fault's location.
        public let discriminatingEdges: [DiscriminatingEdge]

        /// The number of edges present in every reduced counterexample of this cluster — the length of the path the SUT must traverse to reach the fault.
        public let necessaryEdgeCount: Int

        /// Necessary edges absent from the passing runs most similar to this cluster: the branches that push the SUT from "almost fails" to "fails". Empty when no passing runs exist to compare against.
        public let nearMissEdgeIndices: [Int]
    }

    /// One edge that separates a cluster's failures from passing runs.
    ///
    /// Read it as "hit in \(failureHitFraction) of this cluster's failures, \(passingHitFraction) of passing runs". An edge hit in most failures but few passes is a suspect; the causal read still needs judgment — an error-handling path triggered *by* the bug discriminates just as strongly as the bug itself.
    public struct DiscriminatingEdge: Sendable {
        /// The global instrumented-edge index, stable within one build only.
        public let edgeIndex: Int

        /// The fraction of this cluster's reduced counterexamples that hit the edge.
        public let failureHitFraction: Double

        /// The fraction of passing corpus entries that hit the edge.
        public let passingHitFraction: Double

        /// The symbolised source location, like `parseHeader(_:) + 48 (Parser.swift:142)`. Nil when the build lacks a PC table or the platform cannot resolve it.
        public let location: String?
    }

    /// The phase of the run that produced a finding.
    public enum Phase: String, Sendable, Equatable {
        /// Phase 1: covering-array screening over type-boundary values.
        case screening
        /// Phase 2: PRNG-driven random sampling.
        case sampling
        /// Phase 3: coverage-guided mutation from corpus parents.
        case mutation
    }

    /// Why the run stopped.
    public enum Termination: Sendable, Equatable {
        /// The wall-clock budget elapsed.
        case budgetExhausted

        /// The mutation phase stopped learning — no coverage-novel corpus admission for a sustained window — so the run ended early and returned the unused budget rather than burning it. A plateau is not evidence the fault space is exhausted; failures on already-covered paths remain possible.
        case coveragePlateau(unused: TimeBudget)

        /// The build lacks coverage instrumentation, so the run failed loudly before consuming any budget. The recorded issue carries the compiler flags to add.
        case instrumentationMissing

        /// A setting was unusable (an invalid replay seed, a nonpositive time budget), so the run failed loudly before consuming any budget. The payload is the recorded issue's message.
        case invalidConfiguration(String)

        /// Generation failed irrecoverably before the budget elapsed.
        case generationFailed(String)

        /// A package-visible attempt limit stopped the run before any time-based condition fired. Reachable only through harness configuration, never through the public settings.
        case attemptLimitReached
    }

    /// The distinct fault clusters discovered, in discovery order. Empty when every attempt passed.
    public let clusters: [Cluster]

    /// Failures that were recorded without reduction and matched no existing cluster's symptom, keyed by symptom. Nonzero counts mean the backpressure gate declined dispatches whose cluster membership is therefore unknown.
    public let unreducedFailureCounts: [String: Int]

    /// Attempts completed by Phase 1 (covering-array screening).
    public let screeningAttempts: Int

    /// Attempts completed by Phase 2 (random sampling).
    public let samplingAttempts: Int

    /// Attempts completed by Phase 3 (the mutation phase).
    public let mutationAttempts: Int

    /// Mutated candidates the materialiser could not turn into a value. Discarded attempts cost mutation and materialisation time but never invoke the property.
    public let discardedAttempts: Int

    /// Entries accepted into the corpus across all phases.
    public let corpusEntryCount: Int

    /// Distinct instrumented edges the corpus covers.
    public let coveredEdgeCount: Int

    /// Total instrumented edges across all loaded instrumented modules. A denominator for module size, not for exploration progress — the count includes code the property never calls.
    public let instrumentedEdgeCount: Int

    /// Edges hit by exactly one attempt across the whole run. The raw singleton count (f₁) behind the discovery-probability and reachability estimates, exposed so downstream tooling can recompute or extrapolate.
    public let edgeSingletonCount: Int

    /// Edges hit by exactly two attempts across the whole run — the doubleton count (f₂) behind ``estimatedReachableEdgeCount``.
    public let edgeDoubletonCount: Int

    /// The Good-Turing estimate of the probability that one more attempt covers a new edge (`f₁/n`).
    ///
    /// Use this to decide whether extending the budget buys anything: at 2×10⁻⁶, a new edge costs about 500,000 further attempts. The estimate is scoped to what this generator and property can reach and is proven consistent as attempts grow, unlike time-since-last-discovery, which swings orders of magnitude minute to minute.
    public var estimatedNextEdgeProbability: Double {
        CoverageEstimators.goodTuringNextDiscoveryProbability(
            singletons: edgeSingletonCount,
            attempts: totalAttempts
        )
    }

    /// The Chao1 estimate of how many edges this generator and property can reach in total — the asymptote ``coveredEdgeCount`` approaches.
    ///
    /// Unlike ``instrumentedEdgeCount``, which measures the module, this denominator is scoped to the run's own search space, so `coveredEdgeCount / estimatedReachableEdgeCount` is an honest completeness fraction. Treat it as an estimate: adaptive sampling bias did not break consistency in the STADS evaluation, but the guarantee is asymptotic.
    public var estimatedReachableEdgeCount: Double {
        CoverageEstimators.chao1ReachableEdges(
            covered: coveredEdgeCount,
            singletons: edgeSingletonCount,
            doubletons: edgeDoubletonCount,
            attempts: totalAttempts
        )
    }

    /// Why the run stopped.
    public let termination: Termination

    /// Wall-clock time the run consumed.
    public let elapsed: TimeBudget

    /// The root seed. Pass to `.replay(_:)` to re-run the search deterministically.
    public let seed: UInt64

    /// True when outstanding reduction tasks did not finish within the end-of-run drain timeout. The affected failures appear in instance counts but not reduced counts.
    public let reductionsTimedOut: Bool

    /// Attempts completed across all phases. Throughput is the currency of `time:` mode — bug yield scales with attempts.
    public var totalAttempts: Int {
        screeningAttempts + samplingAttempts + mutationAttempts
    }

    /// The fraction of the run's wall-clock time spent outside the property body: generation, mutation, materialisation, coverage snapshots, and corpus bookkeeping.
    ///
    /// Throughput is the currency of `time:` mode, and every microsecond of per-attempt framework overhead is subtracted directly from search power. A rising fraction against a baseline means the pipeline, not the property, is eating the budget. For sub-microsecond properties a high fraction is expected — there is little property time to dominate.
    public let frameworkOverheadFraction: Double

    /// Attempts per second over the whole run. A falling number against a baseline means framework or property overhead is eating the budget.
    public var attemptsPerSecond: Double {
        let seconds = elapsed.seconds
        guard seconds > 0 else {
            return 0
        }
        return Double(totalAttempts) / seconds
    }
}

// MARK: - Wrapping the package-level result

package extension FuzzReport {
    /// Builds the public report from the runner's raw result. Cluster timestamps are converted from monotonic clock readings to run-relative durations.
    ///
    /// - Parameter symbolizeEdges: Whether to resolve discriminating edges to source locations through the live PC table. True only for sancov-backed runs — a synthetic source's edge indices do not address real program counters.
    init(result: FuzzRunResult, symbolizeEdges: Bool = false) {
        let runStartNanoseconds = result.startNanoseconds
        let discriminations = Dictionary(
            uniqueKeysWithValues: result.clusterDiscriminations.map { ($0.clusterID, $0) }
        )
        let locations: [Int: String]
        if symbolizeEdges {
            let allEdges = result.clusterDiscriminations.flatMap { discrimination in
                discrimination.rankedEdges.map(\.edge) + discrimination.nearMissDistinguishingEdges.indices
            }
            locations = SancovSymbolizer.symbolize(edges: Array(Set(allEdges)))
        } else {
            locations = [:]
        }
        clusters = result.clusters.map { cluster in
            let discrimination = discriminations[cluster.id]
            let rankedEdges = (discrimination?.rankedEdges ?? []).map { statistic in
                DiscriminatingEdge(
                    edgeIndex: statistic.edge,
                    failureHitFraction: statistic.failureHitFraction,
                    passingHitFraction: statistic.passingHitFraction,
                    location: locations[statistic.edge]
                )
            }
            return Cluster(
                id: cluster.id,
                reducedDescription: cluster.reducedDescription,
                symptoms: cluster.symptoms.map(\.kind).sorted(),
                instanceCount: cluster.instanceCount,
                reducedCount: cluster.reducedCount,
                unnormalizedMemberCount: cluster.unnormalizedMemberCount,
                isLikelySplit: cluster.signatures.count > 1,
                discoveringPhase: Phase(phase: cluster.discoveringPhase),
                firstSeen: TimeBudget(nanoseconds: cluster.firstSeenNanoseconds &- runStartNanoseconds),
                firstSeenAttempt: cluster.firstSeenAttempt,
                lastSeen: TimeBudget(nanoseconds: cluster.lastSeenNanoseconds &- runStartNanoseconds),
                discriminatingEdges: rankedEdges,
                necessaryEdgeCount: discrimination?.necessaryEdges.count ?? 0,
                nearMissEdgeIndices: discrimination?.nearMissDistinguishingEdges.indices ?? []
            )
        }
        unreducedFailureCounts = Dictionary(
            uniqueKeysWithValues: result.unmatchedUnreducedCounts.map { ($0.key.kind, $0.value) }
        )
        screeningAttempts = result.screeningAttempts
        samplingAttempts = result.samplingAttempts
        mutationAttempts = result.mutationAttempts
        discardedAttempts = result.discardedAttempts
        corpusEntryCount = result.corpusEntryCount
        coveredEdgeCount = result.coveredEdgeCount
        instrumentedEdgeCount = result.instrumentedEdgeCount
        edgeSingletonCount = result.edgeSingletonCount
        edgeDoubletonCount = result.edgeDoubletonCount
        termination = Termination(termination: result.termination)
        elapsed = TimeBudget(nanoseconds: result.elapsedNanoseconds)
        frameworkOverheadFraction = result.elapsedNanoseconds > 0
            ? 1.0 - min(1.0, Double(result.propertyNanoseconds) / Double(result.elapsedNanoseconds))
            : 0
        seed = result.seed
        reductionsTimedOut = result.reductionsTimedOut
    }

    /// The report for a run that never started: missing instrumentation or an invalid setting. Everything is zero except the termination reason.
    static func empty(termination: Termination, seed: UInt64) -> FuzzReport {
        FuzzReport(
            clusters: [],
            unreducedFailureCounts: [:],
            screeningAttempts: 0,
            samplingAttempts: 0,
            mutationAttempts: 0,
            discardedAttempts: 0,
            corpusEntryCount: 0,
            coveredEdgeCount: 0,
            instrumentedEdgeCount: 0,
            edgeSingletonCount: 0,
            edgeDoubletonCount: 0,
            termination: termination,
            elapsed: .zero,
            seed: seed,
            reductionsTimedOut: false,
            frameworkOverheadFraction: 0
        )
    }
}

package extension FuzzReport.Phase {
    init(phase: FuzzPhase) {
        self = switch phase {
            case .screening: .screening
            case .sampling: .sampling
            case .mutation: .mutation
        }
    }
}

package extension FuzzReport.Termination {
    init(termination: FuzzTermination) {
        self = switch termination {
            case .budgetExhausted:
                .budgetExhausted
            case let .plateau(unusedNanoseconds):
                .coveragePlateau(unused: TimeBudget(nanoseconds: unusedNanoseconds))
            case .attemptLimitReached:
                .attemptLimitReached
            case let .generationError(message):
                .generationFailed(message)
        }
    }
}
