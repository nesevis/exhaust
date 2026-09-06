// The public result type of a `#explore(time:)` run.

import ExhaustCore

/// The outcome of a `#explore(time:)` coverage-guided run: a clustered fault inventory plus throughput and coverage statistics.
///
/// A `time:` run catalogs failures instead of stopping at the first one, so the report carries the fault clusters the run discovered. Cluster count is a lower bound on distinct bugs: reduction preserves failure rather than the *reason* for failure, so a fault whose inputs reduce toward another fault's counterexample is absorbed into it and never reported separately. Assert on ``clusters`` when a run is expected to find bugs (combine with `.suppress(.issueReporting)`), or on ``termination`` and the attempt counts when validating search behavior.
///
/// - Important: This mode is experimental. Its settings, report format, and search behavior may change in any release; every call site emits a build warning until the mode stabilizes.
public struct FuzzReport: Sendable {
    /// One fault cluster the run discovered: a unique reduced counterexample with its membership counts. A cluster is an identity over reduced forms, not over root causes.
    ///
    /// Cluster identity is a canonical structural key over the reduced counterexample, so two failures that reduce to the same minimal form are the same cluster even when their surface symptoms differ, and distinct reduced forms are distinct clusters even when their symptoms match. ``isLikelySplit`` marks the middle taxonomy tier: one reduced form observed through more than one coverage signature.
    public struct Cluster: Sendable {
        /// Stable identifier in discovery order, starting at 0.
        public let id: Int

        /// A rendered description of the canonical reduced counterexample.
        public let reducedDescription: String

        /// The symptoms observed across this cluster's members: thrown error type names, or `"returnedFalse"` for properties that returned `false`.
        public let symptoms: [String]

        /// Total failures attributed to this cluster, reduced and unreduced together.
        ///
        /// Only ``reducedCount`` of these were classified by reducing them and comparing the reduced form. The rest are failures the backpressure gate declined to reduce, attributed to the most recently seen cluster sharing their ``symptoms``. That is a weak signal: two distinct faults that throw the same error type are indistinguishable to it, and a property that returns `false` rather than throwing gives every failure in the run the same symptom, so the attribution carries no information at all.
        ///
        /// Read this as a rough weight, not a membership count. ``reducedCount`` is the number this cluster's identity actually rests on.
        public let instanceCount: Int

        /// Members that went through reduction. Bounded by the per-cluster reduction cap, so a hot fault reads "5 reduced, 209 attributed by symptom".
        public let reducedCount: Int

        /// Members whose own reduced form stalled short of the canonical one (an uncleared flag bit, an unclamped byte) and joined this cluster through the normalization pass. Without normalization each distinct stall would appear as its own spurious cluster; a high count relative to ``reducedCount`` means reduction stalls often on this fault, not that more faults exist.
        public let unnormalizedMemberCount: Int

        /// True when the reduced form was reached through more than one coverage signature, which usually means one surface bug arrived via different code paths. Worth a glance; a distinct cluster is worth an investigation.
        public let isLikelySplit: Bool

        /// The phase that first created this cluster. A cluster only the mutation phase could find is evidence the coverage guidance earned its budget.
        public let discoveringPhase: Phase

        /// Elapsed run time at the first failure attributed to this cluster.
        public let firstSeen: TimeSpan

        /// The attempt index (1-based, counted across all phases) of the first failure attributed to this cluster.
        ///
        /// Use this rather than ``firstSeen`` when comparing discovery speed across runs or machines: wall-clock timing moves with machine load, while the attempt index depends only on the search's decisions under its seed. Counted across resumes, so a cluster carried over from a crashed predecessor keeps the index it was discovered at.
        public let firstSeenAttempt: Int

        /// Elapsed run time at the most recent failure attributed to this cluster.
        public let lastSeen: TimeSpan

        /// Edges ranked by discriminative power against passing runs, strongest first, one per resolved source location. The top entry is the best single lead on the fault's location.
        ///
        /// The ranking is over edges, and one function usually ranks at several offsets; the report keeps the strongest edge per symbol and line so the list names distinct places. Compiler-generated globals (metadata accessors, thunks, outlined copies) and synthesized bodies are dropped, and a specialized copy of a function folds onto the function. Without a PC table nothing folds and the edges are listed as ranked.
        public let discriminatingEdges: [DiscriminatingEdge]

        /// The reduced choice sequence retained for source-located diagnostic replay. Package code uses this to materialize the counterexample without exposing the generator's internal representation publicly.
        package let reducedSequence: ExhaustCore.ChoiceSequence
    }

