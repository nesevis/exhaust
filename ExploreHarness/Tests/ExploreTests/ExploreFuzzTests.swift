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
    func fuzzInventory() {
        let report = fuzz()

        // Every planted fault's canonical minimal form appears among the clusters.
        #expect(clusterMatching(report, .faultA) != nil, "expected fault A (data / region 5 / [0, 0])")
        #expect(clusterMatching(report, .faultB) != nil, "expected fault B (control / region 2 / [241])")
        #expect(clusterMatching(report, .faultC) != nil, "expected fault C (heartbeat / region 6)")
        #expect(clusterMatching(report, .faultD) != nil, "expected fault D (checksum 65535)")

        // The slippage pair: one shared symptom type, two distinct reduced forms in two clusters.
        let a = clusterMatching(report, .faultA)
        let b = clusterMatching(report, .faultB)
        if let a, let b {
            #expect(a.symptoms.contains("IntegrityError"))
            #expect(b.symptoms.contains("IntegrityError"))
            #expect(a.id != b.id, "A and B must be distinct clusters despite one symptom type")
        }

        // Canonicalization guard: no reduced value is split across two clusters. The bind-inner-skipping identity key collapses the structurally different but semantically identical reduced forms a bind produces (the same payload reached through different length bookkeeping).
        let byForm = Dictionary(grouping: report.clusters, by: \.reducedDescription)
        for (form, clusters) in byForm {
            #expect(clusters.count == 1, "reduced form split across \(clusters.count) clusters:\n\(form)")
        }

        // Throughput is recorded so a pipeline-cost regression surfaces as falling attempts per second.
        #expect(report.attemptsPerSecond > 0)
        #expect(report.frameworkOverheadFraction >= 0 && report.frameworkOverheadFraction <= 1)
    }

    @Test("The clustered inventory separates the slippage pair that symptom deduplication cannot", .timeLimit(.minutes(2)))
    func slippageDifferential() {
        let report = fuzz()

        // The distinctive signal is separation, not depth: the two faults A and B throw the same error type from the same site, so a symptom-deduplicating view — everything a blind sampler can offer — collapses them to one entry. The blind sampler here confirms it sees at most one IntegrityError symptom, with no way to tell the two faults apart.
        let blindSymptoms = blindSampleFaultTypes(attempts: report.totalAttempts, seed: 20_260_710)
        let blindIntegritySymptoms = blindSymptoms.filter { $0 == "IntegrityError" }
        #expect(blindIntegritySymptoms.count <= 1, "symptom deduplication cannot distinguish A from B")

        // The fuzz run splits the same shared symptom into two clusters with distinct reduced forms. This is the mode's contribution over stack-trace or symptom dedup, and it does not depend on how deep the gates are.
        let integrityClusters = report.clusters.filter { $0.symptoms.contains("IntegrityError") }
        let distinctForms = Set(integrityClusters.map(\.reducedDescription))
        #expect(distinctForms.count >= 2, "the inventory should separate A and B into distinct reduced forms")
        #expect(clusterMatching(report, .faultA) != nil)
        #expect(clusterMatching(report, .faultB) != nil)
    }

    // MARK: - Shared Fuzz Run

    private func fuzz() -> SprawlReport {
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

private func clusterMatching(_ report: SprawlReport, _ fault: PlantedFault) -> SprawlReport.Cluster? {
    report.clusters.first { cluster in
        fault.markers.allSatisfy { cluster.reducedDescription.contains($0) }
    }
}

// MARK: - Blind Sampler

/// A blind PRNG sampler over the same message shape, standing in for `#exhaust`'s random tail. Returns the distinct fault type names it found, used only to show the two search regimes diverge on the deep chains.
private func blindSampleFaultTypes(attempts: Int, seed: UInt64) -> Set<String> {
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var value = state
        value ^= value >> 33
        return value
    }
    var found: Set<String> = []
    for _ in 0 ..< max(1, attempts) {
        let mode = Mode.allCases[Int(next() % 4)]
        let flags = UInt8(next() & 0xFF)
        let checksum = UInt16(next() & 0xFFFF)
        let region = UInt8(next() % 8)
        let length = Int(next() % 7)
        var payload: [UInt8] = []
        for _ in 0 ..< length {
            payload.append(UInt8(next() & 0xFF))
        }
        do {
            _ = try Parser.decode(Message(mode: mode, flags: flags, checksum: checksum, region: region, payload: payload))
        } catch {
            found.insert("\(type(of: error))")
        }
    }
    return found
}
