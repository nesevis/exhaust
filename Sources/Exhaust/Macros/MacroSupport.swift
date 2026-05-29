// Runtime support for macro-expanded code. Not intended for direct use.
//
// The `__` prefix follows Swift Testing's convention (`Testing.__check`, `Testing.__Expression`)
// to signal that this is macro infrastructure, not public API.
import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

#if canImport(XCTest)
    @preconcurrency @_weakLinked import XCTest
#endif

#if canImport(Testing)
    @_weakLinked import Testing
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

    /// Runs a property test with the given generator, settings, and property.
    /// This is the runtime target of the `#exhaust` macro expansion.
    ///
    /// - Parameters:
    ///   - gen: The generator to produce test values from.
    ///   - settings: An array of `PropertySettings` controlling test behavior.
    ///   - settings: An array of `PropertySettings` controlling test behavior.
    ///   - fileID: The file ID of the call site (injected by macro expansion).
    ///   - filePath: The file path of the call site (injected by macro expansion).
    ///   - line: The line number of the call site (injected by macro expansion).
    ///   - column: The column number of the call site (injected by macro expansion).
    ///   - function: The enclosing function name (injected by macro expansion).
    ///   - property: The property to test — returns `true` for passing values.
    /// - Returns: The reduced counterexample if the property failed, or `nil` if all iterations passed.
    /// Runs a property test with a non-throwing predicate. This is the base case — the throwing variant wraps its closure and delegates here.
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
        return __ExhaustRuntime.withIsInterpreting(true) {
            withoutActuallyEscaping(property) { property in
                __exhaustBody(
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
        return __ExhaustRuntime.withIsInterpreting(true) {
            withoutActuallyEscaping(property) { property in
                let property: @Sendable (Output) -> Bool = { value in
                    do {
                        return try property(value)
                    } catch {
                        #if canImport(XCTest)
                            if error is XCTSkip { return true }
                        #endif
                        return false
                    }
                }
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
    }

    // swiftlint:disable:next function_body_length
    package static func __exhaustBody<Output>(
        gen: Generator<Output>,
        settings: [PropertySettings],
        reflecting: Output?,
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
        var coverageReplayRow: Int?
        var suppressIssueReporting = false
        var suppressLogs = false
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
                        reportIssue(
                            "Invalid replay seed: \(replaySeed)",
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column
                        )
                        return (nil, nil)
                    }
                    switch resolved {
                        case let .sampling(resolvedSeed, iteration):
                            seed = resolvedSeed
                            replayIteration = iteration
                        case let .coverage(row):
                            coverageReplayRow = row
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
                case let .parallel(lanes):
                    parallelLanes = UInt8(clamping: max(1, lanes))
                case let .log(level):
                    logLevel = level
            }
        }

        let logConfiguration = ExhaustLog.Configuration(
            isEnabled: suppressLogs == false,
            minimumLevel: logLevel,
            format: logFormat
        )
        return ExhaustLog.withConfiguration(logConfiguration) {
            #if canImport(Testing)
                if let traitConfig = ExhaustTraitConfiguration.current {
                    let hasInlineBudget = settings.contains { if case .budget = $0 { true } else { false } }
                    if hasInlineBudget == false, let traitBudget = traitConfig.budget {
                        budget = traitBudget
                    }
                }
            #endif

            let samplingBudget: UInt64 = (replayIteration != nil || coverageReplayRow != nil) ? 1 : budget.samplingBudget
            let coverageBudget: UInt64 = (replayIteration != nil || coverageReplayRow != nil) ? 0 : budget.coverageBudget
            let totalBudget = coverageBudget + samplingBudget
            let reductionDeadlineNanoseconds = UInt64(totalBudget) * 5 * 1_000_000
            let reductionConfig = Interpreters.ReducerConfiguration(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: reductionDeadlineNanoseconds
            )

            var report = ExhaustReport()
            defer { onReportClosure?(report) }

            let statsAccumulator: OpenPBTStatsAccumulator? = collectOpenPBTStats
                ? OpenPBTStatsAccumulator(propertyName: "\(testName)")
                : nil
            defer {
                if let statsAccumulator {
                    let lines = statsAccumulator.finalize()
                    if lines.isEmpty == false {
                        report.openPBTStatsLines = lines
                        let attachmentName = "\(testName)-openpbtstats.jsonl"
                        switch TestContext.current {
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
                suppressIssueReporting: suppressIssueReporting,
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
                        suppressIssueReporting: suppressIssueReporting,
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
                    reportIssue(localizedErrorMessage(error), fileID: fileID, filePath: filePath, line: line, column: column)
                    return (reflecting, nil)
                }
            }

            let phaseTimingStart = monotonicNanoseconds()
            var coverageIterations = 0
            if let coverageReplayRow {
                let outcome: CoverageOutcome<Output> = runCoveragePhase(
                    context: context,
                    coverageBudget: budget.coverageBudget,
                    skipToRow: coverageReplayRow,
                    report: &report
                )
                switch outcome {
                    case let .counterexample(value):
                        let coverageEnd = monotonicNanoseconds()
                        report.coverageMilliseconds = Double(coverageEnd - phaseTimingStart) / 1_000_000
                        report.totalMilliseconds = report.coverageMilliseconds
                        return (value, report.replaySeed)
                    case .exhaustivePass, .proceed:
                        let coverageEnd = monotonicNanoseconds()
                        report.coverageMilliseconds = Double(coverageEnd - phaseTimingStart) / 1_000_000
                        report.totalMilliseconds = report.coverageMilliseconds
                        report.setInvocations(coverage: 1, randomSampling: 0, reduction: 0)
                        return (nil, nil)
                }
            } else if coverageBudget == 0 {
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
                        let coverageEnd = monotonicNanoseconds()
                        report.coverageMilliseconds = Double(coverageEnd - phaseTimingStart) / 1_000_000
                        report.totalMilliseconds = report.coverageMilliseconds
                        return (value, report.replaySeed)
                    case let .exhaustivePass(iterations):
                        let coverageEnd = monotonicNanoseconds()
                        report.coverageMilliseconds = Double(coverageEnd - phaseTimingStart) / 1_000_000
                        report.totalMilliseconds = report.coverageMilliseconds
                        report.setInvocations(coverage: iterations, randomSampling: 0, reduction: 0)
                        return (nil, nil)
                    case let .proceed(iterations):
                        coverageIterations = iterations
                }
            }
            let coveragePhaseEndTime = monotonicNanoseconds()

            let samplingResult = runSamplingPhase(
                context: context,
                seed: seed,
                replayIteration: replayIteration,
                coverageIterations: coverageIterations,
                report: &report
            )

            let endTime = monotonicNanoseconds()
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

            return (samplingResult, report.replaySeed)
        }
    }

    // MARK: - Void Property (Swift Testing #expect / #require)

    // Replays regression seeds from the test trait and returns the first failing counterexample, if any.
    #if canImport(Testing)
        private static func replayRegressionSeeds<Output>( // swiftlint:disable:this function_parameter_count
            gen: Generator<Output>,
            settings: [PropertySettings],
            fileID: StaticString,
            filePath: StaticString,
            line: UInt,
            column: UInt,
            function: StaticString,
            property: @Sendable (Output) -> Bool
        ) -> (counterexample: Output, replaySeed: String)? {
            guard let traitConfig = ExhaustTraitConfiguration.current else { return nil }
            for encodedSeed in traitConfig.regressions {
                guard CrockfordBase32.decodeWithIteration(encodedSeed) != nil
                    || CrockfordBase32.decodeCoverageRow(encodedSeed) != nil
                else {
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
                    gen.wrapped,
                    settings: [
                        .replay(.encoded(encodedSeed)),
                        .suppress(.issueReporting),
                    ] + settings.filter { setting in
                        if case .budget = setting { return true }
                        return false
                    },

                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    function: function,
                    property: property
                )
                if replayResult == nil {
                    // Seed now passes — the bug was fixed. The seed sits inert as a
                    // silent regression guard until the property fails again.
                } else if let counterexample = replayResult {
                    return (counterexample, replaySeed: encodedSeed)
                }
            }
            return nil
        }
    #endif

    /// Runs a property test with a `Void`-returning property that uses `#expect`/`#require` for assertions.
    ///
    /// Wraps the property into a `Bool`-returning form via `withExpectedIssue`, delegates to the existing pipeline, then re-runs the property one final time without suppression so `#expect` failures record with reduced values.
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
                let boolProperty = wrapDetectionProperty(detection)

                // Suppress assertion issues during coverage/sampling/reduction.
                // The final re-run (outside this scope) produces the user-facing assertion output.
                nonisolated(unsafe) var pipelineResult: Output?
                nonisolated(unsafe) var capturedReplaySeed: String?
                nonisolated(unsafe) var capturedRenderedFailure: String?
                withExpectedIssue(isIntermittent: true) {
                    #if canImport(Testing)
                        if let regression = replayRegressionSeeds(
                            gen: gen,
                            settings: settings,
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column,
                            function: function,
                            property: boolProperty
                        ) {
                            pipelineResult = regression.counterexample
                            capturedReplaySeed = regression.replaySeed
                            return
                        }
                    #endif

                    // Capture seed and rendered failure from the Bool pipeline.
                    var augmentedSettings = settings + [.suppress(.issueReporting)]
                    augmentedSettings.append(.onReport { report in
                        capturedReplaySeed = report.replaySeed
                        capturedRenderedFailure = report.renderedFailure
                    })

                    // Delegate to the Bool pipeline with suppressed issue reporting.
                    pipelineResult = __exhaust(
                        refGen,
                        settings: augmentedSettings,
                        reflecting: reflecting,

                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                        function: function,
                        property: boolProperty
                    )
                }

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

                    // Re-run without suppression so #expect failures record with reduced values.
                    do {
                        try property(counterexample)
                    } catch {
                        // Error propagates to Swift Testing naturally.
                    }

                    if let replaySeed = capturedReplaySeed {
                        print("exhaust:\(function):replay:\(replaySeed)")
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
        let syncProperty = bridgeAsyncProperty(property)
        #if canImport(Testing)
            let traitConfig = ExhaustTraitConfiguration.current
        #endif
        return await dispatchToGCD {
            let run = {
                __exhaust(
                    refGen,
                    settings: settings,
                    reflecting: reflecting,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    function: function,
                    property: syncProperty
                )
            }
            #if canImport(Testing)
                return ExhaustTraitConfiguration.$current.withValue(traitConfig, operation: run)
            #else
                return run()
            #endif
        }
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
        var logLevel: LogLevel = .error
        for setting in settings {
            if case let .log(level) = setting {
                logLevel = level
            }
        }

        return await ExhaustLog.withConfiguration(.init(minimumLevel: logLevel, format: .keyValue)) {
            let syncDetection = bridgeAsyncDetection(detection)
            #if canImport(Testing)
                let traitConfig = ExhaustTraitConfiguration.current
            #endif

            nonisolated(unsafe) var pipelineResult: Output?
            nonisolated(unsafe) var capturedReplaySeed: String?
            nonisolated(unsafe) var capturedRenderedFailure: String?

            await dispatchToGCD {
                // withExpectedIssue cannot be used inside dispatchToGCD because Test.current is nil on the GCD thread, causing TestContext to misdetect as .xcTest. Use withKnownIssue directly since the async path is always in a Swift Testing context.
                #if canImport(Testing)
                    ExhaustTraitConfiguration.$current.withValue(traitConfig) {
                        withKnownIssue(isIntermittent: true) {
                            if let regression = replayRegressionSeeds(
                                gen: gen,
                                settings: settings,
                                fileID: fileID,
                                filePath: filePath,
                                line: line,
                                column: column,
                                function: function,
                                property: syncDetection
                            ) {
                                pipelineResult = regression.counterexample
                                capturedReplaySeed = regression.replaySeed
                                return
                            }

                            var augmentedSettings = settings + [.suppress(.issueReporting)]
                            augmentedSettings.append(.onReport { report in
                                capturedReplaySeed = report.replaySeed
                                capturedRenderedFailure = report.renderedFailure
                            })

                            pipelineResult = __exhaust(
                                refGen,
                                settings: augmentedSettings,
                                reflecting: reflecting,

                                fileID: fileID,
                                filePath: filePath,
                                line: line,
                                column: column,
                                function: function,
                                property: syncDetection
                            )
                        }
                    }
                #else
                    var augmentedSettings = settings + [.suppress(.issueReporting)]
                    augmentedSettings.append(.onReport { report in
                        capturedReplaySeed = report.replaySeed
                        capturedRenderedFailure = report.renderedFailure
                    })

                    pipelineResult = __exhaust(
                        refGen,
                        settings: augmentedSettings,
                        reflecting: reflecting,

                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                        function: function,
                        property: syncDetection
                    )
                #endif
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

                if let replaySeed = capturedReplaySeed {
                    print("exhaust:\(function):replay:\(replaySeed)")
                }
            }

            return counterexample
        }
    }

    // MARK: - Example

    /// Generates a single value from a generator. Runtime target of `#example` expansion.
    static func __example<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        seed: UInt64?,
        fileID _: StaticString = #fileID,
        filePath _: StaticString = #filePath,
        line _: UInt = #line,
        column _: UInt = #column
    ) -> Output {
        let gen = refGen.gen
        return __ExhaustRuntime.withIsInterpreting(true) {
            var interpreter = ValueInterpreter(gen, seed: seed, maxRuns: 1, sizeOverride: 50)
            guard let value = try? interpreter.next() else {
                preconditionFailure(
                    "#example: generator produced no values. If the generator uses a sparse filter, consider restructuring it to produce valid values directly."
                )
            }
            return value
        }
    }

    /// Generates an array of values from a generator. Runtime target of `#example` expansion.
    static func __exampleArray<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        count: UInt64,
        seed: UInt64?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> [Output] {
        let gen = refGen.gen
        return __ExhaustRuntime.withIsInterpreting(true) {
            var interpreter = ValueInterpreter(gen, seed: seed, maxRuns: count)
            var results: [Output] = []
            while let value = try? interpreter.next() {
                results.append(value)
            }
            if results.count < count {
                reportIssue(
                    "#example: generator produced \(results.count) of \(count) requested values. If the generator uses a sparse filter, consider restructuring it to produce valid values directly.",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
            return results
        }
    }

    // MARK: - Examination

    /// Validates a generator's reflection, replay, and health. Runtime target of `#examine` expansion.
    ///
    /// Uses value comparison via `Equatable` for round-trip checks, providing richer failure output and correct handling of non-injective generators (for example, `oneOf` where multiple branches can produce the same value). Skips the reflection check for synthesized generators (``ReflectiveGenerator/isSynthesized``), which are forward-only by design.
    @discardableResult
    static func __examine(
        _ refGen: ReflectiveGenerator<some Equatable>,
        settings: [ExamineSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> ExamineReport {
        let config = ExamineReportingConfiguration(from: settings)

        var seed: UInt64?
        if let replaySeed = config.replaySeed {
            guard let resolved = replaySeed.resolve() else {
                reportIssue(
                    "Invalid replay seed: \(replaySeed)",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                return ExamineReport(
                    sampleCount: 0,
                    valuesGenerated: 0,
                    reflectionRoundTripSuccesses: 0,
                    replayDeterminismSuccesses: nil,
                    uniqueChoiceSequences: 0,
                    reflectionSkipped: false,
                    pinnedFieldCount: 0,
                    failures: [],
                    generationTime: 0,
                    elapsedTime: 0,
                    filterObservations: [:],
                    numericCoverage: [],
                    branchCoverage: 1.0,
                    sequenceLengthDeciles: 10,
                    hasSequences: false,
                    sequenceLengthMin: 0,
                    sequenceLengthMax: 0,
                    sequenceLengthMean: 0,
                    characterCoverage: [],
                    complexityDeciles: 10,
                    representativeTree: nil
                )
            }
            seed = resolved.seed
        }

        let gen = refGen.gen
        return __ExhaustRuntime.withIsInterpreting(true) {
            gen.validate(
                samples: config.samples,
                seed: seed,
                skipReflection: refGen.isSynthesized,
                reporting: config,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
    }

    /// Validates a generator's reflection, replay, and health. Runtime target of `#examine` expansion.
    ///
    /// Falls back to choice-sequence comparison for non-`Equatable` types. Skips the reflection check for synthesized generators (``ReflectiveGenerator/isSynthesized``), which are forward-only by design.
    @discardableResult
    static func __examine(
        _ refGen: ReflectiveGenerator<some Any>,
        settings: [ExamineSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> ExamineReport {
        let config = ExamineReportingConfiguration(from: settings)

        var seed: UInt64?
        if let replaySeed = config.replaySeed {
            guard let resolved = replaySeed.resolve() else {
                reportIssue(
                    "Invalid replay seed: \(replaySeed)",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                return ExamineReport(
                    sampleCount: 0,
                    valuesGenerated: 0,
                    reflectionRoundTripSuccesses: 0,
                    replayDeterminismSuccesses: nil,
                    uniqueChoiceSequences: 0,
                    reflectionSkipped: false,
                    pinnedFieldCount: 0,
                    failures: [],
                    generationTime: 0,
                    elapsedTime: 0,
                    filterObservations: [:],
                    numericCoverage: [],
                    branchCoverage: 1.0,
                    sequenceLengthDeciles: 10,
                    hasSequences: false,
                    sequenceLengthMin: 0,
                    sequenceLengthMax: 0,
                    sequenceLengthMean: 0,
                    characterCoverage: [],
                    complexityDeciles: 10,
                    representativeTree: nil
                )
            }
            seed = resolved.seed
        }

        let gen = refGen.gen
        return __ExhaustRuntime.withIsInterpreting(true) {
            gen.validate(
                samples: config.samples,
                seed: seed,
                skipReflection: refGen.isSynthesized,
                reporting: config,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
    }

    /// Validates a generator with a user-provided replay determinism check. Runtime target of `#examine` expansion with trailing closure.
    @discardableResult
    static func __examine<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        settings: [ExamineSettings],
        replayCheck: @escaping @Sendable (Output, Output) -> Bool,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> ExamineReport {
        let config = ExamineReportingConfiguration(from: settings)

        var seed: UInt64?
        if let replaySeed = config.replaySeed {
            guard let resolved = replaySeed.resolve() else {
                reportIssue(
                    "Invalid replay seed: \(replaySeed)",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                return ExamineReport(
                    sampleCount: 0,
                    valuesGenerated: 0,
                    reflectionRoundTripSuccesses: 0,
                    replayDeterminismSuccesses: nil,
                    uniqueChoiceSequences: 0,
                    reflectionSkipped: false,
                    pinnedFieldCount: 0,
                    failures: [],
                    generationTime: 0,
                    elapsedTime: 0,
                    filterObservations: [:],
                    numericCoverage: [],
                    branchCoverage: 1.0,
                    sequenceLengthDeciles: 10,
                    hasSequences: false,
                    sequenceLengthMin: 0,
                    sequenceLengthMax: 0,
                    sequenceLengthMean: 0,
                    characterCoverage: [],
                    complexityDeciles: 10,
                    representativeTree: nil
                )
            }
            seed = resolved.seed
        }

        let gen = refGen.gen
        return __ExhaustRuntime.withIsInterpreting(true) {
            gen.validate(
                samples: config.samples,
                seed: seed,
                skipReflection: refGen.isSynthesized,
                replayCheck: { lhs, rhs in
                    guard let lhs = lhs as? Output, let rhs = rhs as? Output else {
                        return false
                    }
                    return replayCheck(lhs, rhs)
                },
                reporting: config,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
    }
}