    /// One edge that separates a cluster's failures from passing runs.
    ///
    /// Read it as "hit in \(failureHitFraction) of this cluster's failures, \(passingHitFraction) of passing runs". An edge hit in most failures but few passes is a suspect; the causal read still needs judgment, because an error-handling path triggered *by* the bug discriminates just as strongly as the bug itself.
    public struct DiscriminatingEdge: Sendable {
        /// The global instrumented-edge index, stable within one build only.
        public let edgeIndex: Int

        /// The fraction of this cluster's reduced counterexamples that hit the edge.
        public let failureHitFraction: Double

        /// The fraction of passing corpus entries that hit the edge.
        public let passingHitFraction: Double

        /// The symbol containing the edge, resolved once after the run. Nil when the build lacks a PC table, the platform cannot resolve it, or the coverage source is synthetic.
        public let symbol: SymbolLocation?
    }

    /// A source symbol resolved from an instrumented edge, as fields rather than a composed string.
    ///
    /// ``displayName`` is the demangler's simplified form, the one the debugger prints (`parseHeader(_:)`, `Ledger.audit()`): module, argument and return types, and private discriminators dropped, context kept. ``fullName`` is the full demangling. A specialized copy of a function carries the function's own names. ``file`` and ``line`` come from debug info and are absent when it could not place the address.
    public struct SymbolLocation: Sendable, Equatable {
        /// The module the symbol belongs to, or nil for a symbol that is not Swift.
        public let module: String?
        /// The simplified demangled name, as the debugger prints it.
        public let displayName: String
        /// The full demangled name, with argument and return types.
        public let fullName: String
        /// The source file's last path component, when debug info placed the address.
        public let file: String?
        /// The source line, when debug info placed the address.
        public let line: Int?

        /// The reader's form: `parseHeader(_:) (Parser.swift:142)`, the file alone when no line resolved, the name alone when no file did.
        public var rendered: String {
            guard let file else {
                return displayName
            }
            if let line, line > 0 {
                return "\(displayName) (\(file):\(line))"
            }
            return "\(displayName) (\(file))"
        }

        /// Whether `other` names the same place: the same symbol, no file disagreement, and no two resolved lines that differ. Two resolved lines that differ are distinct locations within one function.
        package func namesSamePlace(as other: SymbolLocation) -> Bool {
            guard displayName == other.displayName, module == other.module else {
                return false
            }
            if let file, let otherFile = other.file, file != otherFile {
                return false
            }
            if let line, line > 0, let otherLine = other.line, otherLine > 0, line != otherLine {
                return false
            }
            return true
        }

        /// Whether debug info placed the address in a synthesized body (a derived conformance, a property wrapper's backing accessor), which the compiler files under `/<compiler-generated>`. Not a place to look.
        package var isSynthesized: Bool {
            file?.contains("<compiler-generated>") == true
        }
    }

    /// The phase of the run that produced a finding.
    public enum Phase: String, Sendable, Equatable {
        /// Phase 1: covering array screening over type-boundary values.
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

        /// The mutation phase stopped learning, with no coverage-novel corpus admission for a sustained window, so the run ended early and returned the unused budget rather than burning it. A plateau is not evidence the fault space is exhausted; failures on already-covered paths remain possible.
        case coveragePlateau(unused: TimeSpan)

        /// The build lacks coverage instrumentation, so the run failed loudly before consuming any budget. The recorded issue carries the compiler flags to add.
        case instrumentationMissing

        /// The build carries instrumentation, but the run recorded no coverage at all, so the search had nothing to follow and stopped rather than spending the budget. Reached when the property's work executes somewhere the coverage source does not observe; see <doc:CoverageGuidedFuzzing> on executor isolation.
        case coverageUnreachable

        /// A setting was unusable (an invalid replay seed, a nonpositive time budget), so the run failed loudly before consuming any budget. The payload is the recorded issue's message.
        case invalidConfiguration(String)

        /// Generation failed irrecoverably before the budget elapsed.
        case generationFailed(String)

        /// A package-visible attempt limit stopped the run before any time-based condition fired. Reachable only through harness configuration, never through the public settings.
        case attemptLimitReached

        /// The first fault clustered and the run stopped there, as `.failFast` requested. The remaining budget was returned rather than spent searching for further faults.
        case firstFaultFound

        /// An attempt's asynchronous work outlived cancellation and was abandoned while still running, so the run stopped rather than measuring later attempts against it.
        ///
        /// Reachable only from `.tasks` spec runs. The abandoned work keeps executing the system under test and keeps recording coverage, so every attempt after it carries some of the escaped attempt's behaviour in its signature. Raise `.idleTimeout`, reduce `.parallelize`, or find the command that does not return under cancellation.
        case uncontainedAsyncWork
    }

