import ExhaustCore

extension __ExhaustRuntime {
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
        let linearizabilityCache = UnsafeSendableBox(Set<Int>())
        let linearizabilityCacheHits = UnsafeSendableBox(0)
        let linearizabilityChecks = UnsafeSendableBox(0)

        func finalizeReport() {
            report.totalMilliseconds = runStopwatch.elapsedMilliseconds
            let hits = linearizabilityCacheHits.value
            let checks = linearizabilityChecks.value
            let total = hits + checks
            if total > 0 {
                let percentage = Int(Double(hits) / Double(total) * 100)
                ExhaustLog.debug(
                    category: .propertyTest,
                    event: "linearizability_sequence_cache",
                    metadata: [
                        "checks": "\(checks)",
                        "hits": "\(hits)",
                        "total": "\(total)",
                        "hit_rate": "\(percentage)%",
                        "entries": "\(linearizabilityCache.value.count)",
                    ]
                )
            }
        }

        let commandGen = Spec.commandGenerator.gen
        let commandLimit = config.commandLimit ?? PreemptiveReduction.defaultCommandLimit
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
        let currentTreeHash = UnsafeSendableBox<Int?>(nil)
        let classifyFailure: @Sendable ([(ScheduleMarker, Spec.Command)], Preemptive.Outcome<Spec>) -> (outcome: Preemptive.Outcome<Spec>, witness: ResponseWitness?, failureDescription: String?)? = { taggedCommands, outcome in
            if outcome.passed {
                return nil
            }
            guard let laneResponses = outcome.laneResponses,
                  let concurrentSpec = outcome.concurrentSpec
            else {
                return (outcome, nil, nil)
            }
            if let treeHash = currentTreeHash.value, linearizabilityCache.value.contains(treeHash) {
                linearizabilityCacheHits.value += 1
                return nil
            }
            linearizabilityChecks.value += 1
            guard case let .notLinearizable(witness, failure) = backend.checkLinearizability(
                taggedCommands: taggedCommands,
                laneResponses: laneResponses,
                concurrentSpec: concurrentSpec
            ) else {
                if let treeHash = currentTreeHash.value {
                    linearizabilityCache.value.insert(treeHash)
                }
                return nil
            }
            return (outcome, witness, failure)
        }

        let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            invocationCounter.value += 1
            let outcome = backend.execute(taggedCommands)
            lastRunTimedOut.value = outcome.timedOut
            guard let failure = classifyFailure(taggedCommands, outcome) else {
                return true
            }
            lastFailingOutcome.value = failure.outcome
            return false
        }

        func confirmRealFailure(_ input: [(ScheduleMarker, Spec.Command)], discoveryIterations: Int) -> (outcome: Preemptive.Outcome<Spec>, witness: ResponseWitness?, failureDescription: String?)? {
            currentTreeHash.value = nil
            for _ in 0 ..< PreemptiveReduction.finalConfirmationRepetitions(discoveryIterations: discoveryIterations) {
                if let confirmed = classifyFailure(input, backend.execute(input)) {
                    return confirmed
                }
            }
            return nil
        }

        func linearizableProbe(_ probeCommands: [(ScheduleMarker, Spec.Command)], probeTree: ChoiceTree) -> (Bool, ResponseWitness?, String?, Preemptive.Outcome<Spec>?) {
            currentTreeHash.value = probeTree.hashValue
            let failure = classifyFailure(probeCommands, backend.execute(probeCommands))
            if let failure {
                return (false, failure.witness, failure.failureDescription, failure.outcome)
            }
            return (true, nil, nil, nil)
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
            taggedCommands: [(ScheduleMarker, Spec.Command)],
            tree: ChoiceTree,
            pruneSeed: UInt64,
            discoveryIterations: Int
        ) -> (reduced: [(ScheduleMarker, Spec.Command)], reductionInvocations: Int, witness: ResponseWitness?, reportedOutcome: Preemptive.Outcome<Spec>?, failureDescription: String?) {
            let repetitions = PreemptiveReduction.confirmationRepetitions(discoveryIterations: discoveryIterations)
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
            let collapseResult = PreemptiveReduction.reduceSinglePass(
                generator: sequenceGen,
                tree: prunedTree,
                output: prunedCommands,
                encoders: [.laneCollapse],
                maxStalls: 2,
                deadlineNanoseconds: 7_500_000_000,
                rematerialize: true,
                repetitions: repetitions,
                tuning: noRelax,
                execute: linearizableProbe
            )

            // Pass 2: deletion and value reduction on the collapsed schedule. The tighter interleaving space (fewer concurrent commands) makes each linearizability check cheaper and the prefix cache more effective — fewer distinct observation sets, more cross-check hits.
            let combinedResult = PreemptiveReduction.reduceSinglePass(
                generator: sequenceGen,
                tree: collapseResult.tree,
                output: collapseResult.output,
                encoders: [.deletion, .valueSearch, .floatSearch],
                maxStalls: 2,
                deadlineNanoseconds: 7_500_000_000,
                rematerialize: true,
                repetitions: repetitions,
                tuning: noRelax,
                execute: linearizableProbe
            )
            var stats = collapseResult.stats
            stats.merge(combinedResult.stats)
            report.applyReductionStats(stats)

            // Present prefix-first. The runner runs all prefix commands sequentially before any lane (execute() partitions by marker, not array position), so reordering is execution-equivalent and makes the execution trace honest.
            let reduced = combinedResult.output.sorted { $0.0.isPrefix && $1.0.isPrefix == false }

            // Evidence priority: (1) reduction cache from the deletion pass, (2) reduction cache from the lane collapse pass, (3) confirmRealFailure re-execution as last resort when no reduction probe reproduced the race.
            let cachedOutcome = combinedResult.failureOutcome ?? collapseResult.failureOutcome
            let cachedWitness = combinedResult.witness ?? collapseResult.witness
            let cachedDescription = combinedResult.failureDescription ?? collapseResult.failureDescription
            if cachedOutcome != nil {
                return (
                    reduced,
                    combinedResult.propertyInvocations + collapseResult.propertyInvocations,
                    cachedWitness,
                    cachedOutcome,
                    cachedDescription
                )
            }
            let confirmed = confirmRealFailure(reduced, discoveryIterations: discoveryIterations)
            return (
                reduced,
                combinedResult.propertyInvocations + collapseResult.propertyInvocations,
                confirmed?.witness,
                confirmed?.outcome,
                confirmed?.failureDescription
            )
        }

        /// Builds the result, records invocation counts, renders the failure issue, and finalizes the report for a reduced failure. The coverage and sampling phases run this identical six-step sequence after ``reduceConfirmedFailure`` and differ only in discovery metadata, so it lives here rather than being spelled out at each phase.
        func assembleReducedFailure(
            reduction: (reduced: [(ScheduleMarker, Spec.Command)], reductionInvocations: Int, witness: ResponseWitness?, reportedOutcome: Preemptive.Outcome<Spec>?, failureDescription: String?),
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
                    actualDescription: reduction.failureDescription ?? reduction.reportedOutcome?.concurrentSpec?.failureDescription(),
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
                let reduction = reduceConfirmedFailure(
                    taggedCommands: taggedCommands,
                    tree: tree,
                    pruneSeed: UInt64(coverageIterations),
                    discoveryIterations: coverageIterations
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
                    currentTreeHash.value = tree.hashValue
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

                    let reduction = reduceConfirmedFailure(
                        taggedCommands: taggedCommands,
                        tree: tree,
                        pruneSeed: UInt64(absoluteIteration),
                        discoveryIterations: coverageInvocations + samplingIteration
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
}
