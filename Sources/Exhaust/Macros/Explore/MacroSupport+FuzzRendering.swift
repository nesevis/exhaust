// Terminal and attachment rendering for `#explore(time:)` reports.

import ExhaustCore
import Foundation

extension __ExhaustRuntime {
    // MARK: - Summary

    /// Renders the terminal summary in the order a reader asks their questions: how many failures, what input, where, whether a longer run would help, and how to reproduce. Every fuzzing-specific figure (throughput, overhead, edge counts, the estimators, phase and attribution counts) is left to ``renderFuzzAttachmentSummary(_:)``, so the terminal never asks the reader to know what an edge is.
    package static func renderFuzzSummary(_ report: FuzzReport) -> String {
        var lines: [String] = []

        // "At least": clusters are keyed by reduced form, and two faults whose inputs reduce to the same form merge into one, so the count is a floor on distinct faults.
        let failureWord = report.clusters.count == 1 ? "distinct failure" : "distinct failures"
        lines.append(
            "#explore(time:) found at least \(report.clusters.count) \(failureWord) in \(renderDuration(report.elapsed)) (\(report.evaluatedSearchCases) inputs tried)."
        )

        let isFrontier = frontierPredicate(for: report)
        for cluster in frontierFirst(report.clusters, isFrontier: isFrontier) {
            lines.append("")
            lines.append(contentsOf: renderClusterBrief(cluster, isFrontier: isFrontier(cluster)))
        }

        lines.append("")
        if let verdict = renderContinuationVerdict(report) {
            lines.append(verdict)
        }
        if report.offLaneEdgeHits > 0 {
            lines.append(
                "\(report.offLaneEdgeHits) times, code under test ran somewhere the search could not observe (a @MainActor function, a custom-executor actor, a detached task, or another test running at the same time), so those runs were not searched. For main-actor or custom-executor work, add inline-8bit-counters to the coverage flags."
            )
        }
        for (symptom, count) in report.unreducedFailureCounts.sorted(by: { $0.key < $1.key }) {
            lines.append("\(count) more failure\(count == 1 ? "" : "s") (\(symptom)) could not be reduced to a form shown above.")
        }
        lines.append("Reproduce: .replay(\(report.seed))")
        lines.append("Coverage, throughput, and full suspect lists are in the explore-time-summary.txt attachment.")
        return lines.joined(separator: "\n")
    }

    /// Renders the full inventory for the summary attachment: throughput header, gap-framed coverage, the estimators, early-stop accounting, and one block per cluster with membership, discovery phase, and up to three suspects. This is the maintainer's view; the terminal shows ``renderFuzzSummary(_:)``.
    package static func renderFuzzAttachmentSummary(_ report: FuzzReport) -> String {
        var lines: [String] = []

        let clusterWord = report.clusters.count == 1 ? "fault cluster" : "fault clusters"
        let overheadPercent = Int((report.testingOverheadFraction * 100).rounded())
        let evaluationDetail = report.rejectedSearchAttempts > 0
            ? ", \(report.evaluatedSearchCases) evaluated"
            : ""
        lines.append(
            "#explore(time:) cataloged \(report.clusters.count) \(clusterWord) in \(report.totalAttempts) attempts\(evaluationDetail) (\(Int(report.attemptsPerSecond.rounded())) evaluated/s; \(overheadPercent)% Exhaust testing overhead)."
        )

        // Gap-framed: the uncovered count is the honest number; a percentage against module size would measure the module, not the search.
        let uncovered = max(0, report.instrumentedEdgeCount - report.coveredEdgeCount)
        lines.append(
            "Coverage: \(report.coveredEdgeCount) of \(report.instrumentedEdgeCount) instrumented edges hit; \(uncovered) never hit (module-wide count, includes code the property never calls)."
        )
        lines.append(contentsOf: renderEstimatorLines(report))
        if report.offLaneEdgeHits > 0 {
            lines.append(
                "\(report.offLaneEdgeHits) edge hits fired off the run's lane and were not searched: property work on another executor (a @MainActor function, a custom-executor actor, a detached task) or another test exercising the instrumented code at the same time. For main-actor or custom-executor work, add inline-8bit-counters to the coverage flags."
            )
        }

        if case let .coveragePlateau(unused) = report.termination {
            lines.append(
                "Stopped \(renderDuration(unused)) early: no coverage-novel corpus admission in the plateau window; the unused budget was returned."
            )
        }

        let isFrontier = frontierPredicate(for: report)
        let ordered = frontierFirst(report.clusters, isFrontier: isFrontier)
        if ordered.isEmpty == false {
            lines.append("")
        }
        for (index, cluster) in ordered.enumerated() {
            if index > 0 {
                lines.append("")
            }
            lines.append(contentsOf: renderClusterDetail(cluster, isFrontier: isFrontier(cluster)))
        }
        if ordered.contains(where: \.isLikelySplit) {
            lines.append("~paths: one reduced form reached through multiple coverage signatures, possibly distinct paths to one fault.")
        }

        if report.clusters.isEmpty == false {
            lines.append("")
        }
        for (symptom, count) in report.unreducedFailureCounts.sorted(by: { $0.key < $1.key }) {
            lines.append("\(count) unreduced failure\(count == 1 ? "" : "s") with symptom \(symptom) matched no cluster.")
        }
        if report.clusters.isEmpty == false {
            lines.append("Full per-cluster detail is in the explore-time-cluster attachments.")
        }
        lines.append("Reproduce: .replay(\(report.seed))")
        return lines.joined(separator: "\n")
    }

