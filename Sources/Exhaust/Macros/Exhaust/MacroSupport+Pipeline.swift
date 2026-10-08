// Test-framework side of the `__exhaust` pipeline: lane suppression, diagnostic reporting, and failure rendering around ``PropertyTestRunner``.

import ExhaustCore
import Foundation
import IssueReporting

package extension __ExhaustRuntime {
    // MARK: - Lane Suppression

    /// Runs each parallel sampling lane under its own suppression scope, so a worker thread absorbs and records what the run's own scope cannot reach.
    ///
    /// A known-issue scope and the issue sink are both task-local, and a `concurrentPerform` worker inherits neither: without this an assertion the detection rewrite never saw would record against no test at all, and Exhaust's own reports from the lane would misroute the way they do on any GCD worker. Each lane's sink is collected rather than replayed on the lane, because replaying belongs on the thread that started the lanes, in ``lanesJoined()``.
    ///
    /// Only a run with an absorbed-issue ledger gets one. A `Bool` property runs without a suppression scope, and adding one to its lanes would swallow issues that currently surface.
    final class AbsorbedIssueLaneScope: SamplingLaneScope {
        private let ledger: AbsorbedIssues
        private let sinks = SendableBox<[DeferredIssueSink]>([])

        init(ledger: AbsorbedIssues) {
            self.ledger = ledger
        }

        package func run<Result>(_ body: () -> Result) -> Result {
            let sink = DeferredIssueSink()
            sinks.withValue { $0.append(sink) }
            return DeferredIssueSink.$current.withValue(sink) {
                ledger.absorbing(body)
            }
        }

        package func lanesJoined() {
            for sink in sinks.value {
                sink.replay()
            }
        }
    }

    // MARK: - Diagnostics

    /// Reports the runner's diagnostics in the order the phases produced them, recording their effects in the report.
    static func reportDiagnostics( // swiftlint:disable:this function_parameter_count
        _ diagnostics: [PropertyTestRunner.Diagnostic],
        samplingBudget: UInt64,
        suppressIssueReporting: Bool,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        report: inout ExhaustReport
    ) {
        for diagnostic in diagnostics {
            switch diagnostic {
                case let .generationError(error):
                    report.generationErrorOccurred = true
                    reportError(
                        localizedErrorMessage(error),
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                case let .filterObservations(observations):
                    emitFilterWarnings(observations, suppressIssueReporting: suppressIssueReporting)
                case let .uniqueExhaustion(iterations):
                    recordUniqueExhaustion(
                        iterations: iterations,
                        samplingBudget: samplingBudget,
                        suppressIssueReporting: suppressIssueReporting,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                        report: &report
                    )
                case let .screeningReplayRowNotTested(row):
                    reportError(
                        "Screening replay never tested row \(row + 1): the covering array under the current budget ends before it. Run value screening replays under the budget the failure was discovered with.",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
            }
        }
    }

    /// Records a unique-exhaustion truncation in the report and surfaces it as a warning.
    ///
    /// Exhaustion inside the interpreter only logs at warning level, which the default configuration never prints, so a run that executed a fraction of its budget would otherwise pass with no signal.
    private static func recordUniqueExhaustion( // swiftlint:disable:this function_parameter_count
        iterations: Int,
        samplingBudget: UInt64,
        suppressIssueReporting: Bool,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        report: inout ExhaustReport
    ) {
        report.runTruncatedByUniqueExhaustion = true
        let message = "A unique site exhausted its retry budget after \(iterations) of \(samplingBudget) sampling iterations. The remaining iterations did not run."
        report.uniqueExhaustionWarning = message
        if suppressIssueReporting == false {
            reportWarning(
                message,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
    }

    /// Emits filter validity warnings when the rejection rate exceeds 98%.
    private static func emitFilterWarnings(
        _ observations: [UInt64: FilterObservation],
        suppressIssueReporting: Bool
    ) {
        guard suppressIssueReporting == false else { return }
        for (_, observation) in observations where observation.attempts >= 20 {
            if observation.validityRate < 0.02, let location = observation.sourceLocation {
                reportWarning(
                    "Filter validity rate \(String(format: "%.1f", observation.validityRate * 100))% over \(observation.attempts) attempts. Generation is spending most of its time on rejection. Consider widening the input range or relaxing the predicate.",
                    fileID: location.fileID,
                    filePath: location.filePath,
                    line: location.line,
                    column: location.column
                )
            }
        }
    }

    // MARK: - Failure Reporting

    /// Renders a failure into the report and reports it, unless issue reporting is suppressed.
    ///
    /// Reads the report's reduction statistics, so the run's statistics must already be applied, and the run's ledger for invocation totals.
    static func reportFailure<Output>( // swiftlint:disable:this function_parameter_count
        _ failure: PropertyTestRunner.Failure<Output>,
        ledger: RunLedger,
        includeDiff: Bool,
        logFormat: LogFormat,
        suppressIssueReporting: Bool,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        report: inout ExhaustReport
    ) {
        var replayHint: String?
        if let screeningReplaySeed = failure.screeningReplaySeed {
            report.replaySeed = screeningReplaySeed
            replayHint = "Reproduce: .replay(\"\(screeningReplaySeed)\")"
        }
        let rendered: String
        if failure.improved, let reducedSequence = failure.reducedSequence {
            var testFailure = PropertyTestFailure(
                counterexample: failure.counterexample,
                original: failure.original,

                seed: failure.seed,
                iteration: failure.iteration,
                phaseBudget: failure.phaseBudget,
                blueprint: reducedSequence.shortString,
                propertyInvocations: ledger.totalInvocations,
                reducedSequence: reducedSequence
            )
            testFailure.replayHint = replayHint
            testFailure.reductionNote = ReductionNote(
                probes: report.reductionProbes,
                invocations: ledger.count(.reduction),
                stalledLeafCount: report.stalledLeafCount,
                anyAcceptanceOccurred: report.anyAcceptanceEverOccurred,
                producedNoImprovement: false,
                wasCapped: report.reductionWasCapped
            )
            testFailure.includeDiff = includeDiff
            rendered = testFailure.render(format: logFormat)
            report.renderedFailure = rendered
            report.replaySeed = testFailure.encodedReplaySeed
        } else {
            // Reduction could not improve, or the deadline left no time to start it. Either way, report the original failure.
            var testFailure = PropertyTestFailure(
                counterexample: failure.counterexample,
                original: nil as Output?,
                seed: failure.seed,
                iteration: failure.iteration,
                phaseBudget: failure.phaseBudget,
                blueprint: nil,
                propertyInvocations: ledger.totalInvocations
            )
            testFailure.replayHint = replayHint
            testFailure.reductionNote = ReductionNote(
                probes: report.reductionProbes,
                invocations: ledger.count(.reduction),
                stalledLeafCount: report.stalledLeafCount,
                anyAcceptanceOccurred: report.anyAcceptanceEverOccurred,
                producedNoImprovement: true,
                wasCapped: report.reductionWasCapped
            )
            rendered = testFailure.render(format: logFormat)
            report.renderedFailure = rendered
            report.replaySeed = testFailure.encodedReplaySeed
        }
        if suppressIssueReporting == false {
            reportError(
                rendered,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
    }
}
