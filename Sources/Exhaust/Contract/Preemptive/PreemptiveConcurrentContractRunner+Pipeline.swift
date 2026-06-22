import ExhaustCore

extension __ExhaustRuntime {
    /// A tagged command with its ChoiceSequence segment — the generation recipe that produced this command. The segment is a stable identity for cache fingerprinting: equal segments imply equal commands regardless of which lane they appear on.
    typealias TaggedCommandWithSegment<Command> = (marker: ScheduleMarker, command: Command, segment: ChoiceSequence)
    /// Runs the shared preemptive pipeline (smoke, SCA coverage, then random sampling with reduction) over a backend that supplies per-probe execution, the smoke trace, and oracle replay.
    ///
    /// The pipeline uses two levels of correctness checking. The fixed-ordering oracle is the fast entry filter: it compares the concurrent SUT's final state against one sequential replay (array order), which is cheap but can false-positive when GCD picks a valid but different ordering. Linearizability is the authority: it tries all valid orderings, comparing both per-command responses and final state via the oracle. The oracle is never bypassed. It runs inside each linearizability check as the state comparator.
    ///
    /// Sampling and lane-collapse use the oracle as their property function (fast, over-reports). Once a candidate survives lane-collapse, linearizability confirms it. Structural reduction uses linearizability as its property function, so commands whose return values carry response-level evidence are not stripped.
    ///
    /// Rendered failure messages are returned as deferred issues rather than reported inline, so each entry point can report them in a context where Swift Testing task-locals are available (the pipeline itself runs on a GCD thread). The fully-populated ``ExhaustReport`` is returned for the entry point to deliver to `onReport`.
    static func runPreemptivePipeline<Backend: PreemptiveBackend>(
        backend: Backend,
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String] = []
    ) -> (result: ContractResult<Backend.Spec>?, deferredIssues: [String], report: ExhaustReport) {
        typealias Spec = Backend.Spec
        let runStopwatch = Stopwatch()
        var report = ExhaustReport()
        report.seed = config.seed
        var deferredIssues: [String] = []

        func finalizeReport() {
            report.totalMilliseconds = runStopwatch.elapsedMilliseconds
        }

        let commandGen = Spec.commandGenerator.gen
        let commandLimit = config.commandLimit ?? Preemptive.defaultCommandLimit
        guard let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel) else {
            deferredIssues.append("Command generator must be a top-level pick (.oneOf). Concurrent testing requires per-command branch structure.")
            finalizeReport()
            return (nil, deferredIssues, report)
        }
        let sequenceGen = Gen.arrayOf(
            taggedCommandGen,
            within: 1 ... UInt64(commandLimit),
            scaling: .constant
        )

        let samplingBudget = config.budget.samplingBudget
        let coverageBudget = config.budget.coverageBudget
        var coverageInvocations = 0
        // Single-threaded: the reducer and SCA row loop call the property sequentially on the pipeline GCD thread.
        let invocationCounter = UnsafeSendableBox(0)
        let lastRunTimedOut = UnsafeSendableBox(false)

        let identifySkips = backend.makeIdentifySkips()
        let lastFailingOutcome = UnsafeSendableBox<Preemptive.Outcome<Spec>?>(nil)
        let prefixCacheBox = UnsafeSendableBox<LinearizabilityPrefixCache?>(LinearizabilityPrefixCache())
        // Classifies one execution against linearizability — the single decision shared by the sampling/coverage property, the reduction probe, and failure confirmation.
        // Returns the failing outcome (and any response-level witness) for a genuine violation: a non-linearizable execution, or an oracle failure with no lane responses (invariant/exception/timeout, real by construction).
        // Returns nil when the execution passed the oracle or was confirmed linearizable (a false positive to skip). The prefix is taken from `taggedCommands` itself so the lane responses fed to the checker match the schedule being classified.
        let classifyFailure: @Sendable ([TaggedCommandWithSegment<Spec.Command>], Preemptive.Outcome<Spec>) -> (outcome: Preemptive.Outcome<Spec>, witness: ResponseWitness?)? = { triples, outcome in
            if outcome.passed {
                return nil
            }
            guard let laneResponses = outcome.laneResponses, let concurrentSpec = outcome.concurrentSpec else {
                return (outcome, nil)
            }
            let prefixCommands = triples.filter(\.marker.isPrefix).map(\.command)
            let observationHashes = computeObservationHashes(triples: triples, laneResponses: laneResponses)
            guard case let .notLinearizable(witness) = backend.checkLinearizability(
                prefix: prefixCommands,
                laneResponses: laneResponses,
                concurrentSpec: concurrentSpec,
                observationHashes: observationHashes,
                prefixCache: &prefixCacheBox.value
            ) else {
                return nil
            }
            return (outcome, witness)
        }

        // The current generation tree, set by the sampling/coverage loop before each property call so classifyFailure can reconcile commands with their ChoiceSequence segments.
        let currentTree = UnsafeSendableBox<ChoiceTree?>(nil)

        // Linearizability-integrated property used by SCA coverage and sampling: returns false only for a genuine non-linearizable (or no-lane-response) failure, so passing and merely-linearizable executions are transparently skipped. Records the failing outcome for evidence rendering.
        let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            invocationCounter.value += 1
            let triples: [TaggedCommandWithSegment<Spec.Command>] = if let tree = currentTree.value {
                reconcileCommandsWithTree(taggedCommands, tree: tree)
            } else {
                taggedCommands.map { (marker: $0.0, command: $0.1, segment: ChoiceSequence()) }
            }
            let outcome = backend.execute(triples.strippingSegments())
            lastRunTimedOut.value = outcome.timedOut
            guard let failure = classifyFailure(triples, outcome) else {
                return true
            }
            lastFailingOutcome.value = failure.outcome
            return false
        }

        /// Confirms whether `input` is a genuine failure by re-executing it up to ``Preemptive/finalConfirmationRepetitions`` times and accepting the first reproduction classified non-linearizable.
        /// Preemptive execution is non-deterministic, so a single re-execution can draw a passing (or merely linearizable) interleaving and miss the race. This is the terminal confirmation (once per reported failure, not per reduction probe), so it uses the larger repetition budget: a timing-fragile race that the reduction loop's ``Preemptive/confirmationRepetitions`` probes could not re-trigger often still reproduces here, attaching the actual-state line and witness to the report.
        /// Returns the confirming execution's outcome (so its lane responses and final state render coherently with the verdict) and the response-level witness, or `nil` when no run reproduced a genuine violation.
        func confirmRealFailure(_ input: [(ScheduleMarker, Spec.Command)]) -> (outcome: Preemptive.Outcome<Spec>, witness: ResponseWitness?)? {
            let triples: [TaggedCommandWithSegment<Spec.Command>] = input.map { (marker: $0.0, command: $0.1, segment: ChoiceSequence()) }
            for _ in 0 ..< Preemptive.finalConfirmationRepetitions {
                if let confirmed = classifyFailure(triples, backend.execute(input)) {
                    return confirmed
                }
            }
            return nil
        }

        // The current reduction tree, set by reduceSinglePass before each property invocation so linearizableProbe can reconcile commands with their ChoiceSequence segments.
        let reductionTreeBox = UnsafeSendableBox<ChoiceTree?>(nil)

        /// Reduction property: a probe "passes" (stays reducible) when its execution is linearizable, so structural reduction keeps only commands whose removal would dissolve a genuine response-level violation. (A bare oracle property would strip commands whose return values carry the response-level evidence.)
        func linearizableProbe(_ probeCommands: [(ScheduleMarker, Spec.Command)]) -> Bool {
            let triples: [TaggedCommandWithSegment<Spec.Command>] = if let tree = reductionTreeBox.value {
                reconcileCommandsWithTree(probeCommands, tree: tree)
            } else {
                probeCommands.map { (marker: $0.0, command: $0.1, segment: ChoiceSequence()) }
            }
            return classifyFailure(triples, backend.execute(probeCommands)) == nil
        }

        /// Per-lane observed return values for failure annotation, keyed by ``ScheduleMarker/rawValue`` in per-lane execution order.
        func laneResponseValues(from outcome: Preemptive.Outcome<Spec>?) -> [UInt8: [String?]]? {
            guard let outcome, let typedResponses = outcome.laneResponses else { return nil }
            var values: [UInt8: [String?]] = [:]
            for laneArray in typedResponses {
                for response in laneArray {
                    values[response.lane, default: []].append(response.outcome.displayValue)
                }
            }
            return values
        }

        /// Reduces a discovered failure to its reported form, shared by the coverage and sampling phases (which differ only in discovery metadata).
        ///
        /// Prunes skipped commands, grows the deterministic prefix (lane collapse, oracle property), simplifies structurally under the linearizability property, then re-confirms and canonicalizes prefix-first. Applies reduction stats to the report. Returns the reported schedule, its total reduction-probe count, the response witness, and the confirming execution's outcome (for evidence and actual-state rendering). `reportedOutcome` is nil when reduction dissolved the violation and the pruned schedule is reported as a fallback.
        func reduceConfirmedFailure(
            triples: [TaggedCommandWithSegment<Spec.Command>],
            tree: ChoiceTree,
            pruneSeed: UInt64
        ) -> (reduced: [(ScheduleMarker, Spec.Command)], reductionInvocations: Int, witness: ResponseWitness?, reportedOutcome: Preemptive.Outcome<Spec>?) {
            let taggedCommands = triples.strippingSegments()
            // Prune commands whose preconditions were not met: a skipped command is a no-op, so removing it up front keeps reduction on the minimal command set and the reported counterexample carries no skipped commands. The prune is reverted if removing the skips dissolves the violation.
            let (prunedCommands, prunedTree) = pruneSkippedCommands(
                value: taggedCommands,
                tree: tree,
                generator: sequenceGen,
                seed: pruneSeed,
                property: property,
                identifySkips: identifySkips,
                logEvent: "preemptive_skip_pruning"
            )

            // Pass 1: lane collapse. Moves concurrent commands into the sequential prefix, reducing the number of lanes and the interleaving space before the checker-heavy deletion pass. Each accepted collapse self-validates as non-linearizable under linearizableProbe.
            let noRelax = SchedulerTuning(relaxMaterializationBudget: 0)
            let collapseResult = Preemptive.reduceSinglePass(
                generator: sequenceGen,
                tree: prunedTree,
                output: prunedCommands,
                encoders: [.laneCollapse],
                maxStalls: 2,
                deadlineNanoseconds: 7_500_000_000,
                rematerialize: true,
                repetitions: Preemptive.confirmationRepetitions,
                tuning: noRelax,
                reductionTreeBox: reductionTreeBox,
                execute: linearizableProbe
            )

            // Pass 2: deletion and value reduction on the collapsed schedule. The tighter interleaving space (fewer concurrent commands) makes each linearizability check cheaper and the prefix cache more effective — fewer distinct observation sets, more cross-check hits.
            let combinedResult = Preemptive.reduceSinglePass(
                generator: sequenceGen,
                tree: collapseResult.tree,
                output: collapseResult.output,
                encoders: [.deletion, .valueSearch, .floatSearch],
                maxStalls: 2,
                deadlineNanoseconds: 7_500_000_000,
                rematerialize: true,
                repetitions: Preemptive.confirmationRepetitions,
                tuning: noRelax,
                reductionTreeBox: reductionTreeBox,
                execute: linearizableProbe
            )
            var stats = collapseResult.stats
            stats.merge(combinedResult.stats)
            report.applyReductionStats(stats)

            reductionTreeBox.value = nil

//            print("DBG: Reduction stats laneCollapse: \(collapseResult.stats) deletion: \(combinedResult.stats)")

            // The combined output is already validated as non-linearizable by the pass (every accepted probe, deletion or collapse, kept it failing under linearizableExecute). Report it unconditionally — never discard the reduction. confirmRealFailure is evidence-only here: a reproducing run supplies coherent lane responses and actual state; a failure to reproduce leaves the evidence empty (the report shows expected-state only) rather than borrowing the original discovering run's, whose schedule no longer matches.
            let reportedOutcome = confirmRealFailure(combinedResult.output)
            // Present prefix-first. The runner runs all prefix commands sequentially before any lane (execute() partitions by marker, not array position), so reordering is execution-equivalent and makes the execution trace honest.
            let reduced = combinedResult.output.filter(\.0.isPrefix) + combinedResult.output.filter { $0.0.isPrefix == false }

            return (
                reduced,
                combinedResult.propertyInvocations + collapseResult.propertyInvocations,
                reportedOutcome?.witness,
                reportedOutcome?.outcome
            )
        }

        /// Builds the result, records invocation counts, renders the failure issue, and finalizes the report for a reduced failure. The coverage and sampling phases run this identical six-step sequence after ``reduceConfirmedFailure`` and differ only in discovery metadata, so it lives here rather than being spelled out at each phase.
        func assembleReducedFailure(
            reduction: (reduced: [(ScheduleMarker, Spec.Command)], reductionInvocations: Int, witness: ResponseWitness?, reportedOutcome: Preemptive.Outcome<Spec>?),
            discoveryMethod: ContractDiscoveryMethod,
            seed: UInt64?,
            iteration: Int,
            budget: UInt64,
            sequencesTested: Int,
            originalCount: Int,
            replaySeed: String,
            coverageInvocations: Int,
            randomSamplingInvocations: Int
        ) -> (result: ContractResult<Spec>?, deferredIssues: [String], report: ExhaustReport) {
            let (result, failureDescription) = backend.buildResult(
                reduced: reduction.reduced,
                seed: seed,
                replaySeed: replaySeed,
                discoveryMethod: discoveryMethod
            )
            report.setInvocations(
                coverage: coverageInvocations,
                randomSampling: randomSamplingInvocations,
                reduction: reduction.reductionInvocations
            )
            if config.suppressIssueReporting == false {
                // Evidence comes only from the reported schedule's own confirming run; when it could not be reproduced, the report shows expected-state only rather than borrowing the original discovering run's (mismatched) evidence.
                deferredIssues.append(makePreemptiveFailureMessage(
                    reduction.reduced,
                    specName: "\(Spec.self)",
                    discoveryMethod: discoveryMethod,
                    seed: seed,
                    iteration: iteration,
                    budget: budget,
                    sequencesTested: sequencesTested,
                    reductionInvocations: reduction.reductionInvocations,
                    originalCount: originalCount,
                    replaySeed: replaySeed,
                    timedOut: false,
                    expectedDescription: failureDescription,
                    actualDescription: reduction.reportedOutcome?.concurrentSpec?.failureDescription(),
                    laneResponseValues: laneResponseValues(from: reduction.reportedOutcome),
                    linearizabilityWitness: reduction.witness
                ))
            }
            finalizeReport()
            return (result, deferredIssues, report)
        }

        // Regression seeds: replay each through the same pipeline with the appropriate replay config.
        if config.coverageReplayRow == nil, config.seed == nil {
            for encodedSeed in regressionSeeds {
                guard let decoded = ReplaySeed.Resolved.decode(encodedSeed) else {
                    deferredIssues.append("Invalid regression seed: \(encodedSeed)")
                    continue
                }

                var replayConfig = config
                switch decoded {
                    case let .coverage(row: row):
                        replayConfig.coverageReplayRow = row
                        let needed = UInt64(row) + 1
                        if replayConfig.budget.coverageBudget < needed {
                            replayConfig.budget = .custom(
                                coverage: needed,
                                sampling: replayConfig.budget.samplingBudget
                            )
                        }
                    case let .sampling(seed, iteration):
                        replayConfig.seed = seed
                        replayConfig.replayIteration = iteration
                }

                let (replayResult, replayIssues, _) = runPreemptivePipeline(
                    backend: backend,
                    config: replayConfig
                )
                deferredIssues.append(contentsOf: replayIssues)

                if let replayResult {
                    finalizeReport()
                    return (replayResult, deferredIssues, report)
                } else if config.suppressIssueReporting == false {
                    deferredIssues.append("Regression seed \"\(encodedSeed)\" now passes. Consider removing it.")
                }
            }
        }

        // Phase 0: Smoke test. Run the first deterministic command sequence sequentially.
        // If the spec is broken without concurrency, fail fast before investing in concurrent probing.
        do {
            let smokeGen = Gen.arrayOf(
                commandGen,
                within: 1 ... UInt64(commandLimit),
                scaling: .constant
            )
            var smokeIterator = ValueAndChoiceTreeInterpreter(smokeGen, materializePicks: false, seed: 0, maxRuns: 1)
            if let (commands, _) = try smokeIterator.next() {
                let smoke = backend.runSmoke(commands)
                if smoke.failed {
                    let result = ContractResult<Spec>(
                        commands: commands,
                        trace: smoke.trace,
                        systemUnderTest: smoke.systemUnderTest,
                        seed: nil,
                        replaySeed: ReplaySeed.Resolved.sampling(seed: 0, iteration: 1).encoded,
                        discoveryMethod: .smokeTest
                    )
                    if config.suppressIssueReporting == false {
                        let failureInfo = ContractFailureInfo<Spec.Command>(discoveryMethod: .smokeTest)
                        let message = renderFailure(result, failureInfo: failureInfo, failureDescription: smoke.failureDescription)
                        deferredIssues.append(message)
                    }
                    report.replaySeed = result.replaySeed
                    report.setInvocations(coverage: 0, randomSampling: 1, reduction: 0)
                    finalizeReport()
                    return (result, deferredIssues, report)
                }
            }
        } catch {
            deferredIssues.append("Generator failed during smoke test: \(error)")
        }

        // Phase 1: Coverage — the property integrates linearizability so the row loop skips false positives and only stops on genuine violations.
        if config.shouldRunCoverage {
            let effectiveCoverageBudget: UInt64 = if let row = config.coverageReplayRow {
                max(coverageBudget, UInt64(row) + 1)
            } else {
                coverageBudget
            }
            let scaRowResult = runSCACoverageRowLoop(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: effectiveCoverageBudget,
                skipToRow: config.coverageReplayRow,
                logEventPrefix: "concurrent_sca_coverage",
                concurrencyLevel: config.concurrencyLevel,
                property: property
            )
            if case let .failure(taggedCommands, tree, coverageIterations) = scaRowResult {
                let triples = reconcileCommandsWithTree(taggedCommands, tree: tree)
                let reduction = reduceConfirmedFailure(
                    triples: triples,
                    tree: tree,
                    pruneSeed: UInt64(coverageIterations)
                )
                // Reduction probes run through reduceSinglePass's own counter, not the shared invocationCounter, so the three buckets are already disjoint: coverage takes the shared counter, sampling is zero, reduction its own count. (setConcurrentInvocations assumes reduction flows through the shared counter, which would drive coverage negative here.)
                return assembleReducedFailure(
                    reduction: reduction,
                    discoveryMethod: .coverage,
                    seed: nil,
                    iteration: coverageIterations,
                    budget: coverageBudget,
                    sequencesTested: invocationCounter.value,
                    originalCount: taggedCommands.count,
                    replaySeed: ReplaySeed.Resolved.encodeCoverageIteration(coverageIterations),
                    coverageInvocations: invocationCounter.value,
                    randomSamplingInvocations: 0
                )
            }
        }
        coverageInvocations = invocationCounter.value

        // Phase 2: Sampling
        if config.coverageReplayRow == nil {
            let (startIndex, maxRuns) = samplingReplayWindow(
                replayIteration: config.replayIteration,
                samplingBudget: samplingBudget
            )
            var interpreter = ValueAndChoiceTreeInterpreter(
                sequenceGen,
                materializePicks: false,
                seed: config.seed,
                maxRuns: maxRuns,
                initialRunIndex: startIndex
            )
            let actualSeed = interpreter.baseSeed

            var samplingIteration = 0
            do {
                while let (taggedCommands, tree) = try interpreter.next() {
                    samplingIteration += 1
                    let absoluteIteration = Int(startIndex) + samplingIteration
                    currentTree.value = tree
                    if property(taggedCommands) {
                        continue
                    }

                    // The property returned false — either a confirmed non-linearizable execution or a timeout/exception (no lane responses). The outcome is in lastFailingOutcome.
                    if lastRunTimedOut.value {
                        let discoveryMethod: ContractDiscoveryMethod = config.replayIteration != nil
                            ? .replay
                            : .randomSampling
                        let samplingReplaySeed = ReplaySeed.Resolved.sampling(seed: actualSeed, iteration: absoluteIteration).encoded
                        let reportedInput = taggedCommands.filter(\.0.isPrefix) + taggedCommands.filter { $0.0.isPrefix == false }
                        let (result, failureDescription) = backend.buildResult(
                            reduced: reportedInput,
                            seed: actualSeed,
                            replaySeed: samplingReplaySeed,
                            discoveryMethod: discoveryMethod
                        )
                        report.setInvocations(coverage: coverageInvocations, randomSampling: samplingIteration, reduction: 0)
                        if config.suppressIssueReporting == false {
                            deferredIssues.append(makePreemptiveFailureMessage(
                                reportedInput,
                                specName: "\(Spec.self)",
                                discoveryMethod: discoveryMethod,
                                seed: actualSeed,
                                iteration: absoluteIteration,
                                budget: samplingBudget,
                                sequencesTested: coverageInvocations + samplingIteration,
                                reductionInvocations: 0,
                                originalCount: taggedCommands.count,
                                replaySeed: samplingReplaySeed,
                                timedOut: true,
                                expectedDescription: failureDescription,
                                actualDescription: nil
                            ))
                        }
                        finalizeReport()
                        return (result, deferredIssues, report)
                    }

                    let triples = reconcileCommandsWithTree(taggedCommands, tree: tree)
                    let reduction = reduceConfirmedFailure(
                        triples: triples,
                        tree: tree,
                        pruneSeed: UInt64(absoluteIteration)
                    )
                    let discoveryMethod: ContractDiscoveryMethod = config.replayIteration != nil ? .replay : .randomSampling
                    return assembleReducedFailure(
                        reduction: reduction,
                        discoveryMethod: discoveryMethod,
                        seed: actualSeed,
                        iteration: absoluteIteration,
                        budget: samplingBudget,
                        sequencesTested: coverageInvocations + samplingIteration,
                        originalCount: taggedCommands.count,
                        replaySeed: ReplaySeed.Resolved.sampling(seed: actualSeed, iteration: absoluteIteration).encoded,
                        coverageInvocations: coverageInvocations,
                        randomSamplingInvocations: samplingIteration
                    )
                }
            } catch {
                deferredIssues.append("Generator failed during sampling: \(error)")
            }
        }

        report.setInvocations(coverage: coverageInvocations, randomSampling: 0, reduction: 0)
        finalizeReport()
        return (nil, deferredIssues, report)
    }

    /// Assembles the rendered failure message shared by the coverage and sampling phases.
    ///
    /// The two phases differ only in their discovery metadata (seed, iteration, budget, counts, replay seed). Everything else (the preemptive flag, the timeout-diagnostic gate, and the expected-state line built from the sequential oracle replay) is identical, so it lives here rather than being spelled out at each call site.
    private static func makePreemptiveFailureMessage(
        _ input: [(ScheduleMarker, some CustomStringConvertible)],
        specName: String,
        discoveryMethod: ContractDiscoveryMethod,
        seed: UInt64?,
        iteration: Int,
        budget: UInt64,
        sequencesTested: Int,
        reductionInvocations: Int,
        originalCount: Int,
        replaySeed: String,
        timedOut: Bool,
        expectedDescription: String?,
        actualDescription: String?,
        laneResponseValues: [UInt8: [String?]]? = nil,
        linearizabilityWitness: ResponseWitness? = nil
    ) -> String {
        var failureContext = FailureContext()
        failureContext.isPreemptive = true
        failureContext.specName = specName
        failureContext.discoveryMethod = discoveryMethod
        failureContext.seed = seed
        failureContext.iteration = iteration
        failureContext.budget = budget
        failureContext.sequencesTested = sequencesTested
        failureContext.reductionInvocations = reductionInvocations
        failureContext.originalCount = originalCount
        failureContext.replaySeed = replaySeed
        failureContext.timedOut = timedOut
        failureContext.oracleDescription = expectedDescription.map { "Expected state (from sequential replay):\n  \($0)" }
        failureContext.failureDescription = actualDescription.map { "Actual state (from concurrent execution):\n  \($0)" }
        failureContext.laneResponseValues = laneResponseValues
        failureContext.linearizabilityWitness = linearizabilityWitness
        let trace = __ExhaustRuntime.buildPreemptiveTrace(
            input,
            laneResponseValues: laneResponseValues,
            linearizabilityWitness: linearizabilityWitness
        )
        return renderFailure(input, trace: trace, context: failureContext)
    }

    /// Reconciles a command array with its generation tree, producing one triple per command.
    ///
    /// Each element of the tree's `.sequence` node is the subtree that generated one command. Flattening that subtree gives the ChoiceSequence segment — the recipe that produced the command. When the tree has no `.sequence` node (should not happen for `Gen.arrayOf` output), falls back to empty segments.
    static func reconcileCommandsWithTree<Command>(
        _ taggedCommands: [(ScheduleMarker, Command)],
        tree: ChoiceTree
    ) -> [TaggedCommandWithSegment<Command>] {
        let segments = tree.perElementSegments()
        return taggedCommands.enumerated().map { index, pair in
            let segment = segments.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? ChoiceSequence()
            return (marker: pair.0, command: pair.1, segment: segment)
        }
    }
}