    /// The distinct fault clusters discovered, in discovery order. Empty when every attempt passed.
    public let clusters: [Cluster]

    /// Failures that were recorded without reduction and matched no existing cluster's symptom, keyed by symptom. Nonzero counts mean the backpressure gate declined dispatches whose cluster membership is therefore unknown.
    public let unreducedFailureCounts: [String: Int]

    /// Why the run stopped.
    public let termination: Termination

    /// The root seed. Pass to `.replay(_:)` to re-run the search deterministically.
    public let seed: UInt64

    /// Whether this run consumed a crashed predecessor's checkpoint, restoring its corpus and fault inventory. Package-visible so issue reporting can tell "the budget was spent by crashed predecessors" from "the property was never invoked".
    package private(set) var resumedFromCrash = false

    /// What the search opened and what became of it, by phase and by producer.
    public let attempts: Attempts

    /// Every property invocation the run made outside the search, plus the search's own, so the total says how many times the property ran.
    public private(set) var invocations: Invocations

    /// What the corpus holds and what the instrumented target let the search see.
    public let coverage: Coverage

    /// Where the run's wall clock went.
    public let timing: Timing

    /// Search attempts by phase and by producer.
    ///
    /// An attempt is a candidate opportunity: a screening row built, a sample drawn, a mutation child produced. Not every attempt reaches the property: the materializer discards some, the duplicate table skips some, and screening rejects rows it cannot build. ``evaluated`` counts the ones that did reach it; ``total`` counts every opportunity.
    public struct Attempts: Sendable, Equatable {
        /// Candidate rows opened by Phase 1 (covering array screening), including rows rejected before property entry.
        public let screening: Int

        /// Generated candidates opened and evaluated by Phase 2 (random sampling).
        public let sampling: Int

        /// Candidate opportunities opened by Phase 3 (the mutation phase), including candidates rejected before property entry.
        public let mutation: Int

        /// Mutation-phase candidates whose value was reconstructed from a comparison operand the property's code compared against and reflected through the generator. Counted inside ``mutation``. Zero when the system under test carries no `trace-cmp` instrumentation or the generator is not reflective.
        public let reflectionInjection: Int

        /// Mutation-phase candidates made by grafting a comparison operand into one field of a corpus parent and reflecting the whole value. Counted inside ``mutation``; zero under the same conditions as ``reflectionInjection``.
        public let graftInjection: Int

        /// Mutation-phase candidates made by writing a comparison operand over tag-compatible entries of a corpus parent's choice sequence, the injection path that needs no reflection. Counted inside ``mutation``; zero when the system under test carries no `trace-cmp` instrumentation.
        public let comparandSubstitution: Int

        /// Mutated candidates the materializer could not turn into a value. These contribute to ``mutation`` but invoke the property zero times.
        public let discardedByMaterializer: Int

        /// Screening rows rejected while building or materializing their candidate before property entry.
        public let screeningRejected: Int

        /// Search candidates skipped before the property ran because the run had recently evaluated the same choice sequence. Counted in the phase tallies, not in ``evaluated``.
        public let duplicatesSkipped: Int

        /// The same skips split by the arm that produced the candidate, so a duplicate rate can be read per arm.
        ///
        /// The arms rebuild already-evaluated inputs at very different rates, and an aggregate cannot say which one is spending its attempts on work the run has already done. Divide an arm's count by its attempt tally for the rate: the injection arms have their own tallies, sampling has ``sampling``, and ordinary mutation children are ``mutation`` less the injection tallies.
        public let duplicateSkips: DuplicateSkips

        /// Search attempts that reached the property, including inconclusive evaluations whose stalled coverage is deliberately excluded from the corpus and estimators.
        ///
        /// This is the denominator for ``FuzzReport/attemptsPerSecond``. Use ``Coverage/incidenceSamples`` for the edge estimators and ``total`` to count opened search opportunities, including pre-property rejections.
        public let evaluated: Int

        /// Evaluated attempts the property discarded by throwing a skip error (its precondition was not met). Counted inside ``evaluated``: the property ran and its coverage was recorded, and a coverage-novel discard stays in the corpus as a low-weight mutation parent so the search can climb toward valid inputs.
        public let discardedByProperty: Int

        /// Comparand-substitution energy keys seated over another key because their whole probe window was occupied. A high ratio to ``operandEnergySeatings`` means the retirement table is undersized for the run, so a retired operand is resurrected by collision rather than by yielding.
        package let operandEnergyEvictions: Int

