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

/// Detects the one clean-signal violation the runtime can see without guessing: two coverage-guided runs in flight at once.
///
/// The isolation a `time:` run needs is documented and is the caller's to arrange, because nothing in-process can tell whether another test is executing instrumented code. Two concurrent fuzz runs are different: each one zeroes the process-global counters at the start of every attempt, so they erase each other's measurements, and the runner can count itself. Left undetected the symptom is a search that wanders and a report whose numbers are fiction, with nothing a reader would recognize as wrong.
enum FuzzRunExclusion {
    private static let isRunInFlight = SendableBox(false)

    /// Claims the process's coverage counters for one run. The caller owes a matching ``endRun()`` only when this returns true; a false return means another run holds the claim and nothing was acquired.
    static func tryBeginRun() -> Bool {
        isRunInFlight.withValue { isInFlight in
            guard isInFlight == false else {
                return false
            }
            isInFlight = true
            return true
        }
    }

    /// Releases a finished run's claim. Paired with every ``tryBeginRun()`` that returned true.
    static func endRun() {
        isRunInFlight.value = false
    }
}

/// Chooses the coverage source for a production run from the registries the loader populated before `main`.
package enum FuzzInstrumentationCheck {
    /// The coverage source for this build, or nil when no instrumented image registered a region (the run then fails with the missing-instrumentation diagnostic).
    ///
    /// Both initializers return nil on an empty registry, so presence needs no separate check. A `trace-pc-guard` build gets the isolated source: its edges route through a thread-bound context, so the run neither shares a table with another run nor pays an O(instrumented edges) clear-and-rescan per attempt. A counter build gets the process-global source, which the driver serializes through ``FuzzRunExclusion``. When both recorders are compiled in, the counters win: the only reason to add `inline-8bit-counters` beside `trace-pc-guard` is that the guard context cannot see the property's work, and a build carrying both would otherwise get the `trace-pc-guard` source and the same diagnostic again.
    ///
    /// - Parameter harvestsComparisons: Requests comparison-operand harvesting; the driver passes true only when injection can place the operands.
    package static func productionSource(harvestsComparisons: Bool) -> (any CoverageSource)? {
        SancovCoverageSource(harvestsComparisons: harvestsComparisons)
            ?? TracePCGuardCoverageSource(harvestsComparisons: harvestsComparisons)
    }
}

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
        var report = await dispatchToGCD(reserving: LaneReservation.fuzz) {
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
    /// The detection closure (the property with `#expect` rewritten to `#require`) records an issue on every failing attempt, and a fuzz run deliberately keeps failing past the first failure, so the whole run executes inside `withRoutedExpectedIssue(isIntermittent:_:)`. The fault inventory is reported afterwards, outside that scope, so it surfaces as a real failure.
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
                withRoutedExpectedIssue(isIntermittent: true) {
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
                // withExpectedIssue cannot be used on a GCD thread because Test.current is nil, causing TestContext to misdetect as .xcTest. Use withKnownIssue directly since the async path is always in a Swift Testing context.
                #if canImport(Testing)
                    withKnownIssue(isIntermittent: true) {
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
                prefix: cluster.reducedSequence,
                mode: .exact
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
                prefix: cluster.reducedSequence,
                mode: .exact
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

        var configuration = FuzzRunnerConfiguration(budgetNanoseconds: budgetNanoseconds, seed: seed)
        configuration.stopOnFirstFault = parsed.failFast
        if parsed.skipScreening {
            configuration.skipScreening = true
        }
        #if DEBUG
            // The benchmark arm: read once at run start, debug builds only. A malformed or unknown knob is a hard configuration error — a silently ignored typo would invalidate a benchmark arm.
            if let experimentValue = ProcessInfo.processInfo.environment["EXHAUST_FUZZ_EXPERIMENT"] {
                do {
                    configuration.experiments = try FuzzExperiments.parse(environmentValue: experimentValue)
                } catch {
                    return .empty(termination: .invalidConfiguration(String(describing: error)), seed: seed)
                }
            }
        #endif

        // The whole-value operand reconstructor, derived from the output type's OperandReconstructable conformance and gated on reflectivity: a non-reflective generator means reflection cannot place a reconstructed value. A reflective composite (a struct) has no whole-type conformance, so this is nil there and the field graft handles it instead.
        let reflectionReconstructor = generatorIsReflective
            ? OperandReconstruction.reconstructor(for: Output.self)
            : nil
        // Injection activates on the presence of trace-cmp instrumentation, not a knob: comparand substitution places operands directly into a parent's flat sequence and needs no reflection, so every run can use a harvested operand, and a build without trace-cmp never fills the pool, so the injection arms stay free. There is no init-time way to detect the flag — its presence shows up as a non-empty pool once a comparison fires. The reflective paths (whole-value through the reconstructor, composites through the field graft) additionally require a reflective generator, gated by their own capability flags.

        // A live source always enables comparison-operand harvesting: the drain is a no-op without trace-cmp instrumentation, and comparand substitution can place operands on any generator.
        let resolvedSource: (any CoverageSource)? = switch coverage {
            case .production:
                FuzzInstrumentationCheck.productionSource(harvestsComparisons: true)
            case .none:
                nil
            case let .injected(injected):
                injected
        }
        guard let source = resolvedSource else {
            return .empty(termination: .instrumentationMissing, seed: seed)
        }

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

        let needsExclusiveCounters = source.requiresExclusiveProcess
        if needsExclusiveCounters, FuzzRunExclusion.tryBeginRun() == false {
            return .empty(
                termination: .invalidConfiguration(
                    "Another coverage-guided run is already in flight in this process. Both zero the same instrumented counters at the start of every attempt, so neither can attribute coverage to its own inputs. Run the target with `swift test --no-parallel`, or filter the run down to a single fuzz test."
                ),
                seed: seed
            )
        }
        defer {
            if needsExclusiveCounters {
                FuzzRunExclusion.endRun()
            }
        }

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
                reflectionReconstructor: reflectionReconstructor,
                // The graft only reaches a zip-shaped generator, so gate it on that static shape here — a non-composite generator otherwise materializes a parent every attempt before discovering it.
                graftReflective: generatorIsReflective && Interpreters.isZipShaped(gen),
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
                        "attempts": "\(result.counts.totalAttempts)",
                        "covered_edges": "\(result.coveredEdgeCount)",
                        "seed": "\(result.seed)",
                    ]
                )
            }
            return result
        }
        var report = FuzzReport(result: result, symbolizeEdges: coverage.isProduction)
        if configuration.persistence?.resumeDocument != nil {
            report.recordCrashResume()
        }
        return report
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
    /// The base directory is the system temporary directory, or `EXHAUST_STATE_DIR` when set for CI and for the trap probe, which needs the parent process to know where the crashed child's state landed. `EXHAUST_RESUME=0` opts out of recovery: predecessor state is ignored and overwritten.
    ///
    /// - Note: The store is keyed by file and line only, so two processes fuzzing the same test concurrently stomp each other's checkpoints and can misread each other's breadcrumbs as their own crash. Documented in the crash-recovery article; callers who overlap runs of one test point each process at its own `EXHAUST_STATE_DIR`.
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
                if report.evaluatedSearchCases == 0 {
                    return
                }
            case .budgetExhausted, .coveragePlateau, .attemptLimitReached, .firstFaultFound:
                break
        }

        if report.evaluatedSearchCases == 0 {
            if report.resumedFromCrash {
                // A resumed run can arrive with its declared budget already consumed by crashed predecessors. The pointless-run error below would misdirect the reader toward the generator and budget, both fine, so the resume gets its own message and the restored inventory still reports.
                reportError(
                    "The declared time budget was already consumed by crashed predecessors, so this run evaluated no new candidates. The restored fault inventory is reported as-is; fix the trap before extending the budget.",
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
        guard suppressAttachments == false, report.totalAttempts > 0 else {
            return
        }
        for cluster in report.clusters {
            recordAttachment(
                renderCluster(cluster, isFrontier: false).joined(separator: "\n"),
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
            let completed = exhaust_runCatchingObjCException({
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
            let completed = exhaust_runCatchingObjCException({
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
