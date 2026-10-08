// The spec adapter and dispatch for coverage-guided spec search: `#explore(Spec.self, mode: .tasks, time:)`.

import ExhaustCore
import Foundation
import IssueReporting

// MARK: - Dispatch

public extension __ExhaustRuntime {
    /// Dispatches a synchronous spec to the coverage-guided runner. Runtime target of `#explore(Spec.self, mode:, time:)`; forwards to the package twin with the production coverage source.
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
        await __runStateMachineTimeDispatch(specType, mode: mode, time: time, settings: settings, coverage: .production, fileID: fileID, filePath: filePath, line: line, column: column)
    }

    /// Dispatches an asynchronous spec to the coverage-guided runner. Runtime target of `#explore(AsyncSpec.self, mode:, time:)`; forwards to the package twin with the production coverage source.
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
        await __runStateMachineTimeDispatchAsync(specType, mode: mode, time: time, settings: settings, coverage: .production, fileID: fileID, filePath: filePath, line: line, column: column)
    }

    /// Dispatches a synchronous spec to the coverage-guided runner based on its execution model. Runtime target of `#explore(Spec.self, mode:, time:)`.
    ///
    /// Async for the same reason plain `#execute` is: the run occupies its thread for the whole time budget, so it hops to a GCD worker instead of starving the cooperative pool. Every path, configuration errors included, funnels through the shared reporting epilogue, so findings, configuration errors, and the summary attachment surface exactly as they do for `#explore(time:)`.
    @discardableResult
    package static func __runStateMachineTimeDispatch(
        _ specType: (some StateMachineSpec).Type,
        mode: SearchableExecutionModel,
        time: TimeSpan,
        settings: [StateMachineFuzzSettings],
        coverage: CoverageSourceSelection,
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
            coverage: coverage,
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
        coverage: CoverageSourceSelection,
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
                    coverage: coverage,
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
    package static func __runStateMachineTimeDispatchAsync(
        _ specType: (some AsyncStateMachineSpec).Type,
        mode: SearchableExecutionModel,
        time: TimeSpan,
        settings: [StateMachineFuzzSettings],
        coverage: CoverageSourceSelection,
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
            coverage: coverage,
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
        coverage: CoverageSourceSelection,
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
                // The bridge to the spec's async commands only keeps them on the lane that bound the coverage context from macOS 15; below that a thread-bound recorder would see none of the run, so say so rather than search blind for the whole budget.
                if #unavailable(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2),
                   case .production = coverage,
                   FuzzInstrumentationCheck.registeredRecorders.isTraceGuardsOnly
                {
                    return .empty(
                        termination: .invalidConfiguration(asyncSequentialNeedsCountersMessage),
                        seed: 0
                    )
                }
                return await runSpecFuzz(
                    makeAdapter: { buildAsyncSequentialSpecAdapter(specType, commandLimit: commandLimit) },
                    time: time,
                    settings: parsed.coreSettings,
                    coverage: coverage,
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
                let telemetry = TasksRunTelemetry()
                let report = await runSpecFuzz(
                    makeAdapter: {
                        buildTasksSpecAdapter(
                            specType,
                            commandLimit: commandLimit,
                            concurrencyLevel: resolvedConcurrencyLevel,
                            telemetry: telemetry
                        )
                    },
                    time: time,
                    settings: parsed.coreSettings,
                    coverage: coverage,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                // An abandoned search passes its probe, so a run that keeps abandoning reports a clean inventory while having judged nothing. The plain runner warns about this and so must this one, through the same helper: a fuzz report full of zeroes means "no faults found", and without the warning there is nothing to distinguish that from "nothing was looked at".
                warnIfSearchesWentUnjudged(
                    abandonedSearches: telemetry.searchAbandonments.value,
                    stalledSearches: telemetry.stalledSearches,
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
        coverage: CoverageSourceSelection,
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
        return await dispatchToGCD(reserving: LaneReservation.fuzz) { _ in
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
                source: coverage,
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
