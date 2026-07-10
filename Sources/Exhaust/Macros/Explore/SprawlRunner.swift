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

    package init(
        budgetNanoseconds: UInt64,
        seed: UInt64,
        screeningBudget: UInt64 = 10000,
        skipScreening: Bool = false,
        skipSampling: Bool = false,
        attemptLimit: Int? = nil
    ) {
        self.budgetNanoseconds = budgetNanoseconds
        self.seed = seed
        self.screeningBudget = screeningBudget
        self.skipScreening = skipScreening
        self.skipSampling = skipSampling
        self.attemptLimit = attemptLimit
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
    package var termination: SprawlTermination
    package var startNanoseconds: UInt64
    package var elapsedNanoseconds: UInt64
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
    private var gate = ReductionGate()
    private var prng: Xoshiro256

    /// G4: at most one thread at a time runs an instrumented evaluation bracket.
    private let attributionToken = NSLock()

    /// Completed classifications waiting for the loop to apply their failure-weight upgrades.
    private let pendingClassifications = SendableBox<[(parentIndex: Int?, classification: ClusterClassification)]>([])

    private var startNanoseconds: UInt64 = 0
    private var lastAdmissionNanoseconds: UInt64 = 0
    private var screeningAttempts = 0
    private var samplingAttempts = 0
    private var sprawlAttempts = 0
    private var discardedAttempts = 0
    private var totalAttempts = 0

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
        corpus = SprawlCorpus(edgeCount: source.edgeCount)
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
            termination: finalTermination,
            startNanoseconds: startNanoseconds,
            elapsedNanoseconds: monotonicNanoseconds() - startNanoseconds,
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
            source.beginAttempt()
            if source.wantsValues {
                source.noteValue(value)
            }
            let verdict = property(value)
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
                    isBoundaryDerived: true
                )
                if case .admitted = admission {
                    lastAdmissionNanoseconds = monotonicNanoseconds()
                }
                if passed == false, case let .fail(symptom) = lastVerdict {
                    handleFailure(
                        value: value,
                        tree: tree,
                        sequence: sequence,
                        symptom: symptom,
                        parentIndex: nil,
                        phase: .screening
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
            if source.wantsValues {
                source.noteValue(value)
            }
            let verdict = property(value)
            var hits: [(edge: Int, hitCount: UInt8)] = []
            source.forEachHitEdge { edge, hitCount in
                hits.append((edge, hitCount))
            }
            attributionToken.unlock()

            samplingAttempts += 1
            totalAttempts += 1

            let sequence = ChoiceSequence.flatten(tree)
            let admission = corpus.offer(
                sequence: sequence,
                tree: tree,
                hits: hits,
                convergence: 1.0,
                generation: 0,
                phase: .sampling
            )
            if case .admitted = admission {
                samplesSinceNovelty = 0
                lastAdmissionNanoseconds = monotonicNanoseconds()
            } else {
                samplesSinceNovelty += 1
            }

            if case let .fail(symptom) = verdict {
                handleFailure(
                    value: value,
                    tree: tree,
                    sequence: sequence,
                    symptom: symptom,
                    parentIndex: nil,
                    phase: .sampling
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

            for _ in 0 ..< SprawlTunables.childrenPerParent {
                if terminationDue() != nil {
                    break
                }
                let mutated = nextCandidate(from: parent)
                evaluateSprawlCandidate(mutated, parent: parent, parentIndex: parentIndex)
            }
        }
    }

    /// Produces one mutated candidate from `parent`: usually an intensity-band mutation, occasionally a bind-boundary splice with a random donor.
    private func nextCandidate(from parent: CorpusEntry) -> ChoiceSequence {
        if randomUnit() < SprawlTunables.spliceProbability, corpus.entries.count > 1 {
            let donorIndex = Int(prng.next(upperBound: UInt64(corpus.entries.count)))
            let donor = corpus.entries[donorIndex]
            if donor.hash != parent.hash,
               let spliced = SprawlMutator.splice(recipient: parent.sequence, donor: donor.sequence, prng: &prng)
            {
                return spliced
            }
        }
        let intensityDraw = prng.next(upperBound: UInt64(SprawlIntensity.allCases.count))
        let intensity = SprawlIntensity.allCases[Int(intensityDraw)]
        return SprawlMutator.mutate(parent.sequence, intensity: intensity, prng: &prng)
    }

    private func evaluateSprawlCandidate(_ candidate: ChoiceSequence, parent: CorpusEntry, parentIndex: Int) {
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
        if source.wantsValues {
            source.noteValue(value)
        }
        let verdict = property(value)
        var hits: [(edge: Int, hitCount: UInt8)] = []
        source.forEachHitEdge { edge, hitCount in
            hits.append((edge, hitCount))
        }
        attributionToken.unlock()

        sprawlAttempts += 1
        totalAttempts += 1

        let sequence = ChoiceSequence.flatten(freshTree)
        let admission = corpus.offer(
            sequence: sequence,
            tree: freshTree,
            hits: hits,
            convergence: decodingReport?.convergence ?? 0,
            generation: parent.generation + 1,
            phase: .sprawl
        )
        if case .admitted = admission {
            lastAdmissionNanoseconds = monotonicNanoseconds()
        }

        if case let .fail(symptom) = verdict {
            handleFailure(
                value: value,
                tree: freshTree,
                sequence: sequence,
                symptom: symptom,
                parentIndex: parentIndex,
                phase: .sprawl
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
        if source.wantsValues {
            source.noteValue(value)
        }
        let verdict = property(value)
        var hits: [(edge: Int, hitCount: UInt8)] = []
        source.forEachHitEdge { edge, hitCount in
            hits.append((edge, hitCount))
        }
        attributionToken.unlock()

        sprawlAttempts += 1
        totalAttempts += 1

        let sequence = ChoiceSequence.flatten(tree)
        let admission = corpus.offer(
            sequence: sequence,
            tree: tree,
            hits: hits,
            convergence: 1.0,
            generation: 0,
            phase: .sprawl
        )
        if case .admitted = admission {
            lastAdmissionNanoseconds = monotonicNanoseconds()
        }
        if case let .fail(symptom) = verdict {
            handleFailure(value: value, tree: tree, sequence: sequence, symptom: symptom, parentIndex: nil, phase: .sprawl)
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
        phase: SprawlPhase
    ) {
        if let parentIndex {
            corpus.applyProvisionalFailureBoost(toParentAt: parentIndex)
        }
        let hash = ZobristHash.hash(of: sequence)
        switch gate.admit(sequenceHash: hash, symptom: symptom) {
            case .duplicate:
                return
            case .recordUnreduced:
                let timestamp = monotonicNanoseconds()
                let inventory = inventory
                Task {
                    await inventory.recordUnreduced(symptom: symptom, timestampNanoseconds: timestamp)
                }
            case .reduce:
                dispatchReduction(value: value, tree: tree, symptom: symptom, parentIndex: parentIndex, phase: phase)
        }
    }

    private func dispatchReduction(
        value: Output,
        tree: ChoiceTree,
        symptom: FailureSymptom,
        parentIndex: Int?,
        phase: SprawlPhase
    ) {
        // The generator and property are Sendable by construction (the macro enforces @Sendable; ReflectiveGenerator is @unchecked Sendable); the tree and value are moved into the task and never touched by the loop again.
        nonisolated(unsafe) let capturedGen = gen
        nonisolated(unsafe) let capturedTree = tree
        nonisolated(unsafe) let capturedValue = value
        let capturedProperty = property
        let reducerConfiguration = reducerConfiguration
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

            let reducedSequence: ChoiceSequence
            let reducedValue: Output
            switch outcome {
                case let .reduced(sequence, _, output), let .unreduced(sequence, _, output):
                    reducedSequence = sequence
                    reducedValue = output
                case .failure, nil:
                    reducedSequence = ChoiceSequence.flatten(capturedTree)
                    reducedValue = capturedValue
            }

            // Post-reduction classification: one instrumented evaluation under the attribution token yields the post-hoc signature. Clustering keys on (reduced form, signature).
            let signature = Self.attributedSignature(
                of: reducedValue,
                property: capturedProperty,
                source: source,
                attributionToken: attributionToken
            )

            var description = ""
            customDump(reducedValue, to: &description, maxDepth: 3)

            let classification = await inventory.recordReduced(
                reducedSequence: reducedSequence,
                reducedDescription: description,
                signature: signature,
                symptom: symptom,
                phase: phase,
                timestampNanoseconds: monotonicNanoseconds()
            )
            pendingClassifications.withValue { pending in
                pending.append((parentIndex: parentIndex, classification: classification))
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

    /// Applies completed classifications' failure-weight upgrades on the loop thread — the corpus is single-threaded by design, so reduction tasks post here instead of calling in.
    private func drainClassifications() {
        let completed = pendingClassifications.withValue { pending -> [(parentIndex: Int?, classification: ClusterClassification)] in
            let drained = pending
            pending.removeAll()
            return drained
        }
        for (parentIndex, classification) in completed {
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
