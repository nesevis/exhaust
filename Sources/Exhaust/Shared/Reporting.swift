import IssueReporting

#if canImport(Testing)
    @_weakLinked import Testing
#endif

// MARK: - Platform-Routed Issue Reporting

//
// IssueReporting's dynamic routing to swift-testing does not function on Linux (probed 2026-07-06 against 1.10.1: no reportIssue call is recorded at any severity, while Testing.Issue.record in the same process records correctly). Every reporting site in this module routes through the two functions below so the platform split lives in one place.

/// Reports a test-failing issue through IssueReporting on Apple platforms, and directly through swift-testing elsewhere.
///
/// Without the direct path, a failure whose only reporting channel is `reportIssue` — a Bool-style property failure, a contract failure report — passes silently on Linux. Outside a swift-testing context the direct path is unavailable, so the fallback remains `reportIssue`.
func reportError(
    _ message: String,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    #if canImport(ObjectiveC)
        reportIssue(message, fileID: fileID, filePath: filePath, line: line, column: column)
    #else
        #if canImport(Testing)
            if Test.current != nil {
                Issue.record(
                    Comment(rawValue: message),
                    sourceLocation: SourceLocation(
                        fileID: "\(fileID)",
                        filePath: "\(filePath)",
                        line: Int(line),
                        column: Int(column)
                    )
                )
                return
            }
        #endif
        reportIssue(message, fileID: fileID, filePath: filePath, line: line, column: column)
    #endif
}

/// Routes a user-configured severity to ``reportError(_:fileID:filePath:line:column:)`` or ``reportWarning(_:fileID:filePath:line:column:)``.
///
/// `#examine` checks carry a per-check severity setting, so their reporting site cannot pick a function at compile time.
func reportConfiguredIssue(
    _ message: String,
    severity: IssueSeverity,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    switch severity {
        case .warning:
            reportWarning(message, fileID: fileID, filePath: filePath, line: line, column: column)
        default:
            reportError(message, fileID: fileID, filePath: filePath, line: line, column: column)
    }
}

/// Reports a warning-severity diagnostic through IssueReporting on Apple platforms, and directly through swift-testing elsewhere.
///
/// Without the direct path, a warning whose only reporting channel is `reportIssue` is not recorded by swift-testing on Linux, so `withKnownIssue` cannot catch it. Outside a swift-testing context the direct path is unavailable, so the fallback remains `reportIssue` plus a printed line.
func reportWarning(
    _ message: String,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    #if canImport(ObjectiveC)
        reportIssue(
            message,
            severity: .warning,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    #else
        #if canImport(Testing)
            if Test.current != nil {
                Issue.record(
                    Comment(rawValue: message),
                    severity: .warning,
                    sourceLocation: SourceLocation(
                        fileID: "\(fileID)",
                        filePath: "\(filePath)",
                        line: Int(line),
                        column: Int(column)
                    )
                )
                return
            }
        #endif
        reportIssue(
            message,
            severity: .warning,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        print("warning: \(fileID):\(line): \(message)")
    #endif
}
