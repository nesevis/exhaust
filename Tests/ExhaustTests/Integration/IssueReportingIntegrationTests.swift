import ExhaustCore
import Foundation
import IssueReporting
import Testing
@testable import Exhaust

@Suite("Issue reporting integration")
struct IssueReportingIntegrationTests {
    @Test("Issue routing preserves severity and source location")
    func issueRoutingPreservesSeverityAndSourceLocation() {
        let reporter = RecordingIssueReporter()
        absorbingDirectTestingIssues {
            withIssueReporters([reporter]) {
                reportError(
                    "error message",
                    fileID: "IssueReporting/Fixture.swift",
                    filePath: "/tmp/Fixture.swift",
                    line: 41,
                    column: 7
                )
                reportWarning(
                    "warning message",
                    fileID: "IssueReporting/Fixture.swift",
                    filePath: "/tmp/Fixture.swift",
                    line: 43,
                    column: 9
                )
            }
        }

        #expect(reporter.issues == [
            RecordedIssue(
                message: "error message",
                severity: .error,
                fileID: "IssueReporting/Fixture.swift",
                filePath: "/tmp/Fixture.swift",
                line: 41,
                column: 7
            ),
            RecordedIssue(
                message: "warning message",
                severity: .warning,
                fileID: "IssueReporting/Fixture.swift",
                filePath: "/tmp/Fixture.swift",
                line: 43,
                column: 9
            ),
        ])
    }

    @Test("Property issue suppression does not alter failure detection")
    func propertyIssueSuppressionDoesNotAlterFailureDetection() {
        let reporter = RecordingIssueReporter()
        let result = withIssueReporters([reporter]) {
            #exhaust(
                #gen(.just(0)),
                .suppress(.issueReporting),
                .budget(.custom(screening: 0, sampling: 1))
            ) { _ in
                false
            }
        }

        #expect(result == 0)
        #expect(reporter.issues.isEmpty)
    }

    @Test("An escape during recovery reports only the escaped-work diagnosis")
    func recoveryEscapeDoesNotReportAPointlessRun() {
        var report = FuzzReport.empty(termination: .uncontainedAsyncWork, seed: 1)
        report = FuzzReport(
            clusters: [],
            unreducedFailureCounts: [:],
            termination: .uncontainedAsyncWork,
            seed: 1,
            attempts: report.attempts,
            invocations: FuzzReport.Invocations(
                search: 0,
                prune: 0,
                reduction: 0,
                normalization: 0,
                classification: 0,
                recovery: 1,
                diagnostic: 0,
                pruneIdentitySkips: 0
            ),
            coverage: FuzzReport.Coverage(
                corpusEntryCount: 0,
                parentCount: 0,
                parentProfile: .empty,
                coveredEdges: 0,
                instrumentedEdges: 16,
                singletons: 0,
                doubletons: 0,
                tripletons: 0,
                quadrupletons: 0,
                incidenceTotal: 0,
                incidenceSamples: 0,
                offLaneHits: 0
            ),
            timing: FuzzReport.Timing(
                elapsed: .nanoseconds(1),
                lastDiscovery: .zero,
                property: .nanoseconds(1),
                screeningOverhead: .zero,
                samplingOverhead: .zero,
                mutationOverhead: .zero,
                reduction: .zero,
                other: .zero,
                testingOverheadFraction: 0
            )
        )
        report.recordCrashResume()
        let reporter = RecordingIssueReporter()

        absorbingDirectTestingIssues {
            withIssueReporters([reporter]) {
                __ExhaustRuntime.reportFuzzIssues(
                    report: report,
                    suppressIssueReporting: false,
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
            }
        }

        #expect(report.attempts.evaluated == 0)
        #expect(report.invocations.total == 1)
        #expect(reporter.issues.count == 1)
        #expect(reporter.issues.first?.message.contains("asynchronous work did not return under cancellation") == true)
        #expect(reporter.issues.contains { $0.message.contains("evaluated no new candidates") } == false)
        #expect(reporter.issues.contains { $0.message.contains("asserts nothing") } == false)
    }

    @Test("Explore assertion rerun is counted as one diagnostic invocation")
    func exploreAssertionRerunIsCountedAsDiagnosticInvocation() {
        let reporter = RecordingIssueReporter()
        let directions: [(String, @Sendable (Int) -> Bool)] = [("any", { _ in true })]
        let report = absorbingDirectTestingIssues {
            withIssueReporters([reporter]) {
                __ExhaustRuntime.__exploreExpect(
                    ReflectiveGenerator(Gen.just(0), isReflective: true),
                    settings: [
                        .budget(.custom(screening: 1, sampling: 1)),
                        .replay(42),
                    ],
                    directions: directions,
                    property: { _ in throw DiagnosticFailure() },
                    detection: { _ in throw DiagnosticFailure() }
                )
            }
        }

        #expect(report.result == 0)
        #expect(report.invocations.diagnostic == 1)
        #expect(report.propertyInvocations == report.invocations.total)
        #expect(reporter.issues.count == 1)
        #expect(reporter.issues.first?.message == "Reproduce: .replay(\"1A\")")
    }

    @Test("Explore Bool failure reports phase counts and a bare replay seed")
    func exploreBoolFailureReportsPhaseCountsAndBareReplaySeed() {
        let reporter = RecordingIssueReporter()
        let directions: [(String, @Sendable (Int) -> Bool)] = [("any", { _ in true })]
        let report = absorbingDirectTestingIssues {
            withIssueReporters([reporter]) {
                __ExhaustRuntime.__explore(
                    ReflectiveGenerator(Gen.just(0), isReflective: true),
                    settings: [
                        .budget(.custom(screening: 1, sampling: 1)),
                        .replay(42),
                    ],
                    directions: directions,
                    property: { _ in false }
                )
            }
        }

        let message = reporter.issues.first?.message ?? ""
        #expect(report.result == 0)
        #expect(reporter.issues.count == 1)
        #expect(message.contains("Property failed after \(report.propertyInvocations) property invocations (seed 1A)"))
        #expect(message.contains("  Warm-up: \(report.invocations.warmup)"))
        #expect(message.contains("  Regression: \(report.invocations.regression)"))
        #expect(message.contains("  Directed sampling: \(report.invocations.directedSampling)/1"))
        #expect(message.contains("  Reduction: \(report.invocations.reduction)"))
        #expect(message.contains("  Diagnostic: 0"))
        #expect(message.contains("Reproduce: .replay(\"1A\")"))
    }

    @Test("Async explore assertion rerun is counted as one diagnostic invocation")
    func asyncExploreAssertionRerunIsCountedAsDiagnosticInvocation() async {
        let reporter = RecordingIssueReporter()
        let directions: [(String, @Sendable (Int) -> Bool)] = [("any", { _ in true })]
        let report = await absorbingDirectTestingIssues(isIntermittent: true) {
            await withIssueReporters([reporter]) {
                await __ExhaustRuntime.__exploreExpectAsync(
                    ReflectiveGenerator(Gen.just(0), isReflective: true),
                    settings: [
                        .budget(.custom(screening: 1, sampling: 1)),
                        .replay(42),
                    ],
                    directions: directions,
                    property: { _ in throw DiagnosticFailure() },
                    detection: { _ in throw DiagnosticFailure() }
                )
            }
        }

        #expect(report.result == 0)
        #expect(report.invocations.diagnostic == 1)
        #expect(report.propertyInvocations == report.invocations.total)
    }

    #if !canImport(ObjectiveC)
        @Test("Non-Apple error routing still notifies custom issue reporters")
        func nonAppleErrorRoutingNotifiesCustomReporter() {
            let reporter = RecordingIssueReporter()
            withKnownIssue {
                withIssueReporters([reporter]) {
                    reportError(
                        "cross-platform error",
                        fileID: "IssueReporting/LinuxFixture.swift",
                        filePath: "/tmp/LinuxFixture.swift",
                        line: 11,
                        column: 5
                    )
                }
            }

            #expect(reporter.issues.count == 1)
        }
    #endif
}

