// Reduction dispatch and reflecting: path for the #exhaust pipeline.

import ExhaustCore
import Foundation
import IssueReporting

#if canImport(XCTest) && canImport(ObjectiveC)
    @preconcurrency @_weakLinked import XCTest
#elseif canImport(XCTest)
    @preconcurrency import XCTest
#endif

package extension __ExhaustRuntime {
    // MARK: - Reflecting

    // swiftlint:disable:next function_parameter_count
    /// Reduces a counterexample using reflection to seed the reducer.
    static func __reduceReflected<Output>(
        _ gen: Generator<Output>,
        value: Output,
        reductionConfig: Interpreters.ReducerConfiguration,
        deadlineNanoseconds: UInt64? = nil,
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

        var reducerConfig = reductionConfig
        reducerConfig.visualize = visualize
        let run = ReductionRunner.reduce(
            gen,
            tree: tree,
            value: value,
            configuration: reducerConfig,
            runDeadlineNanoseconds: deadlineNanoseconds,
            property: property
        )
        if run.started {
            report.applyReductionStats(run.stats)
        } else {
            report.reductionWasCapped = true
        }
        /// The initial failing probe plus every reduction probe, with the initial probe counted as a failure.
        func recordReductionOutcomes() {
            ledger.record(
                .reduction,
                invocations: 1 + run.propertyInvocations,
                skips: (skipCounter?.count ?? 0) - skipsBefore,
                failures: 1 + run.propertyFailures
            )
        }

        if run.improved {
            let reducedValue = run.value
            var failure = PropertyTestFailure(
                counterexample: reducedValue,
                original: value,
                seed: nil,
                iteration: 1,
                phaseBudget: 1,
                blueprint: run.sequence.shortString,
                propertyInvocations: run.propertyInvocations
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
            propertyInvocations: run.propertyInvocations
        )
        failure.replayHint = "No replay seed — counterexample found via reflection."
        // Reflected inputs report only that nothing improved: a user-supplied example is often already minimal, and a stall warning there would be noise.
        failure.reductionNote = report.reductionWasCapped ? .timeLimit : .noImprovement
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
