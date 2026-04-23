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
        // The macro declaration is `throws -> R` so the parameter is throwing.
        // Wrap into non-throwing for the internal pipeline (thrown errors → false).
        // Uses withoutActuallyEscaping since the wrapper doesn't outlive this function.
        withoutActuallyEscaping(property) { property in
            // Shadows the parameter so all downstream call sites use the non-throwing version.
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
                // Merge trait configuration — trait provides defaults, inline settings override.
                #if canImport(Testing)
                    if let traitConfig = ExhaustTraitConfiguration.current {
                        // Budget: trait is the default, only applied if no inline .budget was specified.
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
                        reportIssue(
                            "\(error)",
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column
                        )
                        return reflectingValue
                    }
                }

                // --- Structured coverage phase ---
                let phaseTimingStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                var coveragePhaseEndTime = phaseTimingStart
                var generationPhaseEndTime = phaseTimingStart
                var coverageIterations = 0
                if useRandomOnly {
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "coverage_skipped",
                        "Coverage phase skipped"
                    )
                } else if seed != nil {
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "coverage_skipped",
                        "Coverage phase skipped (deterministic replay)"
                    )
                }
                if !useRandomOnly, seed == nil {
                    let coverageResult = CoverageRunner.run(
                        gen,
                        coverageBudget: coverageBudget,
                        property: property,
                        onExample: statsAccumulator.map { accumulator in
                            { value, tree, passed in
                                var representation = ""
                                customDump(value, to: &representation)
                                accumulator.record(representation: representation, passed: passed, tree: tree, phase: .coverage)
                            }
                        }
                    )
                    coveragePhaseEndTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    switch coverageResult {
                    case let .failure(value, tree, iteration, strength, rows, parameters, totalSpace, kind):
                        coverageIterations = iteration
                        ExhaustLog.notice(
                            category: .propertyTest,
                            event: "coverage_failure",
                            metadata: [
                                "iteration": "\(iteration)",
                                "strength": "\(strength)",
                                "covering_rows": "\(rows)",
                                "parameters": "\(parameters)",
                                "total_space": "\(totalSpace)",
                                "kind": kind,
                            ]
                        )
                        // Reflect to get a structurally correct tree with materialized picks, since coverage-built trees lack unselected branches needed by reducer strategies.
                        let reductionTree = (try? Interpreters.reflect(gen, with: value)) ?? tree
                        var propertyInvocationCount = 0
                        let countingProperty: (Output) -> Bool = { value in
                            propertyInvocationCount += 1
                            return property(value)
                        }
                        do {
                            var reducerConfig = reductionConfig
                            reducerConfig.visualize = visualize
                            let reduceResult = try Interpreters.choiceGraphReduceCollectingStats(
                                gen: gen,
                                tree: reductionTree,
                                output: value,
                                config: reducerConfig,
                                property: countingProperty
                            )
                            report.applyReductionStats(reduceResult.stats)
                            if let (reducedSequence, reducedValue) = reduceResult.reduced {
                                var failure = PropertyTestFailure(
                                    counterexample: reducedValue,
                                    original: value,
                                    sourceCode: sourceCode,
                                    seed: nil,
                                    iteration: iteration,
                                    samplingBudget: samplingBudget,
                                    blueprint: reducedSequence.shortString,
                                    propertyInvocations: propertyInvocationCount
                                )
                                failure.replayHint =
                                    "No replay seed — found via systematic combinatorial coverage."
                                let rendered = failure.render(
                                    format: logFormat
                                )
                                let reductionEndTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                                logPhaseTimings(
                                    start: phaseTimingStart,
                                    coverageEnd: coveragePhaseEndTime,
                                    generationEnd: coveragePhaseEndTime,
                                    reductionEnd: reductionEndTime
                                )
                                let coverageElapsed = coveragePhaseEndTime - phaseTimingStart
                                report.coverageMilliseconds = Double(coverageElapsed) / 1_000_000
                                let reductionElapsed = reductionEndTime - coveragePhaseEndTime
                                report.reductionMilliseconds = Double(reductionElapsed) / 1_000_000
                                let totalElapsed = reductionEndTime - phaseTimingStart
                                report.totalMilliseconds = Double(totalElapsed) / 1_000_000
                                report.setInvocations(
                                    coverage: coverageIterations,
                                    randomSampling: 0,
                                    reduction: propertyInvocationCount
                                )
                                if let statsAccumulator {
                                    var representation = ""
                                    customDump(reducedValue, to: &representation)
                                    statsAccumulator.recordReduced(
                                        representation: representation,
                                        tree: .just,
                                        reductionSeconds: report.reductionMilliseconds / 1000
                                    )
                                }
                                if !suppressIssueReporting {
                                    reportIssue(
                                        rendered,
                                        fileID: fileID,
                                        filePath: filePath,
                                        line: line,
                                        column: column
                                    )
                                }
                                return reducedValue
                            }
                        } catch {
                            reportIssue(
                                "\(error)",
                                fileID: fileID,
                                filePath: filePath,
                                line: line,
                                column: column
                            )
                            report.setInvocations(
                                coverage: coverageIterations,
                                randomSampling: 0,
                                reduction: propertyInvocationCount
                            )
                            return value
                        }

                        // Reduction failed — report original
                        var failure = PropertyTestFailure(
                            counterexample: value,
                            original: nil as Output?,
                            sourceCode: sourceCode,
                            seed: nil,
                            iteration: iteration,
                            samplingBudget: samplingBudget,
                            blueprint: nil,
                            propertyInvocations: propertyInvocationCount
                        )
                        failure.replayHint = "No replay seed — found via systematic combinatorial coverage."
                        let rendered = failure.render(format: logFormat)
                        if suppressIssueReporting == false {
                            reportIssue(
                                rendered,
                                fileID: fileID,
                                filePath: filePath,
                                line: line,
                                column: column
                            )
                        }
                        report.setInvocations(
                            coverage: coverageIterations,
                            randomSampling: 0,
                            reduction: propertyInvocationCount
                        )
                        return nil

                    case let .exhaustive(iterations):
                        ExhaustLog.notice(
                            category: .propertyTest,
                            event: "tway_coverage",
                            metadata: [
                                "exhaustive": "true",
                                "iterations": "\(iterations)",
                            ]
                        )
                        var passMetadata = [
                            "iterations": "\(iterations)",
                            "property_invocations": "\(iterations)",
                        ]
                        if let sourceCode {
                            passMetadata["source"] = sourceCode
                        }
                        ExhaustLog.notice(
                            category: .propertyTest,
                            event: "property_passed",
                            metadata: passMetadata
                        )
                        let exhaustiveEndTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        let elapsed = exhaustiveEndTime - phaseTimingStart
                        report.coverageMilliseconds = Double(elapsed) / 1_000_000
                        report.totalMilliseconds = report.coverageMilliseconds
                        report.setInvocations(
                            coverage: iterations,
                            randomSampling: 0,
                            reduction: 0
                        )
                        return nil

                    case let .partial(iterations, strength, rows, parameters, totalSpace, kind):
                        coverageIterations = iterations
                        ExhaustLog.notice(
                            category: .propertyTest,
                            event: "tway_coverage",
                            metadata: [
                                "strength": "\(strength)",
                                "covering_rows": "\(rows)",
                                "iterations": "\(iterations)",
                                "total_space": "\(totalSpace)",
                                "parameters": "\(parameters)",
                                "exhaustive": "false",
                                "kind": kind,
                            ]
                        )

                    case .notApplicable:
                        ExhaustLog.notice(
                            category: .propertyTest,
                            event: "coverage_not_applicable",
                            "Generator not analyzable for structured coverage"
                        )
                    }
                }
                coveragePhaseEndTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                // --- Random sampling phase (full maxIterations budget) ---

                var iterations = 0
                var generator = ValueAndChoiceTreeInterpreter(
                    gen,
                    materializePicks: true,
                    seed: seed,
                    maxRuns: samplingBudget
                )
                let actualSeed = generator.baseSeed
                report.seed = actualSeed

                var previousFilterObservations: [UInt64: FilterObservation] = [:]

                defer {
                    if suppressIssueReporting == false {
                        for (_, observation) in generator.filterObservations where observation.attempts >= 20 {
                            if observation.validityRate < 0.02, let location = observation.sourceLocation {
                                reportIssue(
                                    "Filter validity rate \(String(format: "%.1f", observation.validityRate * 100))% over \(observation.attempts) attempts. Generation is spending most of its time on rejection. Consider widening the input range or relaxing the predicate.",
                                    severity: .warning,
                                    fileID: location.fileID,
                                    filePath: location.filePath,
                                    line: location.line,
                                    column: location.column
                                )
                            }
                        }
                    }
                }

                do { while true {
                    if statsAccumulator != nil {
                        previousFilterObservations = generator.filterObservations
                    }
                    let generateStart = statsAccumulator != nil ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0
                    guard let (next, tree) = try generator.next() else { break }
                    let generateEnd = statsAccumulator != nil ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0
                    iterations += 1

                    // Compute per-example filter deltas when collecting stats.
                    var filterAttempts: Int?
                    var filterRejections: Int?
                    if statsAccumulator != nil {
                        let currentObservations = generator.filterObservations
                        var totalAttempts = 0
                        var totalPasses = 0
                        for (fingerprint, observation) in currentObservations {
                            let previous = previousFilterObservations[fingerprint]
                            totalAttempts += observation.attempts - (previous?.attempts ?? 0)
                            totalPasses += observation.passes - (previous?.passes ?? 0)
                        }
                        if totalAttempts > 0 {
                            filterAttempts = totalAttempts
                            filterRejections = totalAttempts - totalPasses
                        }
                    }

                    let testStart = statsAccumulator != nil ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0
                    let passed = property(next)
                    let testEnd = statsAccumulator != nil ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0

                    if let statsAccumulator {
                        let generateSeconds = Double(generateEnd - generateStart) / 1_000_000_000
                        let testSeconds = Double(testEnd - testStart) / 1_000_000_000
                        var representation = ""
                        customDump(next, to: &representation)
                        if let rejections = filterRejections, rejections > 0 {
                            statsAccumulator.recordDiscards(count: rejections, phase: .random)
                        }
                        statsAccumulator.record(
                            representation: representation,
                            passed: passed,
                            tree: tree,
                            phase: .random,
                            generateSeconds: generateSeconds,
                            testSeconds: testSeconds,
                            filterAttempts: filterAttempts,
                            filterRejections: filterRejections
                        )
                    }

                    if passed == false {
                        generationPhaseEndTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        var propertyInvocationCount = 0
                        let countingProperty: (Output) -> Bool = { value in
                            propertyInvocationCount += 1
                            return property(value)
                        }
                        do {
                            var reducerConfig = reductionConfig
                            reducerConfig.visualize = visualize
                            let reduceResult = try Interpreters.choiceGraphReduceCollectingStats(
                                gen: gen,
                                tree: tree,
                                output: next,
                                config: reducerConfig,
                                property: countingProperty
                            )
                            report.applyReductionStats(reduceResult.stats)
                            if let (reducedSequence, reducedValue) = reduceResult.reduced {
                                let failure = PropertyTestFailure(
                                    counterexample: reducedValue,
                                    original: next,
                                    sourceCode: sourceCode,
                                    seed: actualSeed,
                                    iteration: iterations,
                                    samplingBudget: samplingBudget,
                                    blueprint: reducedSequence.shortString,
                                    propertyInvocations: propertyInvocationCount
                                )
                                let rendered = failure.render(format: logFormat)
                                ExhaustLog.debug(
                                    category: .propertyTest,
                                    event: "reduced_blueprint",
                                    "\(reducedSequence.shortString)"
                                )
                                let reductionEndTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                                logPhaseTimings(
                                    start: phaseTimingStart,
                                    coverageEnd: coveragePhaseEndTime,
                                    generationEnd: generationPhaseEndTime,
                                    reductionEnd: reductionEndTime
                                )
                                let coverageElapsed = coveragePhaseEndTime - phaseTimingStart
                                report.coverageMilliseconds = Double(coverageElapsed) / 1_000_000
                                let generationElapsed = generationPhaseEndTime - coveragePhaseEndTime
                                report.generationMilliseconds = Double(generationElapsed) / 1_000_000
                                let reductionElapsed = reductionEndTime - generationPhaseEndTime
                                report.reductionMilliseconds = Double(reductionElapsed) / 1_000_000
                                let totalElapsed = reductionEndTime - phaseTimingStart
                                report.totalMilliseconds = Double(totalElapsed) / 1_000_000
                                report.setInvocations(
                                    coverage: coverageIterations,
                                    randomSampling: iterations,
                                    reduction: propertyInvocationCount
                                )
                                if let statsAccumulator {
                                    var representation = ""
                                    customDump(reducedValue, to: &representation)
                                    statsAccumulator.recordReduced(
                                        representation: representation,
                                        tree: .just,
                                        reductionSeconds: report.reductionMilliseconds / 1000
                                    )
                                }
                                if !suppressIssueReporting {
                                    reportIssue(
                                        rendered,
                                        fileID: fileID,
                                        filePath: filePath,
                                        line: line,
                                        column: column
                                    )
                                }
                                return reducedValue
                            }
                        } catch {
                            reportIssue(
                                "\(error)",
                                fileID: fileID,
                                filePath: filePath,
                                line: line,
                                column: column
                            )
                            report.setInvocations(
                                coverage: coverageIterations,
                                randomSampling: iterations,
                                reduction: propertyInvocationCount
                            )
                            return next
                        }

                        // Reduction failed — report the original counterexample
                        let failure = PropertyTestFailure(
                            counterexample: next,
                            original: nil as Output?,
                            sourceCode: sourceCode,
                            seed: actualSeed,
                            iteration: iterations,
                            samplingBudget: samplingBudget,
                            blueprint: nil,
                            propertyInvocations: propertyInvocationCount
                        )
                        let rendered = failure.render(format: logFormat)
                        if suppressIssueReporting == false {
                            reportIssue(
                                rendered,
                                fileID: fileID,
                                filePath: filePath,
                                line: line,
                                column: column
                            )
                        }
                        report.setInvocations(
                            coverage: coverageIterations,
                            randomSampling: iterations,
                            reduction: propertyInvocationCount
                        )
                        return nil
                    }
                }
                } catch {
                    reportIssue(
                        "\(error)",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                    return nil
                }

                let totalPropertyCalls = coverageIterations + iterations
                var passMetadata = [
                    "iterations": "\(samplingBudget)",
                    "property_invocations": "\(totalPropertyCalls)",
                ]
                if coverageIterations > 0 {
                    passMetadata["coverage_invocations"] = "\(coverageIterations)"
                    passMetadata["random_invocations"] = "\(iterations)"
                }
                if let sourceCode {
                    passMetadata["source"] = sourceCode
                }
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "property_passed",
                    metadata: passMetadata
                )
                let passEndTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                logPhaseTimings(
                    start: phaseTimingStart,
                    coverageEnd: coveragePhaseEndTime,
                    generationEnd: passEndTime,
                    reductionEnd: passEndTime
                )
                report.coverageMilliseconds = Double(coveragePhaseEndTime - phaseTimingStart) / 1_000_000
                report.generationMilliseconds = Double(passEndTime - coveragePhaseEndTime) / 1_000_000
                report.totalMilliseconds = Double(passEndTime - phaseTimingStart) / 1_000_000
                report.setInvocations(
                    coverage: coverageIterations,
                    randomSampling: iterations,
                    reduction: 0
                )
                return nil
            } // withConfiguration
        } // withoutActuallyEscaping
    }

    // MARK: - Void Property (Swift Testing #expect / #require)

    /// Wraps a throwing `Void`-returning closure into `(Output) -> Bool` via try/catch.
    ///
    /// The detection closure has `#expect` rewritten to `#require` by the macro, so assertion failures throw and are caught here. No `withKnownIssue` needed.
    private static func wrapDetectionProperty<Output>(
        _ detection: @escaping @Sendable (Output) throws -> Void
    ) -> @Sendable (Output) -> Bool {
        { value in
            do {
                try detection(value)
                return true
            } catch {
                return false
            }
        }
    }

    /// Runs a property test with a `Void`-returning property that uses `#expect`/`#require` for assertions.
    ///
    /// Wraps the property into a `Bool`-returning form via `withKnownIssue`, delegates to the existing pipeline, then re-runs the property one final time without suppression so `#expect` failures record with reduced values.
    @discardableResult
    public static func __exhaustExpect<Output>( // swiftlint:disable:this function_body_length function_parameter_count
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
                try? withKnownIssue(isIntermittent: true) {
                    // Replay regression seeds from the trait before the normal pipeline.
                    #if canImport(Testing)
                        let suppressIssueReportingForRegressions = settings.contains { setting in
                            if case let .suppress(option) = setting, option == .issueReporting || option == .all { return true }
                            return false
                        }
                        if let traitConfig = ExhaustTraitConfiguration.current {
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
                                        // Forward budget from inline settings; trait budget is merged by __exhaust.
                                        if case .budget = setting { return true }
                                        return false
                                    },
                                    sourceCode: sourceCode,
                                    fileID: fileID,
                                    filePath: filePath,
                                    line: line,
                                    column: column,
                                    function: function,
                                    property: boolProperty
                                )
                                if replayResult == nil {
                                    if suppressIssueReportingForRegressions == false {
                                        reportIssue(
                                            "Regression seed \"\(encodedSeed)\" now passes — consider removing it.",
                                            fileID: fileID,
                                            filePath: filePath,
                                            line: line,
                                            column: column
                                        )
                                    }
                                } else if let counterexample = replayResult {
                                    // Regression seed still fails — store for final re-run outside withKnownIssue.
                                    pipelineResult = counterexample
                                    capturedSeed = seed
                                    return // exit withKnownIssue scope
                                }
                            }
                        }
                    #endif

                    // Capture the actual seed from the Bool pipeline via .onReport.
                    var augmentedSettings = settings + [.suppress(.issueReporting)]
                    augmentedSettings.append(.onReport { report in
                        capturedSeed = report.seed
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
                    // Final re-run without withKnownIssue — #expect failures record naturally with reduced values.
                    do {
                        try property(counterexample)
                    } catch {
                        // Error propagates to Swift Testing naturally.
                    }

                    // Emit the replay seed as the only Exhaust artifact.
                    let replayMessage: String
                    if let seed = capturedSeed {
                        let encoded = CrockfordBase32.encode(seed)
                        replayMessage = "Reproduce: .replay(\"\(encoded)\")"
                        // Structured replay tag for agents
                        print("exhaust:\(function):replay:\(encoded)")
                    } else {
                        replayMessage = "No replay seed — found via systematic combinatorial coverage."
                    }

                    reportIssue(
                        replayMessage,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                }

                return counterexample
            }
        } // withConfiguration
    }

    // MARK: - Async Property

    /// Runs a property test with an async `Bool`-returning property closure.
    ///
    /// Wraps the async property into a synchronous closure using `Task` + `DispatchSemaphore`, then dispatches the entire synchronous core (coverage, sampling, reduction) onto a GCD thread where semaphore-blocking is safe. This avoids deadlocking the cooperative thread pool.
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
        var logLevel: LogLevel = .error
        var logFormat: LogFormat = .keyValue
        for setting in settings {
            if case let .logging(level, format) = setting {
                logLevel = level
                logFormat = format
            }
        }

        return await ExhaustLog.withConfiguration(.init(minimumLevel: logLevel, format: logFormat)) {
            let syncProperty: @Sendable (Output) -> Bool = { value in
                let valueBox = SendableBox(value)
                let resultBox = SendableBox(false)
                let semaphore = DispatchSemaphore(value: 0)
                Task { @Sendable in
                    resultBox.value = await (try? property(valueBox.value)) ?? false
                    semaphore.signal()
                }
                semaphore.wait()
                return resultBox.value
            }

            return await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let result = __exhaust(
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
                    continuation.resume(returning: result)
                }
            }
        } // withConfiguration
    }

    /// Runs a property test with an async `Void`-returning property that uses `#expect`/`#require` for assertions.
    ///
    /// Wraps the async detection closure into a synchronous `Bool`-returning form, dispatches the pipeline onto a GCD thread via `withCheckedContinuation`, then performs the final re-run in the async context so `#expect` failures record naturally with reduced values.
    @discardableResult
    public static func __exhaustExpectAsync<Output>( // swiftlint:disable:this function_body_length function_parameter_count
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
            // Wrap async detection into sync Bool (Task + semaphore, called from GCD thread).
            let syncDetection: @Sendable (Output) -> Bool = { value in
                let valueBox = SendableBox(value)
                let resultBox = SendableBox(true)
                let semaphore = DispatchSemaphore(value: 0)
                Task { @Sendable in
                    do {
                        try await detection(valueBox.value)
                    } catch {
                        resultBox.value = false
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                return resultBox.value
            }

            // Capture pipeline output across the GCD boundary.
            nonisolated(unsafe) var pipelineResult: Output?
            nonisolated(unsafe) var capturedSeed: UInt64?

            // Dispatch the sync core (with withKnownIssue wrapping) onto a GCD thread.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    try? withKnownIssue(isIntermittent: true) {
                        // Replay regression seeds from the trait before the normal pipeline.
                        #if canImport(Testing)
                            let suppressIssueReportingForRegressions = settings.contains { setting in
                                if case let .suppress(option) = setting, option == .issueReporting || option == .all { return true }
                                return false
                            }
                            if let traitConfig = ExhaustTraitConfiguration.current {
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
                                        property: syncDetection
                                    )
                                    if replayResult == nil {
                                        if suppressIssueReportingForRegressions == false {
                                            reportIssue(
                                                "Regression seed \"\(encodedSeed)\" now passes — consider removing it.",
                                                fileID: fileID,
                                                filePath: filePath,
                                                line: line,
                                                column: column
                                            )
                                        }
                                    } else if let counterexample = replayResult {
                                        pipelineResult = counterexample
                                        capturedSeed = seed
                                        return // exit withKnownIssue scope
                                    }
                                }
                            }
                        #endif

                        // Capture the actual seed from the Bool pipeline via .onReport.
                        var augmentedSettings = settings + [.suppress(.issueReporting)]
                        augmentedSettings.append(.onReport { report in
                            capturedSeed = report.seed
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
                            property: syncDetection
                        )
                    } // withKnownIssue

                    continuation.resume()
                }
            }

            guard let counterexample = pipelineResult else { return nil }

            // When suppress(.issueReporting) is set, the caller is asserting on the return value.
            let suppressIssueReporting = settings.contains { setting in
                if case let .suppress(option) = setting, option == .issueReporting || option == .all { return true }
                return false
            }
            if suppressIssueReporting == false {
                // Final re-run in the async context — #expect failures record naturally with reduced values.
                do {
                    try await property(counterexample)
                } catch {
                    // Error propagates to Swift Testing naturally.
                }

                // Emit the replay seed as the only Exhaust artifact.
                let replayMessage: String
                if let seed = capturedSeed {
                    let encoded = CrockfordBase32.encode(seed)
                    replayMessage = "Reproduce: .replay(\"\(encoded)\")"
                    print("exhaust:\(function):replay:\(encoded)")
                } else {
                    replayMessage = "No replay seed — found via systematic combinatorial coverage."
                }

                reportIssue(
                    replayMessage,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }

            return counterexample
        } // withConfiguration
    }

    // MARK: - Explore

    /// Runs a classification-aware property test with per-direction CGS tuning. Runtime target of `#explore`.
    @discardableResult
    public static func __explore<Output>(
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExploreSettings],
        directions: [(String, @Sendable (Output) -> Bool)],
        sourceCode: String?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @Sendable @escaping (Output) -> Bool
    ) -> ExploreReport<Output> {
        var budget: ExploreBudget = .expedient
        var seed: UInt64?
        var suppressIssueReporting = false
        var suppressLogs = false
        var logLevel: LogLevel = .error
        var logFormat: LogFormat = .keyValue
        for setting in settings {
            switch setting {
            case let .budget(exploreBudget):
                budget = exploreBudget
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
                    return ExploreReport(
                        result: nil,
                        seed: 0,
                        directionCoverage: [],
                        coOccurrence: CoOccurrenceMatrix(directionCount: 0),
                        counterexampleDirections: [],
                        propertyInvocations: 0,
                        warmupSamples: 0,
                        totalMilliseconds: 0,
                        termination: .budgetExhausted
                    )
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
            case let .logging(level, format):
                logLevel = level
                logFormat = format
            }
        }

        return ExhaustLog.withConfiguration(.init(isEnabled: suppressLogs == false, minimumLevel: logLevel, format: logFormat)) {
            var runner = ClassificationExploreRunner(
                gen: gen,
                property: property,
                directions: directions.map { (name: $0.0, predicate: $0.1) },
                hitsPerDirection: budget.hitsPerDirection,
                maxAttemptsPerDirection: budget.maxAttemptsPerDirection,
                seed: seed
            )
            let result = runner.run()

            let directionCoverage = result.directionCoverage.map { entry in
                DirectionCoverage(
                    name: entry.name,
                    hits: entry.hits,
                    tuningPassSamples: entry.tuningPassSamples,
                    tuningPassPasses: entry.tuningPassPasses,
                    tuningPassFailures: entry.tuningPassFailures,
                    warmupHits: entry.warmupHits,
                    isCovered: entry.isCovered,
                    warmupRuleOfThreeBound: entry.warmupRuleOfThreeBound,
                    tuningPassRuleOfThreeBound: entry.tuningPassRuleOfThreeBound
                )
            }

            let termination: ExploreTermination = switch result.termination {
            case .propertyFailed: .propertyFailed
            case .coverageAchieved: .coverageAchieved
            case .budgetExhausted: .budgetExhausted
            }

            if let counterexample = result.counterexample {
                let matchedDirections = result.counterexampleDirections.map { index in
                    (index: index, name: directionCoverage[index].name)
                }
                let failure = ExploreFailure(
                    counterexample: counterexample,
                    original: result.original,
                    seed: result.seed,
                    propertyInvocations: result.propertyInvocations,
                    totalBudget: directions.count * budget.maxAttemptsPerDirection,
                    matchedDirections: matchedDirections
                )
                let rendered = failure.render()
                if suppressIssueReporting == false {
                    reportIssue(
                        rendered,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                }
            } else {
                var passMetadata = [
                    "invocations": "\(result.propertyInvocations)",
                    "warmup_samples": "\(result.warmupSamples)",
                    "seed": "\(result.seed)",
                ]
                if let sourceCode {
                    passMetadata["source"] = sourceCode
                }
                let coveredCount = directionCoverage.filter(\.isCovered).count
                passMetadata["coverage"] = "\(coveredCount)/\(directions.count)"
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "explore_property_passed",
                    metadata: passMetadata
                )
            }

            return ExploreReport(
                result: result.counterexample,
                seed: result.seed,
                directionCoverage: directionCoverage,
                coOccurrence: result.coOccurrence,
                counterexampleDirections: result.counterexampleDirections,
                propertyInvocations: result.propertyInvocations,
                warmupSamples: result.warmupSamples,
                totalMilliseconds: result.totalMilliseconds,
                termination: termination
            )
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

    // MARK: - Phase Timing

    private static func logPhaseTimings(
        start: UInt64,
        coverageEnd: UInt64,
        generationEnd: UInt64,
        reductionEnd: UInt64
    ) {
        let coverageMs = Double(coverageEnd - start) / 1_000_000
        let generationMs = Double(generationEnd - coverageEnd) / 1_000_000
        let reductionMs = Double(reductionEnd - generationEnd) / 1_000_000
        let totalMs = Double(reductionEnd - start) / 1_000_000
        ExhaustLog.notice(
            category: .propertyTest,
            event: "phase_timing",
            metadata: [
                "coverage_ms": String(format: "%.1f", coverageMs),
                "generation_ms": String(format: "%.1f", generationMs),
                "reduction_ms": String(format: "%.1f", reductionMs),
                "total_ms": String(format: "%.1f", totalMs),
            ]
        )
    }

    // MARK: - Reflecting

    // swiftlint:disable:next function_parameter_count
    private static func __reduceReflected<Output>(
        _ gen: ReflectiveGenerator<Output>,
        value: Output,
        reductionConfig: Interpreters.ReducerConfiguration,
        visualize: Bool,
        suppressIssueReporting: Bool,
        sourceCode: String?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        property: @Sendable (Output) -> Bool,
        report: inout ExhaustReport
    ) throws -> Output? {
        let reflectStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        guard property(value) == false else {
            let message = "reflecting: value passes the property — reduction requires a failing value"
            if !suppressIssueReporting {
                reportIssue(
                    message,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
            report.setInvocations(coverage: 0, randomSampling: 0, reduction: 1)
            return nil
        }

        guard let tree = try Interpreters.reflect(gen, with: value) else {
            let message = "reflecting: could not reflect value into choice tree"
            if !suppressIssueReporting {
                reportIssue(
                    message,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
            report.setInvocations(coverage: 0, randomSampling: 0, reduction: 1)
            return nil
        }

        let reflectionEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        var propertyInvocationCount = 0
        let countingProperty: (Output) -> Bool = { value in
            propertyInvocationCount += 1
            return property(value)
        }
        var reducerConfig = reductionConfig
        reducerConfig.visualize = visualize
        let reduceResult = try Interpreters.choiceGraphReduceCollectingStats(
            gen: gen,
            tree: tree,
            output: value,
            config: reducerConfig,
            property: countingProperty
        )
        report.applyReductionStats(reduceResult.stats)

        if let (reducedSequence, reducedValue) = reduceResult.reduced {
            let failure = PropertyTestFailure(
                counterexample: reducedValue,
                original: value,
                sourceCode: sourceCode,
                seed: nil,
                iteration: 1,
                samplingBudget: 1,
                blueprint: reducedSequence.shortString,
                propertyInvocations: propertyInvocationCount
            )
            let rendered = failure.render(format: ExhaustLog.configuration.format)
            let reductionEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let reflectionMs = Double(reflectionEnd - reflectStart) / 1_000_000
            let reductionMs = Double(reductionEnd - reflectionEnd) / 1_000_000
            let totalMs = Double(reductionEnd - reflectStart) / 1_000_000
            ExhaustLog.notice(
                category: .propertyTest,
                event: "phase_timing",
                metadata: [
                    "reflection_ms": String(format: "%.1f", reflectionMs),
                    "reduction_ms": String(format: "%.1f", reductionMs),
                    "total_ms": String(format: "%.1f", totalMs),
                ]
            )
            report.reflectionMilliseconds = reflectionMs
            report.reductionMilliseconds = reductionMs
            report.totalMilliseconds = totalMs
            report.setInvocations(
                coverage: 0,
                randomSampling: 0,
                reduction: 1 + propertyInvocationCount
            )
            if !suppressIssueReporting {
                reportIssue(
                    rendered,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
            return reducedValue
        }

        // Reflection succeeded but reduction could not improve — return original
        let failure = PropertyTestFailure(
            counterexample: value,
            original: nil as Output?,
            sourceCode: sourceCode,
            seed: nil,
            iteration: 1,
            samplingBudget: 1,
            blueprint: nil,
            propertyInvocations: propertyInvocationCount
        )
        let rendered = failure.render(format: ExhaustLog.configuration.format)
        let reductionEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let reflectionMs = Double(reflectionEnd - reflectStart) / 1_000_000
        let reductionMs = Double(reductionEnd - reflectionEnd) / 1_000_000
        let totalMs = Double(reductionEnd - reflectStart) / 1_000_000
        ExhaustLog.notice(
            category: .propertyTest,
            event: "phase_timing",
            metadata: [
                "reflection_ms": String(format: "%.1f", reflectionMs),
                "reduction_ms": String(format: "%.1f", reductionMs),
                "total_ms": String(format: "%.1f", totalMs),
            ]
        )
        report.reflectionMilliseconds = reflectionMs
        report.reductionMilliseconds = reductionMs
        report.totalMilliseconds = totalMs
        report.setInvocations(
            coverage: 0,
            randomSampling: 0,
            reduction: 1 + propertyInvocationCount
        )
        if !suppressIssueReporting {
            reportIssue(
                rendered,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
        return value
    }
}
