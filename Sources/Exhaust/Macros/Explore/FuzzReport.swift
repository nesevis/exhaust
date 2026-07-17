// The public result type of a `#explore(time:)` run.

import ExhaustCore

/// The outcome of a `#explore(time:)` coverage-guided run: a clustered fault inventory plus throughput and coverage statistics.
///
/// A `time:` run catalogs failures instead of stopping at the first one, so the report carries every distinct fault cluster the run discovered. Assert on ``clusters`` when a run is expected to find bugs (combine with `.suppress(.issueReporting)`), or on ``termination`` and the attempt counts when validating search behavior.
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
        public let firstSeen: TimeSpan

        /// The attempt index (1-based, counted across all phases) of the first failure attributed to this cluster.
        ///
        /// Use this rather than ``firstSeen`` when comparing discovery speed across runs or machines: wall-clock timing moves with machine load, while the attempt index depends only on the search's decisions under its seed. Zero for clusters restored from a progress log written before the index was recorded.
        public let firstSeenAttempt: Int

        /// Elapsed run time at the most recent failure attributed to this cluster.
        public let lastSeen: TimeSpan

        /// Edges ranked by discriminative power against passing runs, strongest first. The top entry is the best single lead on the fault's location.
        public let discriminatingEdges: [DiscriminatingEdge]

        /// The number of edges present in every reduced counterexample of this cluster — the length of the path the SUT must traverse to reach the fault.
        public let necessaryEdgeCount: Int

        /// Necessary edges absent from the passing runs most similar to this cluster: the branches that push the SUT from "almost fails" to "fails". Empty when no passing runs exist to compare against.
        public let nearMissEdgeIndices: [Int]

        /// The reduced choice sequence retained for source-located diagnostic replay. Package code uses this to materialize the counterexample without exposing the generator's internal representation publicly.
        package let reducedSequence: ExhaustCore.ChoiceSequence
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

        /// The symbolized source location, like `parseHeader(_:) + 48 (Parser.swift:142)`. Nil when the build lacks a PC table or the platform cannot resolve it.
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

    /// Partitions the run's elapsed time into non-overlapping property, search-phase overhead, reduction, and residual durations.
    public struct TimingBreakdown: Sendable, Equatable {
        /// Measures wall-clock time spent inside search and prune property invocations.
        public let property: TimeSpan

        /// Measures covering-array screening work outside property invocations and inline reduction.
        public let screeningOverhead: TimeSpan

        /// Measures random-sampling work outside property invocations and inline reduction.
        public let samplingOverhead: TimeSpan

        /// Measures coverage-guided mutation work outside property invocations and inline reduction.
        public let mutationOverhead: TimeSpan

        /// Measures inline reduction, normalization, classification, and their property invocations.
        public let reduction: TimeSpan

        /// Measures setup, recovery, between-phase bookkeeping, and finalization work outside the search phases.
        public let other: TimeSpan
    }

    /// Why the run stopped.
    public enum Termination: Sendable, Equatable {
        /// The wall-clock budget elapsed.
        case budgetExhausted

        /// The mutation phase stopped learning — no coverage-novel corpus admission for a sustained window — so the run ended early and returned the unused budget rather than burning it. A plateau is not evidence the fault space is exhausted; failures on already-covered paths remain possible.
        case coveragePlateau(unused: TimeSpan)

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

    /// Candidate rows opened by Phase 1 (covering-array screening), including rows rejected before property entry.
    public let screeningAttempts: Int

    /// Generated candidates opened and evaluated by Phase 2 (random sampling).
    public let samplingAttempts: Int

    /// Candidate opportunities opened by Phase 3 (the mutation phase), including candidates rejected before property entry.
    public let mutationAttempts: Int

    /// Mutated candidates the materializer could not turn into a value. These attempts contribute to ``mutationAttempts`` but invoke the property zero times.
    public let discardedAttempts: Int

    /// Screening rows rejected while building or materializing their candidate before property entry.
    public let screeningRejectedAttempts: Int

    /// Search attempts that reached the property and produced an attributed coverage sample.
    ///
    /// This is the denominator for the edge estimators and ``attemptsPerSecond``. Use ``totalAttempts`` to count opened search opportunities, including pre-property rejections.
    public let evaluatedSearchCases: Int

    /// Property invocations used to re-evaluate candidates after state-machine pruning.
    public let pruneInvocations: Int

    /// Property invocations made by counterexample reduction.
    public let reductionInvocations: Int

    /// Property invocations made while normalizing reduced counterexamples.
    public let normalizationInvocations: Int

    /// Property invocations made to capture post-reduction coverage signatures for cluster classification.
    public let classificationInvocations: Int

    /// Property invocations made while restoring coverage for persisted corpus entries whose saved signatures no longer match the build.
    public let recoveryInvocations: Int

    /// Final source-located property invocations used to report assertion-closure failures.
    public private(set) var diagnosticInvocations: Int

    /// Entries accepted into the corpus across all phases.
    public let corpusEntryCount: Int

    /// Distinct instrumented edges the corpus covers.
    public let coveredEdgeCount: Int

    /// Total instrumented edges across all loaded instrumented modules. A denominator for module size, not for exploration progress — the count includes code the property never calls.
    public let instrumentedEdgeCount: Int

    /// Edges hit by exactly one evaluated search case across the whole run. The raw singleton count (f₁) behind the discovery-probability and reachability estimates, exposed so downstream tooling can recompute or extrapolate.
    public let edgeSingletonCount: Int

    /// Edges hit by exactly two evaluated search cases across the whole run — the doubleton count (f₂) behind ``estimatedReachableEdgeCount``.
    public let edgeDoubletonCount: Int

    /// The Good-Turing estimate of the probability that one more evaluated search case covers a new edge (`f₁/n`).
    ///
    /// Use this to decide whether extending the budget buys anything: at 2×10⁻⁶, a new edge costs about 500,000 further evaluated cases. The estimate is scoped to what this generator and property can reach and is proven consistent as the sample count grows, unlike time-since-last-discovery, which swings orders of magnitude minute to minute.
    public var estimatedNextEdgeProbability: Double {
        CoverageEstimators.goodTuringNextDiscoveryProbability(
            singletons: edgeSingletonCount,
            attempts: evaluatedSearchCases
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
            attempts: evaluatedSearchCases
        )
    }

    /// Why the run stopped.
    public let termination: Termination

    /// Wall-clock time the run consumed.
    public let elapsed: TimeSpan

    /// Provides a non-overlapping partition of ``elapsed`` for diagnosing where the run spends its budget.
    public let timing: TimingBreakdown

    /// The root seed. Pass to `.replay(_:)` to re-run the search deterministically.
    public let seed: UInt64

    /// Returns wall-clock time spent reducing, normalizing, and classifying failures, inline on the search's lane.
    ///
    /// Reduction displaces search opportunities, so a failure-dense run spends a visible share of its budget here. ``attemptsPerSecond`` and ``testingOverheadFraction`` are computed net of this time, so they keep describing the search pipeline rather than the failure rate.
    public var reductionTime: TimeSpan {
        timing.reduction
    }

    /// Candidate opportunities opened across all search phases, including candidates rejected before property entry.
    public var totalAttempts: Int {
        screeningAttempts + samplingAttempts + mutationAttempts
    }

    /// Search attempts rejected before property entry.
    public var rejectedSearchAttempts: Int {
        screeningRejectedAttempts + discardedAttempts
    }

    /// Property invocations across search, pruning, reduction, normalization, classification, recovery, and final diagnostic replay.
    public var totalPropertyInvocations: Int {
        evaluatedSearchCases
            + pruneInvocations
            + reductionInvocations
            + normalizationInvocations
            + classificationInvocations
            + recoveryInvocations
            + diagnosticInvocations
    }

    /// The fraction of the run's search time spent outside the property body: generation, mutation, materialization, coverage snapshots, and corpus bookkeeping. Time spent reducing failures is excluded (see ``reductionTime``).
    ///
    /// Throughput is the currency of `time:` mode, and every microsecond of per-attempt testing overhead is subtracted directly from search power. A rising fraction against a baseline means the pipeline, not the property, is eating the budget. For sub-microsecond properties a high fraction is expected — there is little property time to dominate.
    public let testingOverheadFraction: Double

    /// Evaluated search cases per second over the run's search time, net of ``reductionTime``. Rejected candidates are excluded because they never reach the property or contribute an edge-incidence sample.
    public var attemptsPerSecond: Double {
        let seconds = elapsed.seconds - reductionTime.seconds
        guard seconds > 0 else {
            return 0
        }
        return Double(evaluatedSearchCases) / seconds
    }
}

