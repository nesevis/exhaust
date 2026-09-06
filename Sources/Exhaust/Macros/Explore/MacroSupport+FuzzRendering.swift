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
            "#explore(time:) found at least \(report.clusters.count) \(failureWord) in \(renderDuration(report.timing.elapsed)) (\(report.attempts.evaluated) inputs tried)."
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
        if report.coverage.offLaneHits > 0 {
            lines.append(
                "\(report.coverage.offLaneHits) times, code under test ran somewhere the search could not observe (a @MainActor function, a custom-executor actor, a detached task, or another test running at the same time), so those runs were not searched. For main-actor or custom-executor work, add inline-8bit-counters to the coverage flags."
            )
        }
        for (symptom, count) in report.unreducedFailureCounts.sorted(by: { $0.key < $1.key }) {
            lines.append("\(count) more failure\(count == 1 ? "" : "s") (\(symptom)) could not be reduced to a form shown above.")
        }
        if report.attempts.discardedByProperty > 0 {
            let percent = Int((Double(report.attempts.discardedByProperty) / Double(max(report.attempts.evaluated, 1)) * 100).rounded())
            lines.append("\(percent)% of inputs were skipped by the property (precondition not met); the search used them to find inputs that meet it.")
        }
        lines.append(reproduceLine(report))
        lines.append("Coverage, throughput, and full suspect lists are in the explore-time-summary.txt attachment.")
        return lines.joined(separator: "\n")
    }

    /// Renders the full inventory for the summary attachment: throughput header, gap-framed coverage, the estimators, early-stop accounting, and one block per cluster with membership, discovery phase, and up to three suspects. This is the maintainer's view; the terminal shows ``renderFuzzSummary(_:)``.
    package static func renderFuzzAttachmentSummary(_ report: FuzzReport) -> String {
        var lines: [String] = []

        let clusterWord = report.clusters.count == 1 ? "fault cluster" : "fault clusters"
        let overheadPercent = Int((report.timing.testingOverheadFraction * 100).rounded())
        let evaluationDetail = report.attempts.rejected > 0
            ? ", \(report.attempts.evaluated) evaluated"
            : ""
        // The rate counts property invocations, so without the skip count beside it a run that skipped half its candidates reads as half as fast.
        let skipDetail = report.attempts.duplicatesSkipped > 0
            ? "; \(report.attempts.duplicatesSkipped) duplicate candidates skipped before evaluation"
            : ""
        lines.append(
            "#explore(time:) cataloged \(report.clusters.count) \(clusterWord) in \(report.attempts.total) attempts\(evaluationDetail) (\(Int(report.attemptsPerSecond.rounded())) evaluated/s; \(overheadPercent)% Exhaust testing overhead\(skipDetail))."
        )

        // Gap-framed: the uncovered count is the honest number; a percentage against module size would measure the module, not the search.
        let uncovered = max(0, report.coverage.instrumentedEdges - report.coverage.coveredEdges)
        lines.append(
            "Coverage: \(report.coverage.coveredEdges) of \(report.coverage.instrumentedEdges) instrumented edges hit; \(uncovered) never hit (module-wide count, includes code the property never calls)."
        )
        lines.append(contentsOf: renderEstimatorLines(report))
        if report.attempts.duplicatesSkipped > 0 {
            lines.append(renderDuplicateSkipLine(report.attempts.duplicateSkips))
        }
        if report.attempts.operandEnergySeatings > 0 {
            lines.append(
                "Comparand energy: \(report.attempts.operandEnergyRetirements) sources retired; \(report.attempts.operandEnergyEvictions) of \(report.attempts.operandEnergySeatings) seatings evicted a live key (a high share means the energy table is undersized for this run)."
            )
        }
        if report.coverage.parentProfile.parentCount > 0 {
            lines.append(renderParentProfileLine(report.coverage.parentProfile, entryCount: report.coverage.corpusEntryCount))
        }
        if report.attempts.discardedByProperty > 0 {
            lines.append(
                "Discarded: \(report.attempts.discardedByProperty) of \(report.attempts.evaluated) evaluated cases threw a skip error; coverage-novel discards stay in the corpus as mutation parents at \(Int((FuzzTunables.discardParentEnergy * 100).rounded()))% weight."
            )
        }
        if report.coverage.offLaneHits > 0 {
            lines.append(
                "\(report.coverage.offLaneHits) edge hits fired off the run's lane and were not searched: property work on another executor (a @MainActor function, a custom-executor actor, a detached task) or another test exercising the instrumented code at the same time. For main-actor or custom-executor work, add inline-8bit-counters to the coverage flags."
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
            lines.append(contentsOf: renderClusterBlock(cluster, isFrontier: isFrontier(cluster), detail: .summary))
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
        lines.append(reproduceLine(report))
        return lines.joined(separator: "\n")
    }

    /// The seed line, hedged on a resume.
    ///
    /// A resumed run draws its own seed and starts its PRNG at position zero against a corpus a different stream built, so the seed reproduces this run's search and nothing the predecessor did. Presenting it unqualified is worse than presenting no seed, because it looks actionable.
    private static func reproduceLine(_ report: FuzzReport) -> String {
        guard report.resumedFromCrash else {
            return "Reproduce: .replay(\(report.seed))"
        }
        return "This run continued a predecessor's findings under a new seed, so it is not reproducible as a whole. Replaying .replay(\(report.seed)) repeats this run's search from an empty corpus."
    }

    /// Answers "should I run longer?" from the termination reason and the run's own discovery estimate, without naming the saturation rule or the estimators. Nil when the run ended for a reason that says nothing about the search (an attempt limit, unreachable coverage, a failed generator) or never covered an edge.
    private static func renderContinuationVerdict(_ report: FuzzReport) -> String? {
        switch report.termination {
            case let .coveragePlateau(unused):
                return "Stopped \(renderDuration(unused)) early: the search had stopped reaching new code, so a longer run is unlikely to find more."
            case .firstFaultFound:
                return "Stopped at the first failure (.failFast)."
            case .budgetExhausted:
                guard report.coverage.coveredEdges > 0 else {
                    return nil
                }
                guard report.coverage.incidenceSamples > 0, report.coverage.incidenceTotal > 0 else {
                    return nil
                }
                let idle = TimeSpan(
                    nanoseconds: report.timing.elapsed.nanoseconds - min(report.timing.lastDiscovery.nanoseconds, report.timing.elapsed.nanoseconds)
                )
                // The same estimate the saturation stop reads, so "still reaching new code" and "would have stopped early" cannot both be true of one run. The idle duration stays in the sentence because it is what a reader can picture; it no longer decides the verdict, because time since the last discovery is not a consistent estimator of anything.
                let edgesPerAttempt = Double(report.coverage.incidenceTotal) / Double(report.coverage.incidenceSamples)
                let newEdgeProbability = report.coverage.estimatedNextEdgeProbability * edgesPerAttempt
                if newEdgeProbability >= FuzzTunables.saturationNextEdgeProbability {
                    return "Used the whole budget and was still reaching new code \(renderDuration(idle)) before the end; a longer run may find more."
                }
                return "Used the whole budget; the last new code was reached \(renderDuration(idle)) before the end, so a longer run is unlikely to find more."
            case .uncontainedAsyncWork:
                return "Stopped when an attempt's asynchronous work escaped cancellation; what ran after that point would have been measured against it."
            case .attemptLimitReached, .coverageUnreachable, .instrumentationMissing, .invalidConfiguration, .generationFailed:
                return nil
        }
    }

    /// A cluster discovered late with few instances marks a fault region the search frontier had only just reached, the strongest signal to extend the budget. Those lead the inventory in both renderings.
    private static func frontierPredicate(for report: FuzzReport) -> (FuzzReport.Cluster) -> Bool {
        let frontierThreshold = report.timing.elapsed * 3 / 4
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

    /// One line on the parent domain's shape: how many entries are parents, how long they are against the whole corpus, and how the champion cells are spread over them.
    private static func renderParentProfileLine(_ profile: FuzzReport.ParentProfile, entryCount: Int) -> String {
        let lengths = "length min \(profile.minimumLength), median \(profile.medianLength), mean \(String(format: "%.1f", profile.meanLength)), max \(profile.maximumLength) (all entries mean \(String(format: "%.1f", profile.meanEntryLength)))"
        let cells = "cells per parent min \(profile.minimumCells), median \(profile.medianCells), mean \(String(format: "%.1f", profile.meanCells)), max \(profile.maximumCells)"
        return "Parents: \(profile.parentCount) of \(entryCount) entries; \(lengths); \(cells)."
    }

    /// One line naming each arm's duplicate skips, omitting arms that skipped nothing.
    private static func renderDuplicateSkipLine(_ skips: FuzzReport.DuplicateSkips) -> String {
        let arms: [(name: String, skipped: Int)] = [
            ("fresh draws", skips.freshDraw),
            ("mutation children", skips.mutationChild),
            ("reflection injection", skips.reflectionInjection),
            ("graft injection", skips.graftInjection),
            ("comparand substitution", skips.comparandSubstitution),
        ]
        let parts = arms
            .filter { $0.skipped > 0 }
            .map { "\($0.skipped) \($0.name)" }
        return "Duplicate skips by arm: \(parts.joined(separator: ", "))."
    }

    /// Renders the estimator lines: the price of one more edge and the completeness fraction against the run's own reachable set. The reachable-set scoping is stated inline so the fraction cannot be read as module coverage.
    ///
    /// The estimator is denominated in incidences, because one attempt covers many edges. Readers think in attempts, so the rate is converted back by the mean edges an attempt covers before it reaches the page.
    private static func renderEstimatorLines(_ report: FuzzReport) -> [String] {
        guard report.coverage.incidenceSamples > 0, report.coverage.coveredEdges > 0 else {
            return []
        }
        var lines: [String] = []
        let edgesPerCase = Double(report.coverage.incidenceTotal) / Double(report.coverage.incidenceSamples)
        let newEdgesPerCase = report.coverage.estimatedNextEdgeProbability * edgesPerCase
        if newEdgesPerCase > 0 {
            let attemptsPerEdge = Int((1 / newEdgesPerCase).rounded())
            lines.append(
                "Estimated chance the next attempt covers a new edge: about 1 in \(attemptsPerEdge)."
            )
        } else {
            lines.append(
                "No edge was hit by only a single incidence sample, so the estimated chance of a new edge on the next sampled case is below 1 in \(report.coverage.incidenceSamples)."
            )
        }
        // With no doubleton the Chao2 ratio never runs and the estimate degenerates to the covered count or the singleton fallback: a number that looks like a verdict and is not one.
        guard report.coverage.doubletons > 0 else {
            lines.append(
                "Too few repeat observations to estimate how many edges this generator and property can reach."
            )
            return lines
        }
        let reachable = report.coverage.estimatedReachableEdges
        let remaining = max(0, Int(reachable.rounded()) - report.coverage.coveredEdges)
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
        let suspects = terminalSuspectSymbols(for: cluster)
        guard let first = suspects.first else {
            return nil
        }
        if (first.line ?? 0) > 0 || suspects.count == 1 {
            return first.rendered
        }
        let files = Set(suspects.map(\.file))
        let hasAnyLine = suspects.contains { ($0.line ?? 0) > 0 }
        if files.count == 1, hasAnyLine == false, let file = first.file {
            return "\(suspects.map(\.displayName).joined(separator: ", ")) (\(file))"
        }
        return suspects.map(\.rendered).joined(separator: ", ")
    }

    /// How much of a cluster one block renders: the summary attachment's three-suspect form, or the cluster's own attachment with every ranked edge.
    enum ClusterDetail {
        /// A name line, an attribute line, the counterexample, and up to three user-code suspects.
        case summary
        /// The same block with the full ranked edge list and the near-miss edges in place of the three suspects.
        case full
    }

    /// Renders one cluster block: a name line, an attribute line, the reduced counterexample (collapsed onto one line when it stays readable), and then either the three terminal suspects or the whole ranked edge list, by `detail`. One renderer for both attachments, so the two cannot drift.
    static func renderClusterBlock(
        _ cluster: FuzzReport.Cluster,
        isFrontier: Bool,
        detail: ClusterDetail
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
        switch detail {
            case .summary:
                let suspects = terminalSuspects(for: cluster)
                if suspects.isEmpty == false {
                    lines.append("  suspect\(suspects.count == 1 ? "" : "s"):")
                    lines.append(contentsOf: suspects.map { "    - \($0)" })
                }
            case .full:
                if cluster.discriminatingEdges.isEmpty == false {
                    lines.append("  Suspect edges:")
                    for edge in cluster.discriminatingEdges {
                        let failPercent = Int((edge.failureHitFraction * 100).rounded())
                        let passPercent = Int((edge.passingHitFraction * 100).rounded())
                        let location = edge.symbol.map { "; \($0.rendered)" } ?? ""
                        lines.append(
                            "    edge \(edge.edgeIndex): hit in \(failPercent)% of this cluster's failures, \(passPercent)% of passing runs\(location)"
                        )
                    }
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

    /// Folds ranked candidate edges onto distinct source locations and drops the ones in synthesized bodies.
    ///
    /// Candidates arrive strongest first. The first edge for each symbol and line wins, so one function ranked at several offsets takes one slot; two resolved lines in one function stay distinct. An edge with no symbol is kept when the run never symbolized (a synthetic source, a build without a PC table) and dropped when it did, because the symbolizer omits compiler-generated globals and an unresolvable address is not a place to look either.
    static func distinctSuspectEdges(
        _ candidates: [FuzzReport.DiscriminatingEdge],
        symbolized: Bool,
        limit: Int
    ) -> [FuzzReport.DiscriminatingEdge] {
        var kept: [FuzzReport.DiscriminatingEdge] = []
        var keptSymbols: [FuzzReport.SymbolLocation] = []
        for candidate in candidates {
            guard let symbol = candidate.symbol else {
                if symbolized {
                    continue
                }
                kept.append(candidate)
                if kept.count == limit {
                    break
                }
                continue
            }
            if symbol.isSynthesized || keptSymbols.contains(where: { $0.namesSamePlace(as: symbol) }) {
                continue
            }
            kept.append(candidate)
            keptSymbols.append(symbol)
            if kept.count == limit {
                break
            }
        }
        return kept
    }

    /// Picks up to three discriminating edges worth a terminal line. Symbols with a resolved line lead (function-entry edges name a specific location; interior edges collapse to the enclosing function and read generic), and symbols that restate the symptom's own error type trail. Symbols naming one place collapse into one, and the line-first ordering makes the line-bearing form the survivor. Empty when nothing symbolized usefully.
    static func terminalSuspects(for cluster: FuzzReport.Cluster) -> [String] {
        terminalSuspectSymbols(for: cluster).map(\.rendered)
    }

    private static func terminalSuspectSymbols(for cluster: FuzzReport.Cluster) -> [FuzzReport.SymbolLocation] {
        let candidates = cluster.discriminatingEdges.compactMap(\.symbol).filter { $0.isSynthesized == false }
        let namesSymptom: (FuzzReport.SymbolLocation) -> Bool = { candidate in
            cluster.symptoms.contains { symptom in candidate.displayName.contains(symptom) }
        }
        let hasLine: (FuzzReport.SymbolLocation) -> Bool = { ($0.line ?? 0) > 0 }
        let ordered = candidates.filter { namesSymptom($0) == false && hasLine($0) }
            + candidates.filter { namesSymptom($0) == false && hasLine($0) == false }
            + candidates.filter { namesSymptom($0) && hasLine($0) }
            + candidates.filter { namesSymptom($0) && hasLine($0) == false }
        var kept: [FuzzReport.SymbolLocation] = []
        for candidate in ordered where kept.contains(where: { $0.namesSamePlace(as: candidate) }) == false {
            kept.append(candidate)
            if kept.count == 3 {
                break
            }
        }
        return kept
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
}
