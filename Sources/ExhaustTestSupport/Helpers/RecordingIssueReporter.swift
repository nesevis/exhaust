import ExhaustCore
import IssueReporting
import Testing

/// Captures diagnostics without redirecting them onto a different test task.
package final class RecordingIssueReporter: IssueReporter, Sendable {
    private let storage = SendableBox<[RecordedIssue]>([])

    package init() {}

    package var issues: [RecordedIssue] {
        storage.value
    }

    package func reportIssue(
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
        storage.withValue { $0.append(issue) }
    }
}

// MARK: - Captured Diagnostic

package struct RecordedIssue: Equatable, Sendable {
    package let message: String
    package let severity: IssueSeverity
    package let fileID: String
    package let filePath: String
    package let line: UInt
    package let column: UInt
    package let testID: String?

    package init(
        message: String,
        severity: IssueSeverity,
        fileID: String,
        filePath: String,
        line: UInt,
        column: UInt,
        testID: String? = Test.current.map { String(describing: $0.id) }
    ) {
        self.message = message
        self.severity = severity
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.column = column
        self.testID = testID
    }
}
