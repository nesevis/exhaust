// Terminal and attachment rendering for `#explore(time:)` reports.

import ExhaustCore
import Foundation

extension __ExhaustRuntime {
    // MARK: - Summary

    /// Renders the fault inventory for the terminal: throughput header, gap-framed coverage, early-stop accounting, and one compact block per cluster with late discoveries foregrounded. The terminal's job is orientation; full per-cluster detail ships in the checkpoint attachments.
    package static func renderFuzzSummary(_ report: FuzzReport) -> String {
        var lines: [String] = []

        let clusterWord = report.clusters.count == 1 ? "fault cluster" : "fault clusters"
        let overheadPercent = Int((report.testingOverheadFraction * 100).rounded())
        lines.append(
            "#explore(time:) catalogued \(report.clusters.count) \(clusterWord) in \(report.totalAttempts) attempts (\(Int(report.attemptsPerSecond.rounded()))/s; \(overheadPercent)% Exhaust testing overhead)."
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
        let isFrontier: (FuzzReport.Cluster) -> Bool = { cluster in
            cluster.firstSeen >= frontierThreshold
                && cluster.instanceCount <= FuzzTunables.perClusterReductionCap
        }
        let ordered = report.clusters.filter(isFrontier).sorted { $0.firstSeen > $1.firstSeen }
            + report.clusters.filter { isFrontier($0) == false }

        let symptomColumnWidth = ordered.map { $0.symptoms.joined(separator: ", ").count }.max() ?? 0
        if ordered.isEmpty == false {
            lines.append("")
        }
        for (index, cluster) in ordered.enumerated() {
            if index > 0 {
                lines.append("")
            }
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
        if report.clusters.isEmpty == false {
            lines.append("Full per-cluster detail is in the explore-time-cluster attachments.")
        }
        lines.append("Reproduce: .replay(\(report.seed))")
        return lines.joined(separator: "\n")
    }

    /// Renders the estimator lines: the Good-Turing price of one more edge and the Chao1 completeness fraction against the run's own reachable set. The reachable-set scoping is stated inline so the fraction cannot be read as module coverage.
    private static func renderEstimatorLines(_ report: FuzzReport) -> [String] {
        guard report.totalAttempts > 0, report.coveredEdgeCount > 0 else {
            return []
        }
        var lines: [String] = []
        let nextEdgeProbability = report.estimatedNextEdgeProbability
        if nextEdgeProbability > 0 {
            let attemptsPerEdge = Int((1 / nextEdgeProbability).rounded())
            lines.append(
                "Estimated chance the next attempt covers a new edge: about 1 in \(attemptsPerEdge)."
            )
        } else {
            lines.append(
                "No edge was hit by only a single attempt — the estimated chance of a new edge on the next attempt is below 1 in \(report.totalAttempts)."
            )
        }
        let reachable = report.estimatedReachableEdgeCount
        let remaining = max(0, Int(reachable.rounded()) - report.coveredEdgeCount)
        lines.append(
            "About \(Int(reachable.rounded())) edges look reachable for this generator and property (Chao1 estimate); \(remaining) of those remain\(remaining == 1 ? "s" : "") uncovered (scoped to this run's search space, not the module)."
        )
        return lines
    }

    // MARK: - Clusters

    /// Renders one cluster's terminal block: an attribute line, the reduced counterexample (collapsed onto one line when it stays readable), and the single strongest user-code suspect. The full ranked edge list lives in the cluster's attachment.
    private static func renderClusterBrief(
        _ cluster: FuzzReport.Cluster,
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
        let failureWord = cluster.instanceCount == 1 ? "failure" : "failures"
        let normalizedSuffix = cluster.unnormalizedMemberCount > 0
            ? " (\(cluster.unnormalizedMemberCount) normalized in)"
            : ""
        // Clusters display 1-based; `id` stays the report's zero-based array position.
        var lines = [
            "Cluster \(cluster.id + 1)  \(paddedSymptoms)  \(cluster.instanceCount) \(failureWord), \(cluster.reducedCount) reduced\(normalizedSuffix)  [\(phaseTag)]\(splitMarker)",
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
            "\(cluster.instanceCount) failure\(cluster.instanceCount == 1 ? "" : "s"), \(cluster.reducedCount) reduced",
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
        // Clusters display 1-based; `id` stays the report's zero-based array position.
        var lines = ["Cluster \(cluster.id + 1) [\(attributes.joined(separator: "; "))]:"]
        lines.append("Counterexample:")
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

    // MARK: - Suspects

    /// Picks up to three discriminating edges worth a terminal line, from the edges that symbolised into user code. Locations with a resolved line number lead (function-entry edges name a specific location; interior `:0` edges collapse to the enclosing function's name and read generic), and symbols that restate the symptom's own error type trail. Candidates naming the same function collapse into one unless both carry resolved lines that differ — `audit (RacyLedger.swift:45)` absorbs `audit (RacyLedger.swift)` and a file-less `audit` (the line-first ordering makes the line-bearing form the survivor), while `audit (RacyLedger.swift:52)` stays a separate suspect. Empty when nothing symbolised usefully.
    static func terminalSuspects(for cluster: FuzzReport.Cluster) -> [String] {
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
        return kept.map(\.rendered)
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

    // MARK: - Shared Fragments

    /// Renders a duration as whole seconds (or minutes and seconds past 90 seconds) for report lines.
    private static func renderDuration(_ duration: TimeBudget) -> String {
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
}