extension Collection {
    /// Strips the ChoiceSequence segments, returning the `(ScheduleMarker, Command)` pairs that the execution path expects.
    func strippingSegments<Command>() -> [(ScheduleMarker, Command)] where Element == __ExhaustRuntime.TaggedCommandWithSegment<Command> {
        map { ($0.marker, $0.command) }
    }
}

/// Computes per-observation fingerprints by combining each command's ChoiceSequence segment hash with its response outcome hash. Returns `nil` if any response has a non-hashable `.returned(Any)` outcome.
///
/// The triples carry the generation-time segment for each command. The lane responses carry the execution-time outcome for each command, grouped by lane. This function matches them by lane marker and per-lane position, producing `[[UInt64]]` with the same shape as `laneResponses`.
private func computeObservationHashes<Command>(
    triples: [__ExhaustRuntime.TaggedCommandWithSegment<Command>],
    laneResponses: [[ObservedResponse<Command>]]
) -> [[UInt64]]? {
    var segmentsByLane: [UInt8: [ChoiceSequence]] = [:]
    for triple in triples where triple.marker.isPrefix == false {
        segmentsByLane[triple.marker.rawValue, default: []].append(triple.segment)
    }

    var result: [[UInt64]] = []
    for laneArray in laneResponses {
        guard let segments = segmentsByLane[laneArray.first?.lane ?? 0],
              segments.count == laneArray.count
        else {
            return nil
        }

        var laneHashes: [UInt64] = []
        for (index, response) in laneArray.enumerated() {
            let segmentHash = ZobristHash.hash(of: segments[index])
            let responseHash: UInt64
            switch response.outcome {
                case let .returned(value):
                    guard let hashable = value as? AnyHashable else { return nil }
                    responseHash = splitmix64(UInt64(bitPattern: Int64(hashable.hashValue)))
                case .returnedVoid:
                    responseHash = 0xA
                case .skipped:
                    responseHash = 0xB
            }
            laneHashes.append(segmentHash ^ responseHash)
        }
        result.append(laneHashes)
    }
    return result
}

private func splitmix64(_ seed: UInt64) -> UInt64 {
    var value = seed
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    value ^= value >> 31
    return value
}
