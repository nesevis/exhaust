// The three-phase coverage-guided exploration loop behind `#explore(time:)`.

import Foundation

private struct EvaluatedFuzzCandidate<Output> {
    let value: Output
    let tree: ChoiceTree
    let sequence: ChoiceSequence
    /// `ZobristHash.hash(of:)` of `sequence`, so admission does not hash it again.
    let sequenceHash: UInt64
    let verdict: FuzzVerdict
    let hits: [(edge: Int, hitCount: UInt8)]
}

private struct PrunedCandidateSelection<Output> {
    let corpus: EvaluatedFuzzCandidate<Output>
    let failure: EvaluatedFuzzCandidate<Output>?
    let independentFailureCoverageNovel: Bool?
}

/// One materialized search candidate on its way to the property: the flat sequence the loop hashes and offers, the value the property judges, and where it came from.
///
/// The tree is nil for the producers that materialize flat (mutation children and fresh draws); ``FuzzRunner/evaluate(_:)`` rebuilds it only for the candidates that admit or fail. The reflection and graft producers already hold the tree they reflected and carry it here so it is not rebuilt.
struct FuzzCandidate<Output>: ~Copyable {
    let sequence: ChoiceSequence
    /// `ZobristHash.hash(of:)` of `sequence`, computed once by the producer for the duplicate check, the breadcrumb, and corpus admission.
    let hash: UInt64
    let value: Output
    /// Set by the producer when it already holds the tree, otherwise by ``FuzzRunner/evaluate(_:)`` when something consumes one.
    var tree: ChoiceTree?
    /// Fraction of coordinates the materializer resolved from the prefix; decides the corpus tier. 1 for fresh draws and reflected values.
    let convergence: Double
    let generation: Int
    let phase: FuzzPhase
    /// The producer, for the per-arm duplicate-skip tally.
    let origin: CandidateOrigin
    /// The parent the candidate was derived from, for failure boosts and attempt attribution; nil for fresh draws and whole-value reflection.
    let parentIndex: Int?
    /// The parent's sequence hash for the crash breadcrumb; 0 without a parent.
    let parentHash: UInt64
    /// Bitmask of the ``MutationArm`` that produced the candidate, credited to the bandit on admission; 0 outside the arm inventory.
    let armsMask: UInt32
    /// Whether the candidate is a covering array row, admitted for its boundary values without coverage novelty.
    let isBoundaryDerived: Bool
}

/// What one evaluation came to: the corpus's decision and, when the property ran, its verdict. The verdict is nil for a candidate skipped as a recent duplicate or discarded before it was recorded.
struct FuzzEvaluation {
    let admission: CorpusAdmission
    let verdict: FuzzVerdict?
}

/// The spec-path carried through `runExploreTimeCore` into ``FuzzRunner`` as one unit.
///
/// Nil on the value path. A spec adapter populates both fields: the prune hook keeps precondition-skipped commands out of the corpus, and the reduce strategy routes reduction through the spec's backend reducer (sequential specs reuse ``FuzzRunner/propertyOnlyReduceStrategy(gen:property:reducerConfiguration:)`` with the spec deadline; `.tasks` specs will wrap their two-pass reducer, which must run synchronously on the loop's lane: reduction is always inline so probes never pollute attempt coverage, and no concurrent dispatch context exists).
package struct FuzzHooks<Output> {
    /// Prunes the value and tree before corpus admission. Runs outside the attribution bracket, only on failures and would-be admissions.
    package let prune: @Sendable (Output, ChoiceTree) -> (value: Output, tree: ChoiceTree)
    /// Reduces one failing candidate, returning the reduced sequence, tree, and value.
    ///
    /// The fourth argument is the bracket every reduction probe's property invocation must run inside; a strategy that drops it leaves its probes unmarked, and an abnormal termination in one of them is then attributed to the last search candidate.
    package let reduceStrategy: @Sendable (ChoiceTree, Output, FailureSymptom, ProbeWrapper?) -> FuzzReductionResult<Output>

    package init(
        prune: @escaping @Sendable (Output, ChoiceTree) -> (value: Output, tree: ChoiceTree),
        reduceStrategy: @escaping @Sendable (ChoiceTree, Output, FailureSymptom, ProbeWrapper?) -> FuzzReductionResult<Output>
    ) {
        self.prune = prune
        self.reduceStrategy = reduceStrategy
    }
}

/// Carries one reduced counterexample and the property invocations used to produce it without coupling fuzz reporting to the reducer's full statistics type.
package struct FuzzReductionResult<Output> {
    package let sequence: ChoiceSequence
    package let tree: ChoiceTree
    package let value: Output
    package let propertyInvocations: Int
    /// Whether a probe's asynchronous work escaped cancellation during the reduction. The reduced form is still the best the reduction reached, and the run ends on it: the escaped work keeps executing the system under test, so nothing after it can be measured.
    package let escaped: Bool

    package init(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        value: Output,
        propertyInvocations: Int,
        escaped: Bool = false
    ) {
        self.sequence = sequence
        self.tree = tree
        self.value = value
        self.propertyInvocations = propertyInvocations
        self.escaped = escaped
    }
}