        /// Comparand-substitution energy keys seated into a slot, whether it was empty or held another key. The denominator for ``operandEnergyEvictions``.
        package let operandEnergySeatings: Int

        /// Comparand-substitution sources moved into the retired set after exhausting their allowance.
        package let operandEnergyRetirements: Int

        /// Candidate opportunities opened across all search phases, including candidates rejected before property entry.
        public var total: Int {
            screening + sampling + mutation
        }

        /// Search attempts rejected before property entry: a screening row the covering array could not materialize, a candidate the materializer discarded, and a candidate skipped as a recent duplicate.
        public var rejected: Int {
            screeningRejected + discardedByMaterializer + duplicatesSkipped
        }
    }

    /// Duplicate skips attributed to the producer that built the candidate. Sums to ``Attempts/duplicatesSkipped``.
    public struct DuplicateSkips: Sendable, Equatable {
        /// Fresh interpreter draws. Counted in whichever phase drew them, so mutation-phase fresh draws land here too, not only the sampling phase's.
        public let freshDraw: Int
        /// Ordinary mutations of a corpus parent.
        public let mutationChild: Int
        /// Harvested operands reconstructed into a whole value.
        public let reflectionInjection: Int
        /// Harvested operands grafted into one field of a corpus parent.
        public let graftInjection: Int
        /// Harvested operands written over tag-compatible entries of a parent's flat sequence.
        public let comparandSubstitution: Int

        /// The breakdown for a run that skipped nothing.
        public static let zero = DuplicateSkips(
            freshDraw: 0,
            mutationChild: 0,
            reflectionInjection: 0,
            graftInjection: 0,
            comparandSubstitution: 0
        )
    }

    /// Property invocations by purpose.
    ///
    /// The search's own invocations are ``Attempts/evaluated``, repeated here as ``search`` so ``total`` is one sum. Everything else is work the run did on top of the search: re-evaluating pruned spec candidates, reducing and normalizing failures, classifying reduced forms, re-judging restored entries, and the final source-located diagnostic replay.
    public struct Invocations: Sendable, Equatable {
        /// Search attempts that reached the property; the same figure as ``Attempts/evaluated``.
        public let search: Int

        /// Invocations used to re-evaluate candidates after state-machine pruning.
        public let prune: Int

        /// Invocations made by counterexample reduction.
        public let reduction: Int

        /// Invocations made while normalizing reduced counterexamples.
        public let normalization: Int

        /// Invocations made to capture post-reduction coverage signatures for cluster classification.
        public let classification: Int

        /// Invocations made while restoring coverage for persisted corpus entries whose saved signatures no longer match the build.
        public let recovery: Int

        /// Final source-located invocations used to report assertion-closure failures.
        public internal(set) var diagnostic: Int

        /// Spec-path pruning passes that removed no command, so the original evaluation stood in for the re-evaluation.
        public let pruneIdentitySkips: Int

        /// Invocations across search, pruning, reduction, normalization, classification, recovery, and final diagnostic replay.
        public var total: Int {
            search + prune + reduction + normalization + classification + recovery + diagnostic
        }
    }

    /// The corpus and the coverage the search saw.
    ///
    /// The edge tallies feed the STADS estimators: ``estimatedReachableEdges`` bounds how many edges this generator and property can reach, and ``estimatedNextEdgeProbability`` is the chance the next incidence covers a new one. Both are scoped to the run's own search space, never to the module.
    public struct Coverage: Sendable, Equatable {
        /// Entries accepted into the corpus across all phases.
        public let corpusEntryCount: Int

        /// Corpus entries eligible to be mutation parents: mutable-tier entries that hold a champion cell and are not quarantined.
        ///
        /// Parent selection is a weighted draw over this set and costs one score lookup per member per pick, so this is the number to watch against ``FuzzReport/attemptsPerSecond`` when diagnosing a run whose throughput falls as the corpus grows.
        public let parentCount: Int

        /// The parent domain's length and cell distribution at the end of the run.
        public let parentProfile: ParentProfile

        /// Distinct instrumented edges the corpus covers.
        public let coveredEdges: Int

        /// Total instrumented edges across all loaded instrumented modules. A denominator for module size, not for exploration progress, because the count includes code the property never calls.
        public let instrumentedEdges: Int

        /// Edges hit by exactly one incidence sample across the whole run: the raw singleton count (Q₁) behind the discovery-probability and reachability estimates.
        public let singletons: Int

        /// Edges hit by exactly two incidence samples across the whole run: the doubleton count (Q₂) behind ``estimatedReachableEdges``.
        public let doubletons: Int

        /// Edges hit by exactly three incidence samples (Q₃), one of the two counts iChao2 adds over Chao2.
        public let tripletons: Int

