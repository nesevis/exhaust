// Pipeline phases for `__exhaust`: coverage, sampling, shared reduction, and async/detection bridge helpers.

import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

extension __ExhaustRuntime {
    // MARK: - Pipeline Context

    /// Bundles parameters shared across coverage, sampling, and reduction phases.
    package struct PipelineContext<Output> {
        let gen: ReflectiveGenerator<Output>
        let property: @Sendable (Output) -> Bool
        let samplingBudget: UInt64
        let reductionConfig: Interpreters.ReducerConfiguration
        let visualize: Bool
        let suppressIssueReporting: Bool
        let sourceCode: String?
        let logFormat: LogFormat
        let fileID: StaticString
        let filePath: StaticString
        let line: UInt
        let column: UInt
        let statsAccumulator: OpenPBTStatsAccumulator?
    }

    package enum CoverageOutcome<Output> {
        case counterexample(Output)
        case exhaustivePass(iterations: Int)
        case proceed(coverageIterations: Int)
    }

    package enum ReduceOutcome<Output> {
        case reduced(Output)
        case unreduced(Output)
        case reductionError
    }

    // MARK: - Coverage Phase

    package static func runCoveragePhase<Output>(
        context: PipelineContext<Output>,
        coverageBudget: UInt64,
        report: inout ExhaustReport
    ) -> CoverageOutcome<Output> {
        let coverageResult = CoverageRunner.run(
            context.gen,
            coverageBudget: coverageBudget,
            property: context.property,
            onExample: context.statsAccumulator.map { accumulator in
                { value, tree, passed in
                    var representation = ""
                    customDump(value, to: &representation)
                    accumulator.record(representation: representation, passed: passed, tree: tree, phase: .coverage)
                }
            }
        )
        switch coverageResult {
        case let .failure(value, tree, iteration, strength, rows, parameters, totalSpace, kind):
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
            let reductionTree = (try? Interpreters.reflect(context.gen, with: value)) ?? tree
            let result = reduceAndReport(
                context: context,
                value: value,
                tree: reductionTree,
                seed: nil,
                iteration: iteration,
                coverageIterations: iteration,
                randomSamplingIterations: 0,
                replayHint: "No replay seed — found via systematic combinatorial coverage.",
                report: &report
            )
            switch result {
            case let .reduced(counterexample):
                return .counterexample(counterexample)
            case let .unreduced(counterexample):
                return .counterexample(counterexample)
            case .reductionError:
                return .proceed(coverageIterations: iteration)
            }

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
            if let sourceCode = context.sourceCode {
                passMetadata["source"] = sourceCode
            }
            ExhaustLog.notice(
                category: .propertyTest,
                event: "property_passed",
                metadata: passMetadata
            )
            report.setInvocations(
                coverage: iterations,
                randomSampling: 0,
                reduction: 0
            )
            return .exhaustivePass(iterations: iterations)

        case let .partial(iterations, strength, rows, parameters, totalSpace, kind):
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
            return .proceed(coverageIterations: iterations)

        case .notApplicable:
            ExhaustLog.notice(
                category: .propertyTest,
                event: "coverage_not_applicable",
                "Generator not analyzable for structured coverage"
            )
            return .proceed(coverageIterations: 0)
        }
    }

    // MARK: - Sampling Phase

