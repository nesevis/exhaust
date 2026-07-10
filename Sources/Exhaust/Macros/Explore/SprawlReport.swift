// The public result type of a `#explore(time:)` run.

import ExhaustCore

/// The outcome of a `#explore(time:)` coverage-guided run: a clustered fault inventory plus throughput and coverage statistics.
///
/// A `time:` run catalogues failures instead of stopping at the first one, so the report carries every distinct fault cluster the run discovered. Assert on ``clusters`` when a run is expected to find bugs (combine with `.suppress(.issueReporting)`), or on ``termination`` and the attempt counts when validating search behavior.
@available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
public struct SprawlReport: Sendable {
    /// One distinct fault the run discovered: a unique reduced counterexample with its membership counts.
    ///
    /// Cluster identity is the reduced counterexample's choice sequence. Two failures that reduce to the same minimal form are the same cluster even when their surface symptoms differ; distinct reduced forms are distinct clusters even when their symptoms match. ``isLikelySplit`` marks the middle taxonomy tier — one reduced form observed through more than one coverage signature.
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

        /// True when the reduced form was reached through more than one coverage signature — the same surface bug, possibly via different code paths. Worth a glance; a distinct cluster is worth an investigation.
        public let isLikelySplit: Bool

        /// The phase that first created this cluster. A cluster only sprawl could find is evidence the coverage guidance earned its budget.
        public let discoveringPhase: Phase

        /// Elapsed run time at the first failure attributed to this cluster.
        public let firstSeen: Duration

        /// Elapsed run time at the most recent failure attributed to this cluster.
        public let lastSeen: Duration
    }

    /// The phase of the run that produced a finding.
    public enum Phase: String, Sendable, Equatable {
        /// Phase 1: covering-array screening over type-boundary values.
        case screening
        /// Phase 2: PRNG-driven random sampling.
        case sampling
        /// Phase 3: coverage-guided mutation from corpus parents.
        case sprawl
    }

    /// Why the run stopped.
    public enum Termination: Sendable, Equatable {
        /// The wall-clock budget elapsed.
        case budgetExhausted

        /// Sprawl stopped learning — no coverage-novel corpus admission for a sustained window — so the run ended early and returned the unused budget rather than burning it. A plateau is not evidence the fault space is exhausted; failures on already-covered paths remain possible.
        case coveragePlateau(unused: Duration)

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

    /// Attempts completed by Phase 3 (coverage-guided sprawl).
    public let sprawlAttempts: Int

    /// Mutated candidates the materialiser could not turn into a value. Discarded attempts cost mutation and materialisation time but never invoke the property.
    public let discardedAttempts: Int

    /// Entries accepted into the corpus across all phases.
    public let corpusEntryCount: Int

    /// Distinct instrumented edges the corpus covers.
    public let coveredEdgeCount: Int

    /// Total instrumented edges across all loaded instrumented modules. A denominator for module size, not for exploration progress — the count includes code the property never calls.
    public let instrumentedEdgeCount: Int

    /// Why the run stopped.
    public let termination: Termination

    /// Wall-clock time the run consumed.
    public let elapsed: Duration

    /// The root seed. Pass to `.replay(_:)` to re-run the search deterministically.
    public let seed: UInt64

    /// True when outstanding reduction tasks did not finish within the end-of-run drain timeout. The affected failures appear in instance counts but not reduced counts.
    public let reductionsTimedOut: Bool

    /// Attempts completed across all phases. Throughput is the currency of `time:` mode — bug yield scales with attempts.
    public var totalAttempts: Int {
        screeningAttempts + samplingAttempts + sprawlAttempts
    }

    /// Attempts per second over the whole run. A falling number against a baseline means framework or property overhead is eating the budget.
    public var attemptsPerSecond: Double {
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard seconds > 0 else {
            return 0
        }
        return Double(totalAttempts) / seconds
    }
}

// MARK: - Wrapping the package-level result

@available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
package extension SprawlReport {
    /// Builds the public report from the runner's raw result. Cluster timestamps are converted from monotonic clock readings to run-relative durations.
    init(result: SprawlRunResult) {
        let runStartNanoseconds = result.startNanoseconds
        clusters = result.clusters.map { cluster in
            Cluster(
                id: cluster.id,
                reducedDescription: cluster.reducedDescription,
                symptoms: cluster.symptoms.map(\.kind).sorted(),
                instanceCount: cluster.instanceCount,
                reducedCount: cluster.reducedCount,
                isLikelySplit: cluster.signatures.count > 1,
                discoveringPhase: Phase(phase: cluster.discoveringPhase),
                firstSeen: .nanoseconds(cluster.firstSeenNanoseconds &- runStartNanoseconds),
                lastSeen: .nanoseconds(cluster.lastSeenNanoseconds &- runStartNanoseconds)
            )
        }
        unreducedFailureCounts = Dictionary(
            uniqueKeysWithValues: result.unmatchedUnreducedCounts.map { ($0.key.kind, $0.value) }
        )
        screeningAttempts = result.screeningAttempts
        samplingAttempts = result.samplingAttempts
        sprawlAttempts = result.sprawlAttempts
        discardedAttempts = result.discardedAttempts
        corpusEntryCount = result.corpusEntryCount
        coveredEdgeCount = result.coveredEdgeCount
        instrumentedEdgeCount = result.instrumentedEdgeCount
        termination = Termination(termination: result.termination)
        elapsed = .nanoseconds(result.elapsedNanoseconds)
        seed = result.seed
        reductionsTimedOut = result.reductionsTimedOut
    }

    /// The report for a run that never started: missing instrumentation or an invalid setting. Everything is zero except the termination reason.
    static func empty(termination: Termination, seed: UInt64) -> SprawlReport {
        SprawlReport(
            clusters: [],
            unreducedFailureCounts: [:],
            screeningAttempts: 0,
            samplingAttempts: 0,
            sprawlAttempts: 0,
            discardedAttempts: 0,
            corpusEntryCount: 0,
            coveredEdgeCount: 0,
            instrumentedEdgeCount: 0,
            termination: termination,
            elapsed: .zero,
            seed: seed,
            reductionsTimedOut: false
        )
    }
}

@available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
package extension SprawlReport.Phase {
    init(phase: SprawlPhase) {
        self = switch phase {
            case .screening: .screening
            case .sampling: .sampling
            case .sprawl: .sprawl
        }
    }
}

@available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
package extension SprawlReport.Termination {
    init(termination: SprawlTermination) {
        self = switch termination {
            case .budgetExhausted:
                .budgetExhausted
            case let .plateau(unusedNanoseconds):
                .coveragePlateau(unused: .nanoseconds(unusedNanoseconds))
            case .attemptLimitReached:
                .attemptLimitReached
            case let .generationError(message):
                .generationFailed(message)
        }
    }
}
