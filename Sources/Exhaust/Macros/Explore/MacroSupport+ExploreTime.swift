// Explore time: mode — coverage-guided fuzzing runtime entry points.

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

public extension __ExhaustRuntime {
    // MARK: - Explore Time (Bool)

    /// Runs a coverage-guided `time:` fuzz run with a Bool-returning property. Runtime target of `#explore(time:)`.
    @discardableResult
    static func __exploreTime<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: SprawlDuration,
        settings: [SprawlSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) throws -> Bool
    ) -> SprawlReport {
        let persistence = makeSprawlPersistenceContext(fileID: fileID, line: line)
        reportSprawlResumeFindings(
            context: persistence,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        let report = runExploreTimeCore(
            gen: refGen.gen,
            time: time,
            settings: settings,
            source: nil,
            configure: nil,
            persistence: persistence,
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

    /// Runs a coverage-guided `time:` fuzz run with a Void/#expect/#require closure.
    ///
    /// The detection closure (the property with `#expect` rewritten to `#require`) records an issue on every failing attempt, and a fuzz run deliberately keeps failing past the first failure, so the whole run executes inside `withExpectedIssue(isIntermittent:)`. The fault inventory is reported afterwards, outside that scope, so it surfaces as a real failure.
    @discardableResult
    static func __exploreTimeExpect<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: SprawlDuration,
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
        let persistence = makeSprawlPersistenceContext(fileID: fileID, line: line)
        reportSprawlResumeFindings(
            context: persistence,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        nonisolated(unsafe) var pipelineReport: SprawlReport?
        withExpectedIssue(isIntermittent: true) {
            pipelineReport = runExploreTimeCore(
                gen: refGen.gen,
                time: time,
                settings: settings,
                source: nil,
                configure: nil,
                persistence: persistence,
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

    /// Runs a coverage-guided `time:` fuzz run with an async Bool-returning property.
    @discardableResult
    static func __exploreTimeAsync<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: SprawlDuration,
        settings: [SprawlSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) async throws -> Bool
    ) async -> SprawlReport {
        let verdictProperty = bridgeAsyncVerdictProperty(property)
        let report = await dispatchToGCD(reserving: LaneReservation.single) {
            let persistence = makeSprawlPersistenceContext(fileID: fileID, line: line)
            reportSprawlResumeFindings(
                context: persistence,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            let report = runExploreTimeCore(
                gen: refGen.gen,
                time: time,
                settings: settings,
                source: nil,
                configure: nil,
                persistence: persistence,
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

    /// Runs a coverage-guided `time:` fuzz run with an async Void/#expect/#require closure.
    @discardableResult
    static func __exploreTimeExpectAsync<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        time: SprawlDuration,
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
            let persistence = makeSprawlPersistenceContext(fileID: fileID, line: line)
            reportSprawlResumeFindings(
                context: persistence,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
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
                        persistence: persistence,
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
                    persistence: persistence,
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
        time: SprawlDuration,
        settings: [SprawlSettings],
        source injectedSource: (any CoverageSource)?,
        configure: ((inout SprawlRunnerConfiguration) -> Void)?,
        persistence: SprawlPersistenceContext? = nil,
        property: @escaping @Sendable (Output) -> SprawlVerdict
    ) -> SprawlReport {
        var seed = UInt64.random(in: UInt64.min ... UInt64.max)
        var suppressLogs = false
        var logLevel: LogLevel = .error
        for setting in settings {
            switch setting {
                case let .replay(replaySeed):
                    // A screening-row replay resolves without a PRNG seed; a fuzz run replays the whole search from its root seed, so only seed-carrying replays apply here.
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

        let budgetNanoseconds = time.nanoseconds
        guard budgetNanoseconds > 0 else {
            return .empty(
                termination: .invalidConfiguration("#explore(time:) requires a positive time budget; got \(time.seconds)s."),
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
        #if DEBUG
            // The benchmark arm seam: read once at run start, debug builds only. A malformed or unknown knob is a hard configuration error — a silently ignored typo would invalidate a benchmark arm.
            if let experimentValue = ProcessInfo.processInfo.environment["EXHAUST_SPRAWL_EXPERIMENT"] {
                do {
                    configuration.experiments = try SprawlExperiments.parse(environmentValue: experimentValue)
                } catch {
                    return .empty(termination: .invalidConfiguration(String(describing: error)), seed: seed)
                }
            }
        #endif
        if let persistence {
            configuration.persistence = persistence
            if let document = persistence.resumeDocument {
                // A resumed run continues the logical run: the remaining slice of the declared budget, straight into sprawl — the restored corpus already carries the screening and sampling phases' work.
                let consumed = document.metadata.consumedNanoseconds
                configuration.budgetNanoseconds = budgetNanoseconds > consumed ? budgetNanoseconds - consumed : 0
                configuration.skipScreening = true
                configuration.skipSampling = true
            }
        }
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

    // MARK: - Crash Recovery

    /// Builds the crash-recovery context for one `#explore(time:)` call site: `<base>/exhaust/<module>/<file>-L<line>/`, which is stable across runs of the same test. Construction is read-only; the runner creates files only once the run actually starts.
    ///
    /// The base directory is the system temporary directory, or `EXHAUST_STATE_DIR` when set — a relocation seam for CI and for the trap probe, which needs the parent process to know where the crashed child's state landed. `EXHAUST_RESUME=0` opts out of recovery: predecessor state is ignored and overwritten.
    package static func makeSprawlPersistenceContext(
        fileID: StaticString,
        line: UInt,
        baseDirectory: URL? = nil
    ) -> SprawlPersistenceContext {
        let base = baseDirectory
            ?? ProcessInfo.processInfo.environment["EXHAUST_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let fileIDText = "\(fileID)"
        let module = fileIDText.split(separator: "/").first.map(String.init) ?? "UnknownModule"
        let file = fileIDText.split(separator: "/").last.map(String.init) ?? "UnknownFile"
        let store = SprawlProgressStore(
            baseDirectory: base,
            module: module,
            testIdentifier: "\(file)-L\(line)"
        )
        let resumeEnabled = ProcessInfo.processInfo.environment["EXHAUST_RESUME"] != "0"
        return SprawlPersistenceContext(store: store, resumeEnabled: resumeEnabled)
    }

    /// Records the crash finding from a resumed run — never silent, never suppressed. The trapping candidate itself usually died before corpus admission, so the report names its mutation parent from the snapshot when one exists.
    package static func reportSprawlResumeFindings(
        context: SprawlPersistenceContext,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        guard context.resumeDocument != nil, let survivor = context.survivor else {
            return
        }
        let parentText: String
        if let parentSequence = context.survivorParentSequence() {
            parentText = "a mutation of corpus parent \(parentSequence.shortString) (hash 0x\(String(survivor.parentHash, radix: 16)))"
        } else if survivor.parentHash == 0 {
            parentText = "a fresh sample with no corpus parent"
        } else {
            parentText = "a mutation of a parent not present in the last checkpoint"
        }
        reportError(
            "A previous run of this test was killed by a Swift trap while evaluating candidate 0x\(String(survivor.candidateHash, radix: 16)) — \(parentText). The run resumes for the remaining budget with the crash region quarantined; fix the trap before extending the budget.",
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
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

    /// Renders the fault inventory for the terminal: throughput header, gap-framed coverage, early-stop accounting, and one compact block per cluster with late discoveries foregrounded. The terminal's job is orientation; full per-cluster detail ships in the checkpoint attachments.
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
        lines.append(contentsOf: renderEstimatorLines(report))

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

        let symptomColumnWidth = ordered.map { $0.symptoms.joined(separator: ", ").count }.max() ?? 0
        if ordered.isEmpty == false {
            lines.append("")
        }
        for cluster in ordered {
            lines.append(
                contentsOf: renderClusterBrief(
                    cluster,
                    isFrontier: isFrontier(cluster),
                    symptomColumnWidth: symptomColumnWidth
                )
            )
        }
        if ordered.contains(where: \.isLikelySplit) {
            lines.append("~paths: one reduced form reached through multiple coverage signatures — possibly distinct paths to one fault.")
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
        if report.clusters.isEmpty == false {
            lines.append("Full per-cluster detail is in the explore-time-cluster attachments.")
        }
        lines.append("Reproduce: .replay(\(report.seed))")
        return lines.joined(separator: "\n")
    }

    /// Renders the STADS estimator lines: the Good-Turing price of one more edge and the Chao1 completeness fraction against the run's own reachable set. Gap-framed per the Marick guardrails — the reachable-set scoping is stated inline so the fraction cannot be read as module coverage.
    private static func renderEstimatorLines(_ report: SprawlReport) -> [String] {
        guard report.totalAttempts > 0, report.coveredEdgeCount > 0 else {
            return []
        }
        var lines: [String] = []
        let nextEdgeProbability = report.estimatedNextEdgeProbability
        if nextEdgeProbability > 0 {
            let attemptsPerEdge = Int((1 / nextEdgeProbability).rounded())
            lines.append(
                "Estimated chance the next attempt covers a new edge: \(String(format: "%.1e", nextEdgeProbability)) (about one per \(attemptsPerEdge) attempts)."
            )
        } else {
            lines.append(
                "No edge was hit by only a single attempt — the estimated chance of a new edge on the next attempt is below 1 in \(report.totalAttempts)."
            )
        }
        let reachable = report.estimatedReachableEdgeCount
        let remaining = max(0, Int(reachable.rounded()) - report.coveredEdgeCount)
        lines.append(
            "Chao1 estimates about \(Int(reachable.rounded())) edges reachable for this generator and property; \(remaining) of those remain uncovered (estimate scoped to this run's search space, not the module)."
        )
        return lines
    }

    /// Renders one cluster's terminal block: an attribute line, the reduced counterexample (collapsed onto one line when it stays readable), and the single strongest user-code suspect. The full ranked edge list lives in the cluster's attachment.
    private static func renderClusterBrief(
        _ cluster: SprawlReport.Cluster,
        isFrontier: Bool,
        symptomColumnWidth: Int
    ) -> [String] {
        let symptoms = cluster.symptoms.joined(separator: ", ")
        let paddedSymptoms = symptoms.padding(
            toLength: max(symptomColumnWidth, symptoms.count),
            withPad: " ",
            startingAt: 0
        )
        var phaseTag = cluster.discoveringPhase.rawValue
        if isFrontier {
            phaseTag += "; discovered late, at \(renderDuration(cluster.firstSeen))"
        }
        let splitMarker = cluster.isLikelySplit ? "  ~paths" : ""
        let instanceWord = cluster.instanceCount == 1 ? "instance" : "instances"
        let normalizedSuffix = cluster.unnormalizedMemberCount > 0
            ? " (\(cluster.unnormalizedMemberCount) normalized in)"
            : ""
        var lines = [
            "Cluster \(cluster.id)  \(paddedSymptoms)  \(cluster.instanceCount) \(instanceWord), \(cluster.reducedCount) reduced\(normalizedSuffix)  [\(phaseTag)]\(splitMarker)",
        ]
        lines.append(contentsOf: collapsedCounterexample(cluster.reducedDescription).map { "  \($0)" })
        let suspects = terminalSuspects(for: cluster)
        if suspects.isEmpty == false {
            lines.append("  suspect\(suspects.count == 1 ? "" : "s"): \(suspects.joined(separator: ", "))")
        }
        return lines
    }

    /// Collapses a multi-line customDump rendering onto one line when the result stays readable, dropping the per-index labels customDump writes inside collections. Larger values keep their block form — a deep counterexample is the finding, not noise.
    private static func collapsedCounterexample(_ description: String) -> [String] {
        let blockLines = description.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard blockLines.count > 1 else {
            return blockLines
        }
        var collapsed = blockLines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        for (fragment, replacement) in [("( ", "("), (" )", ")"), ("[ ", "["), (" ]", "]")] {
            collapsed = collapsed.replacingOccurrences(of: fragment, with: replacement)
        }
        if let indexLabel = try? NSRegularExpression(pattern: #"\[[0-9]+\]: "#) {
            collapsed = indexLabel.stringByReplacingMatches(
                in: collapsed,
                range: NSRange(collapsed.startIndex..., in: collapsed),
                withTemplate: ""
            )
        }
        let singleLineLimit = 120
        guard collapsed.count <= singleLineLimit else {
            return blockLines
        }
        return [collapsed]
    }

    /// Picks up to three discriminating edges worth a terminal line, from the edges that symbolised into user code. Locations with a resolved line number lead (function-entry edges name a specific location; interior `:0` edges collapse to the enclosing function's name and read generic), symbols that restate the symptom's own error type trail, and duplicate rendered names collapse. Empty when nothing symbolised usefully.
    private static func terminalSuspects(for cluster: SprawlReport.Cluster) -> [String] {
        let candidates: [SuspectLocation] = cluster.discriminatingEdges.compactMap { edge in
            guard let location = edge.location, location.contains("/<compiler-generated>") == false else {
                return nil
            }
            return SuspectLocation(parsing: location)
        }
        let namesSymptom: (SuspectLocation) -> Bool = { candidate in
            cluster.symptoms.contains { symptom in candidate.symbol.contains(symptom) }
        }
        let hasLine: (SuspectLocation) -> Bool = { ($0.line ?? 0) > 0 }
        let ordered = candidates.filter { namesSymptom($0) == false && hasLine($0) }
            + candidates.filter { namesSymptom($0) == false && hasLine($0) == false }
            + candidates.filter(namesSymptom)
        var seen = Set<String>()
        var rendered: [String] = []
        for candidate in ordered where seen.insert(candidate.rendered).inserted {
            rendered.append(candidate.rendered)
            if rendered.count == 3 {
                break
            }
        }
        return rendered
    }

    /// One suspect edge's location, split back out of the symbolizer's composed string for compact terminal rendering.
    private struct SuspectLocation {
        let symbol: String
        let file: String?
        let line: Int?

        /// Splits `demangled symbol + offset (File.swift:line)` into its parts and shortens the symbol to its readable core. Every stage degrades gracefully — an unrecognised shape renders as-is.
        init(parsing location: String) {
            var working = location
            var parsedFile: String?
            var parsedLine: Int?
            if working.hasSuffix(")"), let openRange = working.range(of: " (", options: .backwards) {
                let inside = String(working[openRange.upperBound...].dropLast())
                if let colonIndex = inside.lastIndex(of: ":"), let number = Int(inside[inside.index(after: colonIndex)...]) {
                    parsedFile = String(inside[..<colonIndex])
                    parsedLine = number
                    working = String(working[..<openRange.lowerBound])
                }
            }
            if let plusRange = working.range(of: " + ", options: .backwards),
               working[plusRange.upperBound...].allSatisfy(\.isNumber)
            {
                working = String(working[..<plusRange.lowerBound])
            }
            symbol = Self.shortSymbolName(working)
            file = parsedFile
            line = parsedLine
        }

        /// The compact terminal form: `integrityCheck (Parser.swift:121)`, dropping the line when atos resolved none.
        var rendered: String {
            guard let file else {
                return symbol
            }
            if let line, line > 0 {
                return "\(symbol) (\(file):\(line))"
            }
            return "\(symbol) (\(file))"
        }

        /// Shortens a demangled symbol to its readable core: the bare name for private symbols (which demangle as `(name in _Discriminator)`), the last two dotted components otherwise.
        private static func shortSymbolName(_ demangled: String) -> String {
            if let discriminatorRange = demangled.range(of: " in _"),
               let openIndex = demangled[..<discriminatorRange.lowerBound].lastIndex(of: "(")
            {
                let name = demangled[demangled.index(after: openIndex) ..< discriminatorRange.lowerBound]
                if name.isEmpty == false {
                    return String(name)
                }
            }
            var namePath = demangled
            if let parameterIndex = namePath.firstIndex(of: "(") {
                namePath = String(namePath[..<parameterIndex])
            }
            namePath = namePath.trimmingCharacters(in: .whitespaces)
            if namePath.hasPrefix("static ") {
                namePath = String(namePath.dropFirst("static ".count))
            }
            let components = namePath.split(separator: ".").suffix(2)
            guard components.isEmpty == false else {
                return demangled
            }
            return components.joined(separator: ".")
        }
    }

    /// Renders one cluster's full inventory block for its checkpoint attachment: attribute header, reduced counterexample, and the complete ranked suspect-edge list. The terminal summary renders the compact form instead.
    private static func renderCluster(_ cluster: SprawlReport.Cluster, isFrontier: Bool) -> [String] {
        var attributes = [
            cluster.discoveringPhase.rawValue,
            "\(cluster.instanceCount) instance\(cluster.instanceCount == 1 ? "" : "s"), \(cluster.reducedCount) reduced",
            "symptoms: \(cluster.symptoms.joined(separator: ", "))",
        ]
        if cluster.unnormalizedMemberCount > 0 {
            attributes.append("\(cluster.unnormalizedMemberCount) member\(cluster.unnormalizedMemberCount == 1 ? "" : "s") normalized in — reduction stalled short of the canonical form on these")
        }
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
    /// Eager and outcome-independent — a passing fuzz run still attaches its summary, because "what did fifteen minutes buy" is the report's job either way. Must run on the test's own task: Swift Testing's attachment association is task-local, and the XCTest activity hop asserts the main actor, so the async entries call this after `dispatchToGCD` returns, never inside it.
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

    /// Records one plain-text attachment through the current test context. The XCTest lifetime is `.keepAlways` — the default `.deleteOnSuccess` silently drops attachments from passing runs, and a passing fuzz run's report is still the product.
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
    private static func renderDuration(_ duration: SprawlDuration) -> String {
        let totalSeconds = duration.nanoseconds / 1_000_000_000
        if totalSeconds >= 90 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        return String(format: "%.1fs", duration.seconds)
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
}
