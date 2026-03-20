import Testing
@testable import ExhaustCore

@Suite("LiftReport")
struct LiftReportTests {
    @Test("Empty report has zero fidelity, zero coverage, and zero total count")
    func emptyReport() {
        let report = LiftReport()
        #expect(report.fidelity == 0.0)
        #expect(report.coverage == 0.0)
        #expect(report.totalCount == 0)
    }

    @Test("All exact carry-forward yields fidelity 1.0 and coverage 1.0")
    func allExactCarryForward() {
        var report = LiftReport()
        report.record(tier: .exactCarryForward)
        report.record(tier: .exactCarryForward)
        report.record(tier: .exactCarryForward)
        #expect(report.fidelity == 1.0)
        #expect(report.coverage == 1.0)
        #expect(report.totalCount == 3)
    }

    @Test("All PRNG yields fidelity 0.0 and coverage 0.0")
    func allPrng() {
        var report = LiftReport()
        report.record(tier: .prng)
        report.record(tier: .prng)
        #expect(report.fidelity == 0.0)
        #expect(report.coverage == 0.0)
        #expect(report.totalCount == 2)
    }

    @Test("All fallback tree yields fidelity 0.5 and coverage 1.0")
    func allFallbackTree() {
        var report = LiftReport()
        report.record(tier: .fallbackTree)
        report.record(tier: .fallbackTree)
        report.record(tier: .fallbackTree)
        report.record(tier: .fallbackTree)
        #expect(report.fidelity == 0.5)
        #expect(report.coverage == 1.0)
        #expect(report.totalCount == 4)
    }

    @Test("Mixed tiers produce correct weighted fidelity and coverage")
    func mixedTiers() {
        var report = LiftReport()
        // 2 exact (2.0) + 1 fallback (0.5) + 1 PRNG (0.0) = 2.5 / 4 = 0.625
        // coverage: (2 + 1) / 4 = 0.75
        report.record(tier: .exactCarryForward)
        report.record(tier: .exactCarryForward)
        report.record(tier: .fallbackTree)
        report.record(tier: .prng)
        #expect(report.totalCount == 4)
        #expect(report.fidelity == 0.625)
        #expect(report.coverage == 0.75)
    }

    @Test("Single coordinate reports correct fidelity per tier")
    func singleCoordinate() {
        var exact = LiftReport()
        exact.record(tier: .exactCarryForward)
        #expect(exact.fidelity == 1.0)

        var fallback = LiftReport()
        fallback.record(tier: .fallbackTree)
        #expect(fallback.fidelity == 0.5)

        var prng = LiftReport()
        prng.record(tier: .prng)
        #expect(prng.fidelity == 0.0)
    }
}
