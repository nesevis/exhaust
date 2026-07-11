// The three-phase coverage-guided exploration loop behind `#explore(time:)`.

import CustomDump
import ExhaustCore
import Foundation

/// Runs the covering-array, random-sampling, and sprawl phases against one property, accumulating a corpus and a clustered fault inventory.
///
/// The exploration loop is single-threaded: the corpus, gate, and PRNG are touched only by `run()`, which executes on one GCD lane. Reductions are dispatched to the bounded ``ReductionPool`` and complete in parallel; their classifications come back through a locked mailbox the loop drains between attempts, and the attribution token serialises every instrumented evaluation (per-attempt brackets here, classification re-runs there) so in-flight reductions never pollute a snapshot.
package final class SprawlRunner<Output> {
    // Members without an access modifier are internal so ``SprawlRunner+Recovery`` (a same-module extension file) can reach them; nothing outside the module sees them.
    private let gen: Generator<Output>
    let erasedGen: AnyGenerator
    let property: @Sendable (Output) -> SprawlVerdict
    let source: any CoverageSource
    let configuration: SprawlRunnerConfiguration
    private let reducerConfiguration: Interpreters.ReducerConfiguration

    let corpus: SprawlCorpus
    let inventory = FaultInventory()
    private let pool = ReductionPool()
    private var gate: ReductionGate
    private var prng: Xoshiro256
    private var bandit = MutationBandit()

    /// G4: at most one thread at a time runs an instrumented evaluation bracket.
    let attributionToken = NSLock()

    /// Completed classifications waiting for the loop to apply their failure-weight upgrades and escape-interval feedback.
    private let pendingClassifications = SendableBox<[(parentIndex: Int?, symptom: FailureSymptom, wasEscape: Bool, classification: ClusterClassification)]>([])

    /// Zobrist-keyed normalization results shared across reduction tasks; see ``SprawlNormalizer/normalize(reducedSequence:erasedGen:symptom:property:cache:)``.
    private let normalizationCache = SendableBox<[UInt64: ChoiceSequence?]>([:])

    var startNanoseconds: UInt64 = 0
    private var lastAdmissionNanoseconds: UInt64 = 0
    private var screeningAttempts = 0
    private var samplingAttempts = 0
    private var sprawlAttempts = 0
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
        configuration: SprawlRunnerConfiguration
    ) {
        self.gen = gen
        erasedGen = gen.erase()
        self.property = property
        self.source = source
        self.configuration = configuration
        corpus = SprawlCorpus(edgeCount: source.edgeCount, experiments: configuration.experiments)
        gate = ReductionGate(experiments: configuration.experiments)
        prng = Xoshiro256(seed: configuration.seed)
        // Reduction deadline mirrors #exhaust's scaling but is bounded: sprawl reductions run concurrently with exploration and must not outlive the drain timeout.
        reducerConfiguration = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            wallClockDeadlineNanoseconds: 5_000_000_000
        )
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
        let reductionsCompleted = pool.drain(timeoutNanoseconds: 10_000_000_000)
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

    /// Produces one mutated candidate from `parent` plus the bitmask of ``MutationArm``s that shaped it (for bandit credit on admission), routing between the legacy single-operator path, the composed experiment path, and the swarm rewrite.
    private func nextCandidate(from parent: CorpusEntry) -> (candidate: ChoiceSequence, armsMask: UInt8) {
        let experiments = configuration.experiments
        if experiments.swarm {
            let (candidate, armsMask) = experiments.stackedMutation || experiments.banditBands
                ? composedCandidate(from: parent)
                : legacyCandidate(from: parent)
            let epoch = SwarmMask.forEpoch(
                index: sprawlAttempts / SprawlTunables.swarmEpochAttempts,
                rootSeed: configuration.seed
            )
            return (epoch.apply(to: candidate, prng: &prng), armsMask)
        }
        if experiments.stackedMutation || experiments.banditBands {
            return composedCandidate(from: parent)
        }
        return legacyCandidate(from: parent)
    }

    /// The original single-operator mutation path, kept verbatim so knob-off runs replay identically under a pinned seed: usually an intensity-band mutation, occasionally a bind-boundary splice with a random donor.
    private func legacyCandidate(from parent: CorpusEntry) -> (candidate: ChoiceSequence, armsMask: UInt8) {
        if randomUnit() < SprawlTunables.spliceProbability, corpus.entries.count > 1 {
            let donorIndex = Int(prng.next(upperBound: UInt64(corpus.entries.count)))
            let donor = corpus.entries[donorIndex]
            if donor.hash != parent.hash,
               let spliced = SprawlMutator.splice(recipient: parent.sequence, donor: donor.sequence, prng: &prng)
            {
                return (spliced, 1 << UInt8(MutationArm.splice.rawValue))
            }
        }
        let intensityDraw = prng.next(upperBound: UInt64(SprawlIntensity.allCases.count))
        let intensity = SprawlIntensity.allCases[Int(intensityDraw)]
        return (
            SprawlMutator.mutate(parent.sequence, intensity: intensity, prng: &prng),
            1 << UInt8(intensityDraw)
        )
    }

    /// The experiment mutation path: one child composed from `stackedMutation`'s operator stack with each operator drawn from the bandit's distribution (or the legacy fixed one when only stacking is on).
    ///
    /// The stack draw is 2^0...2^2 ({1, 2, 4} operators), not AFL's 2^1...2^7: Exhaust's band operators are each already multi-perturbation (a low-band step moves up to three values, a high-band step corrupts a quarter of the sequence), and the AFL-depth stacks measured on `DeepParser` destroyed parent structure outright (deep-fault discovery 4/20 versus 20/20, throughput −42%).
    private func composedCandidate(from parent: CorpusEntry) -> (candidate: ChoiceSequence, armsMask: UInt8) {
        let experiments = configuration.experiments
        let mutation = 1 << Int(prng.next(upperBound: 3))
        let stackCount = experiments.stackedMutation ? mutation : 1
        var candidate = parent.sequence
        var armsMask: UInt8 = 0
        for _ in 0 ..< stackCount {
            let arm = experiments.banditBands ? bandit.pick(random: randomUnit()) : fixedDistributionArm()
            armsMask |= 1 << UInt8(arm.rawValue)
            switch arm {
                case .low:
                    candidate = SprawlMutator.mutate(candidate, intensity: .low, prng: &prng)
                case .medium:
                    candidate = SprawlMutator.mutate(candidate, intensity: .medium, prng: &prng)
                case .high:
                    candidate = SprawlMutator.mutate(candidate, intensity: .high, prng: &prng)
                case .splice:
                    guard corpus.entries.count > 1 else {
                        continue
                    }
                    let donorIndex = Int(prng.next(upperBound: UInt64(corpus.entries.count)))
                    let donor = corpus.entries[donorIndex]
                    if let spliced = SprawlMutator.splice(recipient: candidate, donor: donor.sequence, prng: &prng) {
                        candidate = spliced
                    }
            }
        }
        return (candidate, armsMask)
    }

    /// The legacy operator distribution (splice at its fixed probability, otherwise a uniform band) expressed as one draw, for the stacked-without-bandit arm.
    private func fixedDistributionArm() -> MutationArm {
        if randomUnit() < SprawlTunables.spliceProbability {
            return .splice
        }
        return MutationArm(rawValue: Int(prng.next(upperBound: 3))) ?? .low
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

        let admission = corpus.offer(
            sequence: sequence,
            tree: tree,
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
                value: value,
                tree: tree,
                sequence: sequence,
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
        nonisolated(unsafe) let capturedGen = gen
        nonisolated(unsafe) let capturedErasedGen = erasedGen
        nonisolated(unsafe) let capturedTree = tree
        nonisolated(unsafe) let capturedValue = value
        let capturedProperty = property
        let reducerConfiguration = reducerConfiguration
        let normalizationEnabled = configuration.experiments.normalization
        let normalizationCache = normalizationCache
        let source = source
        let attributionToken = attributionToken
        let inventory = inventory
        let pendingClassifications = pendingClassifications

        pool.submit {
            // Property-only predicate: reduce while the property fails, exactly as #exhaust does. Reduction attempts are never attributed.
            let boolProperty: (Output) -> Bool = { capturedProperty($0).isFailure == false }
            let outcome = try? Interpreters.choiceGraphReduce(
                gen: capturedGen,
                tree: capturedTree,
                output: capturedValue,
                config: reducerConfiguration,
                property: boolProperty
            )

            var reducedSequence: ChoiceSequence
            var reducedTree: ChoiceTree
            var reducedValue: Output
            switch outcome {
                case let .reduced(sequence, tree, output), let .unreduced(sequence, tree, output):
                    reducedSequence = sequence
                    reducedTree = tree
                    reducedValue = output
                case .failure, nil:
                    reducedSequence = ChoiceSequence.flatten(capturedTree)
                    reducedTree = capturedTree
                    reducedValue = capturedValue
            }

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
                    var description = ""
                    customDump(capturedReducedValue, to: &description, maxDepth: 3)
                    return description
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

    private func randomUnit() -> Double {
        Double(prng.next() >> 11) / Double(1 << 53)
    }
}
