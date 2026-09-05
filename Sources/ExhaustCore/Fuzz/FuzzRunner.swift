// The three-phase coverage-guided exploration loop behind `#explore(time:)`.

import Foundation

private struct EvaluatedFuzzCandidate<Output> {
    let value: Output
    let tree: ChoiceTree
    let sequence: ChoiceSequence
    /// `ZobristHash.hash(of:)` of `sequence` when the producing path already computed it for the crash breadcrumb, so corpus admission does not hash the same sequence twice. Nil on paths that never hashed (screening rows).
    let sequenceHash: UInt64?
    let verdict: FuzzVerdict
    let hits: [(edge: Int, hitCount: UInt8)]
}

private struct PrunedCandidateSelection<Output> {
    let corpus: EvaluatedFuzzCandidate<Output>
    let failure: EvaluatedFuzzCandidate<Output>?
    let independentFailureCoverageNovel: Bool?
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
        gate = ReductionGate(experiments: configuration.experiments)
        prng = Xoshiro256(seed: configuration.seed)
        var arms = MutationArm.legacyArms
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
        if source.reportsLiveCoverage, sawAnyEdge == false, counts.evaluatedSearchCases > 0 {
            finalTermination = .coverageUnreachable
        }

        counts.operandEnergyEvictions = operandEnergy.evictions
        counts.operandEnergySeatings = operandEnergy.seatings
        counts.operandEnergyRetirements = operandEnergy.retirements

        let clusters = inventory.snapshot()
        let unmatched = inventory.unmatchedUnreducedCounts

