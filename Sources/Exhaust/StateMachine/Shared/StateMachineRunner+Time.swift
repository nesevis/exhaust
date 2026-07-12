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
            suppressIssueReporting: sprawlSuppressesIssueReporting(settings),
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        recordSprawlAttachments(report: report)
        return report
    }

    /// Builds the run's report: validates settings, routes on the execution model, and runs the sequential adapter on a GCD worker. Records no issues — the dispatch reports the returned report's termination and clusters exactly once.
    private static func stateMachineTimeReport<Spec: StateMachineSpec>(
        _ specType: Spec.Type,
        time: SprawlDuration,
        settings: [SprawlSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async -> SprawlReport {
        var specCommandLimit: Int?
        var filteredSettings: [SprawlSettings] = []
        for setting in settings {
            switch setting {
                case let .commandLimit(limit):
                    guard limit >= 1 else {
                        return .empty(
                            termination: .invalidConfiguration(".commandLimit must be at least 1, got \(limit)."),
                            seed: 0
                        )
                    }
                    specCommandLimit = limit
                default:
                    filteredSettings.append(setting)
            }
        }

        switch Spec.executionModel {
            case .sequential:
                let commandLimit = specCommandLimit
                let coreSettings = filteredSettings
                return await dispatchToGCD(reserving: LaneReservation.single) {
                    let adapter = buildSequentialSpecAdapter(specType, commandLimit: commandLimit)
                    return runExploreTimeCore(
                        gen: adapter.generator,
                        time: time,
                        settings: coreSettings,
                        source: nil,
                        configure: { configuration in
                            configuration.skipScreening = true
                            configuration.reductionPoolWidth = 1
                        },
                        prune: adapter.pruneHook,
                        reduceStrategy: adapter.reduceStrategy,
                        persistence: prepareSprawlPersistence(
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column
                        ),
                        property: adapter.property
                    )
                }
            case .tasks:
                return .empty(
                    termination: .invalidConfiguration("#execute(time:) does not support .tasks specs yet. Cooperative interleaving support is planned."),
                    seed: 0
                )
            case .threads:
                return .empty(
                    termination: .invalidConfiguration("#execute(time:) does not support .threads specs yet. Preemptive schedules make coverage feedback and replay non-deterministic; run this spec under plain #execute."),
                    seed: 0
                )
        }
    }
}

// MARK: - Spec Adapter

extension __ExhaustRuntime {
    /// Builds the generator, property, prune hook, and reduce strategy for a sequential spec under `time:` mode.
    ///
    /// The returned adapter is ready for `runExploreTimeCore`: the generator emits tagged command sequences, the property maps outcomes to verdicts, and the two seam closures carry the spec's skip pruning and reduction. The caller supplies the time budget, settings, and configuration overrides.
    static func buildSequentialSpecAdapter<Spec: StateMachineSpec>(
        _: Spec.Type,
        commandLimit: Int? = nil
    ) -> SpecSprawlAdapter<[(ScheduleMarker, Spec.Command)]> {
        let commandGen = Spec.commandGenerator
        // The spec path skips screening, so there is no screening budget to size against. `estimateCommandLimit` is reused here only for its domain-size-aware depth heuristic; 10000 is a fixed proxy budget, not a real screening cost.
        let resolvedCommandLimit = commandLimit ?? estimateCommandLimit(
            commandGen: commandGen.gen,
            screeningBudget: 10000
        )
        let untaggedSequenceGen = commandGen.array(length: 0 ... resolvedCommandLimit, scaling: .constant).gen
        let taggedSequenceGen = untaggedSequenceGen.map { commands in
            commands.map { (ScheduleMarker.prefix, $0) }
        }

        // Two executors over the same loop: the verdict property drives the runner and carries the thrown error as the failure symptom; the Bool property stays the probe for pruning and reduction, where only pass/fail matters.
        let rawProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = syncSequentialProperty(Spec.self)
        let verdictProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> SprawlVerdict = syncSequentialVerdictProperty(Spec.self)

        let syncSkipIdentifier = Spec.skipIdentifier
        let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { tagged in
            syncSkipIdentifier(tagged.map(\.1))
        }

        let pruneHook: @Sendable ([(ScheduleMarker, Spec.Command)], ChoiceTree) -> (value: [(ScheduleMarker, Spec.Command)], tree: ChoiceTree) = { value, tree in
            // seed 0 is safe here: skip pruning is pure element deletion into a fully populated tree, so the guided fallback tree is authoritative and the seed fills no gaps.
            let pruned = pruneSkippedCommands(
                value: value,
                tree: tree,
                generator: taggedSequenceGen,
                seed: 0,
                property: rawProperty,
                identifySkips: identifySkips,
                requireFailurePreserved: false,
                logEvent: "spec_time_prune"
            )
            return (pruned.value, pruned.tree)
        }

        let reducerConfiguration = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            wallClockDeadlineNanoseconds: SprawlTunables.specReductionDeadlineNanoseconds
        )

        let reduceStrategy: @Sendable (ChoiceTree, [(ScheduleMarker, Spec.Command)], FailureSymptom) -> (tree: ChoiceTree, value: [(ScheduleMarker, Spec.Command)]) = { tree, value, _ in
            let boolProperty: ([(ScheduleMarker, Spec.Command)]) -> Bool = { rawProperty($0) }
            let outcome = try? Interpreters.choiceGraphReduce(
                gen: taggedSequenceGen,
                tree: tree,
                output: value,
                config: reducerConfiguration,
                property: boolProperty
            )
            switch outcome {
                case let .reduced(_, reducedTree, reducedValue), let .unreduced(_, reducedTree, reducedValue):
                    return (reducedTree, reducedValue)
                case .failure, nil:
                    return (tree, value)
            }
        }

        return SpecSprawlAdapter(
            generator: taggedSequenceGen,
            property: verdictProperty,
            pruneHook: pruneHook,
            reduceStrategy: reduceStrategy
        )
    }
}

// MARK: - Adapter Type

/// Bundles the generator, property, and seam closures for one spec type under `time:` mode.
struct SpecSprawlAdapter<Output> {
    /// Generates tagged command sequences for the runner.
    let generator: Generator<Output>
    /// Maps a command-sequence outcome to a pass or fail verdict.
    let property: @Sendable (Output) -> SprawlVerdict
    /// Removes precondition-skipped commands from a sequence before corpus admission.
    let pruneHook: @Sendable (Output, ChoiceTree) -> (value: Output, tree: ChoiceTree)
    /// Reduces a failing command sequence through the spec's backend reducer.
    let reduceStrategy: @Sendable (ChoiceTree, Output, FailureSymptom) -> (tree: ChoiceTree, value: Output)
}