        /// Edges hit by exactly four incidence samples (Q₄). When this is zero, ``estimatedReachableEdges`` falls back to plain Chao2.
        public let quadrupletons: Int

        /// Every (search case, edge) pair counted once: the incidence-matrix sum `V`.
        ///
        /// One search case covers many edges, so this is far larger than ``incidenceSamples`` and is the correct denominator for ``estimatedNextEdgeProbability``. Its ratio to the sample count is the mean edges an attempt covers.
        public let incidenceTotal: Int

        /// Conclusive, nonduplicate search cases represented as rows in the incidence matrix.
        ///
        /// This can be smaller than ``Attempts/evaluated`` because a stalled evaluation supplies no verdict and a repeated choice sequence supplies no new independent row. It is the attempt denominator for the incidence estimators.
        public let incidenceSamples: Int

        /// Instrumented edges that fired during the run on threads the run did not own, so the search never saw them.
        ///
        /// Under `trace-pc-guard` coverage is recorded on the run's own lane. Work the property hands to another executor (a `@MainActor` function, an actor with a custom executor, a detached task) fires its edges elsewhere, and so does another test exercising the same instrumented code concurrently. A nonzero count says one of those happened; it cannot say which. Zero under counter-based instrumentation, which records on every thread and cannot tell.
        public let offLaneHits: Int

        /// The estimated probability that the next incidence covers an edge nothing has reached yet.
        ///
        /// Denominated in incidences, not search cases: a single case covers thousands of edges, so this is a per-edge-observation probability rather than a per-case one. To express it per case, multiply by ``incidenceTotal`` divided by ``incidenceSamples``.
        ///
        /// Scoped to what this generator and property can reach, and consistent as the sample grows, unlike time-since-last-discovery, which swings orders of magnitude minute to minute.
        public var estimatedNextEdgeProbability: Double {
            CoverageEstimators.nextDiscoveryProbability(
                singletons: singletons,
                incidenceTotal: incidenceTotal,
                undiscovered: estimatedReachableEdges - Double(coveredEdges),
                attempts: incidenceSamples
            )
        }

        /// The iChao2 **lower bound** on how many edges this generator and property can reach in total.
        ///
        /// Unlike ``instrumentedEdges``, which measures the module, this denominator is scoped to the run's own search space, so `coveredEdges / estimatedReachableEdges` is a completeness fraction rather than a module fraction.
        ///
        /// - Important: A lower bound, so the fraction derived from it is an **upper** bound on completeness. A coverage-guided run can approach a false asymptote and then surge, which biases the bound low and the fraction high; the effect shrinks as the run lengthens but is largest exactly when a small ``doubletons`` makes the estimate volatile.
        public var estimatedReachableEdges: Double {
            CoverageEstimators.iChao2ReachableEdges(
                covered: coveredEdges,
                singletons: singletons,
                doubletons: doubletons,
                tripletons: tripletons,
                quadrupletons: quadrupletons,
                attempts: incidenceSamples
            )
        }
    }

    /// Where the run's wall clock went: a non-overlapping partition of ``elapsed`` plus the two discovery figures a reader uses to judge whether a longer run would help.
    public struct Timing: Sendable, Equatable {
        /// Wall-clock time the run consumed.
        public let elapsed: TimeSpan

        /// Time from the run's start to its last discovery: a new edge or a newly classified fault cluster, whichever came later. Zero when the run never covered an edge.
        ///
        /// The gap to ``elapsed`` is how long the search ran without finding anything new, which is what a run that used its whole budget has to say about whether a longer one would help. Not the same question the plateau rule asks minute to minute, but the same two events feed both.
        public let lastDiscovery: TimeSpan

        /// Wall-clock time spent inside search and prune property invocations.
        public let property: TimeSpan

        /// Covering-array screening work outside property invocations and inline reduction.
        public let screeningOverhead: TimeSpan

        /// Random-sampling work outside property invocations and inline reduction.
        public let samplingOverhead: TimeSpan

        /// Coverage-guided mutation work outside property invocations and inline reduction.
        public let mutationOverhead: TimeSpan

        /// Inline reduction, normalization, classification, and their property invocations.
        ///
        /// Reduction displaces search opportunities, so a failure-dense run spends a visible share of its budget here. ``FuzzReport/attemptsPerSecond`` and ``testingOverheadFraction`` are computed net of this time, so they keep describing the search pipeline rather than the failure rate.
        public let reduction: TimeSpan

        /// Setup, recovery, between-phase bookkeeping, and finalization work outside the search phases.
        public let other: TimeSpan

