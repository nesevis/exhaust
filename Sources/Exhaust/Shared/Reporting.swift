import IssueReporting

#if canImport(Testing) && canImport(ObjectiveC)
    @_weakLinked import Testing
#elseif canImport(Testing)
    import Testing
#endif

// MARK: - Platform-Routed Issue Reporting

//
// IssueReporting's swift-testing routing only supports Apple platforms (probed 2026-07-06 against 1.10.1: no reportIssue call is recorded at any severity on Linux, while Testing.Issue.record in the same process records correctly). Every reporting site in this module routes through the functions below so the platform split lives in one place.

/// Reports a test-failing issue through IssueReporting on Apple platforms, and additionally directly through swift-testing elsewhere.
///
/// On Apple platforms `reportIssue` handles both custom reporters and swift-testing delivery in one call. IssueReporting's swift-testing routing only supports Apple platforms, so on Linux two calls are needed: `reportIssue` delivers to custom reporters installed via `withIssueReporters`, and `Issue.record` delivers to swift-testing directly. Without the direct path a failure whose only reporting channel is `reportIssue` passes silently on Linux. Outside a swift-testing context the direct path is unavailable, so the fallback remains `reportIssue` alone.
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
        reportIssue(message, fileID: fileID, filePath: filePath, line: line, column: column)
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
            }
        #endif
    #endif
}

/// Runs `body`, treating the issues it records as expected, through IssueReporting on Apple platforms and directly through swift-testing elsewhere.
///
/// IssueReporting's `withExpectedIssue` routes to swift-testing's `withKnownIssue` on Apple platforms only, so on other platforms swift-testing issues recorded inside `body` (from `#expect`/`#require` in a property closure, or from ``reportError(_:fileID:filePath:line:column:)``'s direct path) would surface as real test failures. There, when a swift-testing test is current, the direct `withKnownIssue` absorbs them instead — the same routing the async pipelines use. Outside a swift-testing context the fallback remains `withExpectedIssue`.
func withRoutedExpectedIssue(isIntermittent: Bool, _ body: () -> Void) {
    #if canImport(ObjectiveC)
        withExpectedIssue(isIntermittent: isIntermittent) {
            body()
        }
    #else
        #if canImport(Testing)
            if Test.current != nil {
                withKnownIssue(isIntermittent: isIntermittent) {
                    body()
                }
                return
            }
        #endif
        withExpectedIssue(isIntermittent: isIntermittent) {
            body()
        }
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
/// On Apple platforms `reportIssue` handles both custom reporters and swift-testing delivery in one call. IssueReporting's swift-testing routing only supports Apple platforms, so on Linux two calls are needed: `reportIssue` delivers to custom reporters installed via `withIssueReporters`, and `Issue.record(severity: .warning)` delivers to swift-testing directly. Outside a swift-testing context the direct path is unavailable, so the fallback remains `reportIssue` plus a printed line.
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
        reportIssue(
            message,
            severity: .warning,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
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
            } else {
                print("warning: \(fileID):\(line): \(message)")
            }
        #else
            print("warning: \(fileID):\(line): \(message)")
        #endif
    #endif
}
