import Testing
@testable import Exhaust

@Suite("Parallel generation", .serialized)
struct ParallelGenerationTests {
    @Test
    func `All iterations run when no counterexample exists`() {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.standard),
            .parallelize(2),
            .randomOnly,
            .onReport { capturedReport = $0 }
        ) { $0 >= 0 }

        #expect(result == nil)
        #expect(capturedReport?.randomSamplingInvocations == 200)
    }

    @Test
    func `First failure cancels remaining lanes before the full budget is consumed`() throws {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 10000)),
            .budget(.extensive),
            .parallelize(2),
            .randomOnly,
            .suppress(.issueReporting),
            .onReport { capturedReport = $0 }
        ) { $0 < 5 }

        #expect(result != nil)
        let report = try #require(capturedReport)
        #expect(report.randomSamplingInvocations < 2000, "Should stop early, not run the full budget")
    }

    @Test
    func `Each lane produces stats lines tagged with its lane index`() throws {
        var capturedReport: ExhaustReport?
        #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.custom(coverage: 0, sampling: 101)),
            .parallelize(2),
            .randomOnly,
            .collectOpenPBTStats,
            .onReport { capturedReport = $0 }
        ) { $0 >= 0 }

        let report = try #require(capturedReport)
        let lines = report.openPBTStatsLines
        #expect(lines.isEmpty == false)
        #expect(lines.allSatisfy { $0.lane != nil })
        let observedLanes = Set(lines.compactMap(\.lane))
        #expect(observedLanes.count == 2)
    }
}