    package static func runSamplingPhase<Output>( // swiftlint:disable:this function_body_length
        context: PipelineContext<Output>,
        seed: UInt64?,
        coverageIterations: Int,
        report: inout ExhaustReport
    ) -> Output? {
        let generationPhaseStart = monotonicNanoseconds()
        var iterations = 0
        var generator = ValueAndChoiceTreeInterpreter(
            context.gen,
            materializePicks: true,
            seed: seed,
            maxRuns: context.samplingBudget
        )
        let actualSeed = generator.baseSeed
        report.seed = actualSeed

        var previousFilterObservations: [UInt64: FilterObservation] = [:]

        defer {
            if context.suppressIssueReporting == false {
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
            if context.statsAccumulator != nil {
                previousFilterObservations = generator.filterObservations
            }
            let generateStart = context.statsAccumulator != nil ? monotonicNanoseconds() : 0
            guard let (next, tree) = try generator.next() else { break }
            let generateEnd = context.statsAccumulator != nil ? monotonicNanoseconds() : 0
            iterations += 1

            var filterAttempts: Int?
            var filterRejections: Int?
            if context.statsAccumulator != nil {
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

            let testStart = context.statsAccumulator != nil ? monotonicNanoseconds() : 0
            let passed = context.property(next)
            let testEnd = context.statsAccumulator != nil ? monotonicNanoseconds() : 0

            if let statsAccumulator = context.statsAccumulator {
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
                report.generationMilliseconds = Double(monotonicNanoseconds() - generationPhaseStart) / 1_000_000
                let result = reduceAndReport(
                    context: context,
                    value: next,
                    tree: tree,
                    seed: actualSeed,
                    iteration: iterations,
                    coverageIterations: coverageIterations,
                    randomSamplingIterations: iterations,
                    replayHint: nil,
                    report: &report
                )
                switch result {
                case let .reduced(counterexample):
                    return counterexample
                case let .unreduced(counterexample):
                    return counterexample
                case .reductionError:
                    return next
                }
            }
        }
        } catch {
            reportIssue(
                "\(error)",
                fileID: context.fileID,
                filePath: context.filePath,
                line: context.line,
                column: context.column
            )
            return nil
        }

        report.setInvocations(
            coverage: coverageIterations,
            randomSampling: iterations,
            reduction: 0
        )
        return nil
    }

    // MARK: - Shared Reduction

    package static func reduceAndReport<Output>( // swiftlint:disable:this function_parameter_count
        context: PipelineContext<Output>,
        value: Output,
        tree: ChoiceTree,
        seed: UInt64?,
        iteration: Int,
        coverageIterations: Int,
        randomSamplingIterations: Int,
        replayHint: String?,
        report: inout ExhaustReport
    ) -> ReduceOutcome<Output> {
        var propertyInvocationCount = 0
        let countingProperty: (Output) -> Bool = { value in
            propertyInvocationCount += 1
            return context.property(value)
        }
        let reductionStart = monotonicNanoseconds()
        do {
            var reducerConfig = context.reductionConfig
            reducerConfig.visualize = context.visualize
            let reduceResult = try Interpreters.choiceGraphReduceCollectingStats(
                gen: context.gen,
                tree: tree,
                output: value,
                config: reducerConfig,
                property: countingProperty
            )
            report.applyReductionStats(reduceResult.stats)
            report.reductionMilliseconds = Double(monotonicNanoseconds() - reductionStart) / 1_000_000
            if let (reducedSequence, reducedValue) = reduceResult.reduced {
                var failure = PropertyTestFailure(
                    counterexample: reducedValue,
                    original: value,
                    sourceCode: context.sourceCode,
                    seed: seed,
                    iteration: iteration,
                    samplingBudget: context.samplingBudget,
                    blueprint: reducedSequence.shortString,
                    propertyInvocations: propertyInvocationCount
                )
                failure.replayHint = replayHint
                let rendered = failure.render(format: context.logFormat)
                report.renderedFailure = rendered
                ExhaustLog.debug(
                    category: .propertyTest,
                    event: "reduced_blueprint",
                    "\(reducedSequence.shortString)"
                )
                report.setInvocations(
                    coverage: coverageIterations,
                    randomSampling: randomSamplingIterations,
                    reduction: propertyInvocationCount
                )
                if let statsAccumulator = context.statsAccumulator {
                    var representation = ""
                    customDump(reducedValue, to: &representation)
                    statsAccumulator.recordReduced(
                        representation: representation,
                        tree: .just,
                        reductionSeconds: report.reductionMilliseconds / 1000
                    )
                }
                if context.suppressIssueReporting == false {
                    reportIssue(
                        rendered,
                        fileID: context.fileID,
                        filePath: context.filePath,
                        line: context.line,
                        column: context.column
                    )
                }
                return .reduced(reducedValue)
            }
        } catch {
            reportIssue(
                "\(error)",
                fileID: context.fileID,
                filePath: context.filePath,
                line: context.line,
                column: context.column
            )
            report.setInvocations(
                coverage: coverageIterations,
                randomSampling: randomSamplingIterations,
                reduction: propertyInvocationCount
            )
            return .reductionError
        }

        // Reduction ran but could not improve
        var failure = PropertyTestFailure(
            counterexample: value,
            original: nil as Output?,
            sourceCode: context.sourceCode,
            seed: seed,
            iteration: iteration,
            samplingBudget: context.samplingBudget,
            blueprint: nil,
            propertyInvocations: propertyInvocationCount
        )
        failure.replayHint = replayHint
        let rendered = failure.render(format: context.logFormat)
        report.renderedFailure = rendered
        if context.suppressIssueReporting == false {
            reportIssue(
                rendered,
                fileID: context.fileID,
                filePath: context.filePath,
                line: context.line,
                column: context.column
            )
        }
        report.setInvocations(
            coverage: coverageIterations,
            randomSampling: randomSamplingIterations,
            reduction: propertyInvocationCount
        )
        return .unreduced(value)
    }

    // MARK: - Phase Timing

    package static func logPhaseTimings(
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
    package static func __reduceReflected<Output>(
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
        let reflectStart = monotonicNanoseconds()

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

        let reflectionEnd = monotonicNanoseconds()

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
            var failure = PropertyTestFailure(
                counterexample: reducedValue,
                original: value,
                sourceCode: sourceCode,
                seed: nil,
                iteration: 1,
                samplingBudget: 1,
                blueprint: reducedSequence.shortString,
                propertyInvocations: propertyInvocationCount
            )
            failure.replayHint = "No replay seed — counterexample found via reflection."
            let rendered = failure.render(format: ExhaustLog.configuration.format)
            report.renderedFailure = rendered
            let reductionEnd = monotonicNanoseconds()
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
        var failure = PropertyTestFailure(
            counterexample: value,
            original: nil as Output?,
            sourceCode: sourceCode,
            seed: nil,
            iteration: 1,
            samplingBudget: 1,
            blueprint: nil,
            propertyInvocations: propertyInvocationCount
        )
        failure.replayHint = "No replay seed — counterexample found via reflection."
        let rendered = failure.render(format: ExhaustLog.configuration.format)
        report.renderedFailure = rendered
        let reductionEnd = monotonicNanoseconds()
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

    // MARK: - Detection and Async Bridges

    /// Wraps a throwing `Void`-returning closure into `(Output) -> Bool` via try/catch.
    package static func wrapDetectionProperty<Output>(
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

    /// Bridges an async Bool-returning property to a synchronous one via `Task` + `DispatchSemaphore`.
    package static func bridgeAsyncProperty<Output>(
        _ property: @escaping @Sendable (Output) async throws -> Bool
    ) -> @Sendable (Output) -> Bool {
        { value in
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
    }

    /// Bridges an async Void-returning detection closure to a synchronous Bool via `Task` + `DispatchSemaphore`.
    package static func bridgeAsyncDetection<Output>(
        _ detection: @escaping @Sendable (Output) async throws -> Void
    ) -> @Sendable (Output) -> Bool {
        { value in
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
    }

    /// Dispatches a synchronous closure onto a GCD thread and returns the result asynchronously.
    package static func dispatchToGCD<Result>(
        _ work: @escaping () -> Result
    ) async -> Result {
        nonisolated(unsafe) let unsafeWork = work
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            DispatchQueue.global().async {
                let result = unsafeWork()
                nonisolated(unsafe) let unsafeResult = result
                continuation.resume(returning: unsafeResult)
            }
        }
    }
}