    /// Answers "should I run longer?" from the termination reason and the time since the last discovery, without naming the plateau rule or the estimators. Nil when the run ended for a reason that says nothing about the search (an attempt limit, unreachable coverage, a failed generator) or never covered an edge.
    private static func renderContinuationVerdict(_ report: FuzzReport) -> String? {
        switch report.termination {
            case let .coveragePlateau(unused):
                return "Stopped \(renderDuration(unused)) early: the search had stopped reaching new code, so a longer run is unlikely to find more."
            case .firstFaultFound:
                return "Stopped at the first failure (.failFast)."
            case .budgetExhausted:
                guard report.coveredEdgeCount > 0 else {
                    return nil
                }
                let idle = TimeSpan(
                    nanoseconds: report.elapsed.nanoseconds - min(report.lastDiscovery.nanoseconds, report.elapsed.nanoseconds)
                )
                // The same fraction the plateau rule uses, so "still reaching new code" and "stopped early" cannot both be true of one run.
                let idleFraction = Double(idle.nanoseconds) / Double(max(report.elapsed.nanoseconds, 1))
                if idleFraction < FuzzTunables.plateauBudgetFraction {
                    return "Used the whole budget and was still reaching new code \(renderDuration(idle)) before the end; a longer run may find more."
                }
                return "Used the whole budget; the last new code was reached \(renderDuration(idle)) before the end, so a longer run is unlikely to find more."
            case .attemptLimitReached, .coverageUnreachable, .instrumentationMissing, .invalidConfiguration, .generationFailed:
                return nil
        }
    }

    /// A cluster discovered late with few instances marks a fault region the search frontier had only just reached, the strongest signal to extend the budget. Those lead the inventory in both renderings.
    private static func frontierPredicate(for report: FuzzReport) -> (FuzzReport.Cluster) -> Bool {
        let frontierThreshold = report.elapsed * 3 / 4
        return { cluster in
            cluster.firstSeen >= frontierThreshold
                && cluster.instanceCount <= FuzzTunables.perClusterReductionCap
        }
    }

    private static func frontierFirst(
        _ clusters: [FuzzReport.Cluster],
        isFrontier: (FuzzReport.Cluster) -> Bool
    ) -> [FuzzReport.Cluster] {
        clusters.filter(isFrontier).sorted { $0.firstSeen > $1.firstSeen }
            + clusters.filter { isFrontier($0) == false }
    }