        /// The fraction of the run's search time spent outside the property body: generation, mutation, materialization, coverage snapshots, and corpus bookkeeping. Time spent reducing failures is excluded (see ``reduction``).
        ///
        /// Throughput is the currency of `time:` mode, and every microsecond of per-attempt testing overhead is subtracted directly from search power. A rising fraction against a baseline means the pipeline, not the property, is eating the budget. For sub-microsecond properties a high fraction is expected, because there is little property time to dominate.
        public let testingOverheadFraction: Double
    }

    /// The shape of the parent domain when the run ended: how long the parents' choice sequences are, and how many champion cells each holds.
    ///
    /// ``Coverage/parentCount`` alone cannot tell growth from displacement. A short entry that claims many champion cells evicts several longer incumbents at once, so the parent domain can shrink while admissions rise. Compare ``meanLength`` against ``meanEntryLength`` to see whether the parents are a shorter population than the corpus they were drawn from, and read the cell figures to see whether a few entries hold most of the archive.
    public struct ParentProfile: Sendable, Equatable {
        /// Entries eligible as mutation parents, the same figure as ``Coverage/parentCount``.
        public let parentCount: Int
        /// The shortest parent's choice-sequence length.
        public let minimumLength: Int
        /// The median parent's choice-sequence length.
        public let medianLength: Int
        /// The mean parent choice-sequence length.
        public let meanLength: Double
        /// The longest parent's choice-sequence length.
        public let maximumLength: Int
        /// The mean choice-sequence length over every admitted entry, parent or not.
        public let meanEntryLength: Double
        /// The fewest champion cells any parent holds. Zero for every field when the champion archive is off.
        public let minimumCells: Int
        /// The median number of champion cells held per parent.
        public let medianCells: Int
        /// The mean number of champion cells held per parent.
        public let meanCells: Double
        /// The most champion cells any one parent holds.
        public let maximumCells: Int

        /// The profile of a run with no parents.
        public static let empty = ParentProfile(
            parentCount: 0,
            minimumLength: 0,
            medianLength: 0,
            meanLength: 0,
            maximumLength: 0,
            meanEntryLength: 0,
            minimumCells: 0,
            medianCells: 0,
            meanCells: 0,
            maximumCells: 0
        )
    }

    /// Evaluated search attempts per second over the run's search time, net of ``Timing/reduction``. Rejected candidates are excluded because they never reach the property or contribute an edge-incidence sample.
    public var attemptsPerSecond: Double {
        let seconds = timing.elapsed.seconds - timing.reduction.seconds
        guard seconds > 0 else {
            return 0
        }
        return Double(attempts.evaluated) / seconds
    }

    /// Renders the run's fault inventory as the multi-line text a failing run reports to the terminal.
    ///
    /// When the run clustered faults, this is the string `#explore(time:)` records as the test failure, so a run under `.suppress(.issueReporting)` can still assert on what a developer would have read. A run that stopped because of a configuration or instrumentation problem reports that separately, and none of that text appears here. Suspect edges appear in their compact form (`integrityCheck (Parser.swift:121)`), not as raw symbolizer output. The wording is diagnostic text and changes between releases, so match substrings rather than whole lines.
    ///
    /// - Complexity: Renders from scratch on every call, including a regular-expression pass per cluster. Bind the result rather than calling this repeatedly.
    public func renderedSummary() -> String {
        __ExhaustRuntime.renderFuzzSummary(self)
    }

    /// Renders the run's full inventory as the text of the `explore-time-summary.txt` attachment.
    ///
    /// Where ``renderedSummary()`` keeps to the reader's questions, this rendering carries the search's own figures: throughput, testing overhead, the instrumented and covered edge counts, the reachability estimate, per-cluster membership and discovery phase, and up to three suspects per cluster. Use it when a test asserts on those, or when a tool wants the numbers without parsing the report. The same wording caveat applies: match substrings, not whole lines.
    public func renderedAttachmentSummary() -> String {
        __ExhaustRuntime.renderFuzzAttachmentSummary(self)
    }
}

// MARK: - Wrapping the package-level result

