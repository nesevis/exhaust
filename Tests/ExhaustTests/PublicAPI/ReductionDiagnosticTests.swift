//
//  ReductionDiagnosticTests.swift
//  Exhaust
//

import Testing
@testable import Exhaust

// MARK: - Reduction Diagnostic Tests

/// Pins which note a failing run reports about reduction. Two of these drive a real run end to end, because the counts the note is built from land at different points in a report's life and a hand-assembled report cannot catch a call site reading one too early.
@Suite("Reduction diagnostics")
struct ReductionDiagnosticTests {
    @Test("A run whose probes never materialize reports the failure note")
    func runWhoseProbesNeverMaterializeReportsTheFailureNote() {
        var rendered = ""
        var probes = -1
        var invocations = -1
        withKnownIssue {
            // The filter admits one value in the range, so every reduced candidate is rejected during materialization and the property never sees one.
            #exhaust(
                #gen(.int(in: 98 ... 100).filter { $0 == 100 }),
                .budget(.quick),
                .onReport { report in
                    rendered = report.renderedFailure ?? ""
                    probes = report.reductionProbes
                    invocations = report.reductionInvocations
                }
            ) { (value: Int) -> Bool in
                value < 100
            }
        }

        #expect(probes > 0)
        #expect(invocations == 0)
        #expect(rendered.contains("Note: reduction failed"))
    }

    @Test("A run whose counterexample actually reduces reports no note at all")
    func runWhoseCounterexampleActuallyReducesReportsNoNote() {
        var rendered = ""
        withKnownIssue {
            #exhaust(
                #gen(.int(in: 0 ... 1000)),
                .budget(.quick),
                .onReport { report in
                    rendered = report.renderedFailure ?? ""
                }
            ) { (value: Int) -> Bool in
                value < 5
            }
        }

        #expect(rendered.isEmpty == false)
        #expect(rendered.contains("Note: reduction") == false)
        #expect(rendered.contains("Note: this result could not be reduced") == false)
    }

    @Test("Never reaching the property outranks the time limit")
    func neverReachingThePropertyOutranksTheTimeLimit() {
        let note = ReductionNote(
            probes: probeCount,
            invocations: 0,
            stalledLeafCount: stalledLeaves,
            anyAcceptanceOccurred: false,
            producedNoImprovement: true,
            wasCapped: true
        )

        #expect(note == .noCandidateMaterialized)
    }

    @Test("The time limit outranks a stall")
    func theTimeLimitOutranksAStall() {
        let note = ReductionNote(
            probes: probeCount,
            invocations: probeCount,
            stalledLeafCount: stalledLeaves,
            anyAcceptanceOccurred: false,
            producedNoImprovement: true,
            wasCapped: true
        )

        #expect(note == .timeLimit)
    }

    @Test("A stall outranks a plain lack of improvement")
    func aStallOutranksAPlainLackOfImprovement() {
        let note = ReductionNote(
            probes: probeCount,
            invocations: probeCount,
            stalledLeafCount: stalledLeaves,
            anyAcceptanceOccurred: false,
            producedNoImprovement: true,
            wasCapped: false
        )

        #expect(note == .stalled)
    }

    @Test("A run that improved and finished reports nothing")
    func runThatImprovedAndFinishedReportsNothing() {
        let note = ReductionNote(
            probes: probeCount,
            invocations: probeCount,
            stalledLeafCount: stalledLeaves,
            anyAcceptanceOccurred: true,
            producedNoImprovement: false,
            wasCapped: false
        )

        #expect(note == nil)
    }
}

// MARK: - Helpers

private extension ReductionDiagnosticTests {
    /// Any nonzero probe count. Only its relation to the invocation count carries meaning.
    var probeCount: Int {
        8
    }

    /// Any nonzero stalled-leaf count.
    var stalledLeaves: Int {
        2
    }
}
