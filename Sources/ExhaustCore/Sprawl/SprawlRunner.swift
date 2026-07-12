// The three-phase coverage-guided exploration loop behind `#explore(time:)`.

import Foundation

/// The spec-path seams carried through `runExploreTimeCore` into ``SprawlRunner`` as one unit.
///
/// Nil on the value path. A spec adapter populates both fields: the prune hook keeps precondition-skipped commands out of the corpus, and the reduce strategy routes reduction through the spec's backend reducer (sequential specs reuse ``SprawlRunner/propertyOnlyReduceStrategy(gen:property:reducerConfiguration:)`` with the spec deadline; `.tasks` specs will wrap their two-pass reducer).
package struct SprawlHooks<Output> {
    /// Prunes the value and tree before corpus admission. Runs outside the attribution bracket, only on failures and would-be admissions.
    package let prune: @Sendable (Output, ChoiceTree) -> (value: Output, tree: ChoiceTree)
    /// Reduces one failing candidate, returning the reduced sequence, tree, and value.
    package let reduceStrategy: @Sendable (ChoiceTree, Output, FailureSymptom) -> (sequence: ChoiceSequence, tree: ChoiceTree, value: Output)

    package init(
        prune: @escaping @Sendable (Output, ChoiceTree) -> (value: Output, tree: ChoiceTree),
        reduceStrategy: @escaping @Sendable (ChoiceTree, Output, FailureSymptom) -> (sequence: ChoiceSequence, tree: ChoiceTree, value: Output)
    ) {
        self.prune = prune
        self.reduceStrategy = reduceStrategy
    }
}

