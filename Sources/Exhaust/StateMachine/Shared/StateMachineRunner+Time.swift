// The spec adapter and dispatch for coverage-guided spec search: `#explore(Spec.self, mode: .tasks, time:)`.

import ExhaustCore
import Foundation
import IssueReporting

// MARK: - Dispatch

public extension __ExhaustRuntime {
    /// Dispatches a synchronous spec to the coverage-guided runner based on its execution model. Runtime target of `#explore(Spec.self, mode:, time:)`.
    ///
    /// Async for the same reason plain `#execute` is: the run occupies its thread for the whole time budget, so it hops to a GCD worker instead of starving the cooperative pool. Every path, configuration errors included, funnels through the shared reporting epilogue, so findings, configuration errors, and the summary attachment surface exactly as they do for `#explore(time:)`.
    @discardableResult
    static func __runStateMachineTimeDispatch(
        _ specType: (some StateMachineSpec).Type,
        mode: SearchableExecutionModel,
        time: TimeSpan,
        settings: [StateMachineFuzzSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> FuzzReport {
        let report = await stateMachineTimeReport(
            specType,
            mode: mode,
            time: time,
            settings: settings,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        // Reporting runs here on the test task, after the GCD hop: issue recording and attachment association both resolve the current test from task-locals a GCD worker does not carry.
        let parsedSettings = ParsedStateMachineFuzzSettings(settings).shared
        reportFuzzIssues(
            report: report,
            suppressIssueReporting: parsedSettings.suppress.issueReporting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        recordFuzzAttachments(report: report, suppressAttachments: parsedSettings.suppress.attachments)
        return report
    }

    /// Builds the run's report: validates settings, routes on the execution model, and runs the matching adapter. Records no issues — the dispatch reports the returned report's termination and clusters exactly once.
    private static func stateMachineTimeReport(
        _ specType: (some StateMachineSpec).Type,
        mode: SearchableExecutionModel,
        time: TimeSpan,
        settings: [StateMachineFuzzSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async -> FuzzReport {
        let parsed = ParsedStateMachineFuzzSettings(settings)
        if let invalid = parsed.invalidConfiguration {
            return .empty(termination: invalid, seed: 0)
        }
        let commandLimit = parsed.commandLimit
        let coreSettings = parsed.coreSettings

        switch mode {
            case .sequential, .tasks:
                // A synchronous `.tasks` spec has no suspension points to interleave at, so it runs through the sequential adapter — the same routing plain `#execute` applies. Cooperative interleaving requires async commands, which dispatch through the async twin.
                return await runSpecFuzz(
                    makeAdapter: { buildSequentialSpecAdapter(specType, commandLimit: commandLimit) },
                    time: time,
                    settings: coreSettings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
        }
    }

    /// Dispatches an asynchronous spec to the coverage-guided runner based on its execution model. Runtime target of `#explore(AsyncSpec.self, mode:, time:)`.
    ///
    /// The same shape as ``__runStateMachineTimeDispatch(_:mode:time:settings:fileID:filePath:line:column:)``: the run occupies a GCD worker for the whole budget, and reporting happens here on the test task after the hop.
    @discardableResult
    static func __runStateMachineTimeDispatchAsync(
        _ specType: (some AsyncStateMachineSpec).Type,
        mode: SearchableExecutionModel,
        time: TimeSpan,
        settings: [StateMachineFuzzSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> FuzzReport {
        let report = await asyncStateMachineTimeReport(
            specType,
            mode: mode,
            time: time,
            settings: settings,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        let parsedSettings = ParsedStateMachineFuzzSettings(settings).shared
        reportFuzzIssues(
            report: report,
            suppressIssueReporting: parsedSettings.suppress.issueReporting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        recordFuzzAttachments(report: report, suppressAttachments: parsedSettings.suppress.attachments)
        return report
    }

    /// The async twin of ``stateMachineTimeReport(_:time:settings:fileID:filePath:line:column:)``: validates settings, routes on the execution model, and runs the matching adapter.
    private static func asyncStateMachineTimeReport(
        _ specType: (some AsyncStateMachineSpec).Type,
        mode: SearchableExecutionModel,
        time: TimeSpan,
        settings: [StateMachineFuzzSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async -> FuzzReport {
        let parsed = ParsedStateMachineFuzzSettings(settings)
        if let invalid = parsed.invalidConfiguration {
            return .empty(termination: invalid, seed: 0)
        }
        let commandLimit = parsed.commandLimit

        switch mode {
            case .sequential:
                return await runSpecFuzz(
                    makeAdapter: { buildAsyncSequentialSpecAdapter(specType, commandLimit: commandLimit) },
                    time: time,
                    settings: parsed.coreSettings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            case .tasks:
                guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
                    return .empty(
                        termination: .invalidConfiguration("#explore(Spec.self, time:) with a .tasks spec requires macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, or visionOS 2+."),
                        seed: 0
                    )
                }
                let resolvedConcurrencyLevel = parsed.parallelize?.rawValue ?? 2
                let searchAbandonments = UnsafeSendableBox(0)
                let report = await runSpecFuzz(
                    makeAdapter: {
                        buildTasksSpecAdapter(
                            specType,
                            commandLimit: commandLimit,
                            concurrencyLevel: resolvedConcurrencyLevel,
                            searchAbandonments: searchAbandonments
                        )
                    },
                    time: time,
                    settings: parsed.coreSettings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                // An abandoned search passes its probe, so a run that keeps abandoning reports a clean inventory while having judged nothing. The plain runner warns about this and so must this one, through the same helper: a fuzz report full of zeroes means "no faults found", and without the warning there is nothing to distinguish that from "nothing was looked at".
                warnIfSearchesWentUnjudged(
                    abandonedSearches: searchAbandonments.value,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                return report
        }
    }

    /// Runs one spec adapter through `runExploreTimeCore` on a GCD worker with the spec-path configuration: screening skipped (boundary-value catalogs apply to values, not command vocabularies).
    ///
    /// Every execution model routes through here; an arm only has to supply its adapter factory. The factory runs on the worker so the adapter's generator and closures never cross a concurrency boundary. A nil adapter means the spec's command generator is not a top-level pick — the one construction the cooperative adapter cannot marker-tag — and terminates the run as a configuration error.
    private static func runSpecFuzz(
        makeAdapter: @escaping () -> SpecFuzzAdapter<some Any>?,
        time: TimeSpan,
        settings: [PropertyFuzzSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async -> FuzzReport {
        // Persistence prepares here on the test task, before the hop: reportFuzzResumeFindings records the predecessor's trap finding, and issue recording resolves the current test from task-locals a GCD worker does not carry. Context construction performs no writes, so nothing about it needs the fuzz lane.
        let persistence = prepareFuzzPersistence(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        return await dispatchToGCD(reserving: LaneReservation.fuzz) {
            guard let adapter = makeAdapter() else {
                return .empty(
                    termination: .invalidConfiguration("Command generator must be a top-level pick (.oneOf). Concurrent testing requires per-command branch structure."),
                    seed: 0
                )
            }
            return runExploreTimeCore(
                gen: adapter.generator,
                time: time,
                settings: settings,
                source: nil,
                configure: { configuration in
                    configuration.skipScreening = true
                    configuration.samplingPlateauWindow = FuzzTunables.specSamplingPlateauWindow
                },
                hooks: adapter.hooks,
                persistence: persistence,
                property: adapter.property
            )
        }
    }
}

// MARK: - Spec Adapter

extension __ExhaustRuntime {
    /// Builds the generator, property, and seam hooks for a sequential spec under `time:` mode.
    ///
    /// The returned adapter is ready for `runExploreTimeCore`: the generator emits tagged command sequences, the property maps outcomes to verdicts, and the hooks carry the spec's skip pruning and reduction. The caller supplies the time budget, settings, and configuration overrides.
    static func buildSequentialSpecAdapter<Spec: StateMachineSpec>(
        _: Spec.Type,
        commandLimit: Int? = nil
    ) -> SpecFuzzAdapter<SpecCandidateValue<Spec>> {
        let taggedSequenceGen = taggedSequenceGenerator(
            commandGen: Spec.commandGenerator,
            commandLimit: commandLimit ?? FuzzTunables.specDefaultCommandLimit
        )
        let candidateGen = specCandidateGenerator(Spec.self, sequenceGen: taggedSequenceGen)

        // Two views of the one executor loop: the verdict property drives the runner and carries the thrown error as the failure symptom; the Bool probe derived from it serves pruning and reduction, where only pass/fail matters.
        let verdictProperty: @Sendable (SpecCandidateValue<Spec>) -> FuzzVerdict = syncSequentialVerdictProperty(Spec.self)
        let rawProperty: @Sendable (SpecCandidateValue<Spec>) -> Bool = syncSequentialProperty(Spec.self)

        let identifySkips: @Sendable (SpecCandidateValue<Spec>) -> Set<Int> = { candidate in
            Spec.identifySkips(setupStep: candidate.setupStep, commands: candidate.taggedCommands.map(\.1))
        }

        let pruneHook = specTimePruneHook(
            sequenceGen: taggedSequenceGen,
            rawProperty: rawProperty,
            identifySkips: identifySkips
        )

        // The value path's reduction with the spec deadline: a spec reduction probe replays a whole command sequence against a fresh SUT, so it gets more wall clock per candidate.
        let reduceStrategy = FuzzRunner.propertyOnlyReduceStrategy(
            gen: candidateGen,
            property: verdictProperty,
            reducerConfiguration: Interpreters.ReducerConfiguration(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: FuzzTunables.specReductionDeadlineNanoseconds
            )
        )

        return SpecFuzzAdapter(
            generator: candidateGen,
            property: verdictProperty,
            hooks: FuzzHooks(prune: pruneHook, reduceStrategy: reduceStrategy)
        )
    }

    /// Builds the `time:` mode prune hook: decomposes the candidate, prunes skipped commands on the command child, and recomposes.
    ///
    /// The decomposition keeps the setup subtree out of `pruneSequenceElements`' reach: without it, a setup containing an array generator would put a `.sequence` node ahead of the command sequence and skip pruning would silently delete setup choices. seed 0 is safe here: skip pruning is pure element deletion into a fully populated tree, so the guided fallback tree is authoritative and the seed fills no gaps.
    static func specTimePruneHook<Spec: StateMachineSpecBase>(
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        rawProperty: @escaping @Sendable (SpecCandidateValue<Spec>) -> Bool,
        identifySkips: @escaping @Sendable (SpecCandidateValue<Spec>) -> Set<Int>
    ) -> @Sendable (SpecCandidateValue<Spec>, ChoiceTree) -> (value: SpecCandidateValue<Spec>, tree: ChoiceTree) {
        { value, tree in
            let setupTree: ChoiceTree?
            let commandTree: ChoiceTree
            if value.setupStep == nil {
                setupTree = nil
                commandTree = tree
            } else if let split = splitCandidateTree(tree) {
                setupTree = split.setupTree
                commandTree = split.commandTree
            } else {
                return (value, tree)
            }

            let setupStep = value.setupStep
            let pruned = pruneSkippedCommands(
                value: value.taggedCommands,
                tree: commandTree,
                generator: sequenceGen,
                seed: 0,
                property: { commands in
                    rawProperty(SpecCandidateValue(setupStep: setupStep, taggedCommands: commands))
                },
                identifySkips: { commands in
                    identifySkips(SpecCandidateValue(setupStep: setupStep, taggedCommands: commands))
                },
                requireFailurePreserved: false,
                logEvent: "spec_time_prune"
            )
            let prunedValue = SpecCandidateValue<Spec>(setupStep: setupStep, taggedCommands: pruned.value)
            let prunedTree = setupTree.map { composeCandidateTree(setupTree: $0, commandTree: pruned.tree) } ?? pruned.tree
            return (prunedValue, prunedTree)
        }
    }

    /// Builds the generator, property, and seam hooks for an async `.sequential` spec under `time:` mode.
    ///
    /// The async twin of ``buildSequentialSpecAdapter(_:commandLimit:)``: the same tagged sequence shape, skip pruning, and property-only reduction, with the executor loop bridged through `_blockingAwaitSemaphore`. The blocking bridge is safe here because the fuzz loop owns a GCD lane — the cooperative pool runs the awaited commands while the lane waits.
    static func buildAsyncSequentialSpecAdapter<Spec: AsyncStateMachineSpec>(
        _: Spec.Type,
        commandLimit: Int? = nil
    ) -> SpecFuzzAdapter<SpecCandidateValue<Spec>> {
        let taggedSequenceGen = taggedSequenceGenerator(
            commandGen: Spec.commandGenerator,
            commandLimit: commandLimit ?? FuzzTunables.specDefaultCommandLimit
        )
        let candidateGen = specCandidateGenerator(Spec.self, sequenceGen: taggedSequenceGen)

        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }

        // Two views of the one executor loop, exactly as the sync adapter: the verdict property carries the thrown error as the failure symptom; the Bool probe derived from it serves pruning and reduction.
        let verdictProperty: @Sendable (SpecCandidateValue<Spec>) -> FuzzVerdict = asyncSequentialVerdictProperty(specInit: specInit)
        let rawProperty: @Sendable (SpecCandidateValue<Spec>) -> Bool = asyncSequentialProperty(specInit: specInit)

        let asyncSkipIdentifier = Spec.skipIdentifier(specInit: specInit)
        let identifySkips: @Sendable (SpecCandidateValue<Spec>) -> Set<Int> = { candidate in
            asyncSkipIdentifier(candidate.setupStep, candidate.taggedCommands.map(\.1))
        }

        let pruneHook = specTimePruneHook(
            sequenceGen: taggedSequenceGen,
            rawProperty: rawProperty,
            identifySkips: identifySkips
        )

        let reduceStrategy = FuzzRunner.propertyOnlyReduceStrategy(
            gen: candidateGen,
            property: verdictProperty,
            reducerConfiguration: Interpreters.ReducerConfiguration(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: FuzzTunables.specReductionDeadlineNanoseconds
            )
        )

        return SpecFuzzAdapter(
            generator: candidateGen,
            property: verdictProperty,
            hooks: FuzzHooks(prune: pruneHook, reduceStrategy: reduceStrategy)
        )
    }
}

// MARK: - Cooperative Adapter

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension __ExhaustRuntime {
    /// Builds the generator, property, and seam hooks for a `.tasks` spec under `time:` mode.
    ///
    /// Unlike the sequential adapters, the generator draws a lane-assigning schedule marker as a choice ahead of each command (``zipScheduleMarker(onto:concurrencyLevel:)``), so the interleaving is searchable input: the byte mutators that move commands between lanes and reorder the schedule are the same ones that mutate command arguments, and reduction minimizes markers toward the sequential prefix. The property drains each sequence through the cooperative scheduler at the marker-directed interleaving.
    ///
    /// A timed-out drain is inconclusive, not a counterexample: it counts as a pass during search (matching plain `#execute`), and aborts reduction so a counterexample under reduction never reduces toward a hang.
    ///
    /// - Returns: Nil when the spec's command generator is not a top-level pick, which schedule-marker tagging requires.
    /// - Parameter idleTimeoutMilliseconds: The drain loop's stall bound. Defaults to the plain-`#execute` default; tests lower it so stall-path assertions do not wait out two seconds per evaluation.
    static func buildTasksSpecAdapter<Spec: AsyncStateMachineSpec>(
        _: Spec.Type,
        commandLimit: Int? = nil,
        concurrencyLevel: Int,
        idleTimeoutMilliseconds: Int = ResolvedConcurrentConfig.defaultIdleTimeout,
        searchAbandonments: UnsafeSendableBox<Int> = UnsafeSendableBox(0)
    ) -> SpecFuzzAdapter<SpecCandidateValue<Spec>>? {
        guard let taggedCommandGen = zipScheduleMarker(
            onto: Spec.commandGenerator.gen,
            concurrencyLevel: concurrencyLevel
        ) else {
            return nil
        }
        // A spec that declares an equivalence pays for an interleaving search on every probe the equivalence rejects, and that search grows multinomially in the sequence length. The plain runner drops to the thread-based default for exactly this reason; `FuzzTunables.specDefaultCommandLimit` is sized for accumulation faults on sequences nothing searches, and at that length an equivalence-bearing spec abandons its searches instead of judging them.
        let resolvedCommandLimit = commandLimit
            ?? (Spec.hasEquivalence ? ConcurrentSpecTunables.defaultCommandLimit : FuzzTunables.specDefaultCommandLimit)
        let sequenceGen = Gen.arrayOf(
            taggedCommandGen,
            within: 1 ... UInt64(resolvedCommandLimit),
            scaling: .constant
        )
        let candidateGen = specCandidateGenerator(Spec.self, sequenceGen: sequenceGen)

        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }

        // Abandonments are tallied on the discovery path only. A run that keeps abandoning its searches passes probes it never judged, which is the one thing a green fuzz report must not hide; counting the reduction probes as well would inflate the figure with re-judgements of a sequence already counted.
        let verdictProperty: @Sendable (SpecCandidateValue<Spec>) -> FuzzVerdict = { candidate in
            let result = drainAndJudge(
                taggedCommands: candidate.taggedCommands,
                setupStep: candidate.setupStep,
                specInit: specInit,
                concurrencyLevel: concurrencyLevel,
                recordTrace: false,
                idleTimeoutMilliseconds: idleTimeoutMilliseconds,
                searchAbandonments: searchAbandonments
            )
            if result.timedOut {
                // Inconclusive, not a counterexample: pass keeps discovery sampling, exactly as plain #execute counts timed-out probes.
                return .pass
            }
            if result.passed {
                return .pass
            }
            return .fail(FailureSymptom(kind: result.failureSymptomKind ?? "returnedFalse"))
        }
        let rawProperty: @Sendable (SpecCandidateValue<Spec>) -> Bool = { candidate in
            verdictProperty(candidate).isFailure == false
        }

        let rawIdentifySkips = Spec.skipIdentifier(specInit: specInit)
        let identifySkips: @Sendable (SpecCandidateValue<Spec>) -> Set<Int> = { candidate in
            rawIdentifySkips(candidate.setupStep, candidate.taggedCommands.map(\.1))
        }

        let pruneHook = specTimePruneHook(
            sequenceGen: sequenceGen,
            rawProperty: rawProperty,
            identifySkips: identifySkips
        )

        // Two-pass reduction (lane collapse + deletion, then value minimization), run inline on the fuzz loop's GCD lane. The drain loop's spin-polling stays off the cooperative pool because the loop's lane hosts it, which is what inline reduction guarantees by construction. Unlike the plain-#execute machine, `time:` mode reduces the whole candidate in one tree, so setup values minimize alongside the commands here rather than in a separate pass.
        let reduceStrategy: @Sendable (ChoiceTree, SpecCandidateValue<Spec>, FailureSymptom) -> FuzzReductionResult<SpecCandidateValue<Spec>> = { tree, value, _ in
            let probeProperty: @Sendable (SpecCandidateValue<Spec>) -> StateMachineProbeVerdict<Void> = { candidate in
                let result = drainAndJudge(
                    taggedCommands: candidate.taggedCommands,
                    setupStep: candidate.setupStep,
                    specInit: specInit,
                    concurrencyLevel: concurrencyLevel,
                    recordTrace: false,
                    idleTimeoutMilliseconds: idleTimeoutMilliseconds
                )
                if result.timedOut {
                    // A probe that times out during reduction is not a counterexample. Abort further reduction and keep the failure as-is rather than reducing toward a hang.
                    ExhaustLog.notice(category: .reducer, event: "spec_time_reduction_timeout")
                    return .abort
                }
                return result.passed ? .pass : .fail(())
            }
            let result = reduceConcurrentTwoPass(
                generator: candidateGen,
                tree: tree,
                output: value,
                deadlineNanoseconds: FuzzTunables.specReductionDeadlineNanoseconds,
                property: probeProperty
            )
            return FuzzReductionResult(
                sequence: result.sequence,
                tree: result.tree,
                value: result.value,
                propertyInvocations: result.stats.reductionProbesWherePropertyPassed
                    + result.stats.reductionProbesWherePropertyFailed
            )
        }

        return SpecFuzzAdapter(
            generator: candidateGen,
            property: verdictProperty,
            hooks: FuzzHooks(prune: pruneHook, reduceStrategy: reduceStrategy)
        )
    }
}

// MARK: - Adapter Type

/// Bundles the generator, property, and seam hooks for one spec type under `time:` mode.
struct SpecFuzzAdapter<Output> {
    /// Generates tagged command sequences for the runner.
    let generator: Generator<Output>
    /// Maps a command-sequence outcome to a pass or fail verdict.
    let property: @Sendable (Output) -> FuzzVerdict
    /// The spec's skip pruning and reduction, carried into ``FuzzRunner`` as one unit.
    let hooks: FuzzHooks<Output>
}
