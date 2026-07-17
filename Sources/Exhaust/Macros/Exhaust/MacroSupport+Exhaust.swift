// Runtime support for macro-expanded code. Not intended for direct use.
//
// The `__` prefix follows Swift Testing's convention (`Testing.__check`, `Testing.__Expression`)
// to signal that this is macro infrastructure, not public API.
import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

#if canImport(XCTest) && canImport(ObjectiveC)
    @preconcurrency @_weakLinked import XCTest
#elseif canImport(XCTest)
    @preconcurrency import XCTest
#endif

#if canImport(Testing) && canImport(ObjectiveC)
    @_weakLinked import Testing
#elseif canImport(Testing)
    import Testing
#endif

public extension __ExhaustRuntime {
    /// Thrown by the detection closure when a rewritten `#expect`/`#require` fails.
    ///
    /// This is a plain error — not a Swift Testing issue — so it produces no test output.
    /// The pipeline's try/catch detects it as a property failure without any console noise.
    struct DetectionFailure: Error {}

    /// Detection replacement for `#expect(_ condition: Bool)` and `#require(_ condition: Bool)`.
    ///
    /// Throws ``DetectionFailure`` when the condition is `false`.
    /// Does not call `Issue.record()` — produces no Swift Testing output.
    static func __detectRequire(_ condition: Bool) throws { // swiftlint:disable:this identifier_name
        if condition == false {
            throw DetectionFailure()
        }
    }

    /// Detection replacement for `#require<T>(_ optionalValue: T?)`.
    ///
    /// Throws ``DetectionFailure`` when the value is `nil`. Returns the unwrapped value otherwise.
    /// Does not call `Issue.record()` — produces no Swift Testing output.
    static func __detectRequire<Value>(_ value: Value?) throws -> Value { // swiftlint:disable:this identifier_name
        guard let unwrapped = value else {
            throw DetectionFailure()
        }
        return unwrapped
    }