/// Runs the covering-array, random-sampling, and sprawl phases against one property, accumulating a corpus and a clustered fault inventory.
///
/// The exploration loop is single-threaded: the corpus, gate, and PRNG are touched only by `run()`, which executes on one GCD lane. Reductions are dispatched to the bounded ``ReductionPool`` and complete in parallel; their classifications come back through a locked mailbox the loop drains between attempts, and the attribution token serialises every instrumented evaluation (per-attempt brackets here, classification re-runs there) so in-flight reductions never pollute a snapshot.
package final class SprawlRunner<Output> {
    // Members without an access modifier are internal so the same-module extension files (SprawlRunner+Recovery, SprawlRunner+Mutation) can reach them; nothing outside the module sees them.
    private let gen: Generator<Output>
    let erasedGen: AnyGenerator
    let property: @Sendable (Output) -> SprawlVerdict
    let source: any CoverageSource
    let configuration: SprawlRunnerConfiguration
    /// Prunes the value and tree before corpus admission. Nil on the value path; the spec path removes precondition-skipped commands so the corpus stores only live sequences. Runs outside the attribution bracket, only on failures and would-be admissions.
    private let prune: (@Sendable (Output, ChoiceTree) -> (value: Output, tree: ChoiceTree))?
    /// The reduction the failure dispatch runs. The value path's default is ``propertyOnlyReduceStrategy(gen:property:reducerConfiguration:)``; the spec path injects its backend reducer through ``SprawlHooks``.
    private let reduceStrategy: @Sendable (ChoiceTree, Output, FailureSymptom) -> (sequence: ChoiceSequence, tree: ChoiceTree, value: Output)

    /// Package-visible so tests can assert on corpus contents (tier membership, entry command counts) after a run.
    package let corpus: SprawlCorpus
    let inventory = FaultInventory()
    private let pool: ReductionPool
    private var gate: ReductionGate
    var prng: Xoshiro256
    var bandit = MutationBandit()

    /// Renders a reduced counterexample for its cluster's report description. Injected because the render runs inside the reduction task — the value never crosses back to a context that could render it later — while the runner's module must stay free of rendering dependencies. The default serves direct package-level construction (tests, harnesses); `runExploreTimeCore` supplies the production renderer.
    private let renderValue: @Sendable (Any) -> String

    /// At most one thread at a time runs an instrumented evaluation bracket.
    let attributionToken = NSLock()

    /// Completed classifications waiting for the loop to apply their failure-weight upgrades and escape-interval feedback.
    private let pendingClassifications = SendableBox<[(parentIndex: Int?, symptom: FailureSymptom, wasEscape: Bool, classification: ClusterClassification)]>([])

    /// Zobrist-keyed normalization results shared across reduction tasks; see ``SprawlNormalizer/normalize(reducedSequence:erasedGen:symptom:property:cache:)``.
    private let normalizationCache = SendableBox<[UInt64: ChoiceSequence?]>([:])

    var startNanoseconds: UInt64 = 0
    private var lastAdmissionNanoseconds: UInt64 = 0
    private var screeningAttempts = 0
    private var samplingAttempts = 0
    var sprawlAttempts = 0
    private var discardedAttempts = 0
    private var totalAttempts = 0

    /// Wall-clock nanoseconds spent inside the property body across all loop attempts; the report derives the framework-overhead fraction from it. Reduction-side evaluations run on other threads and are deliberately excluded.
    private var propertyNanoseconds: UInt64 = 0

    // MARK: - Crash-Recovery State

    // Owned by the recovery extension (see SprawlRunner+Recovery.swift); declared here because stored properties cannot live in an extension.

    var progressWriter: SprawlProgressWriter?
    var breadcrumb: SprawlBreadcrumb?
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
        property: @escaping @Sendable (Output) -> SprawlVerdict,
        source: any CoverageSource,
        configuration: SprawlRunnerConfiguration,
        hooks: SprawlHooks<Output>? = nil,
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
                wallClockDeadlineNanoseconds: SprawlTunables.reductionDeadlineNanoseconds
            )
        )
        corpus = SprawlCorpus(edgeCount: source.edgeCount, experiments: configuration.experiments)
        gate = ReductionGate(experiments: configuration.experiments)
        pool = ReductionPool(maxConcurrent: configuration.reductionPoolWidth ?? SprawlTunables.maxConcurrentReductions)
        prng = Xoshiro256(seed: configuration.seed)
    }

    /// The default reduce strategy: property-only `choiceGraphReduce`, reducing while the property fails exactly as `#exhaust` does. Reduction attempts are never attributed.
    ///
    /// The sequential spec adapter reuses this with the spec reduction deadline, so the value path and sequential spec path share one reduction implementation and differ only in configuration. On a reducer failure the input comes back unreduced.
    package static func propertyOnlyReduceStrategy(
        gen: Generator<Output>,
        property: @escaping @Sendable (Output) -> SprawlVerdict,
        reducerConfiguration: Interpreters.ReducerConfiguration
    ) -> @Sendable (ChoiceTree, Output, FailureSymptom) -> (sequence: ChoiceSequence, tree: ChoiceTree, value: Output) {
        { tree, value, _ in
            let boolProperty: (Output) -> Bool = { property($0).isFailure == false }
            let outcome = try? Interpreters.choiceGraphReduce(
                gen: gen,
                tree: tree,
                output: value,
                config: reducerConfiguration,
                property: boolProperty
            )
            switch outcome {
                case let .reduced(sequence, reducedTree, output), let .unreduced(sequence, reducedTree, output):
                    return (sequence, reducedTree, output)
                case .failure, nil:
                    return (ChoiceSequence.flatten(tree), tree, value)
            }
        }
    }

    // MARK: - Run

    /// Executes the three phases and returns the final result. Synchronous; the caller owns GCD-lane placement.
    package func run() -> SprawlRunResult {
        startNanoseconds = monotonicNanoseconds()
        lastAdmissionNanoseconds = startNanoseconds
        setUpPersistence()

        // Sampling hands over to sprawl by returning nil (plateau or time backstop); a non-nil value is a hard stop that skips sprawl.
        var termination: SprawlTermination?
        if configuration.skipScreening == false {
            runScreeningPhase()
        }
        if terminationDue() == nil, configuration.skipSampling == false {
            termination = runSamplingPhase()
        }
        if termination == nil, terminationDue() == nil {
            termination = runSprawlPhase()
        }

        let finalTermination = termination ?? terminationDue() ?? .budgetExhausted
        let reductionsCompleted = pool.drain(timeoutNanoseconds: SprawlTunables.reductionDrainTimeoutNanoseconds)
        drainClassifications()

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

        return SprawlRunResult(
            clusters: clusters,
            unmatchedUnreducedCounts: unmatched,
            screeningAttempts: screeningAttempts,
            samplingAttempts: samplingAttempts,
            sprawlAttempts: sprawlAttempts,
            discardedAttempts: discardedAttempts,
            corpusEntryCount: corpus.entries.count,
            mutableTierCount: corpus.mutableTierIndices.count,
            coveredEdgeCount: corpus.coveredEdgeCount,
            instrumentedEdgeCount: source.edgeCount,
            edgeSingletonCount: corpus.edgeSingletonCount,
            edgeDoubletonCount: corpus.edgeDoubletonCount,
            termination: finalTermination,
            clusterDiscriminations: discriminations,
            startNanoseconds: reportEpochNanoseconds,
            elapsedNanoseconds: monotonicNanoseconds() - startNanoseconds,
            propertyNanoseconds: propertyNanoseconds,
            seed: configuration.seed,
            reductionsTimedOut: reductionsCompleted == false
        )
    }

    // MARK: - Phase 1: Screening

    private func runScreeningPhase() {
        // The verdict and hits captured by the property wrapper are read by onExample, which fires synchronously after each evaluation and before the next bracket begins.
        var lastVerdict = SprawlVerdict.pass
        var lastHits: [(edge: Int, hitCount: UInt8)] = []

        let wrappedProperty: (Output) -> Bool = { [self] value in
            attributionToken.lock()
            // Screening evaluates before its tree reaches onExample, so the candidate cannot be identified pre-evaluation; a cleared slot beats misattributing a trap to the previous attempt.
            breadcrumb?.clear()
            source.beginAttempt()
            let (verdict, hits) = evaluateInBracket(value, recordingBreadcrumb: nil)
            attributionToken.unlock()
            lastVerdict = verdict
            lastHits = hits
            return verdict.isFailure == false
        }

        _ = ScreeningRunner.run(
            gen,
            screeningBudget: min(configuration.screeningBudget, remainingAttemptBudget()),
            continuePastFailure: true,
            property: wrappedProperty,
            onExample: { [self] value, tree, _ in
                drainClassifications()
                // Every covering-array row is boundary-derived; convergence is 1 because the tree came straight from materialisation.
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
            }
        )
    }

    // MARK: - Phase 2: Random Sampling

    /// Runs open-ended random sampling until plateau (K consecutive samples without a corpus admission), the time backstop, or a run-wide termination condition. Returns a hard termination or nil for normal handover to sprawl.
    private func runSamplingPhase() -> SprawlTermination? {
        var interpreter = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: false,
            seed: configuration.seed,
            maxRuns: UInt64.max
        )
        var samplesSinceNovelty = 0
        let backstopNanoseconds = startNanoseconds
            + UInt64(Double(configuration.budgetNanoseconds) * SprawlTunables.samplingTimeBackstopFraction)

        while true {
            if let termination = terminationDue() {
                return termination
            }
            if samplesSinceNovelty >= SprawlTunables.samplingPlateauWindow {
                return nil
            }
            if monotonicNanoseconds() >= backstopNanoseconds {
                return nil
            }
            drainClassifications()

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

    // MARK: - Phase 3: Sprawl

    private func runSprawlPhase() -> SprawlTermination {
        // Fallback sampling for an empty mutable tier reuses the interpreter idiom with a derived seed so it does not replay Phase 2's stream.
        var fallbackInterpreter = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: false,
            seed: configuration.seed ^ 0x5EED_FA11_BACC_0FFE,
            maxRuns: UInt64.max
        )
        let plateauWindowNanoseconds = UInt64(
            Double(configuration.budgetNanoseconds) * SprawlTunables.sprawlPlateauBudgetFraction
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
            drainClassifications()

            guard let (parentIndex, parent) = corpus.pickParent(random: randomUnit()) else {
                // Empty mutable tier: fall back to fresh sampling until something is mutable.
                switch freshSample(interpreter: &fallbackInterpreter, phase: .sprawl) {
                    case .evaluated:
                        break
                    case .exhausted:
                        discardedAttempts += 1
                    case let .generationError(message):
                        return .generationError(message)
                }
                continue
            }

            let childBudget = configuration.experiments.powerSchedule
                ? corpus.powerScheduleChildren(forParentAt: parentIndex, base: SprawlTunables.childrenPerParent)
                : SprawlTunables.childrenPerParent
            for _ in 0 ..< childBudget {
                if terminationDue() != nil {
                    break
                }
                let (mutated, armsMask) = nextCandidate(from: parent)
                evaluateSprawlCandidate(mutated, parent: parent, parentIndex: parentIndex, armsMask: armsMask)
            }
        }
    }

    private func evaluateSprawlCandidate(
        _ candidate: ChoiceSequence,
        parent: CorpusEntry,
        parentIndex: Int,
        armsMask: UInt8
    ) {
        attributionToken.lock()
        source.beginAttempt()
        let result = Materializer.materializeAny(
            erasedGen,
            prefix: candidate,
            mode: .guided(seed: prng.next(), fallbackTree: parent.tree)
        )
        guard case let .success(anyValue, freshTree, decodingReport) = result else {
            attributionToken.unlock()
            discardedAttempts += 1
            return
        }
        // swiftlint:disable:next force_cast
        let value = anyValue as! Output
        let sequence = ChoiceSequence.flatten(freshTree)
        let (verdict, hits) = evaluateInBracket(
            value,
            recordingBreadcrumb: (candidateHash: ZobristHash.hash(of: sequence), parentHash: parent.hash)
        )
        attributionToken.unlock()

        let admission = recordAttempt(
            value: value,
            tree: freshTree,
            sequence: sequence,
            verdict: verdict,
            hits: hits,
            convergence: decodingReport?.convergence ?? 0,
            generation: parent.generation + 1,
            phase: .sprawl,
            parentIndex: parentIndex
        )
        if admission.isAdmitted, configuration.experiments.banditBands {
            for arm in MutationArm.allCases where armsMask & (1 << UInt8(arm.rawValue)) != 0 {
                bandit.reward(arm)
            }
        }
    }

    // MARK: - Shared Attempt Plumbing

    /// The outcome of one fresh interpreter sample, shared by Phase 2 and sprawl's empty-tier fallback.
    private enum FreshSampleOutcome {
        case evaluated(CorpusAdmission)
        /// The interpreter returned nil; its stream is exhausted.
        case exhausted
        case generationError(String)
    }

    /// Draws one fresh sample from `interpreter`, evaluates it under the attribution bracket, and records the attempt under `phase`.
    private func freshSample(
        interpreter: inout ValueAndChoiceTreeInterpreter<Output>,
        phase: SprawlPhase
    ) -> FreshSampleOutcome {
        attributionToken.lock()
        source.beginAttempt()
        let generated: (Output, ChoiceTree)?
        do {
            generated = try interpreter.next()
        } catch {
            attributionToken.unlock()
            return .generationError(String(describing: error))
        }
        guard let (value, tree) = generated else {
            attributionToken.unlock()
            return .exhausted
        }
        let sequence = ChoiceSequence.flatten(tree)
        let (verdict, hits) = evaluateInBracket(
            value,
            recordingBreadcrumb: (candidateHash: ZobristHash.hash(of: sequence), parentHash: 0)
        )
        attributionToken.unlock()

        let admission = recordAttempt(
            value: value,
            tree: tree,
            sequence: sequence,
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
    /// Must run inside the attribution token, after `source.beginAttempt()` and after candidate production — generation and materialisation can execute user code, and its coverage belongs to the attempt whose bracket is open.
    private func evaluateInBracket(
        _ value: Output,
        recordingBreadcrumb slot: (candidateHash: UInt64, parentHash: UInt64)?
    ) -> (verdict: SprawlVerdict, hits: [(edge: Int, hitCount: UInt8)]) {
        if let slot {
            breadcrumb?.record(candidateHash: slot.candidateHash, parentHash: slot.parentHash)
        }
        if source.wantsValues {
            source.noteValue(value)
        }
        let propertyStart = monotonicNanoseconds()
        let verdict = property(value)
        propertyNanoseconds += monotonicNanoseconds() - propertyStart
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
        verdict: SprawlVerdict,
        hits: [(edge: Int, hitCount: UInt8)],
        convergence: Double,
        generation: Int,
        phase: SprawlPhase,
        isBoundaryDerived: Bool = false,
        parentIndex: Int? = nil
    ) -> CorpusAdmission {
        switch phase {
            case .screening:
                screeningAttempts += 1
            case .sampling:
                samplingAttempts += 1
            case .sprawl:
                sprawlAttempts += 1
        }
        totalAttempts += 1

        // The prune hook runs outside the attribution bracket (recordAttempt is always called outside it). It fires only on failures and would-be corpus admissions — the common non-novel pass never pays the pruning cost.
        var effectiveValue = value
        var effectiveTree = tree
        var effectiveSequence = sequence
        if let prune,
           verdict.isFailure || corpus.wouldAdmit(hits: hits)
        {
            let pruned = prune(effectiveValue, effectiveTree)
            effectiveValue = pruned.value
            effectiveTree = pruned.tree
            effectiveSequence = ChoiceSequence.flatten(effectiveTree)
        }

        let admission = corpus.offer(
            sequence: effectiveSequence,
            tree: effectiveTree,
            hits: hits,
            convergence: convergence,
            generation: generation,
            phase: phase,
            isBoundaryDerived: isBoundaryDerived,
            propertyFailed: verdict.isFailure
        )
        if admission.isAdmitted {
            lastAdmissionNanoseconds = monotonicNanoseconds()
        }
        if case let .fail(symptom) = verdict {
            handleFailure(
                value: effectiveValue,
                tree: effectiveTree,
                sequence: effectiveSequence,
                symptom: symptom,
                parentIndex: parentIndex,
                phase: phase,
                coverageNovel: admission.isAdmitted
            )
        }
        return admission
    }

    // MARK: - Failure Handling

    private func handleFailure(
        value: Output,
        tree: ChoiceTree,
        sequence: ChoiceSequence,
        symptom: FailureSymptom,
        parentIndex: Int?,
        phase: SprawlPhase,
        coverageNovel: Bool
    ) {
        if let parentIndex {
            corpus.applyProvisionalFailureBoost(toParentAt: parentIndex)
        }
        let hash = ZobristHash.hash(of: sequence)
        let attemptIndex = totalAttempts
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
                dispatchReduction(
                    value: value,
                    tree: tree,
                    symptom: symptom,
                    parentIndex: parentIndex,
                    phase: phase,
                    attemptIndex: attemptIndex,
                    wasEscape: isEscape
                )
        }
    }

    private func dispatchReduction(
        value: Output,
        tree: ChoiceTree,
        symptom: FailureSymptom,
        parentIndex: Int?,
        phase: SprawlPhase,
        attemptIndex: Int,
        wasEscape: Bool
    ) {
        // The generator and property are Sendable by construction (the macro enforces @Sendable; ReflectiveGenerator is @unchecked Sendable); the tree and value are moved into the task and never touched by the loop again.
        let capturedErasedGen = erasedGen
        let capturedTree = tree
        nonisolated(unsafe) let capturedValue = value
        let capturedProperty = property
        let normalizationEnabled = configuration.experiments.normalization
        let normalizationCache = normalizationCache
        let source = source
        let attributionToken = attributionToken
        let inventory = inventory
        let pendingClassifications = pendingClassifications
        let reduceStrategy = reduceStrategy
        let renderValue = renderValue

        pool.submit {
            var (reducedSequence, reducedTree, reducedValue) = reduceStrategy(capturedTree, capturedValue, symptom)

            // Normalization runs only on the would-be-new-cluster event: a reduced form whose key already exists needs no canonicalization, and the containsKey pre-check keeps the probing off the saturated-cluster path entirely.
            var unnormalizedResidual = false
            if normalizationEnabled {
                let rawKey = ChoiceSequence.flatten(reducedTree, skipBindInners: true).clusterKey
                if inventory.containsKey(rawKey) == false,
                   let normalized: SprawlNormalizer.NormalizedForm<Output> = SprawlNormalizer.normalize(
                       reducedSequence: reducedSequence,
                       erasedGen: capturedErasedGen,
                       symptom: symptom,
                       property: capturedProperty,
                       cache: normalizationCache
                   )
                {
                    unnormalizedResidual = true
                    reducedSequence = normalized.sequence
                    reducedTree = normalized.tree
                    reducedValue = normalized.value
                }
            }

            // Post-reduction classification: one instrumented evaluation under the attribution token yields the post-hoc signature. Clustering keys on (reduced form, signature).
            let signature = Self.attributedSignature(
                of: reducedValue,
                property: capturedProperty,
                source: source,
                attributionToken: attributionToken
            )

            // Cluster identity is a cheap structural key over the reduced tree flattened with bind-inners skipped; the reflective description render is deferred to recordReduced and runs only when a new cluster is created.
            let reducedKey = ChoiceSequence.flatten(reducedTree, skipBindInners: true).clusterKey
            nonisolated(unsafe) let capturedReducedValue = reducedValue
            let classification = inventory.recordReduced(
                reducedSequence: reducedSequence,
                reducedKey: reducedKey,
                renderDescription: {
                    renderValue(capturedReducedValue)
                },
                signature: signature,
                symptom: symptom,
                phase: phase,
                timestampNanoseconds: monotonicNanoseconds(),
                attemptIndex: attemptIndex,
                unnormalizedResidual: unnormalizedResidual
            )
            pendingClassifications.withValue { pending in
                pending.append((parentIndex: parentIndex, symptom: symptom, wasEscape: wasEscape, classification: classification))
            }
        }
    }

    /// Evaluates the reduced value once under the attribution token and returns its coverage signature.
    ///
    /// Synchronous by construction: `NSLock.lock` is unavailable from async contexts, and the bracket must anyway be brief — it serialises against every per-attempt bracket in the exploration loop.
    private static func attributedSignature(
        of value: Output,
        property: @Sendable (Output) -> SprawlVerdict,
        source: any CoverageSource,
        attributionToken: NSLock
    ) -> BitSet {
        attributionToken.lock()
        defer { attributionToken.unlock() }
        source.beginAttempt()
        if source.wantsValues {
            source.noteValue(value)
        }
        _ = property(value)
        var signature = BitSet(capacity: source.edgeCount)
        source.forEachHitEdge { edge, _ in
            signature.insert(edge)
        }
        return signature
    }

    /// Applies completed classifications' failure-weight upgrades on the loop thread — the corpus is single-threaded by design, so reduction tasks post here instead of calling in. Doubles as the checkpoint pulse: it runs once per loop iteration in every phase, which is exactly the cadence ``checkpointIfDue()`` needs.
    private func drainClassifications() {
        let completed = pendingClassifications.withValue { pending -> [(parentIndex: Int?, symptom: FailureSymptom, wasEscape: Bool, classification: ClusterClassification)] in
            let drained = pending
            pending.removeAll()
            return drained
        }
        for (parentIndex, symptom, wasEscape, classification) in completed {
            if classification.isNewCluster {
                forceCheckpoint = true
            }
            if wasEscape {
                gate.noteEscapeOutcome(symptom: symptom, isNewCluster: classification.isNewCluster)
            }
            guard let parentIndex else {
                continue
            }
            corpus.upgradeFailureBoost(
                atParentIndex: parentIndex,
                isNewCluster: classification.isNewCluster,
                clusterInstanceCount: classification.instanceCount,
                clusterCapReached: classification.capReached
            )
        }
        checkpointIfDue()
    }

    // MARK: - Termination Checks

    /// The run-wide stop conditions every phase checks: wall clock and the testing attempt limit.
    private func terminationDue() -> SprawlTermination? {
        if let limit = configuration.attemptLimit, totalAttempts >= limit {
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
        return UInt64(max(0, limit - totalAttempts))
    }

    /// One uniform draw in [0, 1) from the run PRNG (the top 53 bits of one 64-bit draw), so probability-space decisions replay deterministically under a pinned seed.
    func randomUnit() -> Double {
        Double(prng.next() >> 11) / Double(1 << 53)
    }
}