    /// Renders the estimator lines: the price of one more edge and the completeness fraction against the run's own reachable set. The reachable-set scoping is stated inline so the fraction cannot be read as module coverage.
    ///
    /// The estimator is denominated in incidences, because one attempt covers many edges. Readers think in attempts, so the rate is converted back by the mean edges an attempt covers before it reaches the page.
    private static func renderEstimatorLines(_ report: FuzzReport) -> [String] {
        guard report.evaluatedSearchCases > 0, report.coveredEdgeCount > 0 else {
            return []
        }
        var lines: [String] = []
        let edgesPerCase = Double(report.incidenceTotal) / Double(report.evaluatedSearchCases)
        let newEdgesPerCase = report.estimatedNextEdgeProbability * edgesPerCase
        if newEdgesPerCase > 0 {
            let attemptsPerEdge = Int((1 / newEdgesPerCase).rounded())
            lines.append(
                "Estimated chance the next attempt covers a new edge: about 1 in \(attemptsPerEdge)."
            )
        } else {
            lines.append(
                "No edge was hit by only a single evaluated case, so the estimated chance of a new edge on the next evaluated case is below 1 in \(report.evaluatedSearchCases)."
            )
        }
        // With no doubleton the Chao2 ratio never runs and the estimate degenerates to the covered count or the singleton fallback: a number that looks like a verdict and is not one.
        guard report.edgeDoubletonCount > 0 else {
            lines.append(
                "Too few repeat observations to estimate how many edges this generator and property can reach."
            )
            return lines
        }
        let reachable = report.estimatedReachableEdgeCount
        let remaining = max(0, Int(reachable.rounded()) - report.coveredEdgeCount)
        lines.append(
            "At least \(Int(reachable.rounded())) edges look reachable for this generator and property."
        )
        lines.append(
            "At least \(remaining) of those remain\(remaining == 1 ? "s" : "") uncovered (scoped to this run's search space, not the module)."
        )
        return lines
    }

    // MARK: - Clusters

    /// Renders one cluster for the terminal: a numbered symptom line with the time of first sighting, the reduced counterexample, and the single strongest user-code suspect. The number is the cluster's attachment number, so `explore-time-cluster-N.txt` matches.
    private static func renderClusterBrief(
        _ cluster: FuzzReport.Cluster,
        isFrontier: Bool
    ) -> [String] {
        let symptoms = cluster.symptoms.joined(separator: ", ")
        let lateSuffix = isFrontier ? " (late: the search had only just reached this code)" : ""
        var lines = ["\(cluster.id + 1). \(symptoms), first seen at \(renderDuration(cluster.firstSeen))\(lateSuffix)"]
        let counterexample = collapsedCounterexample(cluster.reducedDescription)
        lines.append(contentsOf: counterexample.map { "   \($0)" })
        if let suspectLine = renderLikelyLocation(for: cluster) {
            lines.append("   likely in \(suspectLine)")
        }
        return lines
    }

    /// The terminal's one-line location: the top suspect alone when it carries a line number, otherwise every ranked suspect (at most three), because without a line the ranking cannot tell an entry point from the branch beneath it and the reader is better served by the chain. Suspects sharing one file print the file once.
    private static func renderLikelyLocation(for cluster: FuzzReport.Cluster) -> String? {
        let suspects = terminalSuspectLocations(for: cluster)
        guard let first = suspects.first else {
            return nil
        }
        if (first.line ?? 0) > 0 || suspects.count == 1 {
            return first.rendered
        }
        let files = Set(suspects.map(\.file))
        let hasAnyLine = suspects.contains { ($0.line ?? 0) > 0 }
        if files.count == 1, hasAnyLine == false, let file = first.file {
            return "\(suspects.map(\.symbol).joined(separator: ", ")) (\(file))"
        }
        return suspects.map(\.rendered).joined(separator: ", ")
    }

    /// Renders one cluster's attachment-summary block: a name line, an attribute line, the reduced counterexample (collapsed onto one line when it stays readable), and up to three user-code suspects. The full ranked edge list lives in the cluster's own attachment.
    private static func renderClusterDetail(
        _ cluster: FuzzReport.Cluster,
        isFrontier: Bool
    ) -> [String] {
        let symptoms = cluster.symptoms.joined(separator: ", ")
        var frontierSuffix = ""
        if isFrontier {
            frontierSuffix = ", discovered late at \(renderDuration(cluster.firstSeen))"
        }
        let splitMarker = cluster.isLikelySplit ? " ~paths" : ""
        let normalizedSuffix = cluster.unnormalizedMemberCount > 0
            ? " (\(cluster.unnormalizedMemberCount) normalized in)"
            : ""
        // Clusters display 1-based; `id` stays the report's zero-based array position.
        var lines = [
            "Cluster \(cluster.id + 1) \(symptoms)\(splitMarker)",
            "  \(membershipPhrase(cluster))\(normalizedSuffix), found via \(cluster.discoveringPhase.rawValue)\(frontierSuffix)",
        ]
        let counterexample = collapsedCounterexample(cluster.reducedDescription)
        if counterexample.count == 1, let onlyLine = counterexample.first {
            lines.append("  Counterexample: \(onlyLine)")
        } else {
            lines.append("  Counterexample:")
            lines.append(contentsOf: counterexample.map { "    \($0)" })
        }
        let suspects = terminalSuspects(for: cluster)
        if suspects.isEmpty == false {
            lines.append("  suspect\(suspects.count == 1 ? "" : "s"):")
            lines.append(contentsOf: suspects.map { "    - \($0)" })
        }
        return lines
    }

