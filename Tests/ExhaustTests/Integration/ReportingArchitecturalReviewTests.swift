import Foundation
import IssueReporting
import Testing
@testable import Exhaust

@Suite("Reporting architectural review")
struct ReportingArchitecturalReviewTests {
    @Test("Report invocation totals include the final assertion rerun")
    func reportInvocationTotalsIncludeFinalAssertionRerun() throws {
        let invocationCounter = LockedCounter()
        let reportCapture = ReportCapture()

        withKnownIssue {
            #exhaust(
                #gen(.just(0)),
                .replay(42),
                .budget(.custom(screening: 0, sampling: 1)),
                .onReport { reportCapture.report = $0 }
            ) { _ in
                invocationCounter.increment()
                #expect(Bool(false))
            }
        }

        let report = try #require(reportCapture.report)
        #expect(report.propertyInvocations == invocationCounter.value)
    }

    @Test("Multiline command descriptions remain inside their command entry")
    func multilineCommandDescriptionsRemainInsideEntry() {
        var lines: [String] = []
        __ExhaustRuntime.renderCommandPartition(
            [(ScheduleMarker(rawValue: 1), MultilineCommand())],
            into: &lines
        )

        #expect(lines == [
            "Lane A:",
            "  1A. first line\n      second line",
            "",
        ])
    }

    @Test("Issue routing preserves severity and source location")
    func issueRoutingPreservesSeverityAndSourceLocation() {
        let reporter = RecordingIssueReporter()
        withIssueReporters([reporter]) {
            reportError(
                "error message",
                fileID: "Review/Fixture.swift",
                filePath: "/tmp/Fixture.swift",
                line: 41,
                column: 7
            )
            reportWarning(
                "warning message",
                fileID: "Review/Fixture.swift",
                filePath: "/tmp/Fixture.swift",
                line: 43,
                column: 9
            )
        }

        #expect(reporter.issues == [
            RecordedIssue(
                message: "error message",
                severity: .error,
                fileID: "Review/Fixture.swift",
                filePath: "/tmp/Fixture.swift",
                line: 41,
                column: 7
            ),
            RecordedIssue(
                message: "warning message",
                severity: .warning,
                fileID: "Review/Fixture.swift",
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

    @Test("JSONL failure rendering escapes arbitrary counterexamples")
    func jsonlFailureRenderingEscapesArbitraryCounterexamples() throws {
        let failure = PropertyTestFailure(
            counterexample: "quote: \"value\"\npath: C:\\temporary\\file",
            original: nil,
            seed: 42,
            iteration: 3,
            phaseBudget: 10,
            blueprint: nil,
            propertyInvocations: 4
        )

        let rendered = failure.render(format: .jsonl)
        let data = try #require(rendered.data(using: .utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["event"] as? String == "property_failed")
        #expect((object["counterexample"] as? String)?.contains("temporary") == true)
    }

    #if !canImport(ObjectiveC)
        @Test("Non-Apple error routing still notifies custom issue reporters")
        func nonAppleErrorRoutingNotifiesCustomReporter() {
            let reporter = RecordingIssueReporter()
            withKnownIssue {
                withIssueReporters([reporter]) {
                    reportError(
                        "cross-platform error",
                        fileID: "Review/LinuxFixture.swift",
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

private struct MultilineCommand: CustomStringConvertible {
    var description: String {
        "first line\nsecond line"
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}

private final class ReportCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ExhaustReport?

    var report: ExhaustReport? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private struct RecordedIssue: Equatable {
    let message: String
    let severity: IssueSeverity
    let fileID: String
    let filePath: String
    let line: UInt
    let column: UInt
}

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
