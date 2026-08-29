import ExhaustGenerators
import IssueReporting

#if canImport(Testing) && canImport(ObjectiveC)
    @_weakLinked import Testing
#elseif canImport(Testing)
    import Testing
#endif

// MARK: - Platform-Routed Issue Reporting

//
// The reporting chokepoints (reportError, reportWarning, reportConfiguredIssue) and the DeferredIssueSink live in ExhaustGenerators, the app-safe target, so generator code can report without pulling Testing into an app's module scan. The forwarders below keep every reporting site in this module compiling unqualified without a per-file `import ExhaustGenerators`.

typealias DeferredIssueSink = ExhaustGenerators.DeferredIssueSink

func reportError(
    _ message: String,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    ExhaustGenerators.reportError(message, fileID: fileID, filePath: filePath, line: line, column: column)
}

func reportWarning(
    _ message: String,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    ExhaustGenerators.reportWarning(message, fileID: fileID, filePath: filePath, line: line, column: column)
}

func reportConfiguredIssue(
    _ message: String,
    severity: IssueSeverity,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    ExhaustGenerators.reportConfiguredIssue(
        message,
        severity: severity,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
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

/// Which test framework is actually running, asking Swift Testing before trusting the fallback.
///
/// ``TestContext/current`` reports `.xcTest` whenever Swift Testing's current test is not visible to it — it is a fallback, not a positive identification. Measured in a consumer package, that fallback fires unconditionally: a plain synchronous `@Test` body with `Test.current` set still resolved to `.xcTest`, as did an async body and a child task. Routing on it therefore sends Swift Testing runs down the XCTest path, where `XCTContext.runActivity` is main-actor only.
///
/// Reading `Test.current` answers the question directly. On Apple platforms the `Testing` import is `@_weakLinked`, so the read is guarded by `#_hasSymbol`: a process without Testing loaded skips it and falls back rather than faulting on a null symbol.
enum ActiveTestFramework {
    case swiftTesting
    case xcTest
    case none

    static var current: ActiveTestFramework {
        #if canImport(Testing)
            if #_hasSymbol(Test.current), Test.current != nil {
                return .swiftTesting
            }
        #endif
        switch TestContext.current {
            #if canImport(Testing)
                case .swiftTesting:
                    return .swiftTesting
            #endif
            case .xcTest:
                return .xcTest
            default:
                return .none
        }
    }
}
