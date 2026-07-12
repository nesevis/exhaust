// Explore time: mode — coverage-guided fuzzing runtime entry points.

import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

#if canImport(ObjectiveC)
    import ExhaustObjCSupport
#endif

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

/// Once-per-process instrumentation presence check for `#explore(time:)`, with a test-only override.
///
/// Counter regions register during image loading, before main, so the first read is already final and caching it is sound. The override exists because the test suite both lacks real instrumentation and registers synthetic regions from other suites running in the same process — a test asserting on either outcome of this check must not depend on suite ordering.
package enum FuzzInstrumentationCheck {
    private static let cachedIsInstrumented: Bool = SancovRuntime.isInstrumented

    /// Test seam: forces the check's outcome. Reset to nil after use.
    package static let overrideForTesting = SendableBox<Bool?>(nil)

    /// Whether the process loaded at least one instrumented image.
    package static var isInstrumented: Bool {
        overrideForTesting.withValue { $0 } ?? cachedIsInstrumented
    }
}

public extension __ExhaustRuntime {
    // MARK: - Explore Time (Bool)

    /// Runs a coverage-guided `time:` fuzz run with a Bool-returning property. Runtime target of `#explore(time:)`.
    @discardableResult
    static func __exploreTime<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: TimeBudget,
        settings: [FuzzSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) throws -> Bool
    ) -> FuzzReport {
        let persistence = prepareFuzzPersistence(fileID: fileID, filePath: filePath, line: line, column: column)
        let report = runExploreTimeCore(
            gen: refGen.gen,
            time: time,
            settings: settings,
            source: nil,
            configure: nil,
            persistence: persistence,
            property: wrapVerdictProperty(property)
        )
        reportFuzzIssues(
            report: report,
            suppressIssueReporting: ParsedFuzzSettings(settings).suppressIssueReporting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        recordFuzzAttachments(report: report)
        return report
    }

    // MARK: - Explore Time (Expect)

    /// Runs a coverage-guided `time:` fuzz run with a Void/#expect/#require closure.
    ///
    /// The detection closure (the property with `#expect` rewritten to `#require`) records an issue on every failing attempt, and a fuzz run deliberately keeps failing past the first failure, so the whole run executes inside `withExpectedIssue(isIntermittent:)`. The fault inventory is reported afterwards, outside that scope, so it surfaces as a real failure.
    @discardableResult
    static func __exploreTimeExpect<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: TimeBudget,
        settings: [FuzzSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) throws -> Void,
        detection: @escaping @Sendable (Output) throws -> Void
    ) -> FuzzReport {
        // The source-located property closure is part of the macro contract but unused until the report can re-materialise reduced counterexamples and replay them for source-anchored issues.
        _ = property
        let verdictProperty = wrapVerdictDetection(detection)
        let persistence = prepareFuzzPersistence(fileID: fileID, filePath: filePath, line: line, column: column)
        nonisolated(unsafe) var pipelineReport: FuzzReport?
        withExpectedIssue(isIntermittent: true) {
            pipelineReport = runExploreTimeCore(
                gen: refGen.gen,
                time: time,
                settings: settings,
                source: nil,
                configure: nil,
                persistence: persistence,
                property: verdictProperty
            )
        }
        let report = pipelineReport ?? .empty(termination: .budgetExhausted, seed: 0)
        reportFuzzIssues(
            report: report,
            suppressIssueReporting: ParsedFuzzSettings(settings).suppressIssueReporting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        recordFuzzAttachments(report: report)
        return report
    }

    // MARK: - Explore Time (Async)

    /// Runs a coverage-guided `time:` fuzz run with an async Bool-returning property.
    @discardableResult
    static func __exploreTimeAsync<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: TimeBudget,
        settings: [FuzzSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) async throws -> Bool
    ) async -> FuzzReport {
        let verdictProperty = bridgeAsyncVerdictProperty(property)
        let report = await dispatchToGCD(reserving: LaneReservation.single) {
            let persistence = prepareFuzzPersistence(fileID: fileID, filePath: filePath, line: line, column: column)
            let report = runExploreTimeCore(
                gen: refGen.gen,
                time: time,
                settings: settings,
                source: nil,
                configure: nil,
                persistence: persistence,
                property: verdictProperty
            )
            reportFuzzIssues(
                report: report,
                suppressIssueReporting: ParsedFuzzSettings(settings).suppressIssueReporting,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return report
        }
        recordFuzzAttachments(report: report)
        return report
    }

    // MARK: - Explore Time (Async Expect)

    /// Runs a coverage-guided `time:` fuzz run with an async Void/#expect/#require closure.
    @discardableResult
    static func __exploreTimeExpectAsync<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: TimeBudget,
        settings: [FuzzSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) async throws -> Void,
        detection: @escaping @Sendable (Output) async throws -> Void
    ) async -> FuzzReport {
        _ = property
        let verdictProperty = bridgeAsyncVerdictDetection(detection)
        let finalReport = await dispatchToGCD(reserving: LaneReservation.single) {
            let persistence = prepareFuzzPersistence(fileID: fileID, filePath: filePath, line: line, column: column)
            nonisolated(unsafe) var pipelineReport: FuzzReport?
            // withExpectedIssue cannot be used on a GCD thread because Test.current is nil, causing TestContext to misdetect as .xcTest. Use withKnownIssue directly since the async path is always in a Swift Testing context.
            #if canImport(Testing)
                withKnownIssue(isIntermittent: true) {
                    pipelineReport = runExploreTimeCore(
                        gen: refGen.gen,
                        time: time,
                        settings: settings,
                        source: nil,
                        configure: nil,
                        persistence: persistence,
                        property: verdictProperty
                    )
                }
            #else
                pipelineReport = runExploreTimeCore(
                    gen: refGen.gen,
                    time: time,
                    settings: settings,
                    source: nil,
                    configure: nil,
                    persistence: persistence,
                    property: verdictProperty
                )
            #endif
            let report = pipelineReport ?? .empty(termination: .budgetExhausted, seed: 0)
            reportFuzzIssues(
                report: report,
                suppressIssueReporting: ParsedFuzzSettings(settings).suppressIssueReporting,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return report
        }
        recordFuzzAttachments(report: finalReport)
        return finalReport
    }

    // MARK: - Core

    /// Parses settings, verifies instrumentation, and runs the three-phase ``FuzzRunner``. Records no issues — every entry point calls ``reportFuzzIssues(report:suppressIssueReporting:fileID:filePath:line:column:)`` itself so the expect variants can defer reporting until after their known-issue scope closes.
    ///
    /// The `source` and `configure` parameters are test seams: in-package tests inject a synthetic coverage source (skipping the instrumentation check) and tighten the runner configuration (attempt limits, phase skips) for deterministic termination.
    package static func runExploreTimeCore<Output>(
        gen: Generator<Output>,
        time: TimeBudget,
        settings: [FuzzSettings],
        source injectedSource: (any CoverageSource)?,
        configure: ((inout FuzzRunnerConfiguration) -> Void)?,
        hooks: FuzzHooks<Output>? = nil,
        persistence: FuzzPersistenceContext? = nil,
        property: @escaping @Sendable (Output) -> FuzzVerdict
    ) -> FuzzReport {
        let parsed = ParsedFuzzSettings(settings)
        if let message = parsed.invalidReplayMessage {
            return .empty(termination: .invalidConfiguration(message), seed: 0)
        }
        if parsed.commandLimit != nil {
            return .empty(
                termination: .invalidConfiguration(".commandLimit is only valid for #execute(time:). #explore(time:) has no command-sequence structure to limit."),
                seed: 0
            )
        }
        let seed = parsed.seed ?? UInt64.random(in: UInt64.min ... UInt64.max)
        let suppressLogs = parsed.suppressLogs
        let logLevel = parsed.logLevel

        let budgetNanoseconds = time.nanoseconds
        guard budgetNanoseconds > 0 else {
            return .empty(
                termination: .invalidConfiguration("#explore(time:) requires a positive time budget; got \(time.seconds)s."),
                seed: seed
            )
        }

        let source: any CoverageSource
        if let injectedSource {
            source = injectedSource
        } else {
            guard FuzzInstrumentationCheck.isInstrumented, let sancovSource = SancovCoverageSource() else {
                return .empty(termination: .instrumentationMissing, seed: seed)
            }
            source = sancovSource
        }

        var configuration = FuzzRunnerConfiguration(budgetNanoseconds: budgetNanoseconds, seed: seed)
        #if DEBUG
            // The benchmark arm seam: read once at run start, debug builds only. A malformed or unknown knob is a hard configuration error — a silently ignored typo would invalidate a benchmark arm.
            if let experimentValue = ProcessInfo.processInfo.environment["EXHAUST_FUZZ_EXPERIMENT"] {
                do {
                    configuration.experiments = try FuzzExperiments.parse(environmentValue: experimentValue)
                } catch {
                    return .empty(termination: .invalidConfiguration(String(describing: error)), seed: seed)
                }
            }
        #endif
        if let persistence {
            configuration.persistence = persistence
            if let document = persistence.resumeDocument {
                // A resumed run continues the logical run: the remaining slice of the declared budget, straight into the mutation phase — the restored corpus already carries the screening and sampling phases' work.
                let consumed = document.metadata.consumedNanoseconds
                configuration.budgetNanoseconds = budgetNanoseconds > consumed ? budgetNanoseconds - consumed : 0
                configuration.skipScreening = true
                configuration.skipSampling = true
            }
        }
        configure?(&configuration)

        let logConfiguration = ExhaustLog.Configuration(
            isEnabled: suppressLogs == false,
            minimumLevel: logLevel,
            format: .keyValue
        )
        let result = ExhaustLog.withConfiguration(logConfiguration) {
            let runner = FuzzRunner(
                gen: gen,
                property: property,
                source: source,
                configuration: configuration,
                hooks: hooks,
                renderValue: { value in
                    var description = ""
                    customDump(value, to: &description, maxDepth: 3)
                    return description
                }
            )
            let result = runner.run()
            if result.clusters.isEmpty {
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "explore_time_no_failures",
                    metadata: [
                        "attempts": "\(result.totalAttempts)",
                        "covered_edges": "\(result.coveredEdgeCount)",
                        "seed": "\(result.seed)",
                    ]
                )
            }
            return result
        }
        return FuzzReport(result: result, symbolizeEdges: injectedSource == nil)
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

    /// Builds the crash-recovery context for one `#explore(time:)` call site: `<base>/exhaust/<module>/<file>-L<line>/`, which is stable across runs of the same test. Construction is read-only; the runner creates files only once the run actually starts.
    ///
    /// The base directory is the system temporary directory, or `EXHAUST_STATE_DIR` when set — a relocation seam for CI and for the trap probe, which needs the parent process to know where the crashed child's state landed. `EXHAUST_RESUME=0` opts out of recovery: predecessor state is ignored and overwritten.
    package static func makeFuzzPersistenceContext(
        fileID: StaticString,
        line: UInt,
        baseDirectory: URL? = nil
    ) -> FuzzPersistenceContext {
        let base = baseDirectory
            ?? ProcessInfo.processInfo.environment["EXHAUST_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let fileIDText = "\(fileID)"
        let module = fileIDText.split(separator: "/").first.map(String.init) ?? "UnknownModule"
        let file = fileIDText.split(separator: "/").last.map(String.init) ?? "UnknownFile"
        let store = FuzzProgressStore(
            baseDirectory: base,
            module: module,
            testIdentifier: "\(file)-L\(line)"
        )
        let resumeEnabled = ProcessInfo.processInfo.environment["EXHAUST_RESUME"] != "0"
        return FuzzPersistenceContext(store: store, resumeEnabled: resumeEnabled)
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
        let parentText: String
        if let parentSequence = context.survivorParentSequence() {
            parentText = "a mutation of corpus parent \(parentSequence.shortString) (hash 0x\(String(survivor.parentHash, radix: 16)))"
        } else if survivor.parentHash == 0 {
            parentText = "a fresh sample with no corpus parent"
        } else {
            parentText = "a mutation of a parent not present in the last checkpoint"
        }
        reportError(
            "A previous run of this test was killed by a Swift trap while evaluating candidate 0x\(String(survivor.candidateHash, radix: 16)) — \(parentText). The run resumes for the remaining budget with the crash region quarantined; fix the trap before extending the budget.",
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
                if report.totalAttempts == 0 {
                    return
                }
            case .budgetExhausted, .coveragePlateau, .attemptLimitReached:
                break
        }

        if report.totalAttempts == 0 {
            reportError(
                "The property was never invoked, so this test asserts nothing. Check the time budget and generator.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
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
    package static func recordFuzzAttachments(report: FuzzReport) {
        guard report.totalAttempts > 0 else {
            return
        }
        for cluster in report.clusters {
            recordAttachment(
                renderCluster(cluster, isFrontier: false).joined(separator: "\n"),
                named: "explore-time-cluster-\(cluster.id).txt"
            )
        }
        recordAttachment(renderFuzzSummary(report), named: "explore-time-summary.txt")
    }

    /// Records one plain-text attachment through the current test context. The XCTest lifetime is `.keepAlways` — the default `.deleteOnSuccess` silently drops attachments from passing runs, and a passing fuzz run's report is still the product.
    private static func recordAttachment(_ text: String, named name: String) {
        switch TestContext.current {
            #if canImport(Testing)
                case .swiftTesting:
                    Attachment.record(text, named: name)
            #endif
            #if canImport(XCTest) && canImport(ObjectiveC)
                case .xcTest:
                    let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
                    attachment.name = name
                    attachment.lifetime = .keepAlways
                    MainActor.assumeIsolated {
                        XCTContext.runActivity(named: name) { activity in
                            activity.add(attachment)
                        }
                    }
            #endif
            default:
                break
        }
    }

    // MARK: - Property Wrapping

    /// Wraps a Bool-returning property into a ``FuzzVerdict`` evaluation: `false` and thrown errors become symptomed failures, skip errors pass, and on Apple platforms an NSException is caught in-process and treated as an ordinary failure.
    package static func wrapVerdictProperty<Output>(
        _ property: @escaping @Sendable (Output) throws -> Bool
    ) -> @Sendable (Output) -> FuzzVerdict {
        { value in
            var verdict = FuzzVerdict.pass
            var caught: NSException?
            let completed = exhaust_runCatchingObjCException({
                do {
                    verdict = try property(value) ? .pass : .fail(.returnedFalse)
                } catch {
                    verdict = isSkipError(error) ? .pass : .fail(.thrown(error))
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
            let completed = exhaust_runCatchingObjCException({
                do {
                    try detection(value)
                } catch {
                    verdict = isSkipError(error) ? .pass : .fail(.thrown(error))
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
                    return isSkipError(error) ? FuzzVerdict.pass : .fail(.thrown(error))
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
                    return isSkipError(error) ? .pass : .fail(.thrown(error))
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
