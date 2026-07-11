// The three-phase coverage-guided exploration loop behind `#explore(time:)`.

import CustomDump
import ExhaustCore
import Foundation

/// The outcome of one property evaluation inside a `time:` run.
///
/// Distinguishes the failure's cheap symptom at evaluation time because the backpressure gate needs it synchronously, before any reduction runs.
package enum SprawlVerdict: Sendable {
    case pass
    case fail(FailureSymptom)

    var isFailure: Bool {
        switch self {
            case .pass:
                false
            case .fail:
                true
        }
    }
}

/// Why a `time:` run stopped.
package enum SprawlTermination: Equatable, Sendable {
    /// The wall-clock budget elapsed.
    case budgetExhausted
    /// No coverage-novel corpus admission for the plateau window; the unused budget is returned rather than burned.
    case plateau(unusedNanoseconds: UInt64)
    /// The package-visible attempt limit was reached (testing control; no time-based termination fired).
    case attemptLimitReached
    /// Generation failed irrecoverably.
    case generationError(String)
}

/// Configuration for one `time:` run. Package-visible controls beyond the public settings exist for the validation harness (phase skipping, attempt limits).
package struct SprawlRunnerConfiguration {
    /// The wall-clock budget in nanoseconds.
    package var budgetNanoseconds: UInt64
    /// Root seed for all PRNG-driven decisions.
    package var seed: UInt64
    /// Covering-array budget for Phase 1.
    package var screeningBudget: UInt64
    /// Skips Phase 1 so sprawl tests are not hostage to screening heuristics.
    package var skipScreening: Bool
    /// Skips Phase 2 (with `skipScreening`, the run starts directly in sprawl).
    package var skipSampling: Bool
    /// Hard cap on total attempts across all phases, for deterministic tests. Nil means time-bounded only.
    package var attemptLimit: Int?
    /// Crash-recovery configuration: where checkpoints go and what a crashed predecessor left. Nil disables persistence entirely.
    package var persistence: SprawlPersistenceContext?
    /// Knobs for benchmark-gated mechanisms; see ``SprawlExperiments`` for the seam precedence.
    package var experiments: SprawlExperiments

    package init(
        budgetNanoseconds: UInt64,
        seed: UInt64,
        screeningBudget: UInt64 = 10000,
        skipScreening: Bool = false,
        skipSampling: Bool = false,
        attemptLimit: Int? = nil,
        persistence: SprawlPersistenceContext? = nil,
        experiments: SprawlExperiments = SprawlExperiments()
    ) {
        self.budgetNanoseconds = budgetNanoseconds
        self.seed = seed
        self.screeningBudget = screeningBudget
        self.skipScreening = skipScreening
        self.skipSampling = skipSampling
        self.attemptLimit = attemptLimit
        self.persistence = persistence
        self.experiments = experiments
    }
}

/// The raw result of a `time:` run, wrapped into the public report by the macro runtime.
package struct SprawlRunResult: Sendable {
    package var clusters: [FaultCluster]
    package var unmatchedUnreducedCounts: [FailureSymptom: Int]
    package var screeningAttempts: Int
    package var samplingAttempts: Int
    package var sprawlAttempts: Int
    package var discardedAttempts: Int
    package var corpusEntryCount: Int
    package var mutableTierCount: Int
    package var coveredEdgeCount: Int
    package var instrumentedEdgeCount: Int
    /// Edges hit by exactly one attempt (f₁) and exactly two (f₂), for the STADS estimators.
    package var edgeSingletonCount: Int
    package var edgeDoubletonCount: Int
    package var termination: SprawlTermination
    /// Report-time discrimination results, parallel to `clusters` by position.
    package var clusterDiscriminations: [ClusterDiscrimination]
    package var startNanoseconds: UInt64
    package var elapsedNanoseconds: UInt64
    /// Nanoseconds spent inside the property body across all loop attempts; `elapsedNanoseconds` minus this is framework overhead.
    package var propertyNanoseconds: UInt64
    package var seed: UInt64
    package var reductionsTimedOut: Bool

    package var totalAttempts: Int {
        screeningAttempts + samplingAttempts + sprawlAttempts
    }

    package var attemptsPerSecond: Double {
        guard elapsedNanoseconds > 0 else {
            return 0
        }
        return Double(totalAttempts) / (Double(elapsedNanoseconds) / 1_000_000_000)
    }
}