    /// Renders one cluster's full inventory block for its checkpoint attachment: attribute header, reduced counterexample, and the complete ranked suspect-edge list. The terminal summary renders the compact form instead.
    static func renderCluster(_ cluster: FuzzReport.Cluster, isFrontier: Bool) -> [String] {
        var attributes = [
            cluster.discoveringPhase.rawValue,
            membershipPhrase(cluster),
            "symptoms: \(cluster.symptoms.joined(separator: ", "))",
        ]
        if cluster.unnormalizedMemberCount > 0 {
            attributes.append("\(cluster.unnormalizedMemberCount) member\(cluster.unnormalizedMemberCount == 1 ? "" : "s") normalized in, reduction stalled short of the canonical form on these")
        }
        if isFrontier {
            attributes.insert("discovered late at \(renderDuration(cluster.firstSeen)): the frontier had just reached this region", at: 1)
        }
        if cluster.isLikelySplit {
            attributes.append("multiple coverage signatures, possibly distinct paths to one fault")
        }
        // Clusters display 1-based; `id` stays the report's zero-based array position.
        var lines = ["Cluster \(cluster.id + 1) [\(attributes.joined(separator: "; "))]:"]
        lines.append("Counterexample:")
        lines.append(cluster.reducedDescription)
        if cluster.discriminatingEdges.isEmpty == false {
            lines.append("  Necessary path: \(cluster.necessaryEdgeCount) edges. Suspect edges:")
            for edge in cluster.discriminatingEdges {
                let failPercent = Int((edge.failureHitFraction * 100).rounded())
                let passPercent = Int((edge.passingHitFraction * 100).rounded())
                let location = edge.location.map { "; \($0)" } ?? ""
                lines.append(
                    "    edge \(edge.edgeIndex): hit in \(failPercent)% of this cluster's failures, \(passPercent)% of passing runs\(location)"
                )
            }
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

    /// Renders a cluster's membership as the two numbers that mean different things.
    ///
    /// The reduced count is the cluster's real membership: those failures were reduced and their reduced form matched. The remainder is attributed by symptom to the most recently seen matching cluster, which cannot separate two faults that throw the same error type and carries no information at all when a property returns `false` rather than throwing. Reporting one total for both invites reading the larger number as a frequency.
    private static func membershipPhrase(_ cluster: FuzzReport.Cluster) -> String {
        let attributed = max(0, cluster.instanceCount - cluster.reducedCount)
        guard attributed > 0 else {
            return "\(cluster.reducedCount) reduced"
        }
        return "\(cluster.reducedCount) reduced, \(attributed) more attributed by symptom"
    }

    // MARK: - Suspects

    /// Picks up to three discriminating edges worth a terminal line, from the edges that symbolized into user code. Locations with a resolved line number lead (function-entry edges name a specific location; interior `:0` edges collapse to the enclosing function's name and read generic), and symbols that restate the symptom's own error type trail. Candidates naming the same function collapse into one unless both carry resolved lines that differ — `audit (RacyLedger.swift:45)` absorbs `audit (RacyLedger.swift)` and a file-less `audit` (the line-first ordering makes the line-bearing form the survivor), while `audit (RacyLedger.swift:52)` stays a separate suspect. Empty when nothing symbolized usefully.
    static func terminalSuspects(for cluster: FuzzReport.Cluster) -> [String] {
        terminalSuspectLocations(for: cluster).map(\.rendered)
    }

    private static func terminalSuspectLocations(for cluster: FuzzReport.Cluster) -> [SuspectLocation] {
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
            + candidates.filter { namesSymptom($0) && hasLine($0) }
            + candidates.filter { namesSymptom($0) && hasLine($0) == false }
        var kept: [SuspectLocation] = []
        for candidate in ordered {
            let isDuplicate = kept.contains { existing in
                guard existing.symbol == candidate.symbol else {
                    return false
                }
                if let existingFile = existing.file, let candidateFile = candidate.file, existingFile != candidateFile {
                    return false
                }
                // Two resolved lines that differ are distinct locations within one function, worth separate suspect entries.
                if let existingLine = existing.line, existingLine > 0,
                   let candidateLine = candidate.line, candidateLine > 0,
                   existingLine != candidateLine
                {
                    return false
                }
                return true
            }
            if isDuplicate {
                continue
            }
            kept.append(candidate)
            if kept.count == 3 {
                break
            }
        }
        return kept
    }

    /// One suspect edge's location, split back out of the symbolizer's composed string for compact terminal rendering.
    private struct SuspectLocation {
        let symbol: String
        let file: String?
        let line: Int?

        /// Splits `demangled symbol + offset (File.swift:line)` into its parts and shortens the symbol to its readable core. Every stage degrades gracefully — an unrecognized shape renders as-is.
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

    // MARK: - Shared Fragments

    /// Renders a duration as whole seconds (or minutes and seconds past 90 seconds) for report lines.
    private static func renderDuration(_ duration: TimeSpan) -> String {
        let totalSeconds = duration.nanoseconds / 1_000_000_000
        if totalSeconds >= 90 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        return String(format: "%.1fs", duration.seconds)
    }

    /// The hard-failure diagnostic for an instrumented build whose coverage the run cannot observe, naming the two causes in order of likelihood.
    ///
    /// An optimized build inlines small functions from the instrumented library into an uninstrumented caller, and the inlined copies record nothing; that is the common case in a release fuzz target with flags on the library alone. The other cause is executor isolation under `trace-pc-guard`: work on an executor the run did not bind is invisible to the thread-bound context, and `inline-8bit-counters` records it at the cost of requiring the run to have the process to itself.
    package static var unreachableCoverageMessage: String {
        """
        #explore(time:) evaluated the property and recorded no coverage at all, so the search had no signal to follow. A run that reaches \(FuzzTunables.coverageUnreachableAttemptThreshold) attempts this way stops early rather than spending the budget; a shorter run reports it when it ends.

        The build is instrumented, so this is not a missing-flags problem. It means the code the property exercises runs without instrumentation. Two causes, in order of likelihood:

        1. An optimized build inlined the code under test into a module that has no coverage flags. In release configuration the compiler copies small functions into their callers, and a copy compiled as part of an uninstrumented module records nothing. Add the coverage flags to the module that calls the code under test (usually the test target) as well as to the library, and keep `-assert-config Debug` alongside them so `assert` oracles survive.

        2. The property's work runs on an executor the run did not bind: a `@MainActor` function, an actor with a custom executor, or a detached task. `trace-pc-guard` records only on the run's own thread. Add counter-based instrumentation, which records regardless of executor; when both recorders are present the counters are used:

        .unsafeFlags(["-sanitize=undefined",
                      "-sanitize-coverage=edge,trace-pc-guard,inline-8bit-counters,pc-table"])

        Counter-based coverage is process-global, so give the run the process to itself: `swift test --no-parallel`, or filter down to the single fuzz test.
        """
    }

    /// The hard-failure diagnostic for a build without coverage instrumentation, with the flags ready to copy-paste.
    package static var missingInstrumentationMessage: String {
        """
        #explore(time:) requires coverage instrumentation, and no instrumented module is loaded. Add the following to the swiftSettings of the target whose coverage you want tracked (typically the library under test):

        .unsafeFlags(["-sanitize=undefined",
                      "-sanitize-coverage=edge,trace-pc-guard,pc-table"],
                     .when(configuration: .debug))

        For a dedicated fuzz target built with `-c release`, drop the `.when(configuration:)` gate, add "-assert-config", "Debug" to the list, and apply the same flags to the test target that calls the code under test. The CoverageGuidedFuzzing article has both recipes.
        """
    }
}
