// Explore time: mode — coverage-guided soak runtime entry points.

import ExhaustCore
import Foundation
import IssueReporting

#if canImport(ObjectiveC)
    import ExhaustObjCSupport
#endif

#if canImport(XCTest) && canImport(ObjectiveC)
    @preconcurrency @_weakLinked import XCTest
#elseif canImport(XCTest)
    @preconcurrency import XCTest
#endif

#if canImport(Testing)
    #if canImport(ObjectiveC)
        @_weakLinked import Testing
    #else
        import Testing // swiftlint:disable:this duplicate_imports
    #endif
#endif

/// Once-per-process instrumentation presence check for `#explore(time:)`, with a test-only override.
///
/// Counter regions register during image loading, before main, so the first read is already final and caching it is sound. The override exists because the test suite both lacks real instrumentation and registers synthetic regions from other suites running in the same process — a test asserting on either outcome of this check must not depend on suite ordering.
package enum SprawlInstrumentationCheck {
    private static let cachedIsInstrumented: Bool = SancovRuntime.isInstrumented

    /// Test seam: forces the check's outcome. Reset to nil after use.
    package static let overrideForTesting = SendableBox<Bool?>(nil)

    /// Whether the process loaded at least one instrumented image.
    package static var isInstrumented: Bool {
        overrideForTesting.withValue { $0 } ?? cachedIsInstrumented
    }
}

@available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
public extension __ExhaustRuntime {
    // MARK: - Explore Time (Bool)

