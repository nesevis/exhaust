// Runtime support for macro-expanded code. Not intended for direct use.
//
// The `__` prefix follows Swift Testing's convention (`Testing.__check`, `Testing.__Expression`)
// to signal that this is macro infrastructure, not public API.
import CustomDump
import Darwin
import ExhaustCore
import Foundation
import IssueReporting

#if canImport(XCTest)
    @_weakLinked import XCTest
#endif

#if canImport(Testing)
    @_weakLinked import Testing
#else
    /// Noop shim — withKnownIssue just runs the body.
    /// The matching closure is never called, so #expect failures go undetected.
    /// Only thrown errors (from #require or manual throws) signal failure.
    private struct _NoopIssue {}

    private func withKnownIssue(
        isIntermittent _: Bool = false,
        _ body: () throws -> Void,
        matching _: @escaping @Sendable (_NoopIssue) -> Bool = { _ in true }
    ) rethrows {
        try body()
    }
#endif

/// Runtime support namespace for `#exhaust`, `#explore`, and `#examine` macro expansions.
public enum __ExhaustRuntime { // swiftlint:disable:this type_name
    /// Thrown by the detection closure when a rewritten `#expect`/`#require` fails.
    ///
    /// This is a plain error — not a Swift Testing issue — so it produces no test output.
    /// The pipeline's try/catch detects it as a property failure without any console noise.
    public struct DetectionFailure: Error {} // swiftlint:disable:this nesting

    /// Detection replacement for `#expect(_ condition: Bool)` and `#require(_ condition: Bool)`.
    ///
    /// Throws ``DetectionFailure`` when the condition is `false`.
    /// Does not call `Issue.record()` — produces no Swift Testing output.
    public static func __detectRequire(_ condition: Bool) throws { // swiftlint:disable:this identifier_name
        if condition == false {
            throw DetectionFailure()
        }
    }

    /// Detection replacement for `#require<T>(_ optionalValue: T?)`.
    ///
    /// Throws ``DetectionFailure`` when the value is `nil`. Returns the unwrapped value otherwise.
    /// Does not call `Issue.record()` — produces no Swift Testing output.
    public static func __detectRequire<Value>(_ value: Value?) throws -> Value { // swiftlint:disable:this identifier_name
        guard let unwrapped = value else {
            throw DetectionFailure()
        }
        return unwrapped
    }