/// Runs the covering-array, random-sampling, and sprawl phases against one property, accumulating a corpus and a clustered fault inventory.
///
/// The exploration loop is single-threaded: the corpus, gate, and PRNG are touched only by `run()`, which executes on one GCD lane. Reductions are dispatched to the bounded ``ReductionPool`` and complete in parallel; their classifications come back through a locked mailbox the loop drains between attempts, and the attribution token serialises every instrumented evaluation (per-attempt brackets here, classification re-runs there) so in-flight reductions never pollute a snapshot.
package final class SprawlRunner<Output> {
    private let gen: Generator<Output>
    private let erasedGen: AnyGenerator
    private let property: @Sendable (Output) -> SprawlVerdict
    private let source: any CoverageSource
    private let configuration: SprawlRunnerConfiguration
    private let reducerConfiguration: Interpreters.ReducerConfiguration

    private let corpus: SprawlCorpus
    private let inventory = FaultInventory()
    private let pool = ReductionPool()
    private var gate: ReductionGate
    private var prng: Xoshiro256
    private var bandit = MutationBandit()

    /// G4: at most one thread at a time runs an instrumented evaluation bracket.
    private let attributionToken = NSLock()

    /// Completed classifications waiting for the loop to apply their failure-weight upgrades and escape-interval feedback.
    private let pendingClassifications = SendableBox<[(parentIndex: Int?, symptom: FailureSymptom, wasEscape: Bool, classification: ClusterClassification)]>([])

    /// Zobrist-keyed normalization results shared across reduction tasks; see ``SprawlNormalizer/normalize(reducedSequence:erasedGen:symptom:property:cache:)``.
    private let normalizationCache = SendableBox<[UInt64: ChoiceSequence?]>([:])

    private var startNanoseconds: UInt64 = 0
    private var lastAdmissionNanoseconds: UInt64 = 0
    private var screeningAttempts = 0
    private var samplingAttempts = 0
    private var sprawlAttempts = 0
    private var discardedAttempts = 0
    private var totalAttempts = 0

    /// Wall-clock nanoseconds spent inside the property body across all loop attempts; the report derives the framework-overhead fraction from it. Reduction-side evaluations run on other threads and are deliberately excluded.
    private var propertyNanoseconds: UInt64 = 0

    // MARK: - Crash-Recovery State

    private var progressWriter: SprawlProgressWriter?
    private var breadcrumb: SprawlBreadcrumb?
    private var lastCheckpointNanoseconds: UInt64 = 0
    /// Set when a new cluster classifies so the next checkpoint fires immediately — discovered clusters must reach disk without waiting out the interval.
    private var forceCheckpoint = false
    /// Run time consumed by crashed predecessors, so checkpoint accounting and report timestamps continue one logical timeline across resumes.
    private var priorConsumedNanoseconds: UInt64 = 0
    private var pcTableHashAtStart: UInt64 = 0

    /// The monotonic origin of the logical run: `startNanoseconds` backdated by predecessor time, so cluster timestamps from before and after a resume land on one timeline.
    private var reportEpochNanoseconds: UInt64 {
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

        let inventory = inventory
        let clusters = __ExhaustRuntime.blockingAwait { await inventory.snapshot() }
        let unmatched = __ExhaustRuntime.blockingAwait { await inventory.unmatchedUnreducedCounts }

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
            onExample: { [self] value, tree, passed in
                screeningAttempts += 1
                totalAttempts += 1
                drainClassifications()
                let sequence = ChoiceSequence.flatten(tree)
                // Every covering-array row is boundary-derived; convergence is 1 because the tree came straight from materialisation.
                let admission = corpus.offer(
                    sequence: sequence,
                    tree: tree,
                    hits: lastHits,
                    convergence: 1.0,
                    generation: 0,
                    phase: .screening,
                    isBoundaryDerived: true,
                    propertyFailed: passed == false
                )
                if case .admitted = admission {
                    lastAdmissionNanoseconds = monotonicNanoseconds()
                }
                if passed == false, case let .fail(symptom) = lastVerdict {
                    var coverageNovel = false
                    if case .admitted = admission {
                        coverageNovel = true
                    }
                    handleFailure(
                        value: value,
                        tree: tree,
                        sequence: sequence,
                        symptom: symptom,
                        parentIndex: nil,
                        phase: .screening,
                        coverageNovel: coverageNovel
                    )
                }
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
                return nil
            }
            let sequence = ChoiceSequence.flatten(tree)
            breadcrumb?.record(candidateHash: ZobristHash.hash(of: sequence), parentHash: 0)
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
            attributionToken.unlock()

            samplingAttempts += 1
            totalAttempts += 1

            let admission = corpus.offer(
                sequence: sequence,
                tree: tree,
                hits: hits,
                convergence: 1.0,
                generation: 0,
                phase: .sampling,
                propertyFailed: verdict.isFailure
            )
            if case .admitted = admission {
                samplesSinceNovelty = 0
                lastAdmissionNanoseconds = monotonicNanoseconds()
            } else {
                samplesSinceNovelty += 1
            }

            if case let .fail(symptom) = verdict {
                var coverageNovel = false
                if case .admitted = admission {
                    coverageNovel = true
                }
                handleFailure(
                    value: value,
                    tree: tree,
                    sequence: sequence,
                    symptom: symptom,
                    parentIndex: nil,
                    phase: .sampling,
                    coverageNovel: coverageNovel
                )
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
                if let termination = fallbackSample(interpreter: &fallbackInterpreter) {
                    return termination
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
        breadcrumb?.record(candidateHash: ZobristHash.hash(of: sequence), parentHash: parent.hash)
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
        attributionToken.unlock()

        sprawlAttempts += 1
        totalAttempts += 1

        let admission = corpus.offer(
            sequence: sequence,
            tree: freshTree,
            hits: hits,
            convergence: decodingReport?.convergence ?? 0,
            generation: parent.generation + 1,
            phase: .sprawl,
            propertyFailed: verdict.isFailure
        )
        if case .admitted = admission {
            lastAdmissionNanoseconds = monotonicNanoseconds()
            if configuration.experiments.banditBands {
                for arm in MutationArm.allCases where armsMask & (1 << UInt8(arm.rawValue)) != 0 {
                    bandit.reward(arm)
                }
            }
        }

        if case let .fail(symptom) = verdict {
            var coverageNovel = false
            if case .admitted = admission {
                coverageNovel = true
            }
            handleFailure(
                value: value,
                tree: freshTree,
                sequence: sequence,
                symptom: symptom,
                parentIndex: parentIndex,
                phase: .sprawl,
                coverageNovel: coverageNovel
            )
        }
    }

    /// One fresh-sampling attempt used when the mutable tier is empty. Returns a termination only on generation error.
    private func fallbackSample(interpreter: inout ValueAndChoiceTreeInterpreter<Output>) -> SprawlTermination? {
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
            discardedAttempts += 1
            return nil
        }
        let sequence = ChoiceSequence.flatten(tree)
        breadcrumb?.record(candidateHash: ZobristHash.hash(of: sequence), parentHash: 0)
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
        attributionToken.unlock()

        sprawlAttempts += 1
        totalAttempts += 1

        let admission = corpus.offer(
            sequence: sequence,
            tree: tree,
            hits: hits,
            convergence: 1.0,
            generation: 0,
            phase: .sprawl,
            propertyFailed: verdict.isFailure
        )
        if case .admitted = admission {
            lastAdmissionNanoseconds = monotonicNanoseconds()
        }
        if case let .fail(symptom) = verdict {
            var coverageNovel = false
            if case .admitted = admission {
                coverageNovel = true
            }
            handleFailure(
                value: value,
                tree: tree,
                sequence: sequence,
                symptom: symptom,
                parentIndex: nil,
                phase: .sprawl,
                coverageNovel: coverageNovel
            )
        }
        return nil
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
                let timestamp = monotonicNanoseconds()
                let inventory = inventory
                Task {
                    await inventory.recordUnreduced(
                        symptom: symptom,
                        timestampNanoseconds: timestamp,
                        attemptIndex: attemptIndex
                    )
                }
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
                if await inventory.containsKey(rawKey) == false,
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
            let classification = await inventory.recordReduced(
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

    // MARK: - Crash Recovery

    /// Creates the writer and live breadcrumb, restores predecessor state, and quarantines the crash region. First write activity of the run — a run that never starts leaves no files.
    private func setUpPersistence() {
        guard let persistence = configuration.persistence else {
            return
        }
        progressWriter = SprawlProgressWriter(store: persistence.store)
        breadcrumb = SprawlBreadcrumb(fileURL: persistence.store.breadcrumbFileURL)
        pcTableHashAtStart = SancovRuntime.pcTableHash()
        lastCheckpointNanoseconds = startNanoseconds

        if let document = persistence.resumeDocument {
            priorConsumedNanoseconds = document.metadata.consumedNanoseconds
            restore(from: document)
            ExhaustLog.notice(
                category: .propertyTest,
                event: "explore_time_resumed",
                metadata: [
                    "consumed_seconds": "\(document.metadata.consumedNanoseconds / 1_000_000_000)",
                    "restored_entries": "\(corpus.entries.count)",
                    "restored_clusters": "\(document.clusters.count)",
                ]
            )
        }
        breadcrumb?.clear()
        if let survivor = persistence.survivor {
            corpus.quarantine(sequenceHash: survivor.candidateHash)
            if survivor.parentHash != 0 {
                corpus.quarantine(sequenceHash: survivor.parentHash)
            }
        }

        // Write one checkpoint synchronously before the first evaluation, so even a crash in the opening milliseconds leaves a parseable log on disk rather than nothing.
        try? persistence.store.write(makeCheckpointDocument(now: startNanoseconds))
    }

    /// Flushes outstanding checkpoints and removes the recovery state. Reaching this method at all means the run terminated normally — a surviving log is the crash signal, so a completed run must not leave one.
    private func finishPersistence() {
        guard let persistence = configuration.persistence else {
            return
        }
        progressWriter?.flush()
        breadcrumb?.clear()
        persistence.store.removeAll()
    }

    /// Hands one checkpoint to the async writer when the interval elapsed or a new cluster forced one. The loop's cost is copying value-type state; encoding and I/O happen on the writer's queue.
    private func checkpointIfDue() {
        guard let writer = progressWriter else {
            return
        }
        let now = monotonicNanoseconds()
        guard forceCheckpoint || now - lastCheckpointNanoseconds >= SprawlTunables.checkpointIntervalNanoseconds else {
            return
        }
        forceCheckpoint = false
        lastCheckpointNanoseconds = now

        let document = makeCheckpointDocument(now: now)
        writer.submit { document }
    }

    /// Snapshots corpus and inventory into a progress document. Called synchronously at startup and once per due checkpoint; the returned document is `Sendable`, so the async writer serialises and writes it off the loop.
    private func makeCheckpointDocument(now: UInt64) -> SprawlProgressDocument {
        let inventory = inventory
        let clusters = __ExhaustRuntime.blockingAwait { await inventory.snapshot() }
        let epoch = reportEpochNanoseconds
        return SprawlProgressDocument(
            metadata: SprawlProgressDocument.Metadata(
                seed: configuration.seed,
                budgetNanoseconds: priorConsumedNanoseconds + configuration.budgetNanoseconds,
                consumedNanoseconds: priorConsumedNanoseconds + (now - startNanoseconds),
                lastCheckpointEpochSeconds: Date().timeIntervalSince1970,
                pcTableHash: pcTableHashAtStart,
                edgeCount: source.edgeCount
            ),
            clusters: clusters.map { SprawlProgressDocument.ClusterRecord(cluster: $0, epochNanoseconds: epoch) },
            snapshot: corpus.entries.map(SprawlProgressDocument.CorpusEntryRecord.init(entry:))
        )
    }

    /// Rebuilds the corpus and inventory from a predecessor's document.
    ///
    /// Every entry is re-materialised in `.exact` mode — the tree is not persisted and mutations need it as the guided fallback. When the PC-table hash and edge count match the predecessor's, cached hits are trusted; otherwise each entry is re-attributed with one instrumented evaluation against the new edge ordering, and cluster signatures (stale edge indices) are dropped. Entries the current generator can no longer materialise are silently pruned — exactly the right pruning after a code change.
    private func restore(from document: SprawlProgressDocument) {
        let signaturesValid = document.metadata.pcTableHash == pcTableHashAtStart
            && document.metadata.edgeCount == source.edgeCount

        var restoredClusters: [FaultCluster] = []
        for record in document.clusters {
            guard let sequence = ChoiceSequenceCodec.decode(record.reducedSequence),
                  let phase = SprawlPhase(rawValue: record.discoveringPhase)
            else {
                continue
            }
            let signatures: [BitSet] = signaturesValid
                ? record.signatureIndices.map { indices in
                    var signature = BitSet(capacity: source.edgeCount)
                    for index in indices where index >= 0 && index < source.edgeCount {
                        signature.insert(index)
                    }
                    return signature
                }
                : []
            restoredClusters.append(FaultCluster(
                restoredID: restoredClusters.count,
                reducedSequence: sequence,
                reducedDescription: record.reducedDescription,
                reducedKey: record.reducedKey,
                signatures: signatures,
                symptoms: Set(record.symptoms.map(FailureSymptom.init(kind:))),
                instanceCount: record.instanceCount,
                reducedCount: record.reducedCount,
                firstSeenNanoseconds: reportEpochNanoseconds + record.firstSeenNanoseconds,
                lastSeenNanoseconds: reportEpochNanoseconds + record.lastSeenNanoseconds,
                firstSeenAttempt: record.firstSeenAttempt ?? 0,
                unnormalizedMemberCount: record.unnormalizedMemberCount ?? 0,
                discoveringPhase: phase
            ))
        }
        let inventory = inventory
        let clustersToRestore = restoredClusters
        __ExhaustRuntime.blockingAwait { await inventory.restore(clusters: clustersToRestore) }

        for record in document.snapshot {
            guard let sequence = ChoiceSequenceCodec.decode(record.sequence),
                  let phase = SprawlPhase(rawValue: record.phase)
            else {
                continue
            }
            let result = Materializer.materializeAny(erasedGen, prefix: sequence, mode: .exact)
            guard case let .success(anyValue, tree, _) = result, let value = anyValue as? Output else {
                continue
            }
            let hits: [(edge: Int, hitCount: UInt8)]
            if signaturesValid {
                hits = zip(record.hitEdges, record.hitCounts).map { (edge: $0.0, hitCount: $0.1) }
            } else {
                attributionToken.lock()
                source.beginAttempt()
                if source.wantsValues {
                    source.noteValue(value)
                }
                // Attribution only — a failing entry's cluster was already restored, so no failure dispatch here.
                _ = property(value)
                var reattributed: [(edge: Int, hitCount: UInt8)] = []
                source.forEachHitEdge { edge, hitCount in
                    reattributed.append((edge, hitCount))
                }
                attributionToken.unlock()
                hits = reattributed
            }
            _ = corpus.offer(
                sequence: sequence,
                tree: tree,
                hits: hits,
                convergence: record.convergence,
                generation: record.generation,
                phase: phase,
                isBoundaryDerived: record.isBoundaryDerived,
                propertyFailed: record.propertyFailed
            )
        }
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
