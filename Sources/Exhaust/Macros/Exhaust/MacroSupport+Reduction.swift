// Reduction dispatch and reflecting: path for the #exhaust pipeline.

import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

#if canImport(XCTest) && canImport(ObjectiveC)
    @preconcurrency @_weakLinked import XCTest
#elseif canImport(XCTest)
    @preconcurrency import XCTest
#endif

package extension __ExhaustRuntime {
    // MARK: - Shared Reduction

    /// Reduces a failing counterexample and reports the result.
    static func reduceAndReport<Output>( // swiftlint:disable:this function_parameter_count
        context: PipelineContext<Output>,
        value: Output,
        tree: ChoiceTree,
        seed: UInt64?,
        iteration: Int,
        phaseBudget: UInt64,
        replayHint: String?,
        report: inout ExhaustReport,
        ledger: inout RunLedger
    ) -> ReduceOutcome<Output> {
        let countingProperty = PropertyOutcomeCounter(context.property)
        let reductionSkipsBefore = context.skipCount
        /// Recorded before the report's failure rendering reads `ledger.totalInvocations`, and on the error path as well, so reduction probes are never dropped from the totals.
        func recordReductionOutcomes() {
            ledger.record(
                .reduction,
                invocations: countingProperty.invocations,
                skips: context.skipCount - reductionSkipsBefore,
                failures: countingProperty.failures
            )
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
                property: { countingProperty($0) }
            )
            report.applyReductionStats(reduceResult.stats)
            report.reductionMilliseconds = Double(monotonicNanoseconds() - reductionStart) / 1_000_000
            recordReductionOutcomes()
            if case let .reduced(reducedSequence, _, reducedValue) = reduceResult.outcome {
                var failure = PropertyTestFailure(
                    counterexample: reducedValue,
                    original: value,

                    seed: seed,
                    iteration: iteration,
                    phaseBudget: phaseBudget,
                    blueprint: reducedSequence.shortString,
                    propertyInvocations: ledger.totalInvocations,
                    reducedSequence: reducedSequence
                )
                failure.replayHint = replayHint
                failure.reductionWasCapped = report.reductionWasCapped
                failure.includeDiff = context.includeDiff
                let rendered = failure.render(format: context.logFormat)
                report.renderedFailure = rendered
                report.replaySeed = failure.encodedReplaySeed
                ExhaustLog.debug(
                    category: .propertyTest,
                    event: "reduced_blueprint",
                    "\(reducedSequence.shortString)"
                )
                if let statsAccumulator = context.statsAccumulator {
                    var representation = ""
                    customDump(reducedValue, to: &representation, maxDepth: 3)
                    statsAccumulator.recordReduced(
                        representation: representation,
                        tree: .just,
                        reductionSeconds: report.reductionMilliseconds / 1000
                    )
                }
                if context.suppressIssueReporting == false {
                    reportError(
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
            recordReductionOutcomes()
            reportError(
                localizedErrorMessage(error),
                fileID: context.fileID,
                filePath: context.filePath,
                line: context.line,
                column: context.column
            )
            return .reductionError
        }

        // Reduction ran but could not improve
        var failure = PropertyTestFailure(
            counterexample: value,
            original: nil as Output?,
            seed: seed,
            iteration: iteration,
            phaseBudget: phaseBudget,
            blueprint: nil,
            propertyInvocations: ledger.totalInvocations
        )
        failure.replayHint = replayHint
        failure.reductionProducedNoImprovement = true
        // Reflected inputs (the other no-improvement site) deliberately do not set this: a user-supplied example is often already minimal, and warning "may not be minimal" there would be noise.
        failure.reductionStalled = report.reductionStalled
        let rendered = failure.render(format: context.logFormat)
        report.renderedFailure = rendered
        report.replaySeed = failure.encodedReplaySeed
        if context.suppressIssueReporting == false {
            reportError(
                rendered,
                fileID: context.fileID,
                filePath: context.filePath,
                line: context.line,
                column: context.column
            )
        }
        return .unreduced(value)
    }

    // MARK: - Reflecting

    // swiftlint:disable:next function_parameter_count
    /// Reduces a counterexample using reflection to seed the reducer.
    static func __reduceReflected<Output>(
        _ gen: Generator<Output>,
        value: Output,
        reductionConfig: Interpreters.ReducerConfiguration,
        visualize: Bool,
        suppressIssueReporting: Bool,
        includeDiff: Bool,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        property: @escaping @Sendable (Output) -> Bool,
        skipCounter: SkipCounter?,
        report: inout ExhaustReport,
        ledger: inout RunLedger
    ) throws -> Output? {
        let reflectStart = monotonicNanoseconds()
        let skipsBefore = skipCounter?.count ?? 0

        guard property(value) == false else {
            let message = "reflecting: value passes the property — reduction requires a failing value"
            if suppressIssueReporting == false {
                reportError(
                    message,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
            ledger.record(.reduction, invocations: 1, skips: (skipCounter?.count ?? 0) - skipsBefore)
            return nil
        }

        guard let tree = try Interpreters.reflect(gen, with: value) else {
            let message = "reflecting: could not reflect value into choice tree"
            if suppressIssueReporting == false {
                reportError(
                    message,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
            ledger.record(.reduction, invocations: 1, failures: 1)
            return nil
        }

        let reflectionEnd = monotonicNanoseconds()

        let countingProperty = PropertyOutcomeCounter(property)
        /// The initial failing probe plus every reduction probe, with the initial probe counted as a failure.
        func recordReductionOutcomes() {
            ledger.record(
                .reduction,
                invocations: 1 + countingProperty.invocations,
                skips: (skipCounter?.count ?? 0) - skipsBefore,
                failures: 1 + countingProperty.failures
            )
        }
        var reducerConfig = reductionConfig
        reducerConfig.visualize = visualize
        let reduceResult = try Interpreters.choiceGraphReduceCollectingStats(
            gen: gen,
            tree: tree,
            output: value,
            config: reducerConfig,
            property: { countingProperty($0) }
        )
        report.applyReductionStats(reduceResult.stats)

        if case let .reduced(reducedSequence, _, reducedValue) = reduceResult.outcome {
            var failure = PropertyTestFailure(
                counterexample: reducedValue,
                original: value,
                seed: nil,
                iteration: 1,
                phaseBudget: 1,
                blueprint: reducedSequence.shortString,
                propertyInvocations: countingProperty.invocations
            )
            failure.replayHint = "No replay seed — counterexample found via reflection."
            failure.includeDiff = includeDiff
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
            recordReductionOutcomes()
            if suppressIssueReporting == false {
                reportError(
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
            seed: nil,
            iteration: 1,
            phaseBudget: 1,
            blueprint: nil,
            propertyInvocations: countingProperty.invocations
        )
        failure.replayHint = "No replay seed — counterexample found via reflection."
        failure.reductionProducedNoImprovement = true
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
        recordReductionOutcomes()
        if suppressIssueReporting == false {
            reportError(
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

    /// Returns whether an error thrown from a property closure is a skip marker rather than a failure.
    static func isSkipError(_ error: any Error) -> Bool {
        if error is PropertySkip {
            return true
        }
        #if canImport(XCTest) && canImport(ObjectiveC)
            // XCTest is weak-linked here: in a plain executable (a fuzz driver, a benchmark loop) its metadata symbols are null, and evaluating `error is XCTSkip` unguarded jumps through the null metadata pointer and kills the process on the first thrown property error.
            if #_hasSymbol(XCTSkip.self), error is XCTSkip {
                return true
            }
        #elseif canImport(XCTest)
            if error is XCTSkip {
                return true
            }
        #endif
        return false
    }

    /// Wraps a throwing `Void`-returning closure into `(Output) -> Bool` via try/catch.
    ///
    /// A thrown skip marker (``PropertySkip`` or `XCTSkip`) counts as a pass and is tallied into `skipCounter`, so the run can warn on a high skip rate and fail when every invocation was skipped.
    static func wrapDetectionProperty<Output>(
        _ detection: @escaping @Sendable (Output) throws -> Void,
        countingSkipsInto skipCounter: SkipCounter? = nil
    ) -> @Sendable (Output) -> Bool {
        { value in
            do {
                try detection(value)
                return true
            } catch {
                if isSkipError(error) {
                    skipCounter?.increment()
                    return true
                }
                return false
            }
        }
    }

    /// Bridges an async Bool-returning property to a synchronous one via ``blockingAwait(_:)``.
    static func bridgeAsyncProperty<Output>(
        _ property: @escaping @Sendable (Output) async throws -> Bool,
        countingSkipsInto skipCounter: SkipCounter? = nil
    ) -> @Sendable (Output) -> Bool {
        { value in
            let valueBox = UnsafeSendableBox(value)
            return blockingAwait {
                do {
                    return try await property(valueBox.value)
                } catch {
                    if isSkipError(error) {
                        skipCounter?.increment()
                        return true
                    }
                    return false
                }
            }
        }
    }

    /// Bridges an async Void-returning detection closure to a synchronous Bool via ``blockingAwait(_:)``.
    static func bridgeAsyncDetection<Output>(
        _ detection: @escaping @Sendable (Output) async throws -> Void,
        countingSkipsInto skipCounter: SkipCounter? = nil
    ) -> @Sendable (Output) -> Bool {
        { value in
            let valueBox = UnsafeSendableBox(value)
            return blockingAwait {
                do {
                    try await detection(valueBox.value)
                } catch {
                    if isSkipError(error) {
                        skipCounter?.increment()
                        return true
                    }
                    return false
                }
                return true
            }
        }
    }
}
