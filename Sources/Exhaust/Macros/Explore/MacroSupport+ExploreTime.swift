// Explore time: mode — coverage-guided fuzzing runtime entry points.

import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

#if canImport(XCTest) && canImport(ObjectiveC)
    @preconcurrency @_weakLinked import XCTest
#elseif canImport(XCTest)
    @preconcurrency import XCTest
#endif

#if canImport(Testing)
    #if canImport(ObjectiveC)
        @_weakLinked import Testing
    #else
        import Testing // swiftlint:disable:this duplicate_imports
    #endif
#endif

public extension __ExhaustRuntime {
    // MARK: - Entry-Point Driver

    /// Runs one value entry point's full pipeline in the one order the reporting channel tolerates: persistence preparation and resume findings, the run core, diagnostic replay, issue reporting, and attachment recording.
    ///
    /// Everything except the core must run on the test task: issue recording and attachment association resolve the current test from task-locals, and a report recorded anywhere else can silently misroute. The four public entry points are closure literals over this driver, so the ordering constraint is stated once instead of hand-copied per variant — a copy once put `reportFuzzIssues` inside the async GCD closure, and a failing run stopped failing its test.
    private static func runFuzzValueEntryPoint(
        settings: [PropertyFuzzSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        runCore: (FuzzPersistenceContext) -> FuzzReport,
        replay: ((inout FuzzReport, _ suppressIssueReporting: Bool) -> Void)? = nil
    ) -> FuzzReport {
        let persistence = prepareFuzzPersistence(fileID: fileID, filePath: filePath, line: line, column: column)
        var report = runCore(persistence)
        let parsedSettings = ParsedPropertyFuzzSettings(settings)
        replay?(&report, parsedSettings.suppress.issueReporting)
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

    /// The async twin of ``runFuzzValueEntryPoint(settings:fileID:filePath:line:column:runCore:replay:)``: identical order, with only the core hopping to the fuzz lane.
    ///
    /// Persistence prepares before the hop because ``reportFuzzResumeFindings(context:fileID:filePath:line:column:)`` records the predecessor's trap — the one finding designed to be impossible to lose — and context construction performs no writes, so nothing about it needs the fuzz lane.
    private static func runFuzzValueEntryPointAsync(
        settings: [PropertyFuzzSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        runCore: @escaping (FuzzPersistenceContext) -> FuzzReport,
        replay: ((inout FuzzReport, _ suppressIssueReporting: Bool) async -> Void)? = nil
    ) async -> FuzzReport {
        let persistence = prepareFuzzPersistence(fileID: fileID, filePath: filePath, line: line, column: column)
        var report = await dispatchToGCD(reserving: LaneReservation.fuzz) { _ in
            runCore(persistence)
        }
        let parsedSettings = ParsedPropertyFuzzSettings(settings)
        await replay?(&report, parsedSettings.suppress.issueReporting)
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

    /// The fallback for the unreachable case where a known-issue scope returns without assigning the pipeline report: loud on debug builds, and honest in release — a distinct internal-error termination rather than a plausible-looking report with a fabricated termination and seed.
    private static func missingPipelineReport() -> FuzzReport {
        assertionFailure("the known-issue scope returned without assigning the pipeline report")
        return .empty(
            termination: .invalidConfiguration("Internal error: the fuzz pipeline returned no report."),
            seed: 0
        )
    }

    // MARK: - Public Entry Points

    // The macro expansions call these. Each forwards to its package twin with the production coverage source; the twins exist so a test can choose the source per call instead of altering process-wide state.

    /// Runs a coverage-guided `time:` fuzz run with a Bool-returning property. Runtime target of `#explore(time:)`.
    @discardableResult
    static func __exploreTime<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: TimeSpan,
        settings: [PropertyFuzzSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) throws -> Bool
    ) -> FuzzReport {
        __exploreTime(refGen, time: time, settings: settings, coverage: .production, fileID: fileID, filePath: filePath, line: line, column: column, property: property)
    }

    /// Refuses a `Void`-returning function reference, so the call site gets a sentence rather than a type mismatch.
    ///
    /// A trailing closure that returns `Void` is supported: the macro reads its body, checks that it has some way to fail, and routes it to the `#expect`-aware runtime. A bare function reference is a name, and the macro cannot see through it to do either. Overload resolution picks this declaration for such a call, and its unavailability is the diagnostic.
    @available(*, unavailable, message: "Pass a closure rather than a function reference when the property returns Void. #explore needs to see the body to route Void properties to the #expect-aware runtime, and a bare name does not expose one. Wrap it: { try myProperty($0) }.")
    @discardableResult
    static func __exploreTime<Output>(
        _: ReflectiveGenerator<Output>,
        time _: TimeSpan,
        settings _: [PropertyFuzzSettings],
        fileID _: StaticString = #fileID,
        filePath _: StaticString = #filePath,
        line _: UInt = #line,
        column _: UInt = #column,
        property _: @escaping @Sendable (Output) throws -> Void
    ) -> FuzzReport {
        fatalError("unavailable")
    }

    /// Runs a coverage-guided `time:` fuzz run with a Void/#expect/#require closure. Runtime target of `#explore(time:)`.
    @discardableResult
    static func __exploreTimeExpect<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: TimeSpan,
        settings: [PropertyFuzzSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) throws -> Void,
        detection: @escaping @Sendable (Output) throws -> Void
    ) -> FuzzReport {
        __exploreTimeExpect(refGen, time: time, settings: settings, coverage: .production, fileID: fileID, filePath: filePath, line: line, column: column, property: property, detection: detection)
    }

    /// Runs a coverage-guided `time:` fuzz run with an async Bool-returning property. Runtime target of `#explore(time:)`.
    @discardableResult
    static func __exploreTimeAsync<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: TimeSpan,
        settings: [PropertyFuzzSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) async throws -> Bool
    ) async -> FuzzReport {
        await __exploreTimeAsync(refGen, time: time, settings: settings, coverage: .production, fileID: fileID, filePath: filePath, line: line, column: column, property: property)
    }

    /// Runs a coverage-guided `time:` fuzz run with an async Void/#expect/#require closure. Runtime target of `#explore(time:)`.
    @discardableResult
    static func __exploreTimeExpectAsync<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: TimeSpan,
        settings: [PropertyFuzzSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) async throws -> Void,
        detection: @escaping @Sendable (Output) async throws -> Void
    ) async -> FuzzReport {
        await __exploreTimeExpectAsync(refGen, time: time, settings: settings, coverage: .production, fileID: fileID, filePath: filePath, line: line, column: column, property: property, detection: detection)
    }