/// Runs `body`, absorbing the issues Exhaust's non-Apple reporting shim records directly with swift-testing.
///
/// On Apple platforms `withIssueReporters` redirects error reporting away from swift-testing, so `body` runs bare. On non-Apple platforms the shim's direct `Issue.record` delivery cannot be redirected, so this helper absorbs those records as known issues.
private func absorbingDirectTestingIssues<Value>(
    isIntermittent: Bool = false,
    _ body: () -> Value
) -> Value {
    #if canImport(ObjectiveC)
        return body()
    #else
        var captured: Value?
        withKnownIssue(isIntermittent: isIntermittent) {
            captured = body()
        }
        guard let captured else {
            fatalError("withKnownIssue did not run its body")
        }
        return captured
    #endif
}

/// Runs async `body`, absorbing the issues Exhaust's non-Apple reporting shim records directly with swift-testing.
///
/// The direct record happens on a bridged thread where the swift-testing test association may not propagate, so async callers pass `isIntermittent: true`.
private func absorbingDirectTestingIssues<Value>(
    isIntermittent: Bool = false,
    _ body: () async -> Value
) async -> Value {
    #if canImport(ObjectiveC)
        return await body()
    #else
        var captured: Value?
        await withKnownIssue(isIntermittent: isIntermittent) {
            captured = await body()
        }
        guard let captured else {
            fatalError("withKnownIssue did not run its body")
        }
        return captured
    #endif
}

private struct RecordedIssue: Equatable {
    let message: String
    let severity: IssueSeverity
    let fileID: String
    let filePath: String
    let line: UInt
    let column: UInt
}

private struct DiagnosticFailure: Error {}

private final class RecordingIssueReporter: IssueReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedIssue] = []

    var issues: [RecordedIssue] {
        lock.withLock { storage }
    }

    func reportIssue(
        _ message: @autoclosure () -> String?,
        severity: IssueSeverity,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        let issue = RecordedIssue(
            message: message() ?? "",
            severity: severity,
            fileID: "\(fileID)",
            filePath: "\(filePath)",
            line: line,
            column: column
        )
        lock.withLock {
            storage.append(issue)
        }
    }
}