        // Report-time statistics: the live loop stored only BitSets; the ranking runs once, here.
        let passing = PassingSample(signatures: corpus.passingSignatures, edgeCount: source.edgeCount)
        let discriminations = clusters.map { cluster in
            CoverageDiscrimination.discriminate(
                clusterID: cluster.id,
                failingSignatures: cluster.signatures,
                passing: passing,
                edgeCount: source.edgeCount
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
            mutableTierCount: corpus.mutableTierIndices.count,
            coveredEdgeCount: incidence.covered,
            instrumentedEdgeCount: source.edgeCount,
            edgeSingletonCount: incidence.singletons,
            edgeDoubletonCount: incidence.doubletons,
            edgeTripletonCount: incidence.tripletons,
            edgeQuadrupletonCount: incidence.quadrupletons,
            incidenceTotal: corpus.incidenceTotal,
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
            offLaneEdgeHits: max(0, source.offLaneHitCount - offLaneHitsAtStart)
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
        // The verdict and hits captured by the property wrapper are read by onExample, which fires synchronously after each evaluation and before the next bracket begins.
        var lastVerdict = FuzzVerdict.pass
        var lastHits: [(edge: Int, hitCount: UInt8)] = []

        let wrappedProperty: (Output) -> Bool = { [self] value in
            let (verdict, hits) = evaluateInBracket(value, recordingBreadcrumb: nil)
            lastVerdict = verdict
            lastHits = hits
            return verdict.isFailure == false
        }

        // The breadcrumb clears before the row is built: screening evaluates before its tree reaches onExample, so the candidate cannot be identified pre-evaluation, and a cleared slot beats misattributing a trap to the previous attempt. The attribution bracket itself opens inside evaluateInBracket, around the property call, for every phase alike.
        let beforeRow: () -> Void = { [self] in
            // Counted before the row runs, so a failure classified inside this row sees a 1-based attempt index like every other phase; the post-phase assignment below reconciles to the runner's own tally, which counts the same rows.
            counts.screeningAttempts += 1
            breadcrumb?.clear()
        }

        let result = ScreeningRunner.run(
            gen,
            screeningBudget: min(configuration.screeningBudget, remainingAttemptBudget()),
            // The run seed, so the screening rows are pinned by the same seed that pins every other search decision. An unseeded #explore draws a fresh seed per run, which rotates the rows the same way a fresh #exhaust run does.
            coveringSeed: configuration.seed,
            continuePastFailure: true,
            beforeRow: beforeRow,
            property: wrappedProperty,
            onExample: { [self] value, tree, _ in
                checkpointIfDue()
                // Every covering-array row is boundary-derived; convergence is 1 because the tree came straight from materialization.
                recordAttempt(
                    value: value,
                    tree: tree,
                    sequence: ChoiceSequence.flatten(tree),
                    verdict: lastVerdict,
                    hits: lastHits,
                    convergence: 1.0,
                    generation: 0,
                    phase: .screening,
                    isBoundaryDerived: true
                )
            },
            shouldTerminate: { [self] in
                terminationDue() != nil
            }
        )
        counts.screeningAttempts = result.summary.rowAttempts
        counts.screeningRejectedAttempts = result.summary.rejectedRows
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

            switch freshSample(interpreter: &interpreter, phase: .sampling) {
                case let .evaluated(admission):
                    if admission.isAdmitted {
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
        let attempts = counts.evaluatedSearchCases
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
        // Reseed burst interpreter, distinct from both Phase 2's seed and the empty-tier fallback's. Created once and advanced across bursts so each plateau escape sees fresh samples.
        var reseedInterpreter = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: false,
            seed: configuration.seed ^ 0x2E_5EED_B005_7000,
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
                    if configuration.experiments.reseedBurst,
                       runReseedBurst(interpreter: &reseedInterpreter)
                    {
                        continue
                    }
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

            // Fresh-draw mixture: with the current mixture probability, spend this iteration on one fresh generator draw instead of a parent batch, keeping sampling alive as a background rate. Fresh draws reach basins no corpus entry has visited, which corpus-uniform exploration cannot. The adaptive ramp (floor to cap over a starvation window of non-admitting attempts) responds to corpus health; with the ramp disabled the fixed epsilon governs alone.
            let freshEpsilon = currentFreshMixture(attemptsSinceAdmission: attemptsSinceAdmission)
            if freshEpsilon > 0, randomUnit() < freshEpsilon {
                switch freshSample(interpreter: &fallbackInterpreter, phase: .mutation) {
                    case .evaluated, .exhausted:
                        continue
                    case let .generationError(message):
                        return .generationError(message)
                }
            }

            guard let (parentIndex, parent) = corpus.pickParent(random: randomUnit()) else {
                // Empty mutable tier: fall back to fresh sampling until something is mutable.
                switch freshSample(interpreter: &fallbackInterpreter, phase: .mutation) {
                    case .evaluated:
                        break
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

            let childBudget = configuration.experiments.powerSchedule
                ? corpus.powerScheduleChildren(forParentAt: parentIndex, base: FuzzTunables.childrenPerParent)
                : FuzzTunables.childrenPerParent

            // Campaign dispatch: a gate-open parent spends this visit's child budget on one coordinated probe session instead of independent draws. Campaign candidates bypass the swarm rewrite deliberately — scrambling branch selections would break the session's coordination.
            if configuration.experiments.campaignMutation,
               corpus.childrenSinceAdmission(forParentAt: parentIndex) >= FuzzTunables.campaignStallThreshold,
               randomUnit() < FuzzTunables.campaignShare,
               runCampaign(parent: parent, parentIndex: parentIndex, budget: childBudget)
            {
                continue
            }
            for _ in 0 ..< childBudget {
                if terminationDue() != nil {
                    break
                }
                let (mutated, armsMask) = nextCandidate(from: parent, parentIndex: parentIndex)
                openMutationAttempt()
                evaluateFuzzCandidate(
                    mutated,
                    parent: parent,
                    parentIndex: parentIndex,
                    armsMask: armsMask,
                    origin: .mutationChild
                )
            }
        }
    }

    /// The fresh-draw mixture in effect for the current iteration: the adaptive starvation ramp when configured, the fixed epsilon otherwise.
    ///
    /// The ramp climbs linearly from ``FuzzTunables/freshMixtureFloor`` to ``FuzzTunables/freshMixtureCap`` as attempts accumulate without a corpus admission, and any admission resets it to the floor, so the mixture responds to corpus health the way FuzzChick's queue-energy scheduler does instead of betting on one constant. A cap at or below the floor disables the ramp.
    package func currentFreshMixture(attemptsSinceAdmission: Int) -> Double {
        let floor = FuzzTunables.freshMixtureFloor
        let cap = FuzzTunables.freshMixtureCap
        guard cap > floor else {
            return FuzzTunables.freshDrawEpsilon
        }
        let progress = min(1, Double(attemptsSinceAdmission) / FuzzTunables.freshMixtureRampAttempts)
        return floor + (cap - floor) * progress
    }

    /// Draws fresh samples to break out of a mutation plateau, returning true when a new edge or fault cluster was discovered and mutation should resume.
    ///
    /// Phase 2's sampling plateau fired against a smaller corpus; after mutation expanded coverage, the generator may still reach edges nothing in the corpus covers. The burst is a fixed attempt budget rather than a consecutive-non-novel window, so a generator that produces only bucket-novel entries (no new edges) does not prolong the burst indefinitely.
    private func runReseedBurst(
        interpreter: inout ValueAndChoiceTreeInterpreter<Output>
    ) -> Bool {
        let discoveryAtEntry = lastDiscoveryNanoseconds
        for _ in 0 ..< FuzzTunables.reseedBurstAttemptLimit {
            if terminationDue() != nil {
                return lastDiscoveryNanoseconds > discoveryAtEntry
            }
            checkpointIfDue()
            switch freshSample(interpreter: &interpreter, phase: .mutation) {
                case .evaluated:
                    if lastDiscoveryNanoseconds > discoveryAtEntry {
                        return true
                    }
                case .exhausted, .generationError:
                    return lastDiscoveryNanoseconds > discoveryAtEntry
            }
        }
        return lastDiscoveryNanoseconds > discoveryAtEntry
    }

    /// Per-candidate outcome handed back to the producing arm. Campaigns steer their next probe on it; single-shot arms discard it.
    struct CandidateFeedback {
        /// Whether guided materialization produced a value and the property ran.
        let materialized: Bool
        /// Whether the property declined to judge the value (its precondition was not met).
        let discarded: Bool
        /// Whether the corpus admitted the candidate.
        let admitted: Bool
        /// Whether the property failed on the candidate. A producing arm can be worth its attempts through faults alone: an operand that satisfies a precondition reaches a failure without necessarily lighting an edge the corpus would admit for.
        let failed: Bool
    }

    @discardableResult
    func evaluateFuzzCandidate(
        _ candidate: ChoiceSequence,
        parent: CorpusEntry,
        parentIndex: Int,
        armsMask: UInt32,
        origin: CandidateOrigin
    ) -> CandidateFeedback {
        // Phase 1: flat emission produces the value, the fresh sequence, and (below) its hash without building a ChoiceTree. The tree is rebuilt in phase 2 only for the rare candidates that consume it: corpus admission and failure dispatch.
        let guidedSeed = prng.next()
        let result = Materializer.materializeAnyFlat(
            erasedGen,
            prefix: candidate,
            mode: .guided(seed: guidedSeed, fallbackTree: parent.tree)
        )
        guard case let .success(anyValue, sequence, decodingReport) = result else {
            counts.discardedAttempts += 1
            corpus.noteChild(forParentAt: parentIndex, admitted: false)
            return CandidateFeedback(materialized: false, discarded: true, admitted: false, failed: false)
        }
        // swiftlint:disable:next force_cast
        let value = anyValue as! Output
        let sequenceHash = ZobristHash.hash(of: sequence)
        if isRecentDuplicate(hash: sequenceHash) {
            noteDuplicateSkip(origin)
            corpus.noteChild(forParentAt: parentIndex, admitted: false)
            return CandidateFeedback(materialized: true, discarded: false, admitted: false, failed: false)
        }
        let (verdict, hits) = evaluateInBracket(
            value,
            recordingBreadcrumb: (candidateHash: sequenceHash, parentHash: parent.hash, sequence: sequence)
        )

        // Phase 2: rebuild the tree only when something downstream reads it. Admission stores the tree as the mutation fallback, and the prune hook consumes it on the same failure-or-would-admit condition it fires on, so both rebuild eagerly here (`wouldAdmit` and offer's admission share one novelty predicate, and mutation-phase offers are never boundary-derived, so a candidate that fails the check can never have its placeholder tree stored). A plain failure consumes the tree only if the failure gate dispatches a reduction — a small minority once a fault's clusters are known — so the failure path defers the rebuild to that dispatch instead of paying a second materialization for every failing candidate. Coverage from a rebuild cannot pollute the next attempt: rebuilds, like reduction probes, run outside any bracket, and the next bracket begins with beginAttempt(), which clears attribution state.
        let admissionNovel = corpus.wouldAdmit(hits: hits)
        var tree = ChoiceTree.just
        var deferredTreeRebuild: (() -> ChoiceTree?)?
        if admissionNovel || (prune != nil && verdict.isFailure) {
            guard let rebuilt = rebuildGuidedTree(
                candidate: candidate,
                seed: guidedSeed,
                fallbackTree: parent.tree,
                expecting: sequence
            ) else {
                counts.discardedAttempts += 1
                corpus.noteChild(forParentAt: parentIndex, admitted: false)
                return CandidateFeedback(materialized: false, discarded: true, admitted: false, failed: false)
            }
            tree = rebuilt
        } else if verdict.isFailure {
            let parentTree = parent.tree
            deferredTreeRebuild = {
                self.rebuildGuidedTree(
                    candidate: candidate,
                    seed: guidedSeed,
                    fallbackTree: parentTree,
                    expecting: sequence
                )
            }
        }

        let admission = recordAttempt(
            value: value,
            tree: tree,
            sequence: sequence,
            sequenceHash: sequenceHash,
            deferredTreeRebuild: deferredTreeRebuild,
            verdict: verdict,
            hits: hits,
            convergence: decodingReport?.convergence ?? 0,
            generation: parent.generation + 1,
            phase: .mutation,
            parentIndex: parentIndex
        )
        if admission.isAdmitted, configuration.experiments.banditBands {
            for arm in MutationArm.allCases where armsMask & (1 << UInt32(arm.rawValue)) != 0 {
                bandit.reward(arm)
            }
        }
        corpus.noteChild(forParentAt: parentIndex, admitted: admission.isAdmitted)
        return CandidateFeedback(
            materialized: true,
            discarded: verdict.isDiscard,
            admitted: admission.isAdmitted,
            failed: verdict.isFailure
        )
    }

    /// Re-materializes the guided tree for a flat-emission candidate and verifies it flattens to the phase-1 sequence.
    ///
    /// The rebuild is deterministic for identical candidate, seed, and fallback, so a nil return marks an impossible parity break; the caller decides whether that discards the attempt (eager path) or skips the consumer (deferred path).
    private func rebuildGuidedTree(
        candidate: ChoiceSequence,
        seed: UInt64,
        fallbackTree: ChoiceTree,
        expecting sequence: ChoiceSequence
    ) -> ChoiceTree? {
        let rebuilt = Materializer.materializeAny(
            erasedGen,
            prefix: candidate,
            mode: .guided(seed: seed, fallbackTree: fallbackTree)
        )
        guard case let .success(_, freshTree, _) = rebuilt,
              ChoiceSequence.flatten(freshTree) == sequence
        else {
            ExhaustLog.error(
                category: .propertyTest,
                event: "flat_emission_rebuild_divergence",
                "guided tree rebuild diverged from the flat-emission sequence for an identical candidate, seed, and fallback"
            )
            assertionFailure("flat-emission parity break: guided tree rebuild diverged for identical inputs")
            return nil
        }
        return freshTree
    }

    // MARK: - Shared Attempt Plumbing

    /// The sole incrementer of `counts.mutationAttempts`: each mutation-phase candidate opportunity opens through here exactly once, so the invariant lives in one place instead of three coordinated comments. Opened by the producer, before materialization, so candidates the materializer discards still count. The child loop and the field graft open their own opportunities; parentless paths (the empty-tier fallback and whole-value injection) open theirs through ``recordAttempt(value:tree:sequence:sequenceHash:deferredTreeRebuild:verdict:hits:convergence:generation:phase:isBoundaryDerived:parentIndex:)``.
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

    /// The outcome of one fresh interpreter sample, shared by Phase 2 and the mutation phase's empty-tier fallback.
    private enum FreshSampleOutcome {
        case evaluated(CorpusAdmission)
        /// The interpreter returned nil; its stream is exhausted.
        case exhausted
        case generationError(String)
    }

    /// Draws one fresh sample from `interpreter`, evaluates it in the attribution bracket, and records the attempt under `phase`.
    ///
    /// The draw is flat: the interpreter emits the sequence the loop hashes and offers on every attempt and builds no tree. The tree is read only by admission (the mutation fallback), the prune hook, and reduction, so it is rebuilt just for the candidates that fail or would be admitted, the discipline ``evaluateFuzzCandidate(_:parent:parentIndex:armsMask:origin:)`` applies to mutated candidates. Building a tree to flatten and drop it was 6% of a mutation-phase run under the adaptive fresh mixture.
    private func freshSample(
        interpreter: inout ValueAndChoiceTreeInterpreter<Output>,
        phase: FuzzPhase
    ) -> FreshSampleOutcome {
        let generated: (value: Output, sequence: ChoiceSequence)?
        do {
            generated = try interpreter.nextFlat()
        } catch {
            return .generationError(String(describing: error))
        }
        guard let (value, sequence) = generated else {
            return .exhausted
        }
        let sequenceHash = ZobristHash.hash(of: sequence)
        if isRecentDuplicate(hash: sequenceHash) {
            openPhaseAttempt(phase, parentIndex: nil)
            noteDuplicateSkip(.freshSample)
            return .evaluated(.rejectedDuplicate)
        }
        let (verdict, hits) = evaluateInBracket(
            value,
            recordingBreadcrumb: (candidateHash: sequenceHash, parentHash: 0, sequence: sequence)
        )

        var tree = ChoiceTree.just
        if verdict.isFailure || corpus.wouldAdmit(hits: hits) {
            guard let rebuilt = rebuildFreshTree(interpreter: &interpreter, expecting: sequence) else {
                openPhaseAttempt(phase, parentIndex: nil)
                counts.discardedAttempts += 1
                return .evaluated(.rejectedNotNovel)
            }
            tree = rebuilt
        }

        let admission = recordAttempt(
            value: value,
            tree: tree,
            sequence: sequence,
            sequenceHash: sequenceHash,
            verdict: verdict,
            hits: hits,
            convergence: 1.0,
            generation: 0,
            phase: phase
        )
        return .evaluated(admission)
    }

    /// Rebuilds the tree of the interpreter's most recent flat draw by replaying the run from its seed, and verifies it flattens to the sequence the draw emitted.
    ///
    /// The replay is deterministic for the same run index, seed, and unique-site decisions, so a nil return marks an impossible parity break between the flat and tree-building walks; the caller drops the attempt rather than admitting a placeholder tree.
    private func rebuildFreshTree(
        interpreter: inout ValueAndChoiceTreeInterpreter<Output>,
        expecting sequence: ChoiceSequence
    ) -> ChoiceTree? {
        guard let (_, tree) = try? interpreter.reproduceWithTree(),
              ChoiceSequence.flatten(tree) == sequence
        else {
            ExhaustLog.error(
                category: .propertyTest,
                event: "flat_draw_rebuild_divergence",
                "tree rebuild diverged from the flat draw's sequence for an identical run and seed"
            )
            assertionFailure("flat draw parity break: tree rebuild diverged for an identical run and seed")
            return nil
        }
        return tree
    }

    /// The shared post-evaluation epilogue: counts the attempt, offers the candidate to the corpus, tracks admission recency, and dispatches failure handling with the admission's coverage-novelty signal.
    @discardableResult
    func recordAttempt(
        value: Output,
        tree: ChoiceTree,
        sequence: ChoiceSequence,
        sequenceHash: UInt64? = nil,
        deferredTreeRebuild: (() -> ChoiceTree?)? = nil,
        verdict: FuzzVerdict,
        hits: [(edge: Int, hitCount: UInt8)],
        convergence: Double,
        generation: Int,
        phase: FuzzPhase,
        isBoundaryDerived: Bool = false,
        parentIndex: Int? = nil
    ) -> CorpusAdmission {
        configuration.onAttempt?(phase, hits)
        openPhaseAttempt(phase, parentIndex: parentIndex)
        counts.evaluatedSearchCases += 1
        if verdict.isDiscard {
            counts.discardedEvaluations += 1
        }
        // An inconclusive evaluation stops here. Its hits describe a stalled execution, so offering them would admit the shape of a timeout as a mutation parent, mark the attempt as discovery, and reset the plateau window on it.
        if verdict.isInconclusive {
            counts.inconclusiveAttempts += 1
            return .rejectedInconclusive
        }

        // Value path: no prune hook, so the candidate offered and the candidate dispatched are both the original. Offering it directly skips the two generic carrier structs below, whose construction and teardown retained and released every field of the output type on every attempt.
        guard prune != nil else {
            let admission = corpus.offer(
                sequence: sequence,
                tree: tree,
                hits: hits,
                convergence: convergence,
                generation: generation,
                phase: phase,
                isBoundaryDerived: isBoundaryDerived,
                propertyFailed: verdict.isFailure,
                propertyDiscarded: verdict.isDiscard,
                precomputedHash: sequenceHash
            )
            noteAdmission(admission)
            if case let .fail(symptom) = verdict {
                handleFailure(
                    value: value,
                    tree: tree,
                    deferredTreeRebuild: deferredTreeRebuild,
                    sequence: sequence,
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
            value: value,
            tree: tree,
            sequence: sequence,
            sequenceHash: sequenceHash,
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
            convergence: convergence,
            generation: generation,
            phase: phase,
            isBoundaryDerived: isBoundaryDerived,
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

        switch (original.verdict, prunedVerdict) {
            case let (.fail(originalSymptom), .fail(prunedSymptom))
            where originalSymptom == prunedSymptom:
                return PrunedCandidateSelection(
                    corpus: prunedCandidate,
                    failure: prunedCandidate,
                    independentFailureCoverageNovel: nil
                )
            // A pruning probe that reached no verdict says nothing about the candidate: its hits describe the stall. The original evaluation stands and is what the corpus sees. The `(.inconclusive, _)` and `(.escaped, _)` arms cannot be reached, because `recordAttempt` drops an inconclusive attempt before pruning.
            case (.fail, .inconclusive), (.fail, .escaped):
                return PrunedCandidateSelection(
                    corpus: original,
                    failure: original,
                    independentFailureCoverageNovel: nil
                )
            case (.pass, .inconclusive), (.pass, .escaped), (.discard, .inconclusive), (.discard, .escaped),
                 (.inconclusive, _), (.escaped, _):
                return PrunedCandidateSelection(
                    corpus: original,
                    failure: nil,
                    independentFailureCoverageNovel: nil
                )
            case (.fail, _):
                return PrunedCandidateSelection(
                    corpus: prunedCandidate,
                    failure: original,
                    independentFailureCoverageNovel: corpus.wouldAdmit(hits: original.hits)
                )
            case (.pass, .fail), (.discard, .fail):
                return PrunedCandidateSelection(
                    corpus: prunedCandidate,
                    failure: prunedCandidate,
                    independentFailureCoverageNovel: nil
                )
            // A discard on either side is not a failure; the pruned candidate carries the corpus verdict either way. The prune hook is the spec path's, which never discards, so the discard arms exist for exhaustiveness.
            case (.pass, .pass), (.pass, .discard), (.discard, .pass), (.discard, .discard):
                return PrunedCandidateSelection(
                    corpus: prunedCandidate,
                    failure: nil,
                    independentFailureCoverageNovel: nil
                )
        }
    }

    /// One uniform draw in [0, 1) from the run PRNG (the top 53 bits of one 64-bit draw), so probability-space decisions replay deterministically under a pinned seed.
    func randomUnit() -> Double {
        Double(prng.next() >> 11) / Double(1 << 53)
    }
}