/// Runs the covering-array, random-sampling, and mutation phases against one property, accumulating a corpus and a clustered fault inventory.
///
/// The runner is single-threaded: the corpus, gate, PRNG, and every instrumented evaluation — attempt brackets, reduction probes, classification re-runs — execute on the one GCD lane that owns `run()`. Reduction runs inline at the point of failure discovery, trading attempts for signal purity: no instrumented code ever executes concurrently with an open attempt bracket, so every coverage snapshot is attributable to exactly one evaluation and classification feedback lands at a deterministic point in the attempt stream.
package final class FuzzRunner<Output> {
    // Members without an access modifier are internal so the same-module extension files (FuzzRunner+Recovery, FuzzRunner+Mutation) can reach them; nothing outside the module sees them.
    let gen: Generator<Output>
    let erasedGen: AnyGenerator
    let property: @Sendable (Output) -> FuzzVerdict
    let source: any CoverageSource
    let configuration: FuzzRunnerConfiguration
    /// Prunes the value and tree before corpus admission. Nil on the value path; the spec path removes precondition-skipped commands so the corpus stores only live sequences. Runs outside the attribution bracket, only on failures and would-be admissions.
    private let prune: (@Sendable (Output, ChoiceTree) -> (value: Output, tree: ChoiceTree))?
    /// The reduction the failure dispatch runs. The value path's default is ``propertyOnlyReduceStrategy(gen:property:reducerConfiguration:)``; the spec path injects its backend reducer through ``FuzzHooks``.
    let reduceStrategy: @Sendable (ChoiceTree, Output, FailureSymptom, ProbeWrapper?) -> FuzzReductionResult<Output>

    /// Set when a property invocation reports that its asynchronous work escaped cancellation, and checked ahead of every limit. Every evaluation after that point would measure the escaped work as well as its own input, so the run stops rather than continuing to record.
    var forcedTermination: FuzzTermination?

    /// Package-visible so tests can assert on corpus contents (tier membership, entry command counts) after a run.
    package let corpus: FuzzCorpus
    let inventory = FaultInventory()
    var gate: ReductionGate
    var prng: Xoshiro256
    var bandit = MutationBandit()

    /// The non-splice arms the fixed distribution draws from, assembled once at init from the experiment knobs.
    var fixedDrawArms: [MutationArm] = []

    /// Comparison operands harvested from the system under test, drawn on during mutation. Stays empty when the source does not harvest or the build lacks `trace-cmp` instrumentation, so reads cost nothing.
    var comparisonPool = ComparisonPool()

    /// Rebuilds an output value from a harvested operand word, or nil when the word is not a natural value of the generator's type. When set, the mutation phase reconstructs a value from the pool, reflects it through the generator to the choices that produce it, and evaluates that candidate: the trace-cmp path for a value that flows through the generator's leaves. Derived from ``OperandReconstructable`` at the typed boundary; the generator's type is the byte schema, reflection supplies the encoding.
    let reflectionReconstructor: (@Sendable (UInt64) -> Output?)?

    /// Whether the generator is reflective, enabling the field-graft path. When true, the mutation phase grafts a harvested operand into one field of a corpus parent and reflects the whole composite through the generator: the trace-cmp path for a struct or tuple whose fields are compared one at a time, which the whole-value reconstructor cannot reach because the composite type has no single natural byte encoding. Distinct from ``reflectionReconstructor``: a composite is reflective but not itself `OperandReconstructable`, so its reconstructor is nil while this stays true.
    private let graftReflective: Bool

    /// Renders a reduced counterexample for its cluster's report description. Injected because the render runs during reduction — the value never crosses back to a context that could render it later — while the runner's module must stay free of rendering dependencies. The default serves direct package-level construction (tests, harnesses); `runExploreTimeCore` supplies the production renderer.
    let renderValue: @Sendable (Any) -> String

    /// Zobrist-keyed normalization results reused across reductions; boxed because ``FuzzNormalizer/normalize(reducedSequence:erasedGen:symptom:property:cache:)`` takes the shared-box type.
    let normalizationCache = SendableBox<[UInt64: ChoiceSequence?]>([:])

    var startNanoseconds: UInt64 = 0
    /// When an attempt last covered an edge no attempt had covered before, or zero if none ever did.
    private var lastNewEdgeNanoseconds: UInt64 = 0
    /// When a failure last classified as a cluster nothing had matched before, or zero if none ever did.
    var lastNewClusterNanoseconds: UInt64 = 0
    /// Attempts evaluated when the first cluster classified.
    var attemptsAtFirstFault = 0

    /// Evaluated attempts since the corpus last admitted an entry, driving the adaptive fresh-draw mixture. Reset on every admission. Package-visible so tests can pin the ramp against a driven counter.
    package var attemptsSinceAdmission = 0

    /// The later of the two discoveries, falling back to the run's start before anything is found.
    ///
    /// This is what the mutation phase measures its plateau against. Corpus admission is the wrong signal for it: a candidate also enters on a new hit-count bucket for an edge already covered, so admissions keep arriving long after the run has stopped finding anything, and the window ends up timing something nobody cares about.
    private var lastDiscoveryNanoseconds: UInt64 {
        max(lastNewEdgeNanoseconds, max(lastNewClusterNanoseconds, startNanoseconds))
    }

    var counts = FuzzRunCounts()
    var timing = FuzzRunTiming()

    /// Derivation index for the swarm mask, advanced once per produced mutation candidate in ``nextCandidate(from:)``.
    ///
    /// Deliberately not `counts.mutationAttempts`: that counter is a report statistic whose increment sites serve attempt accounting, and deriving the mask schedule from it made any reordering of bookkeeping against candidate production a silent change to every activated-swarm run. This index has one meaning and one increment site.
    var swarmDerivationIndex = 0

    /// Scratch the activated swarm rewrite reuses across candidates, so the per-candidate mask allocates nothing.
    var swarmScratch = SwarmMask.ActivationScratch()

    /// Remaining energy per comparand-substitution key, so an operand keeps being drawn while it yields and drops out when it stops.
    var operandEnergy = OperandEnergyTable(capacityExponent: 16)

    // MARK: - Crash-Recovery State

    // Owned by the recovery extension (see FuzzRunner+Recovery.swift); declared here because stored properties cannot live in an extension.

    var progressWriter: FuzzProgressWriter?
    var breadcrumb: FuzzBreadcrumb?
    var lastCheckpointNanoseconds: UInt64 = 0
    /// Set when a new cluster classifies so the next checkpoint fires immediately — discovered clusters must reach disk without waiting out the interval.
    var forceCheckpoint = false

    /// Run time consumed by crashed predecessors, so checkpoint accounting and report timestamps continue one logical timeline across resumes.
    var priorConsumedNanoseconds: UInt64 = 0
    /// Attempts crashed predecessors opened, so cluster discovery indices continue one logical timeline across resumes the way timestamps do. Not folded into `counts`: the attempt limit and the report's attempt tallies describe this process's own search.
    var priorAttempts = 0
    var pcTableHashAtStart: UInt64 = 0

    /// The attempt index a failure observed now belongs to on the logical run's timeline: this process's opened attempts after the predecessors'. A failure restore observes lands at the predecessors' total, which is after every index they recorded and before this run's first attempt.
    var attemptTimelineIndex: Int {
        priorAttempts + counts.totalAttempts
    }

    /// The monotonic origin of the logical run: `startNanoseconds` backdated by predecessor time, so cluster timestamps from before and after a resume land on one timeline.
    var reportEpochNanoseconds: UInt64 {
        startNanoseconds >= priorConsumedNanoseconds ? startNanoseconds - priorConsumedNanoseconds : 0
    }

    package init(
        gen: Generator<Output>,
        property: @escaping @Sendable (Output) -> FuzzVerdict,
        source: any CoverageSource,
        configuration: FuzzRunnerConfiguration,
        hooks: FuzzHooks<Output>? = nil,
        reflectionReconstructor: (@Sendable (UInt64) -> Output?)? = nil,
        graftReflective: Bool = false,
        renderValue: @escaping @Sendable (Any) -> String = { String(describing: $0) }
    ) {
        self.gen = gen
        erasedGen = gen.erase()
        self.property = property
        self.source = source
        self.configuration = configuration
        self.reflectionReconstructor = reflectionReconstructor
        self.graftReflective = graftReflective
        self.renderValue = renderValue
        prune = hooks?.prune
        reduceStrategy = hooks?.reduceStrategy ?? Self.propertyOnlyReduceStrategy(
            gen: gen,
            property: property,
            reducerConfiguration: Interpreters.ReducerConfiguration(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: FuzzTunables.reductionDeadlineNanoseconds
            )
        )
        corpus = FuzzCorpus(edgeCount: source.edgeCount, experiments: configuration.experiments)
        gate = ReductionGate()
        prng = Xoshiro256(seed: configuration.seed)
        var arms = MutationArm.bandArms
        if configuration.experiments.graphMutation {
            arms += [.swap, .shuffle, .move, .lockstepDelta]
        }
        if configuration.experiments.pairMutation {
            arms += [.twinSplice, .typedCrossover]
        }
        bandit = MutationBandit(arms: arms)
        fixedDrawArms = arms.filter { $0 != .splice }
    }

    /// The default reduce strategy: property-only `choiceGraphReduce`, reducing while the property fails exactly as `#exhaust` does. Reduction probes run inline on the loop's lane, outside any attempt bracket; their coverage is never read.
    ///
    /// The sequential spec adapter reuses this with the spec reduction deadline, so the value path and sequential spec path share one reduction implementation and differ only in configuration. On a reducer failure the input comes back unreduced.
    package static func propertyOnlyReduceStrategy(
        gen: Generator<Output>,
        property: @escaping @Sendable (Output) -> FuzzVerdict,
        reducerConfiguration: Interpreters.ReducerConfiguration
    ) -> @Sendable (ChoiceTree, Output, FailureSymptom, ProbeWrapper?) -> FuzzReductionResult<Output> {
        { tree, value, _, probeWrapper in
            // The reducer speaks Bool, so an escape has to leave the probe some other way; the runner reads it from the result.
            let escaped = UnsafeSendableBox(false)
            let boolProperty: (Output) -> Bool = { value in
                let verdict = property(value)
                if verdict.isEscaped {
                    escaped.value = true
                }
                return verdict.isFailure == false
            }
            var configuration = reducerConfiguration
            configuration.probeWrapper = probeWrapper
            let result = try? Interpreters.choiceGraphReduceCollectingStats(
                gen: gen,
                tree: tree,
                output: value,
                config: configuration,
                property: boolProperty
            )
            let propertyInvocations = (result?.stats.reductionProbesWherePropertyPassed ?? 0)
                + (result?.stats.reductionProbesWherePropertyFailed ?? 0)
            switch result?.outcome {
                case let .reduced(sequence, reducedTree, output), let .unreduced(sequence, reducedTree, output):
                    return FuzzReductionResult(
                        sequence: sequence,
                        tree: reducedTree,
                        value: output,
                        propertyInvocations: propertyInvocations,
                        escaped: escaped.value
                    )
                case .failure, nil:
                    return FuzzReductionResult(
                        sequence: ChoiceSequence.flatten(tree),
                        tree: tree,
                        value: value,
                        propertyInvocations: propertyInvocations,
                        escaped: escaped.value
                    )
            }
        }
    }

    // MARK: - Run

    /// Scratch for ``attribute(_:evaluate:)``; see the note there. Declared here because stored properties cannot live in an extension.
    var hitsBuffer: [(edge: Int, hitCount: UInt8)] = []
    /// Whether any attempt has ever recorded an edge. False after a meaningful number of attempts means the source is reading a table the property never writes to, because the property's work is executing somewhere the source does not observe.
    var sawAnyEdge = false

    /// Executes the three phases and returns the final result. Synchronous; the caller owns GCD-lane placement.
    package func run() -> FuzzRunResult {
        // Before the baseline is read and before screening generates a row: the lane's own pre-bracket edges are excluded, not off-lane.
        source.claimLane()
        startNanoseconds = monotonicNanoseconds()
        let offLaneHitsAtStart = source.offLaneHitCount
        setUpPersistence()

        // Sampling hands over to the mutation phase by returning nil (plateau or time backstop); a non-nil value is a hard stop that skips the mutation phase.
        var termination: FuzzTermination?
        if configuration.skipScreening == false {
            let screeningMeasurement = measureSearchPhase {
                runScreeningPhase()
            }
            timing.screeningOverheadNanoseconds += screeningMeasurement.overheadNanoseconds
        }
        if terminationDue() == nil, configuration.skipSampling == false {
            // Screening's coverage must not bind search admission: without this reset, boundary rows that light most of the map on a sparse precondition leave sampling and mutation nothing novel to admit, and the run plateaus empty. A screening-free run reaches here with untouched masks, so the call is a no-op there.
            corpus.resetNoveltyBaseline()
            let samplingMeasurement = measureSearchPhase {
                runSamplingPhase()
            }
            timing.samplingOverheadNanoseconds += samplingMeasurement.overheadNanoseconds
            termination = samplingMeasurement.result
        }
        if termination == nil, terminationDue() == nil, configuration.skipMutation == false {
            let mutationMeasurement = measureSearchPhase {
                runFuzzPhase()
            }
            timing.mutationOverheadNanoseconds += mutationMeasurement.overheadNanoseconds
            termination = mutationMeasurement.result
        }

        var finalTermination = termination ?? terminationDue() ?? .budgetExhausted
        // A run that evaluated the property and never recorded an edge searched nothing, whichever condition ended it. The attempt threshold in terminationDue() only decides how early such a run is cut short; it must not let a short budget turn zero coverage into a green test.
        if forcedTermination == nil,
           source.reportsLiveCoverage,
           sawAnyEdge == false,
           counts.evaluatedSearchCases > 0
        {
            finalTermination = .coverageUnreachable
        }

        counts.operandEnergyEvictions = operandEnergy.evictions
        counts.operandEnergySeatings = operandEnergy.seatings
        counts.operandEnergyRetirements = operandEnergy.retirements

        let clusters = inventory.snapshot()
        let unmatched = inventory.unmatchedUnreducedCounts

        // Report-time statistics: the ranking runs once, here, against one passing sample counted from the corpus.
        let passing = corpus.passingSample
        let discriminations = clusters.map { cluster in
            CoverageDiscrimination.discriminate(
                clusterID: cluster.id,
                failingSignatures: cluster.signatures,
                passing: passing
            )
        }

        finishPersistence()
        let elapsedNanoseconds = monotonicNanoseconds() - startNanoseconds
        let incidence = corpus.edgeIncidenceProfile

        return FuzzRunResult(
            clusters: clusters,
            unmatchedUnreducedCounts: unmatched,
            counts: counts,
            corpusEntryCount: corpus.entries.count,
            parentCount: corpus.parentIndices.count,
            coveredEdgeCount: incidence.covered,
            instrumentedEdgeCount: source.edgeCount,
            edgeSingletonCount: incidence.singletons,
            edgeDoubletonCount: incidence.doubletons,
            edgeTripletonCount: incidence.tripletons,
            edgeQuadrupletonCount: incidence.quadrupletons,
            incidenceTotal: corpus.incidenceTotal,
            incidenceSampleCount: corpus.incidenceSampleCount,
            termination: finalTermination,
            clusterDiscriminations: discriminations,
            startNanoseconds: reportEpochNanoseconds,
            elapsedNanoseconds: elapsedNanoseconds,
            // On the report epoch, so it shares a timeline with cluster timestamps across a resume.
            lastNewEdgeNanoseconds: lastNewEdgeNanoseconds > reportEpochNanoseconds
                ? lastNewEdgeNanoseconds - reportEpochNanoseconds
                : 0,
            attemptsAtFirstFault: attemptsAtFirstFault,
            timing: timing,
            seed: configuration.seed,
            offLaneEdgeHits: max(0, source.offLaneHitCount - offLaneHitsAtStart),
            parentProfile: corpus.parentProfile
        )
    }

    /// Measures one complete search phase and removes property and reduction intervals nested inside it, yielding the phase's exclusive overhead contribution.
    private func measureSearchPhase<Result>(
        _ operation: () -> Result
    ) -> (result: Result, overheadNanoseconds: UInt64) {
        let phaseStartNanoseconds = monotonicNanoseconds()
        let propertyStartNanoseconds = timing.propertyNanoseconds
        let reductionStartNanoseconds = timing.reductionNanoseconds
        let result = operation()
        let phaseNanoseconds = monotonicNanoseconds() - phaseStartNanoseconds
        let propertyNanoseconds = timing.propertyNanoseconds - propertyStartNanoseconds
        let reductionNanoseconds = timing.reductionNanoseconds - reductionStartNanoseconds
        let excludedNanoseconds = propertyNanoseconds + reductionNanoseconds
        return (
            result: result,
            overheadNanoseconds: phaseNanoseconds - min(excludedNanoseconds, phaseNanoseconds)
        )
    }

    // MARK: - Phase 1: Screening

    private func runScreeningPhase() {
        guard let plan = ScreeningRunner.plan(
            gen,
            screeningBudget: min(configuration.screeningBudget, remainingAttemptBudget())
        ) else {
            return
        }
        // The run seed, so the screening rows are pinned by the same seed that pins every other search decision. An unseeded #explore draws a fresh seed per run, which rotates the rows the same way a fresh #exhaust run does.
        var rows = ScreeningRunner.Rows(plan: plan, coveringSeed: configuration.seed, skipToRow: nil)
        var summary = ScreeningRunner.Summary()
        while terminationDue() == nil, let (rowIndex, row) = rows.next() {
            // Counted before the row is built, so a failure classified inside this row sees a 1-based attempt index like every other phase; the post-phase assignment below reconciles to the row count. The breadcrumb clears first so a trap while the generator builds the row is not attributed to the previous attempt.
            counts.screeningAttempts += 1
            breadcrumb?.clear()
            summary.rowAttempts += 1
            guard let (value, tree) = ScreeningRunner.materializeRow(
                erasedGen,
                row: row,
                rowIndex: rowIndex,
                profile: plan.profile,
                needsTree: true
            ) as (Output, ChoiceTree)? else {
                summary.rejectedRows += 1
                continue
            }
            summary.propertyInvocations += 1
            // Convergence is 1: the tree came straight from materialization.
            let sequence = ChoiceSequence.flatten(tree)
            evaluate(FuzzCandidate(
                sequence: sequence,
                hash: ZobristHash.hash(of: sequence),
                value: value,
                tree: tree,
                convergence: 1.0,
                generation: 0,
                phase: .screening,
                origin: .screeningRow,
                parentIndex: nil,
                parentHash: 0,
                armsMask: 0,
                isBoundaryDerived: true
            ))
            checkpointIfDue()
        }
        counts.screeningAttempts = summary.rowAttempts
        counts.screeningRejectedAttempts = summary.rejectedRows
    }

    // MARK: - Phase 2: Random Sampling

    /// Runs open-ended random sampling until plateau (K consecutive samples without a corpus admission), the time backstop, or a run-wide termination condition. Returns a hard termination or nil for normal handover to the mutation phase.
    private func runSamplingPhase() -> FuzzTermination? {
        var interpreter = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: false,
            seed: configuration.seed,
            maxRuns: UInt64.max
        )
        var samplesSinceNovelty = 0
        let backstopNanoseconds = startNanoseconds
            + UInt64(Double(configuration.budgetNanoseconds) * FuzzTunables.samplingTimeBackstopFraction)

        while true {
            if let termination = terminationDue() {
                return termination
            }
            // Both exits hand over to mutation. With mutation skipped there is nowhere to hand over to, so they would cut the arm short rather than pace it.
            if configuration.skipMutation == false {
                if samplesSinceNovelty >= configuration.samplingPlateauWindow {
                    return nil
                }
                if monotonicNanoseconds() >= backstopNanoseconds {
                    return nil
                }
            }
            checkpointIfDue()

            switch freshCandidate(interpreter: &interpreter, phase: .sampling) {
                case let .drawn(candidate):
                    if evaluate(candidate).admission.isAdmitted {
                        samplesSinceNovelty = 0
                    } else {
                        samplesSinceNovelty += 1
                    }
                case .exhausted:
                    return nil
                case let .generationError(message):
                    return .generationError(message)
            }
        }
    }

    /// Whether the estimated chance that the next attempt covers a new edge has fallen below ``FuzzTunables/saturationNextEdgeProbability``.
    ///
    /// The estimate is scoped to what this generator and property can reach, so it answers "is there anything left for this search to find" rather than "is there anything left in the module". A run with no singletons estimates no undiscovered edges and reads as saturated, which is the intended reading: nothing has been seen exactly once, so nothing suggests more remains.
    ///
    /// The estimator is denominated in incidences; the mean edges an attempt covers converts it to the per-attempt figure the threshold and the report both speak in.
    private func isSaturated() -> Bool {
        let attempts = corpus.incidenceSampleCount
        let incidenceTotal = corpus.incidenceTotal
        guard attempts > 0, incidenceTotal > 0 else {
            return false
        }
        let profile = corpus.edgeIncidenceProfile
        let singletons = profile.singletons
        let covered = profile.covered
        let reachable = CoverageEstimators.iChao2ReachableEdges(
            covered: covered,
            singletons: singletons,
            doubletons: profile.doubletons,
            tripletons: profile.tripletons,
            quadrupletons: profile.quadrupletons,
            attempts: attempts
        )
        let perIncidence = CoverageEstimators.nextDiscoveryProbability(
            singletons: singletons,
            incidenceTotal: incidenceTotal,
            undiscovered: reachable - Double(covered),
            attempts: attempts
        )
        let edgesPerAttempt = Double(incidenceTotal) / Double(attempts)
        return perIncidence * edgesPerAttempt < FuzzTunables.saturationNextEdgeProbability
    }

    // MARK: - Phase 3: Mutation

    private func runFuzzPhase() -> FuzzTermination {
        // Fallback sampling for an empty mutable tier reuses the interpreter idiom with a derived seed so it does not replay Phase 2's stream.
        var fallbackInterpreter = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: false,
            seed: configuration.seed ^ 0x5EED_FA11_BACC_0FFE,
            maxRuns: UInt64.max
        )
        // Saturation stop, opt-in only: the run ends early when the discovery-probability estimate says the search has stopped reaching new code, never on a stopwatch. Sampled on an attempt interval because the estimate scans the per-edge incidence counters.
        var nextSaturationCheckAttempt = configuration.saturationMinimumAttempts

        while true {
            if let termination = terminationDue() {
                return termination
            }
            if configuration.stopWhenSaturated, counts.evaluatedSearchCases >= nextSaturationCheckAttempt {
                nextSaturationCheckAttempt = counts.evaluatedSearchCases + configuration.saturationCheckInterval
                if isSaturated() {
                    let plateauNow = monotonicNanoseconds()
                    let deadline = startNanoseconds + configuration.budgetNanoseconds
                    return .plateau(unusedNanoseconds: deadline > plateauNow ? deadline - plateauNow : 0)
                }
            }
            checkpointIfDue()

            // Reflection injection: reconstruct a value from a harvested operand and reflect it to the choices that produce it. Offered on half of iterations when the pool has something to draw from; a whole-value gate leaks its constant on every attempt, so a drawn candidate reaches it quickly.
            // The capability flags are set only when the run harvests operands (a reflective generator on a trace-cmp build), so they gate injection without a separate knob; the empty-pool check makes both arms free when the build carries no trace-cmp instrumentation and nothing is ever harvested.
            if reflectionReconstructor != nil,
               comparisonPool.isEmpty == false,
               prng.next(upperBound: 2) == 0,
               reflectionInjectionAttempt()
            {
                continue
            }

            // Field graft: for a composite compared field by field, graft a harvested operand into one field of a corpus parent and reflect the whole value, preserving the matched prefix. Generic over the output type — the parent's component supplies the field type at runtime, so no per-type closure is needed.
            if graftReflective,
               comparisonPool.isEmpty == false,
               prng.next(upperBound: 2) == 0,
               reflectionGraftAttempt()
            {
                continue
            }

            // Comparand substitution: overwrite one tag-compatible value entry of a parent's flat sequence with a harvested operand. Needs no reflection, so it is the only injection arm on a non-reflective generator; the empty-pool check keeps it free without trace-cmp instrumentation.
            if comparisonPool.isEmpty == false,
               prng.next(upperBound: 2) == 0,
               comparandSubstitutionAttempt()
            {
                continue
            }

            // Fresh-draw mixture: with the current mixture probability, spend this iteration on one fresh generator draw instead of a parent batch, keeping sampling alive as a background rate. Fresh draws reach basins no corpus entry has visited, which corpus-uniform exploration cannot. The adaptive ramp (floor to cap over a starvation window of non-admitting attempts) responds to corpus health, and is also what re-samples the generator once mutation has run the corpus dry.
            if randomUnit() < currentFreshMixture(attemptsSinceAdmission: attemptsSinceAdmission) {
                switch freshCandidate(interpreter: &fallbackInterpreter, phase: .mutation) {
                    case let .drawn(candidate):
                        evaluate(candidate)
                        continue
                    case .exhausted:
                        continue
                    case let .generationError(message):
                        return .generationError(message)
                }
            }

            guard let (parentIndex, parent) = corpus.pickParent(random: randomUnit()) else {
                // Empty mutable tier: fall back to fresh sampling until something is mutable.
                switch freshCandidate(interpreter: &fallbackInterpreter, phase: .mutation) {
                    case let .drawn(candidate):
                        evaluate(candidate)
                    case .exhausted:
                        // A fully enumerated domain with an empty mutable tier has nothing left to produce: the interpreter's stream stays exhausted and tier membership only changes on admissions, which need evaluations. Waiting out the plateau window instead would burn up to half the budget on a hot loop.
                        let now = monotonicNanoseconds()
                        let deadline = startNanoseconds + configuration.budgetNanoseconds
                        return .plateau(unusedNanoseconds: deadline > now ? deadline - now : 0)
                    case let .generationError(message):
                        return .generationError(message)
                }
                continue
            }

            for _ in 0 ..< FuzzTunables.childrenPerParent {
                if terminationDue() != nil {
                    break
                }
                let (mutated, armsMask) = nextCandidate(from: parent, parentIndex: parentIndex)
                if let child = childCandidate(
                    from: mutated,
                    parent: parent,
                    parentIndex: parentIndex,
                    armsMask: armsMask,
                    origin: .mutationChild
                ) {
                    evaluate(child)
                }
            }
        }
    }

    /// The fresh-draw mixture in effect for the current iteration.
    ///
    /// The ramp climbs linearly from ``FuzzTunables/freshMixtureFloor`` to ``FuzzTunables/freshMixtureCap`` as attempts accumulate without a corpus admission, and any admission resets it to the floor, so the mixture responds to corpus health the way FuzzChick's queue-energy scheduler does instead of betting on one constant.
    package func currentFreshMixture(attemptsSinceAdmission: Int) -> Double {
        let floor = FuzzTunables.freshMixtureFloor
        let cap = FuzzTunables.freshMixtureCap
        let progress = min(1, Double(attemptsSinceAdmission) / FuzzTunables.freshMixtureRampAttempts)
        return floor + (cap - floor) * progress
    }

    /// Materializes a mutated sequence into a child candidate through guided materialization, or nil when the materializer rejects it. Opens the mutation attempt before materializing, so a rejected child still counts.
    ///
    /// Flat emission produces the value, the fresh sequence, and its hash without building a ChoiceTree; the tree is rebuilt by ``evaluate(_:)`` only for the rare candidates that consume it.
    func childCandidate(
        from mutated: ChoiceSequence,
        parent: CorpusEntry,
        parentIndex: Int,
        armsMask: UInt32,
        origin: CandidateOrigin
    ) -> FuzzCandidate<Output>? {
        openMutationAttempt()
        let guidedSeed = prng.next()
        let result = Materializer.materializeAnyFlat(
            erasedGen,
            prefix: mutated,
            mode: .guided(seed: guidedSeed, fallbackTree: parent.tree)
        )
        guard case let .success(anyValue, sequence, decodingReport) = result else {
            counts.discardedAttempts += 1
            return nil
        }
        return FuzzCandidate(
            sequence: sequence,
            hash: ZobristHash.hash(of: sequence),
            // swiftlint:disable:next force_cast
            value: anyValue as! Output,
            tree: nil,
            convergence: decodingReport?.convergence ?? 0,
            generation: parent.generation + 1,
            phase: .mutation,
            origin: origin,
            parentIndex: parentIndex,
            parentHash: parent.hash,
            armsMask: armsMask,
            isBoundaryDerived: false
        )
    }

    /// Evaluates one candidate: the recent-duplicate check, the property inside the attribution bracket, the tree rebuild for the candidates that consume it, the corpus offer, failure dispatch, and bandit credit. Every producer, screening rows included, ends here, so the attempt accounting and the breadcrumb live in one place.
    ///
    /// The tree is rebuilt only when something downstream reads it. Admission stores it as the mutation fallback, and the prune hook consumes it on the same failure-or-would-admit condition it fires on, so both rebuild eagerly here (`wouldAdmit` and offer's admission share one novelty predicate, and flat-materialized offers are never boundary-derived, so a candidate that fails the check can never have its placeholder tree stored). A plain failure consumes the tree only if the failure gate dispatches a reduction, a small minority once a fault's clusters are known, so the failure path defers the rebuild to that dispatch instead of paying a second materialization for every failing candidate. Coverage from a rebuild cannot pollute the next attempt: rebuilds, like reduction probes, run outside any bracket, and the next bracket begins with beginAttempt(), which clears attribution state.
    @discardableResult
    func evaluate(_ candidate: consuming FuzzCandidate<Output>) -> FuzzEvaluation {
        // Screening rows are distinct by construction and are never entered in the recent-hash table, as in #exhaust.
        if candidate.origin != .screeningRow, isRecentDuplicate(hash: candidate.hash) {
            openPhaseAttempt(candidate.phase, parentIndex: candidate.parentIndex)
            noteDuplicateSkip(candidate.origin)
            return FuzzEvaluation(admission: .rejectedDuplicate, verdict: nil)
        }
        let (verdict, hits) = evaluateInBracket(
            candidate.value,
            recordingBreadcrumb: (candidateHash: candidate.hash, parentHash: candidate.parentHash, sequence: candidate.sequence)
        )

        var deferredTreeRebuild: (() -> ChoiceTree?)?
        if candidate.tree == nil {
            if corpus.wouldAdmit(hits: hits) || (prune != nil && verdict.isFailure) {
                guard let rebuilt = rebuildTree(for: candidate.sequence) else {
                    openPhaseAttempt(candidate.phase, parentIndex: candidate.parentIndex)
                    counts.discardedAttempts += 1
                    return FuzzEvaluation(admission: .rejectedNotNovel, verdict: nil)
                }
                candidate.tree = rebuilt
            } else if verdict.isFailure {
                let sequence = candidate.sequence
                deferredTreeRebuild = { self.rebuildTree(for: sequence) }
            }
        }

        let admission = recordAttempt(
            candidate,
            deferredTreeRebuild: deferredTreeRebuild,
            verdict: verdict,
            hits: hits
        )
        if admission.isAdmitted, configuration.experiments.banditBands {
            for arm in MutationArm.allCases where candidate.armsMask & (1 << UInt32(arm.rawValue)) != 0 {
                bandit.reward(arm)
            }
        }
        return FuzzEvaluation(admission: admission, verdict: verdict)
    }

    // MARK: - Shared Attempt Plumbing

    /// The sole incrementer of `counts.mutationAttempts`: each mutation-phase candidate opportunity opens through here exactly once, so the invariant lives in one place instead of three coordinated comments. Opened by the producer, before materialization, so candidates the materializer discards still count. The child loop and the field graft open their own opportunities; parentless paths (fresh draws and whole-value injection) open theirs inside ``evaluate(_:)``.
    func openMutationAttempt() {
        counts.mutationAttempts += 1
    }

    /// Opens the phase's attempt tally for a candidate opportunity no producer opened.
    ///
    /// A rejection returns before ``recordAttempt(value:tree:sequence:sequenceHash:deferredTreeRebuild:verdict:hits:convergence:generation:phase:isBoundaryDerived:parentIndex:)``, so without this it lands in `duplicateCandidatesSkipped` or `discardedAttempts` and in no phase tally: `totalAttempts` stops covering the rejections and an attempt-limited run runs past its limit.
    ///
    /// Screening opens none, since its tally is reconciled to the covering array's row count once the phase ends. A mutation candidate with a parent opened its opportunity in the producer, before materialization.
    func openPhaseAttempt(_ phase: FuzzPhase, parentIndex: Int?) {
        switch phase {
            case .screening:
                break
            case .sampling:
                counts.samplingAttempts += 1
            case .mutation:
                if parentIndex == nil {
                    openMutationAttempt()
                }
        }
    }

    /// One fresh interpreter draw, shared by Phase 2 and the mutation phase's fresh mixture and empty-tier fallback.
    enum FreshDraw: ~Copyable {
        case drawn(FuzzCandidate<Output>)
        /// The interpreter returned nil; its stream is exhausted.
        case exhausted
        case generationError(String)
    }

    /// Draws one fresh candidate from `interpreter` under `phase`.
    ///
    /// The draw is flat: the interpreter emits the sequence the loop hashes and offers on every attempt and builds no tree. Building a tree to flatten and drop it was 6% of a mutation-phase run under the adaptive fresh mixture.
    private func freshCandidate(
        interpreter: inout ValueAndChoiceTreeInterpreter<Output>,
        phase: FuzzPhase
    ) -> FreshDraw {
        let generated: (value: Output, sequence: ChoiceSequence)?
        do {
            generated = try interpreter.nextFlat()
        } catch {
            return .generationError(String(describing: error))
        }
        guard let (value, sequence) = generated else {
            return .exhausted
        }
        return .drawn(FuzzCandidate(
            sequence: sequence,
            hash: ZobristHash.hash(of: sequence),
            value: value,
            tree: nil,
            convergence: 1.0,
            generation: 0,
            phase: phase,
            origin: .freshSample,
            parentIndex: nil,
            parentHash: 0,
            armsMask: 0,
            isBoundaryDerived: false
        ))
    }

    /// Rebuilds a candidate's tree by exact materialization of its stored sequence.
    ///
    /// The flat pass emits the complete sequence, and exact mode re-derives everything the flattening drops (`getSize` leaves, inactive branches, bind structure) from the generator walk, so the seed and the fallback tree that produced the candidate are not needed again. A nil return means exact mode rejected a sequence the materializer itself emitted, or its tree re-flattened differently; the caller discards the attempt rather than storing a placeholder tree. Measured 2026-09-06 on IFC and STLC: no such divergence, endpoints identical to the seed-and-fallback replay it replaced.
    private func rebuildTree(for sequence: ChoiceSequence) -> ChoiceTree? {
        guard case let .success(_, tree, _) = Materializer.materializeAny(erasedGen, prefix: sequence, mode: .exact),
              ChoiceSequence.flatten(tree) == sequence
        else {
            ExhaustLog.error(
                category: .propertyTest,
                event: "exact_rebuild_divergence",
                "exact materialization did not reproduce a sequence the flat pass emitted"
            )
            assertionFailure("flat-emission parity break: exact rebuild diverged from the emitted sequence")
            return nil
        }
        return tree
    }

    /// The post-evaluation epilogue: counts the attempt, offers the candidate, tracks admission recency, and dispatches failure handling with the admission's coverage-novelty signal.
    ///
    /// A candidate without a tree is offered with a placeholder. It cannot be stored: trees are rebuilt for every candidate that admits or fails.
    @discardableResult
    func recordAttempt(
        _ candidate: borrowing FuzzCandidate<Output>,
        deferredTreeRebuild: (() -> ChoiceTree?)?,
        verdict: FuzzVerdict,
        hits: [(edge: Int, hitCount: UInt8)]
    ) -> CorpusAdmission {
        let phase = candidate.phase
        let parentIndex = candidate.parentIndex
        let tree = candidate.tree ?? .just
        configuration.onAttempt?(phase, hits)
        openPhaseAttempt(phase, parentIndex: parentIndex)
        counts.evaluatedSearchCases += 1
        if verdict.isDiscard {
            counts.discardedEvaluations += 1
        }
        // An inconclusive evaluation stops here. Its hits describe a stalled execution, so offering them would admit the shape of a timeout as a mutation parent, mark the attempt as discovery, and reset the plateau window on it.
        if verdict.isInconclusive {
            counts.inconclusiveAttempts += 1
            let admission = CorpusAdmission.rejectedInconclusive
            noteAdmission(admission)
            return admission
        }

        // Value path: no prune hook, so the candidate offered and the candidate dispatched are both the original. Offering it directly skips the two generic carrier structs below, whose construction and teardown retained and released every field of the output type on every attempt.
        guard prune != nil else {
            let admission = corpus.offer(
                sequence: candidate.sequence,
                tree: tree,
                hits: hits,
                convergence: candidate.convergence,
                generation: candidate.generation,
                phase: phase,
                isBoundaryDerived: candidate.isBoundaryDerived,
                propertyFailed: verdict.isFailure,
                propertyDiscarded: verdict.isDiscard,
                precomputedHash: candidate.hash
            )
            noteAdmission(admission)
            if case let .fail(symptom) = verdict {
                handleFailure(
                    value: candidate.value,
                    tree: tree,
                    deferredTreeRebuild: deferredTreeRebuild,
                    sequence: candidate.sequence,
                    symptom: symptom,
                    parentIndex: parentIndex,
                    phase: phase,
                    coverageNovel: admission.isAdmitted,
                    attemptIndex: attemptTimelineIndex
                )
            }
            return admission
        }

        let originalCandidate = EvaluatedFuzzCandidate(
            value: candidate.value,
            tree: tree,
            sequence: candidate.sequence,
            sequenceHash: candidate.hash,
            verdict: verdict,
            hits: hits
        )
        let candidates = candidatesAfterPruning(
            original: originalCandidate,
            parentIndex: parentIndex
        )

        let admission = corpus.offer(
            sequence: candidates.corpus.sequence,
            tree: candidates.corpus.tree,
            hits: candidates.corpus.hits,
            convergence: candidate.convergence,
            generation: candidate.generation,
            phase: phase,
            isBoundaryDerived: candidate.isBoundaryDerived,
            propertyFailed: candidates.corpus.verdict.isFailure,
            propertyDiscarded: candidates.corpus.verdict.isDiscard,
            precomputedHash: candidates.corpus.sequenceHash
        )
        noteAdmission(admission)
        if let failure = candidates.failure,
           case let .fail(symptom) = failure.verdict
        {
            // A non-nil deferred rebuild implies no prune hook, so the failure candidate is always the original whose placeholder tree the rebuild replaces.
            handleFailure(
                value: failure.value,
                tree: failure.tree,
                deferredTreeRebuild: deferredTreeRebuild,
                sequence: failure.sequence,
                symptom: symptom,
                parentIndex: parentIndex,
                phase: phase,
                coverageNovel: candidates.independentFailureCoverageNovel
                    ?? admission.isAdmitted,
                attemptIndex: attemptTimelineIndex
            )
        }
        return admission
    }

    /// Tracks discovery recency and the admission-starvation counter behind the adaptive fresh mixture.
    private func noteAdmission(_ admission: CorpusAdmission) {
        // The cumulative record, not the admission masks: `resetNoveltyBaseline()` clears the masks at the screening handover, and a discovery clock driven off them restarts on the first sampling entry to touch an edge screening already covered.
        if case let .admitted(index, _) = admission, corpus.coveredRunFirstEdge(at: index) {
            lastNewEdgeNanoseconds = monotonicNanoseconds()
        }
        if admission.isAdmitted {
            attemptsSinceAdmission = 0
        } else {
            attemptsSinceAdmission += 1
        }
    }

    /// Re-evaluates a pruned corpus candidate without allowing a changed verdict to erase the failure observed by the original attempt.
    private func candidatesAfterPruning(
        original: EvaluatedFuzzCandidate<Output>,
        parentIndex: Int?
    ) -> PrunedCandidateSelection<Output> {
        guard let prune,
              original.verdict.isFailure || corpus.wouldAdmit(hits: original.hits)
        else {
            return PrunedCandidateSelection(
                corpus: original,
                failure: original.verdict.isFailure ? original : nil,
                independentFailureCoverageNovel: nil
            )
        }

        let pruned = prune(original.value, original.tree)
        let prunedSequence = ChoiceSequence.flatten(pruned.tree)
        let prunedSequenceHash = ZobristHash.hash(of: prunedSequence)
        // A hook that removed nothing hands back the sequence just evaluated, and re-running the property on it cannot answer differently.
        if prunedSequenceHash == original.sequenceHash, prunedSequence == original.sequence {
            counts.pruneIdentitySkips += 1
            return PrunedCandidateSelection(
                corpus: original,
                failure: original.verdict.isFailure ? original : nil,
                independentFailureCoverageNovel: nil
            )
        }
        // Recorded, not consulted: the pruned form has to be evaluated here whatever the table says, because its verdict and hits are what the corpus stores. Recording it is what lets a later candidate that mutates into the same pruned form skip.
        _ = isRecentDuplicate(hash: prunedSequenceHash)
        let parentHash = parentIndex.map { corpus.entries[$0].hash } ?? 0
        let (prunedVerdict, prunedHits) = evaluateInBracket(
            pruned.value,
            recordingBreadcrumb: (
                candidateHash: prunedSequenceHash,
                parentHash: parentHash,
                sequence: prunedSequence
            )
        )
        counts.pruneInvocations += 1
        let prunedCandidate = EvaluatedFuzzCandidate(
            value: pruned.value,
            tree: pruned.tree,
            sequence: prunedSequence,
            sequenceHash: prunedSequenceHash,
            verdict: prunedVerdict,
            hits: prunedHits
        )

        // A pruning probe without a verdict says nothing about the candidate; the original evaluation stands. The original is never inconclusive or escaped here: `recordAttempt` drops those before pruning.
        switch prunedVerdict {
            case .inconclusive, .escaped:
                return PrunedCandidateSelection(
                    corpus: original,
                    failure: original.verdict.isFailure ? original : nil,
                    independentFailureCoverageNovel: nil
                )
            case .pass, .discard, .fail:
                break
        }
        // The corpus stores the pruned form. The failure dispatched is the pruned form when it fails with the original's symptom or when only it failed, and the original when pruning changed or removed the failure, with novelty then judged on the original's own hits. The spec path's prune hook never discards; a discard is simply not a failure.
        guard case let .fail(originalSymptom) = original.verdict else {
            return PrunedCandidateSelection(
                corpus: prunedCandidate,
                failure: prunedVerdict.isFailure ? prunedCandidate : nil,
                independentFailureCoverageNovel: nil
            )
        }
        if case let .fail(prunedSymptom) = prunedVerdict, prunedSymptom == originalSymptom {
            return PrunedCandidateSelection(
                corpus: prunedCandidate,
                failure: prunedCandidate,
                independentFailureCoverageNovel: nil
            )
        }
        return PrunedCandidateSelection(
            corpus: prunedCandidate,
            failure: original,
            independentFailureCoverageNovel: corpus.wouldAdmit(hits: original.hits)
        )
    }

    /// One uniform draw in [0, 1) from the run PRNG (the top 53 bits of one 64-bit draw), so probability-space decisions replay deterministically under a pinned seed.
    func randomUnit() -> Double {
        Double(prng.next() >> 11) / Double(1 << 53)
    }
}
