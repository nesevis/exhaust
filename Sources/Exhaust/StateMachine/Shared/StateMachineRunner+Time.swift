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
        time: SprawlDuration,
        settings: [SprawlSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> SprawlReport {
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
        reportSprawlIssues(
            report: report,
            suppressIssueReporting: ParsedSprawlSettings(settings).suppressIssueReporting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        recordSprawlAttachments(report: report)
        return report
    }

    /// Builds the run's report: validates settings, routes on the execution model, and runs the matching adapter. Records no issues — the dispatch reports the returned report's termination and clusters exactly once.
    private static func stateMachineTimeReport<Spec: StateMachineSpec>(
        _ specType: Spec.Type,
        time: SprawlDuration,
        settings: [SprawlSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async -> SprawlReport {
        let commandLimit = ParsedSprawlSettings(settings).commandLimit
        if let commandLimit, commandLimit < 1 {
            return .empty(
                termination: .invalidConfiguration(".commandLimit must be at least 1, got \(commandLimit)."),
                seed: 0
            )
        }
        // The core rejects `.commandLimit` because it is meaningless on the value path; this dispatch has consumed it, so it must not travel further.
        let coreSettings = settings.filter { setting in
            if case .commandLimit = setting {
                return false
            }
            return true
        }

        switch Spec.executionModel {
            case .sequential:
                return await runSpecFuzz(
                    makeAdapter: { buildSequentialSpecAdapter(specType, commandLimit: commandLimit) },
                    time: time,
                    settings: coreSettings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            case .tasks:
                return .empty(
                    termination: .invalidConfiguration("#execute(time:) does not support .tasks specs yet. Cooperative interleaving support is planned."),
                    seed: 0
                )
            case .threads:
                // Ruled permanently out of scope (2026-07-12), not deferred: coverage novelty requires every attempt to be a deterministic function of its choice sequence, and preemptive race detection requires the opposite — the OS realizing different schedules for the same input. One degree of freedom cannot be both pinned and free.
                return .empty(
                    termination: .invalidConfiguration("#execute(time:) does not support .threads specs. Coverage-guided search needs each attempt to be a deterministic function of its command sequence; .threads race detection needs the OS free to realize different schedules for the same sequence. The two are incompatible, so run this spec under plain #execute."),
                    seed: 0
                )
        }
    }

    /// Runs one spec adapter through `runExploreTimeCore` on a GCD worker with the spec-path configuration: screening skipped and reductions serialized (each reduction candidate instantiates its own SUT, and stateful subjects are not assumed safe for concurrent instantiation).
    ///
    /// Every execution model routes through here; an arm only has to supply its adapter factory. The factory runs on the worker so the adapter's generator and closures never cross a concurrency boundary.
    private static func runSpecFuzz(
        makeAdapter: @escaping () -> SpecSprawlAdapter<some Any>,
        time: SprawlDuration,
        settings: [SprawlSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async -> SprawlReport {
        await dispatchToGCD(reserving: LaneReservation.single) {
            let adapter = makeAdapter()
            return runExploreTimeCore(
                gen: adapter.generator,
                time: time,
                settings: settings,
                source: nil,
                configure: { configuration in
                    configuration.skipScreening = true
                    configuration.reductionPoolWidth = 1
                },
                hooks: adapter.hooks,
                persistence: prepareSprawlPersistence(
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
    ) -> SpecSprawlAdapter<[(ScheduleMarker, Spec.Command)]> {
        let taggedSequenceGen = taggedSequenceGenerator(
            commandGen: Spec.commandGenerator,
            commandLimit: commandLimit ?? SprawlTunables.specDefaultCommandLimit
        )

        // Two views of the one executor loop: the verdict property drives the runner and carries the thrown error as the failure symptom; the Bool probe derived from it serves pruning and reduction, where only pass/fail matters.
        let verdictProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> SprawlVerdict = syncSequentialVerdictProperty(Spec.self)
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
        let reduceStrategy = SprawlRunner.propertyOnlyReduceStrategy(
            gen: taggedSequenceGen,
            property: verdictProperty,
            reducerConfiguration: Interpreters.ReducerConfiguration(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: SprawlTunables.specReductionDeadlineNanoseconds
            )
        )

        return SpecSprawlAdapter(
            generator: taggedSequenceGen,
            property: verdictProperty,
            hooks: SprawlHooks(prune: pruneHook, reduceStrategy: reduceStrategy)
        )
    }
}

// MARK: - Adapter Type

/// Bundles the generator, property, and seam hooks for one spec type under `time:` mode.
struct SpecSprawlAdapter<Output> {
    /// Generates tagged command sequences for the runner.
    let generator: Generator<Output>
    /// Maps a command-sequence outcome to a pass or fail verdict.
    let property: @Sendable (Output) -> SprawlVerdict
    /// The spec's skip pruning and reduction, carried into ``SprawlRunner`` as one unit.
    let hooks: SprawlHooks<Output>
}