    /// Runs a coverage-guided `time:` soak with a Bool-returning property. Runtime target of `#explore(time:)`.
    @discardableResult
    static func __exploreTime<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: Duration,
        settings: [SprawlSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) throws -> Bool
    ) -> SprawlReport {
        let report = runExploreTimeCore(
            gen: refGen.gen,
            time: time,
            settings: settings,
            source: nil,
            configure: nil,
            property: wrapVerdictProperty(property)
        )
        reportSprawlIssues(
            report: report,
            suppressIssueReporting: sprawlSuppressesIssueReporting(settings),
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        recordSprawlAttachments(report: report)
        return report
    }

    // MARK: - Explore Time (Expect)

    /// Runs a coverage-guided `time:` soak with a Void/#expect/#require closure.
    ///
    /// The detection closure (the property with `#expect` rewritten to `#require`) records an issue on every failing attempt, and a soak deliberately keeps failing past the first failure, so the whole run executes inside `withExpectedIssue(isIntermittent:)`. The fault inventory is reported afterwards, outside that scope, so it surfaces as a real failure.
    @discardableResult
    static func __exploreTimeExpect<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: Duration,
        settings: [SprawlSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) throws -> Void,
        detection: @escaping @Sendable (Output) throws -> Void
    ) -> SprawlReport {
        // The source-located property closure is part of the macro contract but unused until the report can re-materialise reduced counterexamples and replay them for source-anchored issues.
        _ = property
        let verdictProperty = wrapVerdictDetection(detection)
        nonisolated(unsafe) var pipelineReport: SprawlReport?
        withExpectedIssue(isIntermittent: true) {
            pipelineReport = runExploreTimeCore(
                gen: refGen.gen,
                time: time,
                settings: settings,
                source: nil,
                configure: nil,
                property: verdictProperty
            )
        }
        let report = pipelineReport ?? .empty(termination: .budgetExhausted, seed: 0)
        reportSprawlIssues(
            report: report,
            suppressIssueReporting: sprawlSuppressesIssueReporting(settings),
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        recordSprawlAttachments(report: report)
        return report
    }

    // MARK: - Explore Time (Async)

    /// Runs a coverage-guided `time:` soak with an async Bool-returning property.
    @discardableResult
    static func __exploreTimeAsync<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: Duration,
        settings: [SprawlSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) async throws -> Bool
    ) async -> SprawlReport {
        let verdictProperty = bridgeAsyncVerdictProperty(property)
        let report = await dispatchToGCD(reserving: LaneReservation.single) {
            let report = runExploreTimeCore(
                gen: refGen.gen,
                time: time,
                settings: settings,
                source: nil,
                configure: nil,
                property: verdictProperty
            )
            reportSprawlIssues(
                report: report,
                suppressIssueReporting: sprawlSuppressesIssueReporting(settings),
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return report
        }
        recordSprawlAttachments(report: report)
        return report
    }

    // MARK: - Explore Time (Async Expect)

    /// Runs a coverage-guided `time:` soak with an async Void/#expect/#require closure.
    @discardableResult
    static func __exploreTimeExpectAsync<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: Duration,
        settings: [SprawlSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) async throws -> Void,
        detection: @escaping @Sendable (Output) async throws -> Void
    ) async -> SprawlReport {
        _ = property
        let verdictProperty = bridgeAsyncVerdictDetection(detection)
        let finalReport = await dispatchToGCD(reserving: LaneReservation.single) {
            nonisolated(unsafe) var pipelineReport: SprawlReport?
            // withExpectedIssue cannot be used on a GCD thread because Test.current is nil, causing TestContext to misdetect as .xcTest. Use withKnownIssue directly since the async path is always in a Swift Testing context.
            #if canImport(Testing)
                withKnownIssue(isIntermittent: true) {
                    pipelineReport = runExploreTimeCore(
                        gen: refGen.gen,
                        time: time,
                        settings: settings,
                        source: nil,
                        configure: nil,
                        property: verdictProperty
                    )
                }
            #else
                pipelineReport = runExploreTimeCore(
                    gen: refGen.gen,
                    time: time,
                    settings: settings,
                    source: nil,
                    configure: nil,
                    property: verdictProperty
                )
            #endif
            let report = pipelineReport ?? .empty(termination: .budgetExhausted, seed: 0)
            reportSprawlIssues(
                report: report,
                suppressIssueReporting: sprawlSuppressesIssueReporting(settings),
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return report
        }
        recordSprawlAttachments(report: finalReport)
        return finalReport
    }

    // MARK: - Core

    /// Parses settings, verifies instrumentation, and runs the three-phase ``SprawlRunner``. Records no issues — every entry point calls ``reportSprawlIssues(report:suppressIssueReporting:fileID:filePath:line:column:)`` itself so the expect variants can defer reporting until after their known-issue scope closes.
    ///
    /// The `source` and `configure` parameters are test seams: in-package tests inject a synthetic coverage source (skipping the instrumentation check) and tighten the runner configuration (attempt limits, phase skips) for deterministic termination.
    package static func runExploreTimeCore<Output>(
        gen: Generator<Output>,
        time: Duration,
        settings: [SprawlSettings],
        source injectedSource: (any CoverageSource)?,
        configure: ((inout SprawlRunnerConfiguration) -> Void)?,
        property: @escaping @Sendable (Output) -> SprawlVerdict
    ) -> SprawlReport {
        var seed = UInt64.random(in: UInt64.min ... UInt64.max)
        var suppressLogs = false
        var logLevel: LogLevel = .error
        for setting in settings {
            switch setting {
                case let .replay(replaySeed):
                    // A screening-row replay resolves without a PRNG seed; a soak replays the whole search from its root seed, so only seed-carrying replays apply here.
                    guard let resolved = replaySeed.resolve(), let resolvedSeed = resolved.seed else {
                        return .empty(
                            termination: .invalidConfiguration("Invalid replay seed for #explore(time:): \(replaySeed). Pass the run seed from a prior report."),
                            seed: 0
                        )
                    }
                    seed = resolvedSeed
                case let .suppress(option):
                    if option == .logs || option == .all {
                        suppressLogs = true
                    }
                case let .log(level):
                    logLevel = level
            }
        }

        guard let budgetNanoseconds = wholeNanoseconds(of: time), budgetNanoseconds > 0 else {
            return .empty(
                termination: .invalidConfiguration("#explore(time:) requires a positive time budget; got \(time)."),
                seed: seed
            )
        }

        let source: any CoverageSource
        if let injectedSource {
            source = injectedSource
        } else {
            guard SprawlInstrumentationCheck.isInstrumented, let sancovSource = SancovCoverageSource() else {
                return .empty(termination: .instrumentationMissing, seed: seed)
            }
            source = sancovSource
        }

        var configuration = SprawlRunnerConfiguration(budgetNanoseconds: budgetNanoseconds, seed: seed)
        configure?(&configuration)

        let logConfiguration = ExhaustLog.Configuration(
            isEnabled: suppressLogs == false,
            minimumLevel: logLevel,
            format: .keyValue
        )
        let result = ExhaustLog.withConfiguration(logConfiguration) {
            let runner = SprawlRunner(
                gen: gen,
                property: property,
                source: source,
                configuration: configuration
            )
            let result = runner.run()
            if result.clusters.isEmpty {
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "explore_time_no_failures",
                    metadata: [
                        "attempts": "\(result.totalAttempts)",
                        "covered_edges": "\(result.coveredEdgeCount)",
                        "seed": "\(result.seed)",
                    ]
                )
            }
            return result
        }
        return SprawlReport(result: result, symbolizeEdges: injectedSource == nil)
    }

    // MARK: - Issue Reporting

    /// Records the run's issues from the report alone: configuration and instrumentation errors (never suppressed — they signal a malfunction, not the failures a caller may be asserting on), the pointless-run error, and the fault inventory (suppressible for tests asserting on the returned report).
    package static func reportSprawlIssues(
        report: SprawlReport,
        suppressIssueReporting: Bool,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        switch report.termination {
            case .instrumentationMissing:
                reportError(
                    missingInstrumentationMessage,
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
                return
            case let .invalidConfiguration(message):
                reportError(
                    message,
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
                return
            case let .generationFailed(message):
                reportError(
                    "Generator failed during exploration: \(message)",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
            case .budgetExhausted, .coveragePlateau, .attemptLimitReached:
                break
        }

        if report.totalAttempts == 0 {
            reportError(
                "The property was never invoked, so this test asserts nothing. Check the time budget and generator.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }

        if report.clusters.isEmpty == false, suppressIssueReporting == false {
            reportError(
                renderSprawlSummary(report),
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    /// Renders the fault inventory for the terminal: throughput header, gap-framed coverage, early-stop accounting, and the clusters with late discoveries foregrounded.
    package static func renderSprawlSummary(_ report: SprawlReport) -> String {
        var lines: [String] = []

        let clusterWord = report.clusters.count == 1 ? "fault cluster" : "fault clusters"
        let overheadPercent = Int((report.frameworkOverheadFraction * 100).rounded())
        lines.append(
            "#explore(time:) catalogued \(report.clusters.count) \(clusterWord) in \(report.totalAttempts) attempts (\(Int(report.attemptsPerSecond.rounded()))/s; \(overheadPercent)% framework overhead)."
        )

        // Gap-framed: the uncovered count is the honest number; a percentage against module size would measure the module, not the search.
        let uncovered = max(0, report.instrumentedEdgeCount - report.coveredEdgeCount)
        lines.append(
            "Coverage: \(report.coveredEdgeCount) of \(report.instrumentedEdgeCount) instrumented edges hit; \(uncovered) never hit (module-wide count, includes code the property never calls)."
        )

        if case let .coveragePlateau(unused) = report.termination {
            lines.append(
                "Stopped \(renderDuration(unused)) early: no coverage-novel corpus admission in the plateau window; the unused budget was returned."
            )
        }

        // A cluster discovered late with few instances marks a fault region the search frontier had only just reached — the strongest signal to extend the budget. Those lead the inventory.
        let frontierThreshold = report.elapsed * 3 / 4
        let isFrontier: (SprawlReport.Cluster) -> Bool = { cluster in
            cluster.firstSeen >= frontierThreshold
                && cluster.instanceCount <= SprawlTunables.perClusterReductionCap
        }
        let ordered = report.clusters.filter(isFrontier).sorted { $0.firstSeen > $1.firstSeen }
            + report.clusters.filter { isFrontier($0) == false }

        for cluster in ordered {
            lines.append("")
            lines.append(contentsOf: renderCluster(cluster, isFrontier: isFrontier(cluster)))
        }

        if report.clusters.isEmpty == false {
            lines.append("")
        }
        for (symptom, count) in report.unreducedFailureCounts.sorted(by: { $0.key < $1.key }) {
            lines.append("\(count) unreduced failure\(count == 1 ? "" : "s") with symptom \(symptom) matched no cluster.")
        }
        if report.reductionsTimedOut {
            lines.append("Some reductions did not finish before the drain timeout; instance counts include unclassified failures.")
        }
        lines.append("Reproduce: .replay(\(report.seed))")
        return lines.joined(separator: "\n")
    }

    /// Renders one cluster's inventory block: attribute header, reduced counterexample, and suspect edges.
    private static func renderCluster(_ cluster: SprawlReport.Cluster, isFrontier: Bool) -> [String] {
        var attributes = [
            cluster.discoveringPhase.rawValue,
            "\(cluster.instanceCount) instance\(cluster.instanceCount == 1 ? "" : "s"), \(cluster.reducedCount) reduced",
            "symptoms: \(cluster.symptoms.joined(separator: ", "))",
        ]
        if isFrontier {
            attributes.insert("discovered late, at \(renderDuration(cluster.firstSeen)) — the frontier had just reached this region", at: 1)
        }
        if cluster.isLikelySplit {
            attributes.append("multiple coverage signatures — possibly distinct paths to one fault")
        }
        var lines = ["Cluster \(cluster.id) [\(attributes.joined(separator: "; "))]:"]
        lines.append(cluster.reducedDescription)
        if cluster.discriminatingEdges.isEmpty == false {
            lines.append("  Necessary path: \(cluster.necessaryEdgeCount) edges. Suspect edges:")
            for edge in cluster.discriminatingEdges {
                let failPercent = Int((edge.failureHitFraction * 100).rounded())
                let passPercent = Int((edge.passingHitFraction * 100).rounded())
                let location = edge.location.map { " — \($0)" } ?? ""
                lines.append(
                    "    edge \(edge.edgeIndex) — hit in \(failPercent)% of this cluster's failures, \(passPercent)% of passing runs\(location)"
                )
            }
        }
        return lines
    }

    // MARK: - Checkpoint Attachments

    /// Records the run's checkpoint attachments: one per discovered cluster plus the final summary.
    ///
    /// Eager and outcome-independent — a passing soak still attaches its summary, because "what did fifteen minutes buy" is the report's job either way. Must run on the test's own task: Swift Testing's attachment association is task-local, and the XCTest activity hop asserts the main actor, so the async entries call this after `dispatchToGCD` returns, never inside it.
    package static func recordSprawlAttachments(report: SprawlReport) {
        guard report.totalAttempts > 0 else {
            return
        }
        for cluster in report.clusters {
            recordAttachment(
                renderCluster(cluster, isFrontier: false).joined(separator: "\n"),
                named: "explore-time-cluster-\(cluster.id).txt"
            )
        }
        recordAttachment(renderSprawlSummary(report), named: "explore-time-summary.txt")
    }

    /// Records one plain-text attachment through the current test context. The XCTest lifetime is `.keepAlways` — the default `.deleteOnSuccess` silently drops attachments from passing runs, and a passing soak's report is still the product.
    private static func recordAttachment(_ text: String, named name: String) {
        switch TestContext.current {
            #if canImport(Testing)
                case .swiftTesting:
                    Attachment.record(text, named: name)
            #endif
            #if canImport(XCTest) && canImport(ObjectiveC)
                case .xcTest:
                    let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
                    attachment.name = name
                    attachment.lifetime = .keepAlways
                    MainActor.assumeIsolated {
                        XCTContext.runActivity(named: name) { activity in
                            activity.add(attachment)
                        }
                    }
            #endif
            default:
                break
        }
    }

    /// Renders a duration as whole seconds (or minutes and seconds past 90 seconds) for report lines.
    private static func renderDuration(_ duration: Duration) -> String {
        let totalSeconds = duration.components.seconds
        if totalSeconds >= 90 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        let fractional = Double(totalSeconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1fs", fractional)
    }

    /// The hard-failure diagnostic for a build without coverage instrumentation, with the flags ready to copy-paste.
    package static var missingInstrumentationMessage: String {
        """
        #explore(time:) requires coverage instrumentation, and no instrumented module is loaded. Add the following to the swiftSettings of the target whose coverage you want tracked (typically the library under test):

        .unsafeFlags(["-sanitize=undefined",
                      "-sanitize-coverage=edge,inline-8bit-counters,pc-table"],
                     .when(configuration: .debug))
        """
    }

    // MARK: - Property Wrapping

    /// Wraps a Bool-returning property into a ``SprawlVerdict`` evaluation: `false` and thrown errors become symptomed failures, skip errors pass, and on Apple platforms an NSException is caught in-process and treated as an ordinary failure.
    package static func wrapVerdictProperty<Output>(
        _ property: @escaping @Sendable (Output) throws -> Bool
    ) -> @Sendable (Output) -> SprawlVerdict {
        { value in
            var verdict = SprawlVerdict.pass
            var caught: NSException?
            let completed = exhaust_runCatchingObjCException({
                do {
                    verdict = try property(value) ? .pass : .fail(.returnedFalse)
                } catch {
                    verdict = isSkipError(error) ? .pass : .fail(.thrown(error))
                }
            }, &caught)
            if completed == false {
                verdict = .fail(FailureSymptom(kind: exceptionSymptomKind(of: caught)))
            }
            return verdict
        }
    }

    /// Wraps a throwing Void detection closure (the `#expect`-to-`#require` rewrite of the property) into a ``SprawlVerdict`` evaluation.
    package static func wrapVerdictDetection<Output>(
        _ detection: @escaping @Sendable (Output) throws -> Void
    ) -> @Sendable (Output) -> SprawlVerdict {
        { value in
            var verdict = SprawlVerdict.pass
            var caught: NSException?
            let completed = exhaust_runCatchingObjCException({
                do {
                    try detection(value)
                } catch {
                    verdict = isSkipError(error) ? .pass : .fail(.thrown(error))
                }
            }, &caught)
            if completed == false {
                verdict = .fail(FailureSymptom(kind: exceptionSymptomKind(of: caught)))
            }
            return verdict
        }
    }

    /// Bridges an async Bool-returning property to the synchronous verdict evaluation the single-threaded loop requires.
    ///
    /// No NSException guard here: the Objective-C `@try` cannot span an `await`, so async properties get the same exception behavior as every other async Exhaust path.
    package static func bridgeAsyncVerdictProperty<Output>(
        _ property: @escaping @Sendable (Output) async throws -> Bool
    ) -> @Sendable (Output) -> SprawlVerdict {
        { value in
            let valueBox = UnsafeSendableBox(value)
            return blockingAwait {
                do {
                    return try await property(valueBox.value) ? .pass : .fail(.returnedFalse)
                } catch {
                    return isSkipError(error) ? SprawlVerdict.pass : .fail(.thrown(error))
                }
            }
        }
    }

    /// Bridges an async Void detection closure to the synchronous verdict evaluation, mirroring ``bridgeAsyncVerdictProperty(_:)``.
    package static func bridgeAsyncVerdictDetection<Output>(
        _ detection: @escaping @Sendable (Output) async throws -> Void
    ) -> @Sendable (Output) -> SprawlVerdict {
        { value in
            let valueBox = UnsafeSendableBox(value)
            return blockingAwait {
                do {
                    try await detection(valueBox.value)
                    return SprawlVerdict.pass
                } catch {
                    return isSkipError(error) ? .pass : .fail(.thrown(error))
                }
            }
        }
    }

    // MARK: - Helpers

    private static func sprawlSuppressesIssueReporting(_ settings: [SprawlSettings]) -> Bool {
        settings.contains { setting in
            if case let .suppress(option) = setting, option == .issueReporting || option == .all {
                return true
            }
            return false
        }
    }

    /// The symptom kind for a caught NSException, carrying the exception name on Apple platforms.
    private static func exceptionSymptomKind(of caught: NSException?) -> String {
        #if canImport(ObjectiveC)
            return caught.map { "NSException(\($0.name.rawValue))" } ?? "NSException"
        #else
            _ = caught
            return "NSException"
        #endif
    }

    /// Converts a duration to whole nanoseconds, or nil when it is negative. Saturates at `UInt64.max` (585 years) rather than trapping on absurd budgets.
    private static func wholeNanoseconds(of time: Duration) -> UInt64? {
        let components = time.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return nil
        }
        let secondsPart = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard secondsPart.overflow == false else {
            return UInt64.max
        }
        let nanoseconds = UInt64(secondsPart.partialValue)
            .addingReportingOverflow(UInt64(components.attoseconds / 1_000_000_000))
        return nanoseconds.overflow ? UInt64.max : nanoseconds.partialValue
    }
}