    /// Runs a property test with the given generator, settings, and property.
    /// This is the runtime target of the `#exhaust` macro expansion.
    ///
    /// - Parameters:
    ///   - gen: The generator to produce test values from.
    ///   - settings: An array of `ExhaustSettings` controlling test behavior.
    ///   - sourceCode: A string representation of the property closure body, captured at compile time. `nil` when a function reference is passed instead of a trailing closure.
    ///   - fileID: The file ID of the call site (injected by macro expansion).
    ///   - filePath: The file path of the call site (injected by macro expansion).
    ///   - line: The line number of the call site (injected by macro expansion).
    ///   - column: The column number of the call site (injected by macro expansion).
    ///   - function: The enclosing function name (injected by macro expansion).
    ///   - property: The property to test — returns `true` for passing values.
    /// - Returns: The reduced counterexample if the property failed, or `nil` if all iterations passed.
    @discardableResult
    public static func __exhaust<Output>(
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExhaustSettings<Output>],
        sourceCode: String?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @Sendable (Output) throws -> Bool
    ) -> Output? {
        withoutActuallyEscaping(property) { property in
            let property: @Sendable (Output) -> Bool = { value in
                (try? property(value)) ?? false
            }

            var budget = ExhaustBudget.expedient
            var seed: UInt64?
            var suppressIssueReporting = false
            var suppressLogs = false
            var reflectingValue: Output?
            var useRandomOnly = false
            var visualize = false
            var onReportClosure: ((ExhaustReport) -> Void)?
            var collectOpenPBTStats = false
            var logLevel: LogLevel = .error
            var logFormat: LogFormat = .keyValue

            for setting in settings {
                switch setting {
                case let .budget(b):
                    budget = b
                case let .replay(replaySeed):
                    seed = replaySeed.resolve()
                    if seed == nil {
                        reportIssue(
                            "Invalid replay seed: \(replaySeed)",
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column
                        )
                        return nil
                    }
                case let .suppress(option):
                    switch option {
                    case .issueReporting:
                        suppressIssueReporting = true
                    case .logs:
                        suppressLogs = true
                    case .all:
                        suppressIssueReporting = true
                        suppressLogs = true
                    }
                case let .reflecting(value):
                    reflectingValue = value
                case .randomOnly:
                    useRandomOnly = true
                case .visualize:
                    visualize = true
                case let .onReport(closure):
                    onReportClosure = closure
                case .collectOpenPBTStats:
                    collectOpenPBTStats = true
                case let .logging(level, format):
                    logLevel = level
                    logFormat = format
                }
            }

            return ExhaustLog.withConfiguration(.init(isEnabled: suppressLogs == false, minimumLevel: logLevel, format: logFormat)) {
                #if canImport(Testing)
                    if let traitConfig = ExhaustTraitConfiguration.current {
                        let hasInlineBudget = settings.contains { if case .budget = $0 { true } else { false } }
                        if hasInlineBudget == false, let traitBudget = traitConfig.budget {
                            budget = traitBudget
                        }
                    }
                #endif

                let samplingBudget = budget.samplingBudget
                let coverageBudget = budget.coverageBudget
                let reductionConfig = Interpreters.ReducerConfiguration(maxStalls: 2)

                var report = ExhaustReport()
                defer { onReportClosure?(report) }

                let statsAccumulator: OpenPBTStatsAccumulator? = collectOpenPBTStats
                    ? OpenPBTStatsAccumulator(propertyName: "\(function)")
                    : nil
                defer {
                    if let statsAccumulator {
                        let lines = statsAccumulator.finalize()
                        if lines.isEmpty == false {
                            report.openPBTStatsLines = lines
                            let attachmentName = "\(function)-openpbtstats.jsonl"
                            switch TestContext.current {
                            #if canImport(Testing)
                                case .swiftTesting:
                                    Attachment.record(lines.jsonlString(), named: attachmentName)
                            #endif
                            #if canImport(XCTest)
                                case .xcTest:
                                    let xctAttachment = XCTAttachment(data: Data(lines.jsonlString().utf8), uniformTypeIdentifier: "public.json")
                                    xctAttachment.name = attachmentName
                                    XCTContext.runActivity(named: "OpenPBTStats") { activity in
                                        activity.add(xctAttachment)
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
                    suppressIssueReporting: suppressIssueReporting,
                    sourceCode: sourceCode,
                    logFormat: logFormat,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    statsAccumulator: statsAccumulator
                )

                if let reflectingValue {
                    do {
                        return try __reduceReflected(
                            gen,
                            value: reflectingValue,
                            reductionConfig: reductionConfig,
                            visualize: visualize,
                            suppressIssueReporting: suppressIssueReporting,
                            sourceCode: sourceCode,
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column,
                            property: property,
                            report: &report
                        )
                    } catch {
                        reportIssue("\(error)", fileID: fileID, filePath: filePath, line: line, column: column)
                        return reflectingValue
                    }
                }

                let phaseTimingStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                var coverageIterations = 0
                if useRandomOnly {
                    ExhaustLog.notice(category: .propertyTest, event: "coverage_skipped", "Coverage phase skipped")
                } else if seed != nil {
                    ExhaustLog.notice(category: .propertyTest, event: "coverage_skipped", "Coverage phase skipped (deterministic replay)")
                } else {
                    let outcome: CoverageOutcome<Output> = runCoveragePhase(
                        context: context,
                        coverageBudget: coverageBudget,
                        report: &report
                    )
                    switch outcome {
                    case let .counterexample(value):
                        let coverageEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        report.coverageMilliseconds = Double(coverageEnd - phaseTimingStart) / 1_000_000
                        report.totalMilliseconds = report.coverageMilliseconds
                        return value
                    case let .exhaustivePass(iterations):
                        let coverageEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        report.coverageMilliseconds = Double(coverageEnd - phaseTimingStart) / 1_000_000
                        report.totalMilliseconds = report.coverageMilliseconds
                        report.setInvocations(coverage: iterations, randomSampling: 0, reduction: 0)
                        return nil
                    case let .proceed(iterations):
                        coverageIterations = iterations
                    }
                }
                let coveragePhaseEndTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

                let samplingResult = runSamplingPhase(
                    context: context,
                    seed: seed,
                    coverageIterations: coverageIterations,
                    report: &report
                )

                let endTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                report.coverageMilliseconds = Double(coveragePhaseEndTime - phaseTimingStart) / 1_000_000
                report.totalMilliseconds = Double(endTime - phaseTimingStart) / 1_000_000

                if samplingResult == nil {
                    report.generationMilliseconds = Double(endTime - coveragePhaseEndTime) / 1_000_000
                    let totalPropertyCalls = coverageIterations + report.randomSamplingInvocations
                    var passMetadata = [
                        "iterations": "\(samplingBudget)",
                        "property_invocations": "\(totalPropertyCalls)",
                    ]
                    if coverageIterations > 0 {
                        passMetadata["coverage_invocations"] = "\(coverageIterations)"
                        passMetadata["random_invocations"] = "\(report.randomSamplingInvocations)"
                    }
                    if let sourceCode {
                        passMetadata["source"] = sourceCode
                    }
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "property_passed",
                        metadata: passMetadata
                    )
                }

                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "phase_timing",
                    metadata: [
                        "coverage_ms": String(format: "%.1f", report.coverageMilliseconds),
                        "generation_ms": String(format: "%.1f", report.generationMilliseconds),
                        "reduction_ms": String(format: "%.1f", report.reductionMilliseconds),
                        "total_ms": String(format: "%.1f", report.totalMilliseconds),
                    ]
                )

                return samplingResult
            }
        }
    }

    // MARK: - Void Property (Swift Testing #expect / #require)

    /// Replays regression seeds from the test trait and returns the first failing counterexample, if any.
    #if canImport(Testing)
    private static func replayRegressionSeeds<Output>( // swiftlint:disable:this function_parameter_count
        gen: ReflectiveGenerator<Output>,
        settings: [ExhaustSettings<Output>],
        sourceCode: String?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        function: StaticString,
        property: @Sendable (Output) -> Bool
    ) -> (counterexample: Output, seed: UInt64)? {
        let suppressIssueReporting = settings.contains { setting in
            if case let .suppress(option) = setting, option == .issueReporting || option == .all { return true }
            return false
        }
        guard let traitConfig = ExhaustTraitConfiguration.current else { return nil }
        for encodedSeed in traitConfig.regressions {
            guard let seed = CrockfordBase32.decode(encodedSeed) else {
                reportIssue(
                    "Invalid regression seed: \(encodedSeed)",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                continue
            }
            let replayResult = __exhaust(
                gen,
                settings: [
                    .replay(.numeric(seed)),
                    .suppress(.issueReporting),
                ] + settings.filter { setting in
                    if case .budget = setting { return true }
                    return false
                },
                sourceCode: sourceCode,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column,
                function: function,
                property: property
            )
            if replayResult == nil {
                if suppressIssueReporting == false {
                    reportIssue(
                        "Regression seed \"\(encodedSeed)\" now passes — consider removing it.",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                }
            } else if let counterexample = replayResult {
                return (counterexample, seed)
            }
        }
        return nil
    }
    #endif

    /// Runs a property test with a `Void`-returning property that uses `#expect`/`#require` for assertions.
    ///
    /// Wraps the property into a `Bool`-returning form via `withKnownIssue`, delegates to the existing pipeline, then re-runs the property one final time without suppression so `#expect` failures record with reduced values.
    @discardableResult
    public static func __exhaustExpect<Output>( // swiftlint:disable:this function_parameter_count
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExhaustSettings<Output>],
        sourceCode: String?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @Sendable (Output) throws -> Void,
        detection: @Sendable (Output) throws -> Void
    ) -> Output? {
        var logLevel: LogLevel = .error
        var logFormat: LogFormat = .keyValue
        var suppressLogs = false
        for setting in settings {
            switch setting {
            case let .logging(level, format):
                logLevel = level
                logFormat = format
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

        return ExhaustLog.withConfiguration(.init(isEnabled: suppressLogs == false, minimumLevel: logLevel, format: logFormat)) {
            withoutActuallyEscaping(detection) { detection in
                let boolProperty = wrapDetectionProperty(detection)

                // Wrap the entire pipeline in withKnownIssue to suppress #require issues from the detection closure during coverage/sampling/reduction.
                // The final re-run (outside this scope) produces the user-facing #expect output.
                nonisolated(unsafe) var pipelineResult: Output?
                nonisolated(unsafe) var capturedSeed: UInt64?
                nonisolated(unsafe) var capturedRenderedFailure: String?
                try? withKnownIssue(isIntermittent: true) {
                    #if canImport(Testing)
                        if let regression = replayRegressionSeeds(
                            gen: gen, settings: settings, sourceCode: sourceCode,
                            fileID: fileID, filePath: filePath, line: line, column: column,
                            function: function, property: boolProperty
                        ) {
                            pipelineResult = regression.counterexample
                            capturedSeed = regression.seed
                            return
                        }
                    #endif

                    // Capture seed and rendered failure from the Bool pipeline.
                    var augmentedSettings = settings + [.suppress(.issueReporting)]
                    augmentedSettings.append(.onReport { report in
                        capturedSeed = report.seed
                        capturedRenderedFailure = report.renderedFailure
                    })

                    // Delegate to the Bool pipeline with suppressed issue reporting.
                    pipelineResult = __exhaust(
                        gen,
                        settings: augmentedSettings,
                        sourceCode: sourceCode,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                        function: function,
                        property: boolProperty
                    )
                } // withKnownIssue — all #require issues from the detection closure are now suppressed.

                guard let counterexample = pipelineResult else { return nil }

                // When suppress(.issueReporting) is set, the caller is asserting on the return value.
                // Skip the final re-run and replay message.
                let suppressIssueReporting = settings.contains { setting in
                    if case let .suppress(option) = setting, option == .issueReporting || option == .all { return true }
                    return false
                }
                if suppressIssueReporting == false {
                    if let rendered = capturedRenderedFailure {
                        reportIssue(rendered, fileID: fileID, filePath: filePath, line: line, column: column)
                    }

                    // Re-run without withKnownIssue so #expect failures record with reduced values.
                    do {
                        try property(counterexample)
                    } catch {
                        // Error propagates to Swift Testing naturally.
                    }

                    if let seed = capturedSeed {
                        let encoded = CrockfordBase32.encode(seed)
                        print("exhaust:\(function):replay:\(encoded)")
                    }
                }

                return counterexample
            }
        } // withConfiguration
    }

    // MARK: - Async Property

    /// Runs a property test with an async `Bool`-returning property closure.
    ///
    /// Bridges the async property to sync, then dispatches the synchronous core onto a GCD thread where semaphore-blocking is safe.
    @discardableResult
    public static func __exhaustAsync<Output>( // swiftlint:disable:this function_parameter_count
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExhaustSettings<Output>],
        sourceCode: String?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @escaping @Sendable (Output) async throws -> Bool
    ) async -> Output? {
        let syncProperty = bridgeAsyncProperty(property)
        return await dispatchToGCD {
            __exhaust(
                gen,
                settings: settings,
                sourceCode: sourceCode,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column,
                function: function,
                property: syncProperty
            )
        }
    }

    /// Runs a property test with an async `Void`-returning property that uses `#expect`/`#require` for assertions.
    ///
    /// Bridges the async detection to sync, dispatches the pipeline onto a GCD thread, then re-runs the async property in the original context so `#expect` failures record with reduced values.
    @discardableResult
    public static func __exhaustExpectAsync<Output>( // swiftlint:disable:this function_parameter_count
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExhaustSettings<Output>],
        sourceCode: String?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        function: StaticString = #function,
        property: @escaping @Sendable (Output) async throws -> Void,
        detection: @escaping @Sendable (Output) async throws -> Void
    ) async -> Output? {
        var logLevel: LogLevel = .error
        var logFormat: LogFormat = .keyValue
        for setting in settings {
            if case let .logging(level, format) = setting {
                logLevel = level
                logFormat = format
            }
        }

        return await ExhaustLog.withConfiguration(.init(minimumLevel: logLevel, format: logFormat)) {
            let syncDetection = bridgeAsyncDetection(detection)

            nonisolated(unsafe) var pipelineResult: Output?
            nonisolated(unsafe) var capturedSeed: UInt64?
            nonisolated(unsafe) var capturedRenderedFailure: String?

            await dispatchToGCD {
                try? withKnownIssue(isIntermittent: true) {
                    #if canImport(Testing)
                        if let regression = replayRegressionSeeds(
                            gen: gen, settings: settings, sourceCode: sourceCode,
                            fileID: fileID, filePath: filePath, line: line, column: column,
                            function: function, property: syncDetection
                        ) {
                            pipelineResult = regression.counterexample
                            capturedSeed = regression.seed
                            return
                        }
                    #endif

                    var augmentedSettings = settings + [.suppress(.issueReporting)]
                    augmentedSettings.append(.onReport { report in
                        capturedSeed = report.seed
                        capturedRenderedFailure = report.renderedFailure
                    })

                    pipelineResult = __exhaust(
                        gen,
                        settings: augmentedSettings,
                        sourceCode: sourceCode,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                        function: function,
                        property: syncDetection
                    )
                }
            }

            guard let counterexample = pipelineResult else { return nil }

            let suppressIssueReporting = settings.contains { setting in
                if case let .suppress(option) = setting, option == .issueReporting || option == .all { return true }
                return false
            }
            if suppressIssueReporting == false {
                if let rendered = capturedRenderedFailure {
                    reportIssue(rendered, fileID: fileID, filePath: filePath, line: line, column: column)
                }

                do {
                    try await property(counterexample)
                } catch {
                    // Error propagates to Swift Testing naturally.
                }

                if let seed = capturedSeed {
                    let encoded = CrockfordBase32.encode(seed)
                    print("exhaust:\(function):replay:\(encoded)")
                }
            }

            return counterexample
        }
    }


    // MARK: - Example

    /// Generates a single value from a generator. Runtime target of `#example` expansion.
    public static func __example<Output>(
        _ gen: ReflectiveGenerator<Output>,
        seed: UInt64?
    ) -> Output {
        var interpreter = ValueInterpreter(gen, seed: seed, maxRuns: 1, sizeOverride: 50)
        guard let value = try? interpreter.next() else {
            fatalError("#example: generator produced no values")
        }
        return value
    }

    /// Generates an array of values from a generator. Runtime target of `#example` expansion.
    public static func __exampleArray<Output>(
        _ gen: ReflectiveGenerator<Output>,
        count: UInt64,
        seed: UInt64?
    ) -> [Output] {
        var interpreter = ValueInterpreter(gen, seed: seed, maxRuns: count)
        var results: [Output] = []
        while let value = try? interpreter.next() {
            results.append(value)
        }
        return results
    }

    // MARK: - Examination

    /// Validates a generator's reflection, replay, and health. Runtime target of `#examine` expansion.
    ///
    /// Uses value comparison via `Equatable` for round-trip checks, providing richer failure output and correct handling of non-injective generators (for example `oneOf` where multiple branches can produce the same value).
    @discardableResult
    public static func __examine(
        _ gen: ReflectiveGenerator<some Equatable>,
        samples: Int,
        seed: UInt64?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> ValidationReport {
        gen.validate(
            samples: samples,
            seed: seed,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// Validates a generator's reflection, replay, and health. Runtime target of `#examine` expansion.
    ///
    /// Falls back to choice-sequence comparison for non-`Equatable` types.
    @discardableResult
    public static func __examine(
        _ gen: ReflectiveGenerator<some Any>,
        samples: Int,
        seed: UInt64?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> ValidationReport {
        gen.validate(
            samples: samples,
            seed: seed,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

}