package extension FuzzReport {
    /// Records one source-located diagnostic replay after a reduced counterexample was materialized successfully.
    mutating func recordDiagnosticInvocation() {
        invocations.diagnostic += 1
    }

    /// Marks the run as having consumed a crashed predecessor's checkpoint. Called by the core once the runner returns, because the raw ``FuzzRunResult`` does not carry persistence state.
    mutating func recordCrashResume() {
        resumedFromCrash = true
    }

    /// Builds the public report from the runner's raw result. Cluster timestamps are converted from monotonic clock readings to run-relative durations.
    ///
    /// - Parameter symbolizeEdges: Whether to resolve discriminating edges to source locations through the live PC table. True only for sancov-backed runs; a synthetic source's edge indices do not address real program counters.
    init(result: FuzzRunResult, symbolizeEdges: Bool = false) {
        let runStartNanoseconds = result.startNanoseconds
        let discriminations = Dictionary(
            uniqueKeysWithValues: result.clusterDiscriminations.map { ($0.clusterID, $0) }
        )
        let locations: [Int: ExhaustCore.SymbolLocation]
        if symbolizeEdges {
            let allEdges = result.clusterDiscriminations.flatMap { discrimination in
                discrimination.rankedEdges.map(\.edge)
            }
            locations = SancovSymbolizer.symbolize(edges: Array(Set(allEdges)))
        } else {
            locations = [:]
        }
        clusters = result.clusters.map { cluster in
            let discrimination = discriminations[cluster.id]
            let candidates = (discrimination?.rankedEdges ?? []).map { statistic in
                DiscriminatingEdge(
                    edgeIndex: statistic.edge,
                    failureHitFraction: statistic.failureHitFraction,
                    passingHitFraction: statistic.passingHitFraction,
                    symbol: locations[statistic.edge].map { resolved in
                        SymbolLocation(
                            module: resolved.module,
                            displayName: resolved.displayName,
                            fullName: resolved.fullName,
                            file: resolved.file,
                            line: resolved.line
                        )
                    }
                )
            }
            let rankedEdges = __ExhaustRuntime.distinctSuspectEdges(candidates, symbolized: symbolizeEdges, limit: FuzzTunables.discriminatingEdgeLimit)
            return Cluster(
                id: cluster.id,
                reducedDescription: cluster.reducedDescription,
                symptoms: cluster.symptoms.map(\.kind).sorted(),
                instanceCount: cluster.instanceCount,
                reducedCount: cluster.reducedCount,
                unnormalizedMemberCount: cluster.unnormalizedMemberCount,
                isLikelySplit: cluster.signatures.count > 1,
                discoveringPhase: Phase(phase: cluster.discoveringPhase),
                // Clamped like every other timestamp conversion in the pipeline: a restored record that violates the ordering assumption must read as zero, not as a wrapped 584-year duration.
                firstSeen: TimeSpan(
                    nanoseconds: cluster.firstSeenNanoseconds > runStartNanoseconds
                        ? cluster.firstSeenNanoseconds - runStartNanoseconds
                        : 0
                ),
                firstSeenAttempt: cluster.firstSeenAttempt,
                lastSeen: TimeSpan(
                    nanoseconds: cluster.lastSeenNanoseconds > runStartNanoseconds
                        ? cluster.lastSeenNanoseconds - runStartNanoseconds
                        : 0
                ),
                discriminatingEdges: rankedEdges,
                reducedSequence: cluster.reducedSequence
            )
        }
        unreducedFailureCounts = Dictionary(
            uniqueKeysWithValues: result.unmatchedUnreducedCounts.map { ($0.key.kind, $0.value) }
        )
        let counts = result.counts
        attempts = Attempts(
            screening: counts.screeningAttempts,
            sampling: counts.samplingAttempts,
            mutation: counts.mutationAttempts,
            reflectionInjection: counts.reflectionInjectionAttempts,
            graftInjection: counts.graftInjectionAttempts,
            comparandSubstitution: counts.comparandSubstitutionAttempts,
            discardedByMaterializer: counts.discardedAttempts,
            screeningRejected: counts.screeningRejectedAttempts,
            duplicatesSkipped: counts.duplicateCandidatesSkipped,
            duplicateSkips: DuplicateSkips(
                freshDraw: counts[duplicateSkipsFor: .freshSample],
                mutationChild: counts[duplicateSkipsFor: .mutationChild],
                reflectionInjection: counts[duplicateSkipsFor: .reflectionInjection],
                graftInjection: counts[duplicateSkipsFor: .graftInjection],
                comparandSubstitution: counts[duplicateSkipsFor: .comparandSubstitution]
            ),
            evaluated: counts.evaluatedSearchCases,
            discardedByProperty: counts.discardedEvaluations,
            operandEnergyEvictions: result.diagnostics.operandEnergyEvictions,
            operandEnergySeatings: result.diagnostics.operandEnergySeatings,
            operandEnergyRetirements: result.diagnostics.operandEnergyRetirements
        )
        invocations = Invocations(
            search: counts.evaluatedSearchCases,
            prune: counts.pruneInvocations,
            reduction: counts.reductionInvocations,
            normalization: counts.normalizationInvocations,
            classification: counts.classificationInvocations,
            recovery: counts.recoveryInvocations,
            diagnostic: 0,
            pruneIdentitySkips: result.diagnostics.pruneIdentitySkips
        )
        let profile = result.parentProfile
        coverage = Coverage(
            corpusEntryCount: result.corpusEntryCount,
            parentCount: result.parentCount,
            parentProfile: ParentProfile(
                parentCount: profile.parentCount,
                minimumLength: profile.minimumLength,
                medianLength: profile.medianLength,
                meanLength: profile.meanLength,
                maximumLength: profile.maximumLength,
                meanEntryLength: profile.meanEntryLength,
                minimumCells: profile.minimumCells,
                medianCells: profile.medianCells,
                meanCells: profile.meanCells,
                maximumCells: profile.maximumCells
            ),
            coveredEdges: result.incidence.covered,
            instrumentedEdges: result.instrumentedEdgeCount,
            singletons: result.incidence.singletons,
            doubletons: result.incidence.doubletons,
            tripletons: result.incidence.tripletons,
            quadrupletons: result.incidence.quadrupletons,
            incidenceTotal: result.incidenceTotal,
            incidenceSamples: result.incidenceSampleCount,
            offLaneHits: result.offLaneEdgeHits
        )
        termination = Termination(termination: result.termination)
        timing = Timing(
            elapsed: TimeSpan(nanoseconds: result.elapsedNanoseconds),
            // Clamped like idleFraction: a resumed run's discoveries can predate this process.
            lastDiscovery: TimeSpan(
                nanoseconds: min(
                    max(result.lastNewEdgeNanoseconds, result.lastNewClusterNanoseconds),
                    result.elapsedNanoseconds
                )
            ),
            property: TimeSpan(nanoseconds: result.timing.propertyNanoseconds),
            screeningOverhead: TimeSpan(nanoseconds: result.timing.screeningOverheadNanoseconds),
            samplingOverhead: TimeSpan(nanoseconds: result.timing.samplingOverheadNanoseconds),
            mutationOverhead: TimeSpan(nanoseconds: result.timing.mutationOverheadNanoseconds),
            reduction: TimeSpan(nanoseconds: result.timing.reductionNanoseconds),
            other: TimeSpan(
                nanoseconds: result.timing.otherNanoseconds(totalNanoseconds: result.elapsedNanoseconds)
            ),
            testingOverheadFraction: result.searchNanoseconds > 0
                ? 1.0 - min(
                    1.0,
                    Double(result.timing.propertyNanoseconds) / Double(result.searchNanoseconds)
                )
                : 0
        )
        seed = result.seed
    }

    /// The report for a run that never started: missing instrumentation or an invalid setting. Everything is zero except the termination reason.
    static func empty(termination: Termination, seed: UInt64) -> FuzzReport {
        FuzzReport(
            clusters: [],
            unreducedFailureCounts: [:],
            termination: termination,
            seed: seed,
            attempts: Attempts(
                screening: 0,
                sampling: 0,
                mutation: 0,
                reflectionInjection: 0,
                graftInjection: 0,
                comparandSubstitution: 0,
                discardedByMaterializer: 0,
                screeningRejected: 0,
                duplicatesSkipped: 0,
                duplicateSkips: .zero,
                evaluated: 0,
                discardedByProperty: 0,
                operandEnergyEvictions: 0,
                operandEnergySeatings: 0,
                operandEnergyRetirements: 0
            ),
            invocations: Invocations(
                search: 0,
                prune: 0,
                reduction: 0,
                normalization: 0,
                classification: 0,
                recovery: 0,
                diagnostic: 0,
                pruneIdentitySkips: 0
            ),
            coverage: Coverage(
                corpusEntryCount: 0,
                parentCount: 0,
                parentProfile: .empty,
                coveredEdges: 0,
                instrumentedEdges: 0,
                singletons: 0,
                doubletons: 0,
                tripletons: 0,
                quadrupletons: 0,
                incidenceTotal: 0,
                incidenceSamples: 0,
                offLaneHits: 0
            ),
            timing: Timing(
                elapsed: .zero,
                lastDiscovery: .zero,
                property: .zero,
                screeningOverhead: .zero,
                samplingOverhead: .zero,
                mutationOverhead: .zero,
                reduction: .zero,
                other: .zero,
                testingOverheadFraction: 0
            )
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
            case .firstFaultFound:
                .firstFaultFound
            case .coverageUnreachable:
                .coverageUnreachable
            case let .generationError(message):
                .generationFailed(message)
            case .uncontainedAsyncWork:
                .uncontainedAsyncWork
        }
    }
}
