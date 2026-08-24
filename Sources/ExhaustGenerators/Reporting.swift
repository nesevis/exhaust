import IssueReporting

#if canImport(Testing) && !canImport(ObjectiveC)
    import Testing
#endif

// MARK: - Platform-Routed Issue Reporting

//
// IssueReporting's swift-testing routing only supports Apple platforms (probed 2026-07-06 against 1.10.1: no reportIssue call is recorded at any severity on Linux, while Testing.Issue.record in the same process records correctly). Every reporting site in the Exhaust and ExhaustGenerators modules routes through the functions below so the platform split lives in one place.
//
// This file lives in ExhaustGenerators, the app-safe target: on Apple platforms it never imports Testing, so importing the module from an app target does not require test-framework search paths. The non-Apple direct-record branch keeps its Testing import, which resolves from the toolchain there.

/// Collects issues recorded on a GCD worker for replay on the test task.
///
/// Issue recording resolves the current test from task-locals that a GCD worker does not carry, so a report recorded there misroutes: IssueReporting misdetects the context as XCTest, calls `_XCTFail` with no test case to attach to, and the report surfaces as a runtime warning instead of failing the test. `__ExhaustRuntime.dispatchToGCD` binds a sink via ``current`` around every dispatched body, ``reportError(_:fileID:filePath:line:column:)`` and ``reportWarning(_:fileID:filePath:line:column:)`` record into it instead of reporting live, and the hop replays the collected issues on the test task after its continuation resumes. Reporting placement inside a dispatched body therefore cannot misroute, regardless of how an entry point is structured.
///
/// Marked `@unchecked Sendable` for the same reason `CapturedDiagnostics` is: the dispatched body appends on the GCD worker, and the hop replays only after its continuation resumes, so no access is ever concurrent. Tasks spawned by the body through the sync-async bridge run while the GCD worker blocks on the bridge semaphore, which preserves that serialization.
package final class DeferredIssueSink: @unchecked Sendable {
    /// The sink bound for the current GCD-dispatched body, or nil to report live.
    @TaskLocal package static var current: DeferredIssueSink?

    /// One recorded issue with the source location it was recorded against.
    private struct Entry {
        let severity: IssueSeverity
        let message: String
        let fileID: StaticString
        let filePath: StaticString
        let line: UInt
        let column: UInt
    }

    private var entries: [Entry] = []

    package init() {}

    /// Records one issue for later replay, preserving the location the reporting site supplied.
    package func record(
        _ severity: IssueSeverity,
        _ message: String,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        entries.append(Entry(
            severity: severity,
            message: message,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        ))
    }

    /// Replays the collected issues through the live reporting functions. Call on the test task, outside any ``current`` binding.
    package func replay() {
        for entry in entries {
            reportConfiguredIssue(
                entry.message,
                severity: entry.severity,
                fileID: entry.fileID,
                filePath: entry.filePath,
                line: entry.line,
                column: entry.column
            )
        }
    }
}

/// Reports a test-failing issue through IssueReporting on Apple platforms, and additionally directly through swift-testing elsewhere.
///
/// On Apple platforms `reportIssue` handles both custom reporters and swift-testing delivery in one call. IssueReporting's swift-testing routing only supports Apple platforms, so on Linux two calls are needed: `reportIssue` delivers to custom reporters installed via `withIssueReporters`, and `Issue.record` delivers to swift-testing directly. Without the direct path a failure whose only reporting channel is `reportIssue` passes silently on Linux. Outside a swift-testing context the direct path is unavailable, so the fallback remains `reportIssue` alone.
package func reportError(
    _ message: String,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    if let sink = DeferredIssueSink.current {
        sink.record(.error, message, fileID: fileID, filePath: filePath, line: line, column: column)
        return
    }
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

/// Routes a user-configured severity to ``reportError(_:fileID:filePath:line:column:)`` or ``reportWarning(_:fileID:filePath:line:column:)``.
///
/// `#examine` checks carry a per-check severity setting, so their reporting site cannot pick a function at compile time.
package func reportConfiguredIssue(
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
package func reportWarning(
    _ message: String,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    if let sink = DeferredIssueSink.current {
        sink.record(.warning, message, fileID: fileID, filePath: filePath, line: line, column: column)
        return
    }
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
