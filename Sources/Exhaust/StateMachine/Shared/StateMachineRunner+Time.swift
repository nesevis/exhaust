// The spec adapter and dispatch for coverage-guided execution: `#execute(Spec.self, time:)`.

import ExhaustCore
import Foundation
import IssueReporting

// MARK: - Dispatch

public extension __ExhaustRuntime {
    /// Dispatches a synchronous spec to the coverage-guided runner based on its execution model. Runtime target of `#execute(Spec.self, time:)`.
    ///
    /// Async for the same reason plain `#execute` is: the run occupies its thread for the whole time budget, so it hops to a GCD worker instead of starving the cooperative pool. Every path — configuration errors included — funnels through the shared reporting epilogue, so findings, configuration errors, and the summary attachment surface exactly as they do for `#explore(time:)`.
    @discardableResult
    static func __runStateMachineTimeDispatch(
        _ specType: (some StateMachineSpec).Type,
        time: TimeBudget,
        settings: [FuzzSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> FuzzReport {
        let report = await stateMachineTimeReport(
            specType,
            time: time,
            settings: settings,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        // Reporting runs here on the test task, after the GCD hop: issue recording and attachment association both resolve the current test from task-locals a GCD worker does not carry.
        reportFuzzIssues(
            report: report,
            suppressIssueReporting: ParsedFuzzSettings(settings).suppressIssueReporting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        recordFuzzAttachments(report: report, suppressAttachments: ParsedFuzzSettings(settings).suppressAttachments)
        return report
    }

    /// The spec-path settings the dispatch consumes rather than forwards, with the remainder ready for the core. Both time dispatches (sync and async) consume through this so validation and filtering cannot drift between the twins.
    private struct ConsumedSpecSettings {
        let commandLimit: Int?
        let parallelize: ConcurrencyLevel?
        /// The settings to forward: the core rejects `.commandLimit` and `.parallelize` because they are meaningless on the value path, so the consumed cases must not travel further.
        let coreSettings: [FuzzSettings]
        /// Non-nil when a consumed setting is invalid; the dispatch returns an empty report with this termination.
        let invalidConfiguration: FuzzReport.Termination?

        init(_ settings: [FuzzSettings]) {
            let parsed = ParsedFuzzSettings(settings)
            commandLimit = parsed.commandLimit
            parallelize = parsed.parallelize
            coreSettings = settings.filter { setting in
                switch setting {
                    case .commandLimit, .parallelize:
                        return false
                    default:
                        return true
                }
            }
            if let commandLimit = parsed.commandLimit, commandLimit < 1 {
                invalidConfiguration = .invalidConfiguration(".commandLimit must be at least 1, got \(commandLimit).")
            } else {
                invalidConfiguration = nil
            }
        }
    }

    /// Builds the run's report: validates settings, routes on the execution model, and runs the matching adapter. Records no issues — the dispatch reports the returned report's termination and clusters exactly once.
    private static func stateMachineTimeReport<Spec: StateMachineSpec>(
        _ specType: Spec.Type,
        time: TimeBudget,
        settings: [FuzzSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async -> FuzzReport {
        let consumed = ConsumedSpecSettings(settings)
        if let invalid = consumed.invalidConfiguration {
            return .empty(termination: invalid, seed: 0)
        }
        let commandLimit = consumed.commandLimit
        let coreSettings = consumed.coreSettings

        switch Spec.executionModel {
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
            case .threads:
                // Ruled permanently out of scope (2026-07-12), not deferred: coverage novelty requires every attempt to be a deterministic function of its choice sequence, and preemptive race detection requires the opposite — the OS realizing different schedules for the same input. One degree of freedom cannot be both pinned and free.
                return .empty(
                    termination: .invalidConfiguration("#execute(time:) does not support .threads specs. Coverage-guided search needs each attempt to be a deterministic function of its command sequence; .threads race detection needs the OS free to realize different schedules for the same sequence. The two are incompatible, so run this spec under plain #execute."),
                    seed: 0
                )
        }
    }

    /// Dispatches an asynchronous spec to the coverage-guided runner based on its execution model. Runtime target of `#execute(AsyncSpec.self, time:)`.
    ///
    /// The same shape as ``__runStateMachineTimeDispatch(_:time:settings:fileID:filePath:line:column:)``: the run occupies a GCD worker for the whole budget, and reporting happens here on the test task after the hop.
    @discardableResult
    static func __runStateMachineTimeDispatchAsync(
        _ specType: (some AsyncStateMachineSpec).Type,
        time: TimeBudget,
        settings: [FuzzSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> FuzzReport {
        let report = await asyncStateMachineTimeReport(
            specType,
            time: time,
            settings: settings,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        reportFuzzIssues(
            report: report,
            suppressIssueReporting: ParsedFuzzSettings(settings).suppressIssueReporting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        recordFuzzAttachments(report: report, suppressAttachments: ParsedFuzzSettings(settings).suppressAttachments)
        return report
    }

    /// The async twin of ``stateMachineTimeReport(_:time:settings:fileID:filePath:line:column:)``: validates settings, routes on the execution model, and runs the matching adapter.
    private static func asyncStateMachineTimeReport<Spec: AsyncStateMachineSpec>(
        _ specType: Spec.Type,
        time: TimeBudget,
        settings: [FuzzSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async -> FuzzReport {
        let consumed = ConsumedSpecSettings(settings)
        if let invalid = consumed.invalidConfiguration {
            return .empty(termination: invalid, seed: 0)
        }
        let commandLimit = consumed.commandLimit

        switch Spec.executionModel {
            case .sequential:
                return await runSpecFuzz(
                    makeAdapter: { buildAsyncSequentialSpecAdapter(specType, commandLimit: commandLimit) },
                    time: time,
                    settings: consumed.coreSettings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            case .tasks:
                guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
                    return .empty(
                        termination: .invalidConfiguration("#execute(time:) with a .tasks spec requires macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, or visionOS 2+."),
                        seed: 0
                    )
                }
                var concurrencyLevel = consumed.parallelize?.rawValue ?? 2
                if Spec.self is any Actor.Type, concurrencyLevel > 1 {
                    if consumed.parallelize != nil {
                        reportWarning(
                            "Actor isolation serializes all command dispatch. .parallelize(lanes: \(concurrencyLevel)) will be ignored.",
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column
                        )
                    }
                    concurrencyLevel = 1
                }
                let resolvedConcurrencyLevel = concurrencyLevel
                return await runSpecFuzz(
                    makeAdapter: {
                        buildTasksSpecAdapter(
                            specType,
                            commandLimit: commandLimit,
                            concurrencyLevel: resolvedConcurrencyLevel
                        )
                    },
                    time: time,
                    settings: consumed.coreSettings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            case .threads:
                // Ruled permanently out of scope (2026-07-12), not deferred: coverage novelty requires every attempt to be a deterministic function of its choice sequence, and preemptive race detection requires the opposite — the OS realizing different schedules for the same input. One degree of freedom cannot be both pinned and free.
                return .empty(
                    termination: .invalidConfiguration("#execute(time:) does not support .threads specs. Coverage-guided search needs each attempt to be a deterministic function of its command sequence; .threads race detection needs the OS free to realize different schedules for the same sequence. The two are incompatible, so run this spec under plain #execute."),
                    seed: 0
                )
        }
    }

    /// Runs one spec adapter through `runExploreTimeCore` on a GCD worker with the spec-path configuration: screening skipped (boundary-value catalogues apply to values, not command vocabularies).
    ///
    /// Every execution model routes through here; an arm only has to supply its adapter factory. The factory runs on the worker so the adapter's generator and closures never cross a concurrency boundary. A nil adapter means the spec's command generator is not a top-level pick — the one construction the cooperative adapter cannot marker-tag — and terminates the run as a configuration error.
    private static func runSpecFuzz(
        makeAdapter: @escaping () -> SpecFuzzAdapter<some Any>?,
        time: TimeBudget,
        settings: [FuzzSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async -> FuzzReport {
        await dispatchToGCD(reserving: LaneReservation.fuzz) {
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
                },
                hooks: adapter.hooks,
                persistence: prepareFuzzPersistence(
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                ),
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
    ) -> SpecFuzzAdapter<[(ScheduleMarker, Spec.Command)]> {
        let taggedSequenceGen = taggedSequenceGenerator(
            commandGen: Spec.commandGenerator,
            commandLimit: commandLimit ?? FuzzTunables.specDefaultCommandLimit
        )

        // Two views of the one executor loop: the verdict property drives the runner and carries the thrown error as the failure symptom; the Bool probe derived from it serves pruning and reduction, where only pass/fail matters.
        let verdictProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> FuzzVerdict = syncSequentialVerdictProperty(Spec.self)
        let rawProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = syncSequentialProperty(Spec.self)

        let syncSkipIdentifier = Spec.skipIdentifier
        let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { tagged in
            syncSkipIdentifier(tagged.map(\.1))
        }

        let pruneHook: @Sendable ([(ScheduleMarker, Spec.Command)], ChoiceTree) -> (value: [(ScheduleMarker, Spec.Command)], tree: ChoiceTree) = { value, tree in
            // seed 0 is safe here: skip pruning is pure element deletion into a fully populated tree, so the guided fallback tree is authoritative and the seed fills no gaps.
            pruneSkippedCommands(
                value: value,
                tree: tree,
                generator: taggedSequenceGen,
                seed: 0,
                property: rawProperty,
                identifySkips: identifySkips,
                requireFailurePreserved: false,
                logEvent: "spec_time_prune"
            )
        }

        // The value path's reduction with the spec deadline: a spec reduction probe replays a whole command sequence against a fresh SUT, so it gets more wall clock per candidate.
        let reduceStrategy = FuzzRunner.propertyOnlyReduceStrategy(
            gen: taggedSequenceGen,
            property: verdictProperty,
            reducerConfiguration: Interpreters.ReducerConfiguration(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: FuzzTunables.specReductionDeadlineNanoseconds
            )
        )

        return SpecFuzzAdapter(
            generator: taggedSequenceGen,
            property: verdictProperty,
            hooks: FuzzHooks(prune: pruneHook, reduceStrategy: reduceStrategy)
        )
    }

    /// Builds the generator, property, and seam hooks for an async `.sequential` spec under `time:` mode.
    ///
    /// The async twin of ``buildSequentialSpecAdapter(_:commandLimit:)``: the same tagged sequence shape, skip pruning, and property-only reduction, with the executor loop bridged through `_blockingAwaitSemaphore`. The blocking bridge is safe here because the fuzz loop owns a GCD lane — the cooperative pool runs the awaited commands while the lane waits.
    static func buildAsyncSequentialSpecAdapter<Spec: AsyncStateMachineSpec>(
        _: Spec.Type,
        commandLimit: Int? = nil
    ) -> SpecFuzzAdapter<[(ScheduleMarker, Spec.Command)]> {
        let taggedSequenceGen = taggedSequenceGenerator(
            commandGen: Spec.commandGenerator,
            commandLimit: commandLimit ?? FuzzTunables.specDefaultCommandLimit
        )

        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }

        // Two views of the one executor loop, exactly as the sync adapter: the verdict property carries the thrown error as the failure symptom; the Bool probe derived from it serves pruning and reduction.
        let verdictProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> FuzzVerdict = asyncSequentialVerdictProperty(specInit: specInit)
        let rawProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = asyncSequentialProperty(specInit: specInit)

        let asyncSkipIdentifier = Spec.skipIdentifier(specInit: specInit)
        let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { tagged in
            asyncSkipIdentifier(tagged.map(\.1))
        }

        let pruneHook: @Sendable ([(ScheduleMarker, Spec.Command)], ChoiceTree) -> (value: [(ScheduleMarker, Spec.Command)], tree: ChoiceTree) = { value, tree in
            // seed 0 is safe here: skip pruning is pure element deletion into a fully populated tree, so the guided fallback tree is authoritative and the seed fills no gaps.
            pruneSkippedCommands(
                value: value,
                tree: tree,
                generator: taggedSequenceGen,
                seed: 0,
                property: rawProperty,
                identifySkips: identifySkips,
                requireFailurePreserved: false,
                logEvent: "spec_time_prune"
            )
        }

        let reduceStrategy = FuzzRunner.propertyOnlyReduceStrategy(
            gen: taggedSequenceGen,
            property: verdictProperty,
            reducerConfiguration: Interpreters.ReducerConfiguration(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: FuzzTunables.specReductionDeadlineNanoseconds
            )
        )

        return SpecFuzzAdapter(
            generator: taggedSequenceGen,
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
    /// A timed-out drain is inconclusive, not a counterexample: it counts as a pass during search (matching plain `#execute`), and aborts reduction so a shrinking counterexample never reduces toward a hang.
    ///
    /// - Returns: Nil when the spec's command generator is not a top-level pick, which schedule-marker tagging requires.
    /// - Parameter idleTimeoutMilliseconds: The drain loop's stall bound. Defaults to the plain-`#execute` default; tests lower it so stall-path assertions do not wait out two seconds per evaluation.
    static func buildTasksSpecAdapter<Spec: AsyncStateMachineSpec>(
        _: Spec.Type,
        commandLimit: Int? = nil,
        concurrencyLevel: Int,
        idleTimeoutMilliseconds: Int = ResolvedConcurrentConfig.defaultIdleTimeout
    ) -> SpecFuzzAdapter<[(ScheduleMarker, Spec.Command)]>? {
        guard let taggedCommandGen = zipScheduleMarker(
            onto: Spec.commandGenerator.gen,
            concurrencyLevel: concurrencyLevel
        ) else {
            return nil
        }
        let resolvedCommandLimit = commandLimit ?? FuzzTunables.specDefaultCommandLimit
        let sequenceGen = Gen.arrayOf(
            taggedCommandGen,
            within: 1 ... UInt64(resolvedCommandLimit),
            scaling: .constant
        )

        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }

        let verdictProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> FuzzVerdict = { tagged in
            let result = drainSchedule(
                taggedCommands: tagged,
                specInit: specInit,
                concurrencyLevel: concurrencyLevel,
                recordTrace: false,
                idleTimeoutMilliseconds: idleTimeoutMilliseconds
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
        let rawProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { tagged in
            verdictProperty(tagged).isFailure == false
        }

        let rawIdentifySkips = Spec.skipIdentifier(specInit: specInit)
        let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { tagged in
            rawIdentifySkips(tagged.map(\.1))
        }

        let pruneHook: @Sendable ([(ScheduleMarker, Spec.Command)], ChoiceTree) -> (value: [(ScheduleMarker, Spec.Command)], tree: ChoiceTree) = { value, tree in
            // seed 0 is safe here: skip pruning is pure element deletion into a fully populated tree, so the guided fallback tree is authoritative and the seed fills no gaps.
            pruneSkippedCommands(
                value: value,
                tree: tree,
                generator: sequenceGen,
                seed: 0,
                property: rawProperty,
                identifySkips: identifySkips,
                requireFailurePreserved: false,
                logEvent: "spec_time_prune"
            )
        }

        // Two-pass reduction (lane collapse + deletion, then value minimization), run inline on the fuzz loop's GCD lane. The drain loop's spin-polling stays off the cooperative pool because the loop's lane hosts it, which is what inline reduction guarantees by construction.
        let reduceStrategy: @Sendable (ChoiceTree, [(ScheduleMarker, Spec.Command)], FailureSymptom) -> (sequence: ChoiceSequence, tree: ChoiceTree, value: [(ScheduleMarker, Spec.Command)]) = { tree, value, _ in
            let probeProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> StateMachineProbeVerdict<Void> = { tagged in
                let result = drainSchedule(
                    taggedCommands: tagged,
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
                generator: sequenceGen,
                tree: tree,
                output: value,
                deadlineNanoseconds: FuzzTunables.specReductionDeadlineNanoseconds,
                property: probeProperty
            )
            return (result.sequence, result.tree, result.value)
        }

        return SpecFuzzAdapter(
            generator: sequenceGen,
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
