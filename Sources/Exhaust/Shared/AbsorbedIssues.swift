import ExhaustCore
import ExhaustGenerators
import Foundation
import IssueReporting

#if canImport(Testing) && canImport(ObjectiveC)
    @_weakLinked import Testing
#elseif canImport(Testing)
    import Testing
#endif

#if canImport(XCTest) && canImport(ObjectiveC)
    @preconcurrency @_weakLinked import XCTest
#endif

// MARK: - Absorbed Issues

/// One issue a suppression scope absorbed, kept so the caller can decide whether it must still fail the run.
package struct AbsorbedIssue: Sendable {
    /// Which reporting API produced the issue.
    ///
    /// Only ``expectation`` identifies an assertion the detection rewrite never saw. Everything Exhaust itself reports arrives as ``recorded``, as does a bare `Issue.record` in user code.
    package enum Origin: Sendable, Equatable {
        case expectation
        case recorded
    }

    package let origin: Origin
    package let description: String

    /// The assertion's own `fileID:line:column`, or nil when the framework supplied no location.
    ///
    /// Carried as text rather than as a location the reporting chokepoints accept: those take `StaticString`, which a location read at runtime cannot be. A caller reporting one of these therefore names the location in its message and reports against its own call site.
    package let location: String?
}

/// Collects the issues a suppression scope absorbs, across every thread that scope covers.
///
/// A pipeline scope absorbs everything recorded inside it, which is what keeps screening, sampling, and reduction from reporting a failure per invocation. An assertion the detection rewrite never saw is absorbed the same way, and the pipeline reads that invocation as a pass, so without recording what was absorbed the whole run passes silently. The caller inspects ``expectationFailures`` once the pipeline is done and decides what still has to fail.
package final class AbsorbedIssues: Sendable {
    /// The framework resolved when this ledger was created, for scopes bound on a thread that cannot resolve it themselves.
    ///
    /// `Test.current` is task-local and a GCD worker does not carry it, so ``ActiveTestFramework/current`` read on a worker reports `.xcTest` for a Swift Testing run. Resolving once, on the thread that starts the run, and reusing it through ``absorbing(_:)`` keeps every worker scope on the framework that is actually running.
    package let framework: ActiveTestFramework

    private let storage = SendableBox<[AbsorbedIssue]>([])

    package init(framework: ActiveTestFramework = .current) {
        self.framework = framework
    }

    /// Records one absorbed issue. Called from the matcher, on whichever thread recorded the issue.
    package func record(_ issue: AbsorbedIssue) {
        storage.withValue { $0.append(issue) }
    }

    /// The absorbed `#expect` and `#require` failures, in the order they were recorded.
    package var expectationFailures: [AbsorbedIssue] {
        storage.value.filter { $0.origin == .expectation }
    }

    /// Binds a suppression scope on the calling thread, recording into this ledger through the framework it resolved at creation.
    package func absorbing<Result>(isIntermittent: Bool = true, _ body: () -> Result) -> Result {
        withAbsorbedIssues(into: self, isIntermittent: isIntermittent, framework: framework, body)
    }
}

// MARK: - Suppression Scope

/// Runs `body` with the issues it records absorbed, recording each one into `ledger`.
///
/// This is the single suppression scope for every pipeline: it replaces a direct `withExpectedIssue`, which cannot resolve the framework on a GCD worker (`Test.current` is nil there and `TestContext` then reports `.xcTest` for a Swift Testing run), and a direct `withKnownIssue`, which assumes Swift Testing is the framework running. Routing on ``ActiveTestFramework`` picks the matching absorb-and-observe API for each: Swift Testing's known-issue matcher, XCTest's expected-failure issue matcher, or IssueReporting's `withExpectedIssue` outside a test, where nothing can be observed and the ledger stays empty.
///
/// The scope binds on the calling thread and covers what that thread runs. An unstructured `Task` inherits the binding, so the sync-async bridge needs no second scope, but a body that hands work to another thread and waits does: that thread inherits nothing, and its issues escape absorption entirely. Bind again inside such work through ``AbsorbedIssues/absorbing(isIntermittent:_:)``.
///
/// - Parameters:
///   - ledger: Where to record what the scope absorbs. Pass nil for a scope whose caller acts on the absorbed issues by other means.
///   - isIntermittent: Whether a scope that absorbs nothing is acceptable. Passing false reports an issue when the body records none.
///   - framework: The framework to route to. Defaults to resolving on the calling thread, which is only correct on a thread carrying the test's task-locals.
package func withAbsorbedIssues<Result>(
    into ledger: AbsorbedIssues? = nil,
    isIntermittent: Bool = true,
    framework: ActiveTestFramework = .current,
    _ body: () -> Result
) -> Result {
    // Every branch below runs `body` exactly once before returning, so the unwrap at the end always finds a value.
    var result: Result?

    switch framework {
        #if canImport(Testing)
            case .swiftTesting:
                withKnownIssue(isIntermittent: isIntermittent) {
                    result = body()
                } matching: { issue in
                    ledger?.record(AbsorbedIssue(issue))
                    return true
                }
        #endif
        #if canImport(XCTest) && canImport(ObjectiveC)
            case .xcTest:
                result = XCTExpectFailure(
                    strict: isIntermittent == false,
                    failingBlock: { body() },
                    issueMatcher: { issue in
                        ledger?.record(AbsorbedIssue(issue))
                        return true
                    }
                )
        #endif
        default:
            withExpectedIssue(isIntermittent: isIntermittent) {
                result = body()
            }
    }

    return result!
}

/// Runs a pipeline `body` with Exhaust's own reports deferred and everything the property records absorbed into `ledger`.
///
/// The two halves belong together. Absorption alone would swallow a generation or filter error the same way it swallows a per-invocation assertion, leaving a malfunctioning run silent; deferring Exhaust's own reports through ``DeferredIssueSink`` moves them past the scope, where they surface, and leaves the ledger holding only what the property itself recorded.
package func withPipelineSuppression<Result>(into ledger: AbsorbedIssues, _ body: () -> Result) -> Result {
    let sink = DeferredIssueSink()
    let result = DeferredIssueSink.$current.withValue(sink) {
        ledger.absorbing(body)
    }
    sink.replay()
    return result
}

// MARK: - Framework Issue Adapters

#if canImport(Testing)
    extension AbsorbedIssue {
        /// Adapts a Swift Testing issue, keeping the assertion's own source location rather than the scope's.
        init(_ issue: Testing.Issue) {
            origin = switch issue.kind {
                case .expectationFailed:
                    .expectation
                default:
                    .recorded
            }
            description = "\(issue.kind)"
            location = issue.sourceLocation.map { "\($0.fileID):\($0.line):\($0.column)" }
        }
    }
#endif

#if canImport(XCTest) && canImport(ObjectiveC)
    extension AbsorbedIssue {
        /// Adapts an XCTest issue.
        ///
        /// A Swift Testing `#expect` failure never arrives here: it records through Swift Testing, which an XCTest expected-failure scope does not see. Under an XCTest host the ledger therefore reports XCTest's own assertion failures and nothing else.
        init(_ issue: XCTIssue) {
            origin = switch issue.type {
                case .assertionFailure:
                    .expectation
                default:
                    .recorded
            }
            description = issue.compactDescription
            location = issue.sourceCodeContext.location.map {
                "\($0.fileURL.lastPathComponent):\($0.lineNumber)"
            }
        }
    }
#endif