    // MARK: - Explore Time (Bool)

    /// Runs a coverage-guided `time:` fuzz run with a Bool-returning property. Runtime target of `#explore(time:)`.
    @discardableResult
    package static func __exploreTime<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: TimeSpan,
        settings: [PropertyFuzzSettings],
        coverage: CoverageSourceSelection,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) throws -> Bool
    ) -> FuzzReport {
        runFuzzValueEntryPoint(
            settings: settings,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            runCore: { persistence in
                runExploreTimeCore(
                    gen: refGen.gen,
                    generatorIsReflective: refGen.isReflective,
                    time: time,
                    settings: settings,
                    source: coverage,
                    configure: nil,
                    persistence: persistence,
                    property: wrapVerdictProperty(property)
                )
            }
        )
    }

    // MARK: - Explore Time (Expect)

    /// Runs a coverage-guided `time:` fuzz run with a Void/#expect/#require closure.
    ///
    /// The detection closure (the property with `#expect` rewritten to `#require`) records an issue on every failing attempt, and a fuzz run deliberately keeps failing past the first failure, so the whole run executes inside ``withAbsorbedIssues(into:isIntermittent:framework:_:)``. The fault inventory is reported afterwards, outside that scope, so it surfaces as a real failure.
    @discardableResult
    package static func __exploreTimeExpect<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: TimeSpan,
        settings: [PropertyFuzzSettings],
        coverage: CoverageSourceSelection,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) throws -> Void,
        detection: @escaping @Sendable (Output) throws -> Void
    ) -> FuzzReport {
        let verdictProperty = wrapVerdictDetection(detection)
        return runFuzzValueEntryPoint(
            settings: settings,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            runCore: { persistence in
                nonisolated(unsafe) var pipelineReport: FuzzReport?
                // No ledger: a fuzz run reports its failures from the fault inventory afterwards, so it acts on nothing the scope absorbs.
                withAbsorbedIssues {
                    pipelineReport = runExploreTimeCore(
                        gen: refGen.gen,
                        generatorIsReflective: refGen.isReflective,
                        time: time,
                        settings: settings,
                        source: coverage,
                        configure: nil,
                        persistence: persistence,
                        property: verdictProperty
                    )
                }
                return pipelineReport ?? missingPipelineReport()
            },
            replay: { report, suppressIssueReporting in
                replayFuzzDiagnostics(
                    report: &report,
                    gen: refGen.gen,
                    suppressIssueReporting: suppressIssueReporting,
                    property: property
                )
            }
        )
    }

    // MARK: - Explore Time (Async)

    /// Runs a coverage-guided `time:` fuzz run with an async Bool-returning property.
    @discardableResult
    package static func __exploreTimeAsync<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: TimeSpan,
        settings: [PropertyFuzzSettings],
        coverage: CoverageSourceSelection,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) async throws -> Bool
    ) async -> FuzzReport {
        let verdictProperty = bridgeAsyncVerdictProperty(property)
        return await runFuzzValueEntryPointAsync(
            settings: settings,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            runCore: { persistence in
                runExploreTimeCore(
                    gen: refGen.gen,
                    generatorIsReflective: refGen.isReflective,
                    time: time,
                    settings: settings,
                    source: coverage,
                    configure: nil,
                    persistence: persistence,
                    property: verdictProperty
                )
            }
        )
    }

    // MARK: - Explore Time (Async Expect)

    /// Runs a coverage-guided `time:` fuzz run with an async Void/#expect/#require closure.
    @discardableResult
    package static func __exploreTimeExpectAsync<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: TimeSpan,
        settings: [PropertyFuzzSettings],
        coverage: CoverageSourceSelection,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) async throws -> Void,
        detection: @escaping @Sendable (Output) async throws -> Void
    ) async -> FuzzReport {
        let verdictProperty = bridgeAsyncVerdictDetection(detection)
        return await runFuzzValueEntryPointAsync(
            settings: settings,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            runCore: { persistence in
                nonisolated(unsafe) var pipelineReport: FuzzReport?
                // The framework is named rather than resolved: this runs on a GCD thread, where Test.current is nil and resolution reports XCTest for a Swift Testing run. The async path is always in a Swift Testing context.
                #if canImport(Testing)
                    withAbsorbedIssues(framework: .swiftTesting) {
                        pipelineReport = runExploreTimeCore(
                            gen: refGen.gen,
                            generatorIsReflective: refGen.isReflective,
                            time: time,
                            settings: settings,
                            source: coverage,
                            configure: nil,
                            persistence: persistence,
                            property: verdictProperty
                        )
                    }
                #else
                    pipelineReport = runExploreTimeCore(
                        gen: refGen.gen,
                        generatorIsReflective: refGen.isReflective,
                        time: time,
                        settings: settings,
                        source: coverage,
                        configure: nil,
                        persistence: persistence,
                        property: verdictProperty
                    )
                #endif
                return pipelineReport ?? missingPipelineReport()
            },
            replay: { report, suppressIssueReporting in
                await replayFuzzDiagnosticsAsync(
                    report: &report,
                    gen: refGen.gen,
                    suppressIssueReporting: suppressIssueReporting,
                    property: property
                )
            }
        )
    }

    // MARK: - Diagnostic Replay

    /// Re-materializes each reduced fault cluster and runs the source-located assertion closure once so Swift Testing or XCTest can report the original expression and reduced value.
    package static func replayFuzzDiagnostics<Output>(
        report: inout FuzzReport,
        gen: Generator<Output>,
        suppressIssueReporting: Bool,
        property: @Sendable (Output) throws -> Void
    ) {
        guard suppressIssueReporting == false else {
            return
        }
        for cluster in report.clusters {
            let result = Materializer.materialize(
                gen,
                context: .init(
                    prefix: cluster.reducedSequence,
                    mode: .exact
                )
            )
            guard case let .success(value, _, _) = result else {
                continue
            }
            report.recordDiagnosticInvocation()
            try? property(value)
        }
    }

    /// Re-materializes each reduced fault cluster and awaits the source-located assertion closure once so async diagnostics carry the original expression and reduced value.
    package static func replayFuzzDiagnosticsAsync<Output>(
        report: inout FuzzReport,
        gen: Generator<Output>,
        suppressIssueReporting: Bool,
        property: @Sendable (Output) async throws -> Void
    ) async {
        guard suppressIssueReporting == false else {
            return
        }
        for cluster in report.clusters {
            let result = Materializer.materialize(
                gen,
                context: .init(
                    prefix: cluster.reducedSequence,
                    mode: .exact
                )
            )
            guard case let .success(value, _, _) = result else {
                continue
            }
            report.recordDiagnosticInvocation()
            try? await property(value)
        }
    }

    // MARK: - Core

    /// Parses settings, verifies instrumentation, and runs the three-phase ``FuzzRunner``. Records no issues — every entry point calls ``reportFuzzIssues(report:suppressIssueReporting:fileID:filePath:line:column:)`` itself so the expect variants can defer reporting until after their known-issue scope closes.
    ///
    /// `source` says where coverage comes from; in-package tests pass `.injected` with a synthetic source or `.none` to exercise the uninstrumented path, and `configure` tightens the runner configuration (attempt limits, phase skips) for deterministic termination.
    package static func runExploreTimeCore<Output>(
        gen: Generator<Output>,
        generatorIsReflective: Bool = true,
        time: TimeSpan,
        settings: [PropertyFuzzSettings],
        source coverage: CoverageSourceSelection,
        configure: ((inout FuzzRunnerConfiguration) -> Void)?,
        hooks: FuzzHooks<Output>? = nil,
        persistence: FuzzPersistenceContext? = nil,
        property: @escaping @Sendable (Output) -> FuzzVerdict
    ) -> FuzzReport {
        let parsed = ParsedPropertyFuzzSettings(settings)
        if let message = parsed.invalidReplayMessage {
            return .empty(termination: .invalidConfiguration(message), seed: 0)
        }
        let seed = parsed.seed ?? UInt64.random(in: UInt64.min ... UInt64.max)
        let suppressLogs = parsed.suppress.logs
        let logLevel = parsed.logLevel

        let budgetNanoseconds = time.nanoseconds
        guard budgetNanoseconds > 0 else {
            return .empty(
                termination: .invalidConfiguration("#explore(time:) requires a positive time budget; got \(time.seconds)s."),
                seed: seed
            )
        }

        let options = FuzzSession.Options(
            budgetNanoseconds: budgetNanoseconds,
            seed: seed,
            stopOnFirstFault: parsed.failFast,
            skipScreening: parsed.skipScreening,
            stopWhenSaturated: parsed.stopWhenSaturated,
            logConfiguration: ExhaustLog.Configuration(
                isEnabled: suppressLogs == false,
                minimumLevel: logLevel,
                format: .keyValue
            )
        )
        let outcome = FuzzSession.run(
            gen: gen,
            generatorIsReflective: generatorIsReflective,
            options: options,
            source: coverage,
            configure: configure,
            hooks: hooks,
            persistence: persistence,
            renderValue: { value in
                var description = ""
                customDump(value, to: &description, maxDepth: 3)
                return description
            },
            property: property
        )
        switch outcome {
            case let .completed(result, resumed):
                var report = FuzzReport(result: result, symbolizeEdges: coverage.isProduction)
                if resumed {
                    report.recordCrashResume()
                }
                return report
            case let .invalidExperiment(error):
                return .empty(termination: .invalidConfiguration(String(describing: error)), seed: seed)
            case let .mixedRecorders(guardEdges, counterEdges):
                return .empty(
                    termination: .invalidConfiguration(
                        mixedRecorderMessage(guardEdges: guardEdges, counterEdges: counterEdges)
                    ),
                    seed: seed
                )
            case .instrumentationMissing:
                return .empty(termination: .instrumentationMissing, seed: seed)
            case .anotherRunInFlight:
                return .empty(
                    termination: .invalidConfiguration(
                        "Another coverage-guided run is already in flight in this process. Both zero the same instrumented counters at the start of every attempt, so neither can attribute coverage to its own inputs. Run the target with `swift test --no-parallel`, or filter the run down to a single fuzz test."
                    ),
                    seed: seed
                )
        }
    }

    // MARK: - Crash Recovery

    /// The shared prologue of every `time:` entry point: builds the call site's crash-recovery context and reports any predecessor crash finding before the run starts.
    package static func prepareFuzzPersistence(
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> FuzzPersistenceContext {
        let persistence = makeFuzzPersistenceContext(fileID: fileID, line: line)
        reportFuzzResumeFindings(
            context: persistence,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        return persistence
    }

    /// Records the crash finding from a resumed run — never silent, never suppressed. The trapping candidate itself usually died before corpus admission, so the report names its mutation parent from the snapshot when one exists.
    package static func reportFuzzResumeFindings(
        context: FuzzPersistenceContext,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        guard context.resumeDocument != nil, let survivor = context.survivor else {
            return
        }
        // The sidecar holds the candidate itself when it fit the slot, so the reader gets the input rather than a number they can do nothing with.
        let candidateText: String
        if let sequence = survivor.candidateSequence {
            candidateText = "candidate \(sequence.shortString)"
        } else {
            candidateText = "candidate 0x\(String(survivor.candidateHash, radix: 16)) (too large to record, or written by an older build)"
        }
        // Which probe was running decides where to look: a reduction or normalization probe drives inputs the search never produced.
        let probeText = switch survivor.kind {
            case .search: "a search attempt"
            case .reduction: "reduction of an earlier failure"
            case .normalization: "normalization of a reduced form"
            case .classification: "post-reduction classification"
            case .recovery: "the re-judgement of a restored input"
        }
        let parentText: String
        if let parentSequence = context.survivorParentSequence() {
            parentText = "a mutation of corpus parent \(parentSequence.shortString) (hash 0x\(String(survivor.parentHash, radix: 16)))"
        } else if survivor.parentHash == 0 {
            parentText = "a fresh sample with no corpus parent"
        } else {
            parentText = "a mutation of a parent not present in the last checkpoint"
        }
        reportError(
            "A previous run of this test terminated abnormally while \(candidateText) was in flight, during \(probeText), \(parentText). A trap in the property is one cause; a kill signal, an out-of-memory kill, or a crash elsewhere in the process leave the same marker. The run resumes for the remaining budget with the crash region quarantined; establish what ended the predecessor before extending the budget.",
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    // MARK: - Issue Reporting

    /// Records the run's issues from the report alone: configuration and instrumentation errors (never suppressed — they signal a malfunction, not the failures a caller may be asserting on), the pointless-run error, and the fault inventory (suppressible for tests asserting on the returned report).
    package static func reportFuzzIssues(
        report: FuzzReport,
        suppressIssueReporting: Bool,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        switch report.termination {
            case .instrumentationMissing:
                reportError(
                    missingInstrumentationMessage,
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
                return
            case .coverageUnreachable:
                // The search was blind, but the property still ran: a failure on the unseen path (the inlined or off-executor code the message itself names) is a real finding and reports below like any other.
                reportError(
                    unreachableCoverageMessage,
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
            case let .invalidConfiguration(message):
                reportError(
                    message,
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
                return
            case let .generationFailed(message):
                reportError(
                    "Generator failed during exploration: \(message)",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
                // The generation error explains why nothing ran; the pointless-run diagnostic below would misdirect the reader toward the time budget.
                if report.attempts.evaluated == 0 {
                    return
                }
            case .uncontainedAsyncWork:
                // The attempts before the escape are real findings and report below; the run stopped because everything after it would have been measured against work that was still running.
                reportError(
                    "An attempt's asynchronous work did not return under cancellation and was abandoned while still running, so the run stopped: the escaped work keeps executing the system under test and keeps recording coverage, and every later attempt would carry some of it in its own signature. Raise .idleTimeout, reduce .parallelize, or find the command that does not return when its task is cancelled.",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
            case .budgetExhausted, .coveragePlateau, .attemptLimitReached, .firstFaultFound:
                break
        }

        if report.attempts.evaluated == 0, report.termination != .uncontainedAsyncWork {
            if report.resumedFromCrash {
                // A resumed run can arrive with its declared budget already consumed by crashed predecessors. The pointless-run error below would misdirect the reader toward the generator and budget, both fine, so the resume gets its own message and the restored inventory still reports.
                reportError(
                    "The declared time budget was already consumed by predecessors that terminated abnormally, so this run evaluated no new candidates. The restored fault inventory is reported as-is; establish what ended the predecessors before extending the budget.",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
            } else {
                reportError(
                    "The property was never invoked, so this test asserts nothing. Check the time budget and generator.",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
                return
            }
        }

        if report.clusters.isEmpty == false, suppressIssueReporting == false {
            reportError(
                renderFuzzSummary(report),
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    // MARK: - Checkpoint Attachments

    /// Records the run's checkpoint attachments: one per discovered cluster plus the final summary.
    ///
    /// Eager and outcome-independent — a passing fuzz run still attaches its summary, because "what did fifteen minutes buy" is the report's job either way. Must run on the test's own task: Swift Testing's attachment association is task-local, and the XCTest activity hop asserts the main actor, so the async entries call this after `dispatchToGCD` returns, never inside it.
    package static func recordFuzzAttachments(report: FuzzReport, suppressAttachments: Bool) {
        guard suppressAttachments == false, report.attempts.total > 0 else {
            return
        }
        for cluster in report.clusters {
            recordAttachment(
                renderClusterBlock(cluster, isFrontier: false, detail: .full).joined(separator: "\n"),
                named: "explore-time-cluster-\(cluster.id + 1).txt"
            )
        }
        recordAttachment(renderFuzzAttachmentSummary(report), named: "explore-time-summary.txt")
    }

    /// Records one plain-text attachment through the current test context. Kept on a passing run, because the default XCTest lifetime silently drops attachments from passing runs and a passing fuzz run's report is still the product.
    private static func recordAttachment(_ text: String, named name: String) {
        recordTestAttachment(text, named: name, uniformTypeIdentifier: "public.plain-text", keepsOnPassingRun: true)
    }

    // MARK: - Property Wrapping

    /// Wraps a Bool-returning property into a ``FuzzVerdict`` evaluation: `false` and thrown errors become symptomed failures, skip errors discard, and on Apple platforms an NSException is caught in-process and treated as an ordinary failure.
    package static func wrapVerdictProperty<Output>(
        _ property: @escaping @Sendable (Output) throws -> Bool
    ) -> @Sendable (Output) -> FuzzVerdict {
        { value in
            var verdict = FuzzVerdict.pass
            var caught: NSException?
            let completed = runCatchingObjCException({
                do {
                    verdict = try property(value) ? .pass : .fail(.returnedFalse)
                } catch {
                    verdict = isSkipError(error) ? .discard : .fail(.thrown(error))
                }
            }, &caught)
            if completed == false {
                verdict = .fail(FailureSymptom(kind: exceptionSymptomKind(of: caught)))
            }
            return verdict
        }
    }

    /// Wraps a throwing Void detection closure (the `#expect`-to-`#require` rewrite of the property) into a ``FuzzVerdict`` evaluation.
    package static func wrapVerdictDetection<Output>(
        _ detection: @escaping @Sendable (Output) throws -> Void
    ) -> @Sendable (Output) -> FuzzVerdict {
        { value in
            var verdict = FuzzVerdict.pass
            var caught: NSException?
            let completed = runCatchingObjCException({
                do {
                    try detection(value)
                } catch {
                    verdict = isSkipError(error) ? .discard : .fail(.thrown(error))
                }
            }, &caught)
            if completed == false {
                verdict = .fail(FailureSymptom(kind: exceptionSymptomKind(of: caught)))
            }
            return verdict
        }
    }

    /// Bridges an async Bool-returning property to the synchronous verdict evaluation the single-threaded loop requires.
    ///
    /// No NSException guard here: the Objective-C `@try` cannot span an `await`, so async properties get the same exception behavior as every other async Exhaust path.
    package static func bridgeAsyncVerdictProperty<Output>(
        _ property: @escaping @Sendable (Output) async throws -> Bool
    ) -> @Sendable (Output) -> FuzzVerdict {
        { value in
            let valueBox = UnsafeSendableBox(value)
            return blockingAwait {
                do {
                    return try await property(valueBox.value) ? .pass : .fail(.returnedFalse)
                } catch {
                    return isSkipError(error) ? FuzzVerdict.discard : .fail(.thrown(error))
                }
            }
        }
    }

    /// Bridges an async Void detection closure to the synchronous verdict evaluation, mirroring ``bridgeAsyncVerdictProperty(_:)``.
    package static func bridgeAsyncVerdictDetection<Output>(
        _ detection: @escaping @Sendable (Output) async throws -> Void
    ) -> @Sendable (Output) -> FuzzVerdict {
        { value in
            let valueBox = UnsafeSendableBox(value)
            return blockingAwait {
                do {
                    try await detection(valueBox.value)
                    return FuzzVerdict.pass
                } catch {
                    return isSkipError(error) ? .discard : .fail(.thrown(error))
                }
            }
        }
    }

    // MARK: - Helpers

    /// The symptom kind for a caught NSException, carrying the exception name on Apple platforms.
    private static func exceptionSymptomKind(of caught: NSException?) -> String {
        #if canImport(ObjectiveC)
            return caught.map { "NSException(\($0.name.rawValue))" } ?? "NSException"
        #else
            _ = caught
            return "NSException"
        #endif
    }
}