// MARK: - Wrapping the package-level result

package extension FuzzReport {
    /// Records one source-located diagnostic replay after a reduced counterexample was materialized successfully.
    mutating func recordDiagnosticInvocation() {
        diagnosticInvocations += 1
    }

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
                firstSeen: TimeSpan(nanoseconds: cluster.firstSeenNanoseconds &- runStartNanoseconds),
                firstSeenAttempt: cluster.firstSeenAttempt,
                lastSeen: TimeSpan(nanoseconds: cluster.lastSeenNanoseconds &- runStartNanoseconds),
                discriminatingEdges: rankedEdges,
                necessaryEdgeCount: discrimination?.necessaryEdges.count ?? 0,
                nearMissEdgeIndices: discrimination?.nearMissDistinguishingEdges.indices ?? [],
                reducedSequence: cluster.reducedSequence
            )
        }
        unreducedFailureCounts = Dictionary(
            uniqueKeysWithValues: result.unmatchedUnreducedCounts.map { ($0.key.kind, $0.value) }
        )
        screeningAttempts = result.counts.screeningAttempts
        samplingAttempts = result.counts.samplingAttempts
        mutationAttempts = result.counts.mutationAttempts
        discardedAttempts = result.counts.discardedAttempts
        screeningRejectedAttempts = result.counts.screeningRejectedAttempts
        evaluatedSearchCases = result.counts.evaluatedSearchCases
        pruneInvocations = result.counts.pruneInvocations
        reductionInvocations = result.counts.reductionInvocations
        normalizationInvocations = result.counts.normalizationInvocations
        classificationInvocations = result.counts.classificationInvocations
        recoveryInvocations = result.counts.recoveryInvocations
        diagnosticInvocations = 0
        corpusEntryCount = result.corpusEntryCount
        coveredEdgeCount = result.coveredEdgeCount
        instrumentedEdgeCount = result.instrumentedEdgeCount
        edgeSingletonCount = result.edgeSingletonCount
        edgeDoubletonCount = result.edgeDoubletonCount
        termination = Termination(termination: result.termination)
        elapsed = TimeSpan(nanoseconds: result.elapsedNanoseconds)
        timing = TimingBreakdown(
            property: TimeSpan(nanoseconds: result.timing.propertyNanoseconds),
            screeningOverhead: TimeSpan(nanoseconds: result.timing.screeningOverheadNanoseconds),
            samplingOverhead: TimeSpan(nanoseconds: result.timing.samplingOverheadNanoseconds),
            mutationOverhead: TimeSpan(nanoseconds: result.timing.mutationOverheadNanoseconds),
            reduction: TimeSpan(nanoseconds: result.timing.reductionNanoseconds),
            other: TimeSpan(
                nanoseconds: result.timing.otherNanoseconds(totalNanoseconds: result.elapsedNanoseconds)
            )
        )
        testingOverheadFraction = result.searchNanoseconds > 0
            ? 1.0 - min(
                1.0,
                Double(result.timing.propertyNanoseconds) / Double(result.searchNanoseconds)
            )
            : 0
        seed = result.seed
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
            screeningRejectedAttempts: 0,
            evaluatedSearchCases: 0,
            pruneInvocations: 0,
            reductionInvocations: 0,
            normalizationInvocations: 0,
            classificationInvocations: 0,
            recoveryInvocations: 0,
            diagnosticInvocations: 0,
            corpusEntryCount: 0,
            coveredEdgeCount: 0,
            instrumentedEdgeCount: 0,
            edgeSingletonCount: 0,
            edgeDoubletonCount: 0,
            termination: termination,
            elapsed: .zero,
            timing: TimingBreakdown(
                property: .zero,
                screeningOverhead: .zero,
                samplingOverhead: .zero,
                mutationOverhead: .zero,
                reduction: .zero,
                other: .zero
            ),
            seed: seed,
            testingOverheadFraction: 0
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
                .coveragePlateau(unused: TimeSpan(nanoseconds: unusedNanoseconds))
            case .attemptLimitReached:
                .attemptLimitReached
            case let .generationError(message):
                .generationFailed(message)
        }
    }
}