    /// Runs a property test with a non-throwing predicate. This is the base case (the throwing variant wraps its closure and delegates here) and the runtime target of the `#exhaust` macro expansion.
    ///
    /// - Parameters:
    ///   - refGen: The generator to produce test values from.
    ///   - settings: An array of `PropertySettings` controlling test behavior.
    ///   - reflecting: A known failing value to reduce directly, or `nil` to run the full screening and sampling pipeline.
    ///   - fileID: The file ID of the call site (injected by macro expansion).
    ///   - filePath: The file path of the call site (injected by macro expansion).
    ///   - line: The line number of the call site (injected by macro expansion).
    ///   - column: The column number of the call site (injected by macro expansion).
    ///   - function: The enclosing function name (injected by macro expansion).
    ///   - property: The property to test. Returns `true` for passing values.
    /// - Returns: The reduced counterexample if the property failed, or `nil` if all iterations passed.
    @discardableResult
    static func __exhaust<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        settings: [PropertySettings],
        reflecting: Output? = nil,

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @Sendable (Output) -> Bool
    ) -> Output? {
        let gen = refGen.gen
        return withoutActuallyEscaping(property) { property in
            #if canImport(Testing)
                let reportDelivery = DeferredReportDelivery(settings: settings)
                if let regression = replayRegressionSeeds(
                    gen: gen,
                    settings: reportDelivery.pipelineSettings,
                    forceIssueReportingSuppression: false,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    function: function,
                    property: property
                ) {
                    reportDelivery.deliver(regression.report)
                    return regression.counterexample
                }
            #endif
            return __exhaustBody(
                gen: gen,
                settings: settings,
                reflecting: reflecting,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column,
                testName: "\(function)",
                property: property
            ).0
        }
    }

    /// Runs a property test with a throwing predicate. Wraps the closure to catch errors (including `XCTSkip`) and delegates to the non-throwing base case.
    @discardableResult
    static func __exhaust<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        settings: [PropertySettings],
        reflecting: Output? = nil,

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @Sendable (Output) throws -> Bool
    ) -> Output? {
        let gen = refGen.gen
        let skipCounter = SkipCounter()
        return withoutActuallyEscaping(property) { property in
            let property: @Sendable (Output) -> Bool = { value in
                do {
                    return try property(value)
                } catch {
                    if isSkipError(error) {
                        skipCounter.increment()
                        return true
                    }
                    return false
                }
            }
            #if canImport(Testing)
                let reportDelivery = DeferredReportDelivery(settings: settings)
                if let regression = replayRegressionSeeds(
                    gen: gen,
                    settings: reportDelivery.pipelineSettings,
                    skipCounter: skipCounter,
                    forceIssueReportingSuppression: false,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    function: function,
                    property: property
                ) {
                    reportDelivery.deliver(regression.report)
                    return regression.counterexample
                }
            #endif
            return __exhaustBody(
                gen: gen,
                settings: settings,
                reflecting: reflecting,
                skipCounter: skipCounter,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column,
                testName: "\(function)",
                property: property
            ).0
        }
    }

    /// Runs a throwing `Bool` property selected through type-directed dispatch.
    ///
    /// The macro uses this overload only when a single `try` expression does not reveal whether its helper returns `Bool` or `Void`.
    @discardableResult
    static func __exhaustDispatched<Output>( // swiftlint:disable:this function_parameter_count
        _ refGen: ReflectiveGenerator<Output>,
        settings: [PropertySettings],
        reflecting: Output? = nil,

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @Sendable (Output) throws -> Bool
    ) -> Output? {
        __exhaust(
            refGen,
            settings: settings,
            reflecting: reflecting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            function: function,
            property: property
        )
    }

    /// Runs a throwing `Void` property through assertion detection when Swift's type checker resolves the property result as `Void`.
    ///
    /// This overload handles single-call properties whose source syntax does not reveal whether the called helper returns `Bool` or `Void`. Exhaust treats a thrown error as a counterexample, then re-runs the property with the reduced value so the error occurs in the original test context.
    ///
    /// - Parameters:
    ///   - refGen: The generator to produce test values from.
    ///   - settings: An array of `PropertySettings` controlling test behavior.
    ///   - reflecting: A known failing value to reduce directly, or `nil` to run the full screening and sampling pipeline.
    ///   - fileID: The file ID of the call site.
    ///   - filePath: The file path of the call site.
    ///   - line: The line number of the call site.
    ///   - column: The column number of the call site.
    ///   - function: The enclosing function name.
    ///   - property: The property to test. Returning normally passes, while throwing a non-skip error fails.
    /// - Returns: The reduced counterexample if the property failed, or `nil` if all iterations passed.
    @discardableResult
    static func __exhaustDispatched<Output>( // swiftlint:disable:this function_parameter_count
        _ refGen: ReflectiveGenerator<Output>,
        settings: [PropertySettings],
        reflecting: Output? = nil,

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @Sendable (Output) throws -> Void
    ) -> Output? {
        __exhaustExpect(
            refGen,
            settings: settings,
            reflecting: reflecting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            function: function,
            property: property,
            detection: property
        )
    }

    // swiftlint:disable:next function_body_length
    package static func __exhaustBody<Output>(
        gen: Generator<Output>,
        settings: [PropertySettings],
        reflecting: Output?,
        skipCounter: SkipCounter? = nil,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        testName: String,
        property: @escaping @Sendable (Output) -> Bool
    ) -> (Output?, String?) {
        var budget = ExhaustBudget.standard
        var seed: UInt64?
        var replayIteration: Int?
        var screeningReplayRow: Int?
        var invalidReplaySeed: ReplaySeed?
        var suppress = SuppressFlags()
        var visualize = false
        var includeDiff = false
        var onReportClosure: ((ExhaustReport) -> Void)?
        var collectOpenPBTStats = false
        var parallelLanes: UInt8 = 0
        var logLevel: LogLevel = .error
        let logFormat: LogFormat = .keyValue

        for setting in settings {
            switch setting {
                case let .budget(b):
                    budget = b
                case let .replay(replaySeed):
                    guard let resolved = replaySeed.resolve() else {
                        invalidReplaySeed = replaySeed
                        continue
                    }
                    switch resolved {
                        case let .sampling(resolvedSeed, iteration):
                            seed = resolvedSeed
                            replayIteration = iteration
                        case let .screening(row):
                            screeningReplayRow = row
                    }
                case let .suppress(option):
                    suppress.apply(option)
                case .visualize:
                    visualize = true
                case let .onReport(closure):
                    if let existing = onReportClosure {
                        let chained = existing
                        onReportClosure = { report in
                            chained(report)
                            closure(report)
                        }
                    } else {
                        onReportClosure = closure
                    }
                case .collectOpenPBTStats:
                    collectOpenPBTStats = true
                case .includeDiff:
                    includeDiff = true
                case let .parallelize(lanes):
                    parallelLanes = UInt8(lanes.rawValue)
                case let .log(level):
                    logLevel = level
            }
        }

        let logConfiguration = suppress.logConfiguration(minimumLevel: logLevel, format: logFormat)
        return ExhaustLog.withConfiguration(logConfiguration) {
            #if canImport(Testing)
                if let traitConfig = ExhaustTraitConfiguration.current {
                    let hasInlineBudget = settings.contains { if case .budget = $0 { true } else { false } }
                    if hasInlineBudget == false, let traitBudget = traitConfig.budget {
                        budget = traitBudget
                    }
                }
            #endif
            budget.preconditionValid()

            if parallelLanes > 1, seed != nil, suppress.issueReporting == false {
                reportWarning(
                    ".parallelize has no effect with .replay: replay runs single-lane for deterministic reproduction.",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }

            let samplingBudget: UInt64 = (replayIteration != nil || screeningReplayRow != nil) ? 1 : UInt64(budget.samplingBudget)
            let screeningBudget: UInt64 = (replayIteration != nil || screeningReplayRow != nil) ? 0 : UInt64(budget.screeningBudget)
            // Deadline scales with the preset, not the phase budgets — replay collapses those to 1/0 but still reduces one counterexample, so it must keep the full reduction deadline.
            // The floor keeps small custom budgets deterministic in practice: without it, a budget of a few runs yields a deadline of tens of milliseconds, which machine load (a parallel test suite, cold caches, debug logging) can cross mid-reduction, truncating to a non-minimal counterexample. Two seconds is orders of magnitude above any healthy reduction at these budgets while still bounding a runaway one.
            let reductionDeadlineNanoseconds = max(
                UInt64(budget.screeningBudget + budget.samplingBudget) * 5 * 1_000_000,
                2_000_000_000
            )
            let reductionConfig = Interpreters.ReducerConfiguration(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: reductionDeadlineNanoseconds
            )

            var report = ExhaustReport()
            defer { onReportClosure?(report) }

            if let invalidReplaySeed {
                reportError(
                    "Invalid replay seed: \(invalidReplaySeed)",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                return (nil, nil)
            }

            let statsAccumulator: OpenPBTStatsAccumulator? = collectOpenPBTStats
                ? OpenPBTStatsAccumulator(propertyName: "\(testName)")
                : nil
            defer {
                if let statsAccumulator {
                    let lines = statsAccumulator.finalize()
                    if lines.isEmpty == false {
                        // Suppression skips only the attachment write below; the lines still reach the report, so `.collectOpenPBTStats` with `.suppress(.attachments)` collects without attaching.
                        report.openPBTStatsLines = lines
                        let attachmentName = "\(testName)-openpbtstats.jsonl"
                        let attachmentContext: TestContext? = suppress.attachments ? nil : TestContext.current
                        switch attachmentContext {
                            #if canImport(Testing)
                                case .swiftTesting:
                                    Attachment.record(lines.jsonlString(), named: attachmentName)
                            #endif
                            #if canImport(ObjectiveC)
                                case .xcTest:
                                    let xctAttachment = XCTAttachment(data: Data(lines.jsonlString().utf8), uniformTypeIdentifier: "public.json")
                                    xctAttachment.name = attachmentName
                                    MainActor.assumeIsolated {
                                        XCTContext.runActivity(named: "OpenPBTStats") { activity in
                                            activity.add(xctAttachment)
                                        }
                                    }
                            #endif
                            default:
                                break
                        }
                    }
                }
            }

            let context = PipelineContext(
                gen: gen,
                property: property,
                samplingBudget: samplingBudget,
                reductionConfig: reductionConfig,
                visualize: visualize,
                suppressIssueReporting: suppress.issueReporting,
                includeDiff: includeDiff,
                parallelLanes: parallelLanes,

                logFormat: logFormat,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column,
                statsAccumulator: statsAccumulator
            )

            if let reflecting {
                do {
                    let result = try __reduceReflected(
                        gen,
                        value: reflecting,
                        reductionConfig: reductionConfig,
                        visualize: visualize,
                        suppressIssueReporting: suppress.issueReporting,
                        includeDiff: includeDiff,

                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                        property: property,
                        report: &report
                    )
                    return (result, nil)
                } catch {
                    reportError(localizedErrorMessage(error), fileID: fileID, filePath: filePath, line: line, column: column)
                    return (reflecting, nil)
                }
            }

            let phaseTimingStart = monotonicNanoseconds()
            if let screeningReplayRow {
                let outcome: ScreeningOutcome<Output> = runScreeningPhase(
                    context: context,
                    screeningBudget: UInt64(budget.screeningBudget),
                    skipToRow: screeningReplayRow,
                    report: &report
                )
                switch outcome {
                    case let .counterexample(value):
                        let screeningEnd = monotonicNanoseconds()
                        report.screeningMilliseconds = Double(screeningEnd - phaseTimingStart) / 1_000_000
                        report.totalMilliseconds = report.screeningMilliseconds
                        return (value, report.replaySeed)
                    case .exhaustivePass, .proceed:
                        let screeningEnd = monotonicNanoseconds()
                        report.screeningMilliseconds = Double(screeningEnd - phaseTimingStart) / 1_000_000
                        report.totalMilliseconds = report.screeningMilliseconds
                        return (nil, nil)
                }
            } else if screeningBudget == 0 {
                ExhaustLog.notice(category: .propertyTest, event: "screening_skipped", "Screening phase skipped")
            } else {
                let outcome: ScreeningOutcome<Output> = runScreeningPhase(
                    context: context,
                    screeningBudget: screeningBudget,
                    report: &report
                )
                switch outcome {
                    case let .counterexample(value):
                        let screeningEnd = monotonicNanoseconds()
                        report.screeningMilliseconds = Double(screeningEnd - phaseTimingStart) / 1_000_000
                        report.totalMilliseconds = report.screeningMilliseconds
                        return (value, report.replaySeed)
                    case .exhaustivePass:
                        let screeningEnd = monotonicNanoseconds()
                        report.screeningMilliseconds = Double(screeningEnd - phaseTimingStart) / 1_000_000
                        report.totalMilliseconds = report.screeningMilliseconds
                        reportSkipsAndPointlessRun(
                            totalPropertyCalls: report.screeningInvocations,
                            skipCounter: skipCounter,
                            suppressIssueReporting: suppress.issueReporting,
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column,
                            report: &report
                        )
                        return (nil, nil)
                    case .proceed:
                        break
                }
            }
            let screeningPhaseEndTime = monotonicNanoseconds()

            let samplingResult = runSamplingPhase(
                context: context,
                seed: seed,
                replayIteration: replayIteration,
                report: &report
            )

            let endTime = monotonicNanoseconds()
            report.screeningMilliseconds = Double(screeningPhaseEndTime - phaseTimingStart) / 1_000_000
            report.totalMilliseconds = Double(endTime - phaseTimingStart) / 1_000_000

            if samplingResult == nil {
                report.generationMilliseconds = Double(endTime - screeningPhaseEndTime) / 1_000_000
                let totalPropertyCalls = report.propertyInvocations
                var passMetadata = [
                    "iterations": "\(samplingBudget)",
                    "property_invocations": "\(totalPropertyCalls)",
                ]
                if report.screeningRows > 0 {
                    passMetadata["screening_rows"] = "\(report.screeningRows)"
                    passMetadata["screening_rejections"] = "\(report.screeningRejectedRows)"
                    passMetadata["screening_invocations"] = "\(report.screeningInvocations)"
                    passMetadata["random_invocations"] = "\(report.randomSamplingInvocations)"
                }
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "property_passed",
                    metadata: passMetadata
                )
                if replayIteration == nil {
                    reportSkipsAndPointlessRun(
                        totalPropertyCalls: totalPropertyCalls,
                        skipCounter: skipCounter,
                        suppressIssueReporting: suppress.issueReporting,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                        report: &report
                    )
                }
            } else {
                report.skippedInvocations = skipCounter?.count ?? 0
            }

            ExhaustLog.notice(
                category: .propertyTest,
                event: "phase_timing",
                metadata: [
                    "screening_ms": String(format: "%.1f", report.screeningMilliseconds),
                    "generation_ms": String(format: "%.1f", report.generationMilliseconds),
                    "reduction_ms": String(format: "%.1f", report.reductionMilliseconds),
                    "total_ms": String(format: "%.1f", report.totalMilliseconds),
                ]
            )

            return (samplingResult, report.replaySeed)
        }
    }

    // MARK: - Lane Accounting

    /// Extracts the `.parallelize` lane count from the settings, for sizing the ``LaneGate`` reservation before the GCD hop.
    private static func parallelLaneCount(in settings: [PropertySettings]) -> Int {
        for setting in settings {
            if case let .parallelize(lanes) = setting {
                return lanes.rawValue
            }
        }
        return 0
    }

    // MARK: - Skip and Pointless-Run Accounting

    /// Records skip accounting for a passing run and fails runs that asserted nothing.
    ///
    /// A passing run that never effectively invoked the property proves nothing, so it reports an error: either the combined budget was zero, or every invocation was skipped. A run that skipped nearly every invocation reports a warning, using the filter-validity thresholds (at least 20 skips, above 98% skipped).
    ///
    /// The pointless-run error is deliberately not gated on `.suppress(.issueReporting)`: it signals a malfunctioning test, not the property failure suppression targets. It stays silent only when a generation error was already reported for the same root cause.
    private static func reportSkipsAndPointlessRun(
        totalPropertyCalls: Int,
        skipCounter: SkipCounter?,
        suppressIssueReporting: Bool,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        report: inout ExhaustReport
    ) {
        let skipped = skipCounter?.count ?? 0
        report.skippedInvocations = skipped

        guard report.generationErrorOccurred == false else { return }

        if totalPropertyCalls == 0 {
            report.pointlessRunFailure = "The property was never invoked: the screening and sampling budgets are both zero, so this test asserts nothing."
        } else if skipped >= totalPropertyCalls {
            report.pointlessRunFailure = "All \(totalPropertyCalls) property invocations were skipped, so this test asserts nothing."
        }
        if let pointlessRunFailure = report.pointlessRunFailure {
            reportError(
                pointlessRunFailure,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return
        }

        if skipped >= 20 {
            let skipRate = Double(skipped) / Double(totalPropertyCalls)
            if skipRate > 0.98 {
                report.skipRateWarning = "Property skip rate \(String(format: "%.1f", skipRate * 100))% over \(totalPropertyCalls) invocations. Most of the budget asserted nothing."
            }
        }
        if suppressIssueReporting == false, let skipRateWarning = report.skipRateWarning {
            reportWarning(
                skipRateWarning,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
    }

    // MARK: - Void Property (Swift Testing #expect / #require)

    /// Runs a property test with a `Void`-returning property that uses `#expect`/`#require` for assertions.
    ///
    /// Wraps the property into a `Bool`-returning form via `withRoutedExpectedIssue`, delegates to the existing pipeline, then re-runs the property one final time without suppression so `#expect` failures record with reduced values.
    @discardableResult
    static func __exhaustExpect<Output>( // swiftlint:disable:this function_parameter_count
        _ refGen: ReflectiveGenerator<Output>,
        settings: [PropertySettings],
        reflecting: Output? = nil,

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @Sendable (Output) throws -> Void,
        detection: @Sendable (Output) throws -> Void
    ) -> Output? {
        let gen = refGen.gen
        let reportDelivery = DeferredReportDelivery(settings: settings)
        var logLevel: LogLevel = .error
        var suppressLogs = false
        for setting in settings {
            switch setting {
                case let .log(level):
                    logLevel = level
                case let .suppress(option):
                    switch option {
                        case .logs, .all:
                            suppressLogs = true
                        default:
                            break
                    }
                default:
                    break
            }
        }

        return ExhaustLog.withConfiguration(.init(isEnabled: suppressLogs == false, minimumLevel: logLevel, format: .keyValue)) {
            withoutActuallyEscaping(detection) { detection in
                let skipCounter = SkipCounter()
                let boolProperty = wrapDetectionProperty(detection, countingSkipsInto: skipCounter)

                // Suppress assertion issues during screening/sampling/reduction.
                // The final re-run (outside this scope) produces the user-facing assertion output.
                let diagnostics = CapturedDiagnostics<Output>()
                withRoutedExpectedIssue(isIntermittent: true) {
                    #if canImport(Testing)
                        if let regression = replayRegressionSeeds(
                            gen: gen,
                            settings: reportDelivery.pipelineSettings,
                            skipCounter: skipCounter,
                            forceIssueReportingSuppression: true,
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column,
                            function: function,
                            property: boolProperty
                        ) {
                            diagnostics.pipelineResult = regression.counterexample
                            diagnostics.replaySeed = regression.replaySeed
                            diagnostics.report = regression.report
                            return
                        }
                    #endif

                    // Capture seed and rendered failure from the Bool pipeline.
                    var augmentedSettings = reportDelivery.pipelineSettings + [.suppress(.issueReporting)]
                    augmentedSettings.append(.onReport { diagnostics.capture(from: $0) })

                    // Delegate to the Bool pipeline with suppressed issue reporting.
                    diagnostics.pipelineResult = __exhaustBody(
                        gen: gen,
                        settings: augmentedSettings,
                        reflecting: reflecting,
                        skipCounter: skipCounter,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                        testName: "\(function)",
                        property: boolProperty
                    ).0
                }

                // When suppress(.issueReporting) is set, the caller is asserting on the return value.
                // Skip the final re-run and replay message.
                let suppressIssueReporting = settings.contains { setting in
                    if case let .suppress(option) = setting, option == .issueReporting || option == .all { return true }
                    return false
                }

                guard let counterexample = diagnostics.pipelineResult else {
                    // The pipeline's own issues fired inside withRoutedExpectedIssue, where they are swallowed as known issues. Re-report them here so a run that asserted nothing fails the test.
                    diagnostics.reportPassDiagnostics(
                        suppressIssueReporting: suppressIssueReporting,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                    reportDelivery.deliver(diagnostics.report)
                    return nil
                }

                if suppressIssueReporting == false {
                    if let rendered = diagnostics.report.renderedFailure {
                        reportError(rendered, fileID: fileID, filePath: filePath, line: line, column: column)
                    }

                    // Re-run without suppression so #expect failures record with reduced values.
                    diagnostics.report.recordDiagnosticInvocation()
                    do {
                        try property(counterexample)
                    } catch {
                        // Error propagates to Swift Testing naturally.
                    }

                    if let replaySeed = diagnostics.replaySeed {
                        print("exhaust:\(function):replay:\(replaySeed)")
                    }
                }

                reportDelivery.deliver(diagnostics.report)

                return counterexample
            }
        } // withConfiguration
    }

    // MARK: - Async Property

    /// Runs a property test with an async `Bool`-returning property closure.
    ///
    /// Bridges the async property to sync, then dispatches the synchronous core onto a GCD thread where semaphore-blocking is safe.
    @discardableResult
    static func __exhaustAsync<Output>( // swiftlint:disable:this function_parameter_count
        _ refGen: ReflectiveGenerator<Output>,
        settings: [PropertySettings],
        reflecting: Output? = nil,

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @escaping @Sendable (Output) async throws -> Bool
    ) async -> Output? {
        let skipCounter = SkipCounter()
        let syncProperty = bridgeAsyncProperty(property, countingSkipsInto: skipCounter)
        #if canImport(Testing)
            let reportDelivery = DeferredReportDelivery(settings: settings)
            let traitConfig = ExhaustTraitConfiguration.current
        #endif
        return await dispatchToGCD(reserving: LaneReservation.property(parallelLanes: parallelLaneCount(in: settings))) {
            let run: () -> Output? = {
                #if canImport(Testing)
                    if let regression = replayRegressionSeeds(
                        gen: refGen.gen,
                        settings: reportDelivery.pipelineSettings,
                        skipCounter: skipCounter,
                        forceIssueReportingSuppression: false,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                        function: function,
                        property: syncProperty
                    ) {
                        reportDelivery.deliver(regression.report)
                        return regression.counterexample
                    }
                #endif
                return __exhaustBody(
                    gen: refGen.gen,
                    settings: settings,
                    reflecting: reflecting,
                    skipCounter: skipCounter,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    testName: "\(function)",
                    property: syncProperty
                ).0
            }
            #if canImport(Testing)
                return ExhaustTraitConfiguration.$current.withValue(traitConfig, operation: run)
            #else
                return run()
            #endif
        }
    }

    /// Runs an asynchronous throwing `Bool` property selected through type-directed dispatch.
    ///
    /// The macro uses this overload only when a single `try` expression does not reveal whether its helper returns `Bool` or `Void`.
    @discardableResult
    static func __exhaustDispatchedAsync<Output>( // swiftlint:disable:this function_parameter_count
        _ refGen: ReflectiveGenerator<Output>,
        settings: [PropertySettings],
        reflecting: Output? = nil,

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @escaping @Sendable (Output) async throws -> Bool
    ) async -> Output? {
        await __exhaustAsync(
            refGen,
            settings: settings,
            reflecting: reflecting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            function: function,
            property: property
        )
    }

    /// Runs an asynchronous throwing `Void` property through assertion detection when Swift's type checker resolves the property result as `Void`.
    ///
    /// This overload handles single-call async properties whose source syntax does not reveal whether the called helper returns `Bool` or `Void`. Exhaust treats a thrown error as a counterexample, then re-runs the property with the reduced value in the original async context.
    ///
    /// - Parameters:
    ///   - refGen: The generator to produce test values from.
    ///   - settings: An array of `PropertySettings` controlling test behavior.
    ///   - reflecting: A known failing value to reduce directly, or `nil` to run the full screening and sampling pipeline.
    ///   - fileID: The file ID of the call site.
    ///   - filePath: The file path of the call site.
    ///   - line: The line number of the call site.
    ///   - column: The column number of the call site.
    ///   - function: The enclosing function name.
    ///   - property: The property to test. Returning normally passes, while throwing a non-skip error fails.
    /// - Returns: The reduced counterexample if the property failed, or `nil` if all iterations passed.
    @discardableResult
    static func __exhaustDispatchedAsync<Output>( // swiftlint:disable:this function_parameter_count
        _ refGen: ReflectiveGenerator<Output>,
        settings: [PropertySettings],
        reflecting: Output? = nil,

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @escaping @Sendable (Output) async throws -> Void
    ) async -> Output? {
        await __exhaustExpectAsync(
            refGen,
            settings: settings,
            reflecting: reflecting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            function: function,
            property: property,
            detection: property
        )
    }

    /// Runs a property test with an async `Void`-returning property that uses `#expect`/`#require` for assertions.
    ///
    /// Bridges the async detection to sync, dispatches the pipeline onto a GCD thread, then re-runs the async property in the original context so `#expect` failures record with reduced values.
    @discardableResult
    static func __exhaustExpectAsync<Output>( // swiftlint:disable:this function_parameter_count
        _ refGen: ReflectiveGenerator<Output>,
        settings: [PropertySettings],
        reflecting: Output? = nil,

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @escaping @Sendable (Output) async throws -> Void,
        detection: @escaping @Sendable (Output) async throws -> Void
    ) async -> Output? {
        let gen = refGen.gen
        let reportDelivery = DeferredReportDelivery(settings: settings)
        var logLevel: LogLevel = .error
        for setting in settings {
            if case let .log(level) = setting {
                logLevel = level
            }
        }

        return await ExhaustLog.withConfiguration(.init(minimumLevel: logLevel, format: .keyValue)) {
            let skipCounter = SkipCounter()
            let syncDetection = bridgeAsyncDetection(detection, countingSkipsInto: skipCounter)
            #if canImport(Testing)
                let traitConfig = ExhaustTraitConfiguration.current
            #endif

            let diagnostics = CapturedDiagnostics<Output>()

            await dispatchToGCD(reserving: LaneReservation.property(parallelLanes: parallelLaneCount(in: settings))) {
                // withExpectedIssue cannot be used inside dispatchToGCD because Test.current is nil on the GCD thread, causing TestContext to misdetect as .xcTest. Use withKnownIssue directly since the async path is always in a Swift Testing context.
                #if canImport(Testing)
                    ExhaustTraitConfiguration.$current.withValue(traitConfig) {
                        withKnownIssue(isIntermittent: true) {
                            if let regression = replayRegressionSeeds(
                                gen: gen,
                                settings: reportDelivery.pipelineSettings,
                                skipCounter: skipCounter,
                                forceIssueReportingSuppression: true,
                                fileID: fileID,
                                filePath: filePath,
                                line: line,
                                column: column,
                                function: function,
                                property: syncDetection
                            ) {
                                diagnostics.pipelineResult = regression.counterexample
                                diagnostics.replaySeed = regression.replaySeed
                                diagnostics.report = regression.report
                                return
                            }

                            var augmentedSettings = reportDelivery.pipelineSettings + [.suppress(.issueReporting)]
                            augmentedSettings.append(.onReport { diagnostics.capture(from: $0) })

                            diagnostics.pipelineResult = __exhaustBody(
                                gen: gen,
                                settings: augmentedSettings,
                                reflecting: reflecting,
                                skipCounter: skipCounter,
                                fileID: fileID,
                                filePath: filePath,
                                line: line,
                                column: column,
                                testName: "\(function)",
                                property: syncDetection
                            ).0
                        }
                    }
                #else
                    var augmentedSettings = reportDelivery.pipelineSettings + [.suppress(.issueReporting)]
                    augmentedSettings.append(.onReport { diagnostics.capture(from: $0) })

                    diagnostics.pipelineResult = __exhaustBody(
                        gen: gen,
                        settings: augmentedSettings,
                        reflecting: reflecting,
                        skipCounter: skipCounter,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                        testName: "\(function)",
                        property: syncDetection
                    ).0
                #endif
            }

            let suppressIssueReporting = settings.contains { setting in
                if case let .suppress(option) = setting, option == .issueReporting || option == .all { return true }
                return false
            }

            guard let counterexample = diagnostics.pipelineResult else {
                // The pipeline's own issues fired inside withKnownIssue, where they are swallowed as known issues. Re-report them here so a run that asserted nothing fails the test.
                diagnostics.reportPassDiagnostics(
                    suppressIssueReporting: suppressIssueReporting,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                reportDelivery.deliver(diagnostics.report)
                return nil
            }

            if suppressIssueReporting == false {
                if let rendered = diagnostics.report.renderedFailure {
                    reportError(rendered, fileID: fileID, filePath: filePath, line: line, column: column)
                }

                diagnostics.report.recordDiagnosticInvocation()
                do {
                    try await property(counterexample)
                } catch {
                    // Error propagates to Swift Testing naturally.
                }

                if let replaySeed = diagnostics.replaySeed {
                    print("exhaust:\(function):replay:\(replaySeed)")
                }
            }

            reportDelivery.deliver(diagnostics.report)

            return counterexample
        }
    }
}

// MARK: - Captured Diagnostics

extension __ExhaustRuntime {
    /// Collects the diagnostics an `#expect` wrapper must re-report after its known-issue scope ends.
    ///
    /// The wrappers run the Bool pipeline with issue reporting suppressed inside `withRoutedExpectedIssue`/`withKnownIssue`, where anything the pipeline records is swallowed. The pipeline's report is captured through an appended `.onReport` closure calling ``capture(from:)``, and ``reportPassDiagnostics(suppressIssueReporting:fileID:filePath:line:column:)`` re-reports outside the scope.
    ///
    /// Marked `@unchecked Sendable` for the same reason the `nonisolated(unsafe)` locals it replaces were safe: the pipeline mutates the fields on the GCD worker inside `dispatchToGCD`, and the wrapper reads them only after the hop's continuation resumes, so no access is ever concurrent.
    final class CapturedDiagnostics<Output>: @unchecked Sendable {
        /// The pipeline's counterexample, or `nil` when every iteration passed.
        var pipelineResult: Output?
        /// The pipeline report, retained until the outer wrapper has completed any diagnostic rerun.
        var report = ExhaustReport()
        /// The encoded replay seed for a discovered failure.
        var replaySeed: String?

        /// Retains the pipeline's report until the wrapper has completed any diagnostic rerun. Install via an appended `.onReport` closure.
        func capture(from report: ExhaustReport) {
            self.report = report
            replaySeed = report.replaySeed
        }

        /// Re-reports the diagnostics of a run that found no counterexample: the pointless-run failure regardless of suppression, and the advisories only when the caller did not suppress issue reporting.
        func reportPassDiagnostics(
            suppressIssueReporting: Bool,
            fileID: StaticString,
            filePath: StaticString,
            line: UInt,
            column: UInt
        ) {
            if let pointlessRunFailure = report.pointlessRunFailure {
                reportError(pointlessRunFailure, fileID: fileID, filePath: filePath, line: line, column: column)
            } else if suppressIssueReporting == false, let skipRateWarning = report.skipRateWarning {
                reportWarning(skipRateWarning, fileID: fileID, filePath: filePath, line: line, column: column)
            }
            if suppressIssueReporting == false, let uniqueExhaustionWarning = report.uniqueExhaustionWarning {
                reportWarning(uniqueExhaustionWarning, fileID: fileID, filePath: filePath, line: line, column: column)
            }
        }
    }
}
