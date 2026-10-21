import Exhaust
import ExhaustCore
import ExploreFixture
import Foundation
import Testing

/// The instrumented end-to-end validation: a real `#explore(time:)` fuzz run against the coverage-instrumented
/// fixture, asserting the clustered fault inventory separates and merges what it should.
///
/// Assertions are deliberately tolerant of reduction quality. Reduction is not guaranteed canonical on a real SUT, so a fault can leave a near-minimal residual alongside its minimal form (a masked-bit gate that reduces to `flags: 76` in one instance and `flags: 12` in another). The harness validates that the mode finds and separates the faults and surfaces each canonical minimal form — not that reduction is optimal.
@Suite("Explore fuzz validation", .serialized)
struct ExploreFuzzTests {
    @Test("A fuzz run finds every catchable fault, separates the slippage pair, and never over-splits one value", .timeLimit(.minutes(2)))
    func fuzzInventory() throws {
        let report = Self.report

        // Every planted fault's canonical minimal form appears among the clusters.
        let faultA = try #require(clusterMatching(report, .faultA), "expected fault A (data / region 5 / [0, 0])")
        let faultB = try #require(clusterMatching(report, .faultB), "expected fault B (control / region 2 / [241])")
        #expect(clusterMatching(report, .faultC) != nil, "expected fault C (heartbeat / region 6)")
        #expect(clusterMatching(report, .faultD) != nil, "expected fault D (checksum 65535)")

        // The slippage pair: one shared symptom type, two distinct reduced forms in two clusters.
        #expect(faultA.symptoms.contains("IntegrityError"))
        #expect(faultB.symptoms.contains("IntegrityError"))
        #expect(faultA.id != faultB.id)
        #expect(faultA.reducedDescription != faultB.reducedDescription)

        // Canonicalization guard: no reduced value is split across two clusters. The bind-inner-skipping identity key collapses the structurally different but semantically identical reduced forms a bind produces (the same payload reached through different length bookkeeping).
        let byForm = Dictionary(grouping: report.clusters, by: \.reducedDescription)
        for (form, clusters) in byForm {
            #expect(clusters.count == 1, "reduced form split across \(clusters.count) clusters:\n\(form)")
        }

        // Throughput is recorded so a pipeline-cost regression surfaces as falling attempts per second.
        #expect(report.attemptsPerSecond > 0)
        #expect(report.timing.testingOverheadFraction >= 0 && report.timing.testingOverheadFraction <= 1)
    }

    @Test("The reported summary names the function that threw for every cluster", .timeLimit(.minutes(2)))
    func summaryAttribution() {
        let summary = Self.summary

        // The suspect form is the debugger's simplified name, what a developer reads in the failure message, and each fault names the branch it threw from.
        #expect(summary.contains("static Parser.validateWindow(_:) (Parser.swift)"))
        #expect(summary.contains("static Parser.decodeData(_:) (Parser.swift)"))
        #expect(summary.contains("static Parser.decodeControl(_:) (Parser.swift)"))
        #expect(summary.contains("static Parser.checkChecksum(_:) (Parser.swift)"))

        // Function-entry edges resolve to a line; interior edges collapse to the bare file rather than rendering a misleading `:0`.
        #expect(summary.contains("static Parser.integrityCheck(mode:) (Parser.swift:121)"))

        // The seed reaches the report, so the run a reader replays is the run that produced these clusters.
        #expect(summary.contains("Reproduce: .replay(20260710)"))
    }

    @Test("The reported summary separates the slippage pair by decoder frame", .timeLimit(.minutes(2)))
    func summarySlippagePairSeparation() {
        let summary = Self.summary
        guard let faultA = clusterMatching(Self.report, .faultA),
              let faultB = clusterMatching(Self.report, .faultB),
              let data = block(for: faultA, in: summary),
              let control = block(for: faultB, in: summary)
        else {
            Issue.record("expected a rendered block for each half of the slippage pair:\n\(summary)")
            return
        }

        // Both halves throw from one site, so the line a stack trace would print is identical for the two.
        #expect(data.contains("static Parser.integrityCheck(mode:) (Parser.swift:121)"))
        #expect(control.contains("static Parser.integrityCheck(mode:) (Parser.swift:121)"))

        // The suspect list reaches past the shared throw site to the decoder that selected the branch, which is what shows the reader these are two faults rather than one.
        #expect(data.contains("static Parser.decodeData(_:) (Parser.swift)"))
        #expect(data.contains("decodeControl") == false)
        #expect(control.contains("static Parser.decodeControl(_:) (Parser.swift)"))
        #expect(control.contains("decodeData") == false)
    }

    // MARK: - Shared Fuzz Run

    /// One instrumented run for the whole suite. Swift Testing builds a fresh suite value per test, so a per-test call would spend the full wall-clock budget repeatedly and leave each test describing a different campaign.
    private static let report = fuzz()

    /// The shared run's rendered inventory, in the attachment form that carries every suspect. The terminal form names one suspect per cluster, which cannot separate the slippage pair; ``FuzzReport/renderedAttachmentSummary()`` re-renders on every call, and every assertion against it wants the same text.
    private static let summary = ExploreFuzzTests.report.renderedAttachmentSummary()

    private static func fuzz() -> FuzzReport {
        // A throwing single-expression property, so each distinct fault type flows through as its own symptom rather than collapsing to a bare returnedFalse.
        #explore(
            Fixture.messageGenerator,
            time: .seconds(8),
            .replay(20_260_710),
            .suppress(.issueReporting)
        ) { message in
            try Parser.decode(message).byteCount >= 0
        }
    }
}

// MARK: - Fault Matching

/// A planted fault, identified by substrings its canonical reduced description must contain.
private enum PlantedFault {
    case faultA
    case faultB
    case faultC
    case faultD

    /// Substrings the reduced description must all contain to count as this fault. Chosen to survive incomplete reduction of unrelated fields (for example extra flag bits) while still pinning mode, region, and payload.
    var markers: [String] {
        switch self {
            case .faultA: [".data", "region: 5", "[0]: 0", "[1]: 0"]
            case .faultB: [".control", "region: 2", "[0]: 241"]
            case .faultC: [".heartbeat", "region: 6"]
            case .faultD: ["checksum: 65535"]
        }
    }
}

private func clusterMatching(_ report: FuzzReport, _ fault: PlantedFault) -> FuzzReport.Cluster? {
    report.clusters.first { cluster in
        fault.markers.allSatisfy { cluster.reducedDescription.contains($0) }
    }
}

/// The rendered block for `cluster`, taken from the summary's blank-line-separated sections.
///
/// Found by displayed cluster number rather than by matching counterexample text: the summary rewrites a counterexample when it collapses a multi-line dump onto one line, dropping the per-index labels ``PlantedFault/markers`` relies on. The number is stable because a cluster's `id` stays its position in the report even though the summary orders frontier clusters first.
private func block(for cluster: FuzzReport.Cluster, in summary: String) -> String? {
    summary.components(separatedBy: "\n\n").first { $0.hasPrefix("Cluster \(cluster.id + 1) ") }
}
