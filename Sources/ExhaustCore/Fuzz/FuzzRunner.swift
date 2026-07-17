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

/// The spec-path seams carried through `runExploreTimeCore` into ``FuzzRunner`` as one unit.
///
/// Nil on the value path. A spec adapter populates both fields: the prune hook keeps precondition-skipped commands out of the corpus, and the reduce strategy routes reduction through the spec's backend reducer (sequential specs reuse ``FuzzRunner/propertyOnlyReduceStrategy(gen:property:reducerConfiguration:)`` with the spec deadline; `.tasks` specs will wrap their two-pass reducer, which must run synchronously on the loop's lane: reduction is always inline so probes never pollute attempt coverage, and no concurrent dispatch context exists).
package struct FuzzHooks<Output> {
    /// Prunes the value and tree before corpus admission. Runs outside the attribution bracket, only on failures and would-be admissions.
    package let prune: @Sendable (Output, ChoiceTree) -> (value: Output, tree: ChoiceTree)
    /// Reduces one failing candidate, returning the reduced sequence, tree, and value.
    package let reduceStrategy: @Sendable (ChoiceTree, Output, FailureSymptom) -> FuzzReductionResult<Output>

    package init(
        prune: @escaping @Sendable (Output, ChoiceTree) -> (value: Output, tree: ChoiceTree),
        reduceStrategy: @escaping @Sendable (ChoiceTree, Output, FailureSymptom) -> FuzzReductionResult<Output>
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

    package init(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        value: Output,
        propertyInvocations: Int
    ) {
        self.sequence = sequence
        self.tree = tree
        self.value = value
        self.propertyInvocations = propertyInvocations
    }
}

/// Runs the covering-array, random-sampling, and mutation phases against one property, accumulating a corpus and a clustered fault inventory.
///
/// The runner is single-threaded: the corpus, gate, PRNG, and every instrumented evaluation — attempt brackets, reduction probes, classification re-runs — execute on the one GCD lane that owns `run()`. Reduction runs inline at the point of failure discovery, trading attempts for signal purity: no instrumented code ever executes concurrently with an open attempt bracket, so every coverage snapshot is attributable to exactly one evaluation and classification feedback lands at a deterministic point in the attempt stream.
package final class FuzzRunner<Output> {
    // Members without an access modifier are internal so the same-module extension files (FuzzRunner+Recovery, FuzzRunner+Mutation) can reach them; nothing outside the module sees them.
    private let gen: Generator<Output>
    let erasedGen: AnyGenerator
    let property: @Sendable (Output) -> FuzzVerdict
    let source: any CoverageSource
    let configuration: FuzzRunnerConfiguration
    /// Prunes the value and tree before corpus admission. Nil on the value path; the spec path removes precondition-skipped commands so the corpus stores only live sequences. Runs outside the attribution bracket, only on failures and would-be admissions.
    private let prune: (@Sendable (Output, ChoiceTree) -> (value: Output, tree: ChoiceTree))?
    /// The reduction the failure dispatch runs. The value path's default is ``propertyOnlyReduceStrategy(gen:property:reducerConfiguration:)``; the spec path injects its backend reducer through ``FuzzHooks``.
    private let reduceStrategy: @Sendable (ChoiceTree, Output, FailureSymptom) -> FuzzReductionResult<Output>

    /// Package-visible so tests can assert on corpus contents (tier membership, entry command counts) after a run.
    package let corpus: FuzzCorpus
    let inventory = FaultInventory()
    private var gate: ReductionGate
    var prng: Xoshiro256
    var bandit = MutationBandit()

    /// Renders a reduced counterexample for its cluster's report description. Injected because the render runs during reduction — the value never crosses back to a context that could render it later — while the runner's module must stay free of rendering dependencies. The default serves direct package-level construction (tests, harnesses); `runExploreTimeCore` supplies the production renderer.
    private let renderValue: @Sendable (Any) -> String

    /// Zobrist-keyed normalization results reused across reductions; boxed because ``FuzzNormalizer/normalize(reducedSequence:erasedGen:symptom:property:cache:)`` takes the shared-box type.
    private let normalizationCache = SendableBox<[UInt64: ChoiceSequence?]>([:])

    var startNanoseconds: UInt64 = 0
    private var lastAdmissionNanoseconds: UInt64 = 0
    var counts = FuzzRunCounts()
    private var timing = FuzzRunTiming()

    // MARK: - Crash-Recovery State

    // Owned by the recovery extension (see FuzzRunner+Recovery.swift); declared here because stored properties cannot live in an extension.

    var progressWriter: FuzzProgressWriter?
    var breadcrumb: FuzzBreadcrumb?
    var lastCheckpointNanoseconds: UInt64 = 0
    /// Set when a new cluster classifies so the next checkpoint fires immediately — discovered clusters must reach disk without waiting out the interval.
    var forceCheckpoint = false
    /// Run time consumed by crashed predecessors, so checkpoint accounting and report timestamps continue one logical timeline across resumes.
    var priorConsumedNanoseconds: UInt64 = 0
    var pcTableHashAtStart: UInt64 = 0

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
        renderValue: @escaping @Sendable (Any) -> String = { String(describing: $0) }
    ) {
        self.gen = gen
        erasedGen = gen.erase()
        self.property = property
        self.source = source
        self.configuration = configuration
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
    }

    /// The default reduce strategy: property-only `choiceGraphReduce`, reducing while the property fails exactly as `#exhaust` does. Reduction probes run inline on the loop's lane, outside any attempt bracket; their coverage is never read.
    ///
    /// The sequential spec adapter reuses this with the spec reduction deadline, so the value path and sequential spec path share one reduction implementation and differ only in configuration. On a reducer failure the input comes back unreduced.
    package static func propertyOnlyReduceStrategy(
        gen: Generator<Output>,
        property: @escaping @Sendable (Output) -> FuzzVerdict,
        reducerConfiguration: Interpreters.ReducerConfiguration
    ) -> @Sendable (ChoiceTree, Output, FailureSymptom) -> FuzzReductionResult<Output> {
        { tree, value, _ in
            let boolProperty: (Output) -> Bool = { property($0).isFailure == false }
            let result = try? Interpreters.choiceGraphReduceCollectingStats(
                gen: gen,
                tree: tree,
                output: value,
                config: reducerConfiguration,
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
                        propertyInvocations: propertyInvocations
                    )
                case .failure, nil:
                    return FuzzReductionResult(
                        sequence: ChoiceSequence.flatten(tree),
                        tree: tree,
                        value: value,
                        propertyInvocations: propertyInvocations
                    )
            }
        }
    }

    // MARK: - Run

    /// Executes the three phases and returns the final result. Synchronous; the caller owns GCD-lane placement.
    package func run() -> FuzzRunResult {
        startNanoseconds = monotonicNanoseconds()
        lastAdmissionNanoseconds = startNanoseconds
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
            let samplingMeasurement = measureSearchPhase {
                runSamplingPhase()
            }
            timing.samplingOverheadNanoseconds += samplingMeasurement.overheadNanoseconds
            termination = samplingMeasurement.result
        }
        if termination == nil, terminationDue() == nil {
            let mutationMeasurement = measureSearchPhase {
                runFuzzPhase()
            }
            timing.mutationOverheadNanoseconds += mutationMeasurement.overheadNanoseconds
            termination = mutationMeasurement.result
        }

        let finalTermination = termination ?? terminationDue() ?? .budgetExhausted

        let clusters = inventory.snapshot()
        let unmatched = inventory.unmatchedUnreducedCounts

        // Report-time statistics: the live loop stored only BitSets; the ranking runs once, here.
        let passingSignatures = corpus.passingSignatures
        let discriminations = clusters.map { cluster in
            CoverageDiscrimination.discriminate(
                clusterID: cluster.id,
                failingSignatures: cluster.signatures,
                passingSignatures: passingSignatures,
                edgeCount: source.edgeCount
            )
        }

        finishPersistence()
        let elapsedNanoseconds = monotonicNanoseconds() - startNanoseconds

        var ledger = RunLedger()
        ledger.record(.sampling, .pass, count: counts.evaluatedSearchCases)
        ledger.record(.pruning, .pass, count: counts.pruneInvocations)
        ledger.record(.reduction, .pass, count: counts.reductionInvocations)
        ledger.record(.normalization, .pass, count: counts.normalizationInvocations)
        ledger.record(.classification, .pass, count: counts.classificationInvocations)
        ledger.record(.recovery, .pass, count: counts.recoveryInvocations)
        ledger.addElapsed(.screening, nanoseconds: timing.screeningOverheadNanoseconds)
        ledger.addElapsed(.sampling, nanoseconds: timing.samplingOverheadNanoseconds + timing.propertyNanoseconds)
        ledger.addElapsed(.mutation, nanoseconds: timing.mutationOverheadNanoseconds)
        ledger.addElapsed(.reduction, nanoseconds: timing.reductionNanoseconds)

        return FuzzRunResult(
            clusters: clusters,
            unmatchedUnreducedCounts: unmatched,
            counts: counts,
            corpusEntryCount: corpus.entries.count,
            mutableTierCount: corpus.mutableTierIndices.count,
            coveredEdgeCount: corpus.coveredEdgeCount,
            instrumentedEdgeCount: source.edgeCount,
            edgeSingletonCount: corpus.edgeSingletonCount,
            edgeDoubletonCount: corpus.edgeDoubletonCount,
            termination: finalTermination,
            clusterDiscriminations: discriminations,
            startNanoseconds: reportEpochNanoseconds,
            elapsedNanoseconds: elapsedNanoseconds,
            timing: timing,
            ledger: ledger,
            seed: configuration.seed
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
            // Screening evaluates before its tree reaches onExample, so the candidate cannot be identified pre-evaluation; a cleared slot beats misattributing a trap to the previous attempt.
            breadcrumb?.clear()
            source.beginAttempt()
            let (verdict, hits) = evaluateInBracket(value, recordingBreadcrumb: nil)
            lastVerdict = verdict
            lastHits = hits
            return verdict.isFailure == false
        }

        let result = ScreeningRunner.run(
            gen,
            screeningBudget: min(configuration.screeningBudget, remainingAttemptBudget()),
            continuePastFailure: true,
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
            if samplesSinceNovelty >= FuzzTunables.samplingPlateauWindow {
                return nil
            }
            if monotonicNanoseconds() >= backstopNanoseconds {
                return nil
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

    // MARK: - Phase 3: Mutation

    private func runFuzzPhase() -> FuzzTermination {
        // Fallback sampling for an empty mutable tier reuses the interpreter idiom with a derived seed so it does not replay Phase 2's stream.
        var fallbackInterpreter = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: false,
            seed: configuration.seed ^ 0x5EED_FA11_BACC_0FFE,
            maxRuns: UInt64.max
        )
        let plateauWindowNanoseconds = UInt64(
            Double(configuration.budgetNanoseconds) * FuzzTunables.plateauBudgetFraction
        )

        while true {
            if let termination = terminationDue() {
                return termination
            }
            let now = monotonicNanoseconds()
            if now - lastAdmissionNanoseconds >= plateauWindowNanoseconds {
                let deadline = startNanoseconds + configuration.budgetNanoseconds
                return .plateau(unusedNanoseconds: deadline > now ? deadline - now : 0)
            }
            checkpointIfDue()

            guard let (parentIndex, parent) = corpus.pickParent(random: randomUnit()) else {
                // Empty mutable tier: fall back to fresh sampling until something is mutable.
                switch freshSample(interpreter: &fallbackInterpreter, phase: .mutation) {
                    case .evaluated:
                        break
                    case .exhausted:
                        break
                    case let .generationError(message):
                        return .generationError(message)
                }
                continue
            }

            let childBudget = configuration.experiments.powerSchedule
                ? corpus.powerScheduleChildren(forParentAt: parentIndex, base: FuzzTunables.childrenPerParent)
                : FuzzTunables.childrenPerParent
            for _ in 0 ..< childBudget {
                if terminationDue() != nil {
                    break
                }
                let (mutated, armsMask) = nextCandidate(from: parent)
                counts.mutationAttempts += 1
                evaluateFuzzCandidate(mutated, parent: parent, parentIndex: parentIndex, armsMask: armsMask)
            }
        }
    }

    private func evaluateFuzzCandidate(
        _ candidate: ChoiceSequence,
        parent: CorpusEntry,
        parentIndex: Int,
        armsMask: UInt8
    ) {
        source.beginAttempt()
        // Phase 1: flat emission produces the value, the fresh sequence, and (below) its hash without building a ChoiceTree. The tree is rebuilt in phase 2 only for the rare candidates that consume it: corpus admission and failure dispatch.
        let guidedSeed = prng.next()
        let result = Materializer.materializeAnyFlat(
            erasedGen,
            prefix: candidate,
            mode: .guided(seed: guidedSeed, fallbackTree: parent.tree)
        )
        guard case let .success(anyValue, sequence, decodingReport) = result else {
            counts.discardedAttempts += 1
            return
        }
        // swiftlint:disable:next force_cast
        let value = anyValue as! Output
        let sequenceHash = ZobristHash.hash(of: sequence)
        let (verdict, hits) = evaluateInBracket(
            value,
            recordingBreadcrumb: (candidateHash: sequenceHash, parentHash: parent.hash)
        )

        // Phase 2: rebuild the tree only when something downstream reads it. Admission stores the tree as the mutation fallback, and the prune hook consumes it on the same failure-or-would-admit condition it fires on, so both rebuild eagerly here (`wouldAdmit` and offer's admission share one novelty predicate, and mutation-phase offers are never boundary-derived, so a candidate that fails the check can never have its placeholder tree stored). A plain failure consumes the tree only if the failure gate dispatches a reduction — a small minority once a fault's clusters are known — so the failure path defers the rebuild to that dispatch instead of paying a second materialization for every failing candidate. Coverage from a rebuild cannot pollute the next attempt: an eager rebuild runs inside this attempt's bracket, a deferred one runs on the reduction dispatch's lane, and either way the next bracket begins with beginAttempt(), which clears attribution state (the same argument that covers inline reduction probes).
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
                return
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
            for arm in MutationArm.allCases where armsMask & (1 << UInt8(arm.rawValue)) != 0 {
                bandit.reward(arm)
            }
        }
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

    /// The outcome of one fresh interpreter sample, shared by Phase 2 and the mutation phase's empty-tier fallback.
    private enum FreshSampleOutcome {
        case evaluated(CorpusAdmission)
        /// The interpreter returned nil; its stream is exhausted.
        case exhausted
        case generationError(String)
    }

    /// Draws one fresh sample from `interpreter`, evaluates it under the attribution bracket, and records the attempt under `phase`.
    private func freshSample(
        interpreter: inout ValueAndChoiceTreeInterpreter<Output>,
        phase: FuzzPhase
    ) -> FreshSampleOutcome {
        source.beginAttempt()
        let generated: (Output, ChoiceTree)?
        do {
            generated = try interpreter.next()
        } catch {
            return .generationError(String(describing: error))
        }
        guard let (value, tree) = generated else {
            return .exhausted
        }
        let sequence = ChoiceSequence.flatten(tree)
        let sequenceHash = ZobristHash.hash(of: sequence)
        let (verdict, hits) = evaluateInBracket(
            value,
            recordingBreadcrumb: (candidateHash: sequenceHash, parentHash: 0)
        )

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

    /// The instrumented tail of one evaluation bracket: records the breadcrumb slot, notes the value, times the property, and collects the attempt's hits.
    ///
    /// Must run inside the attribution token, after `source.beginAttempt()` and after candidate production — generation and materialization can execute user code, and its coverage belongs to the attempt whose bracket is open.
    private func evaluateInBracket(
        _ value: Output,
        recordingBreadcrumb slot: (candidateHash: UInt64, parentHash: UInt64)?
    ) -> (verdict: FuzzVerdict, hits: [(edge: Int, hitCount: UInt8)]) {
        if let slot {
            breadcrumb?.record(candidateHash: slot.candidateHash, parentHash: slot.parentHash)
        }
        if source.wantsValues {
            source.noteValue(value)
        }
        let propertyStart = monotonicNanoseconds()
        let verdict = property(value)
        timing.propertyNanoseconds += monotonicNanoseconds() - propertyStart
        var hits: [(edge: Int, hitCount: UInt8)] = []
        source.forEachHitEdge { edge, hitCount in
            hits.append((edge, hitCount))
        }
        return (verdict, hits)
    }

    /// The shared post-evaluation epilogue: counts the attempt, offers the candidate to the corpus, tracks admission recency, and dispatches failure handling with the admission's coverage-novelty signal.
    @discardableResult
    private func recordAttempt(
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
        switch phase {
            case .screening:
                break
            case .sampling:
                counts.samplingAttempts += 1
            case .mutation:
                if parentIndex == nil {
                    counts.mutationAttempts += 1
                }
        }
        counts.evaluatedSearchCases += 1

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
            precomputedHash: candidates.corpus.sequenceHash
        )
        if admission.isAdmitted {
            lastAdmissionNanoseconds = monotonicNanoseconds()
        }
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
                    ?? admission.isAdmitted
            )
        }
        return admission
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
        let parentHash = parentIndex.map { corpus.entries[$0].hash } ?? 0
        source.beginAttempt()
        let (prunedVerdict, prunedHits) = evaluateInBracket(
            pruned.value,
            recordingBreadcrumb: (
                candidateHash: prunedSequenceHash,
                parentHash: parentHash
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
            case (.fail, _):
                return PrunedCandidateSelection(
                    corpus: prunedCandidate,
                    failure: original,
                    independentFailureCoverageNovel: corpus.wouldAdmit(hits: original.hits)
                )
            case (.pass, .fail):
                return PrunedCandidateSelection(
                    corpus: prunedCandidate,
                    failure: prunedCandidate,
                    independentFailureCoverageNovel: nil
                )
            case (.pass, .pass):
                return PrunedCandidateSelection(
                    corpus: prunedCandidate,
                    failure: nil,
                    independentFailureCoverageNovel: nil
                )
        }
    }

    // MARK: - Failure Handling

    private func handleFailure(
        value: Output,
        tree: ChoiceTree,
        deferredTreeRebuild: (() -> ChoiceTree?)? = nil,
        sequence: ChoiceSequence,
        symptom: FailureSymptom,
        parentIndex: Int?,
        phase: FuzzPhase,
        coverageNovel: Bool
    ) {
        if let parentIndex {
            corpus.applyProvisionalFailureBoost(toParentAt: parentIndex)
        }
        let hash = ZobristHash.hash(of: sequence)
        let attemptIndex = counts.totalAttempts
        switch gate.admit(sequenceHash: hash, symptom: symptom, coverageNovel: coverageNovel) {
            case .duplicate:
                return
            case .recordUnreduced:
                inventory.recordUnreduced(
                    symptom: symptom,
                    timestampNanoseconds: monotonicNanoseconds(),
                    attemptIndex: attemptIndex
                )
            case let .reduce(isEscape):
                let reductionTree: ChoiceTree
                if let deferredTreeRebuild {
                    guard let rebuilt = deferredTreeRebuild() else {
                        // Divergence on the deferred path: the attempt is already recorded, so the failure is held unreduced rather than dispatched with a placeholder tree.
                        inventory.recordUnreduced(
                            symptom: symptom,
                            timestampNanoseconds: monotonicNanoseconds(),
                            attemptIndex: attemptIndex
                        )
                        return
                    }
                    reductionTree = rebuilt
                } else {
                    reductionTree = tree
                }
                performReduction(
                    value: value,
                    tree: reductionTree,
                    symptom: symptom,
                    parentIndex: parentIndex,
                    phase: phase,
                    attemptIndex: attemptIndex,
                    wasEscape: isEscape
                )
        }
    }

    /// Reduces one gated failure inline on the loop's lane: reduce, normalize, capture the post-hoc signature, classify, and apply the classification's feedback before the next attempt.
    ///
    /// Inline execution trades attempts for signal purity: reduction probes never run concurrently with an attempt bracket, so they cannot pollute attempt signatures, and the feedback (failure-boost upgrades, escape-gate outcomes) lands at a deterministic point in the attempt stream. The time spent is accumulated into the reduction timing bucket so the report's throughput and overhead figures keep describing the search pipeline.
    private func performReduction(
        value: Output,
        tree: ChoiceTree,
        symptom: FailureSymptom,
        parentIndex: Int?,
        phase: FuzzPhase,
        attemptIndex: Int,
        wasEscape: Bool
    ) {
        let reductionStart = monotonicNanoseconds()
        let reduction = reduceStrategy(tree, value, symptom)
        counts.reductionInvocations += reduction.propertyInvocations
        var reducedSequence = reduction.sequence
        var reducedTree = reduction.tree
        var reducedValue = reduction.value

        // Normalization runs only on the would-be-new-cluster event: a reduced form whose key already exists needs no canonicalization, and the containsKey pre-check keeps the probing off the saturated-cluster path entirely.
        var unnormalizedResidual = false
        if configuration.experiments.normalization {
            let rawKey = ChoiceSequence.flatten(reducedTree, skipBindInners: true).clusterKey
            if inventory.containsKey(rawKey) == false,
               let normalized: FuzzNormalizer.NormalizedForm<Output> = FuzzNormalizer.normalize(
                   reducedSequence: reducedSequence,
                   erasedGen: erasedGen,
                   symptom: symptom,
                   property: { [self] value in
                       counts.normalizationInvocations += 1
                       return property(value)
                   },
                   cache: normalizationCache
               )
            {
                unnormalizedResidual = true
                reducedSequence = normalized.sequence
                reducedTree = normalized.tree
                reducedValue = normalized.value
            }
        }

        // Post-reduction classification: one clean-bracket evaluation yields the post-hoc signature. Cluster identity keys on the reduced form; the signature collects within the cluster, where a second distinct one raises the ~paths marker.
        let signature = attributedSignature(of: reducedValue)

        // Cluster identity is a cheap structural key over the reduced tree flattened with bind-inners skipped; the reflective description render is deferred to recordReduced and runs only when a new cluster is created.
        let reducedKey = ChoiceSequence.flatten(reducedTree, skipBindInners: true).clusterKey
        let classification = inventory.recordReduced(
            reducedSequence: reducedSequence,
            reducedKey: reducedKey,
            renderDescription: {
                renderValue(reducedValue)
            },
            signature: signature,
            symptom: symptom,
            phase: phase,
            timestampNanoseconds: monotonicNanoseconds(),
            attemptIndex: attemptIndex,
            unnormalizedResidual: unnormalizedResidual
        )
        timing.reductionNanoseconds += monotonicNanoseconds() - reductionStart

        if classification.isNewCluster {
            forceCheckpoint = true
        }
        if wasEscape {
            gate.noteEscapeOutcome(symptom: symptom, isNewCluster: classification.isNewCluster)
        }
        if let parentIndex {
            corpus.upgradeFailureBoost(
                atParentIndex: parentIndex,
                isNewCluster: classification.isNewCluster,
                clusterInstanceCount: classification.instanceCount,
                clusterCapReached: classification.capReached
            )
        }
        checkpointIfDue()
    }

    /// Evaluates the reduced value once in a bracket of its own and returns its coverage signature.
    private func attributedSignature(of value: Output) -> BitSet {
        source.beginAttempt()
        if source.wantsValues {
            source.noteValue(value)
        }
        counts.classificationInvocations += 1
        _ = property(value)
        var signature = BitSet(capacity: source.edgeCount)
        source.forEachHitEdge { edge, _ in
            signature.insert(edge)
        }
        return signature
    }

    // MARK: - Termination Checks

    /// The run-wide stop conditions every phase checks: wall clock and the testing attempt limit.
    private func terminationDue() -> FuzzTermination? {
        if let limit = configuration.attemptLimit, counts.totalAttempts >= limit {
            return .attemptLimitReached
        }
        if monotonicNanoseconds() - startNanoseconds >= configuration.budgetNanoseconds {
            return .budgetExhausted
        }
        return nil
    }

    /// Remaining attempts under the testing limit, as a screening budget bound.
    private func remainingAttemptBudget() -> UInt64 {
        guard let limit = configuration.attemptLimit else {
            return UInt64.max
        }
        return UInt64(max(0, limit - counts.totalAttempts))
    }

    /// One uniform draw in [0, 1) from the run PRNG (the top 53 bits of one 64-bit draw), so probability-space decisions replay deterministically under a pinned seed.
    func randomUnit() -> Double {
        Double(prng.next() >> 11) / Double(1 << 53)
    }
}
