import Exhaust
import Testing

@Suite("Parallel generation", .serialized)
struct ParallelGenerationTests {
    @Test("All iterations run when no counterexample exists")
    func allIterationsRunWhenNoCounterexampleExists() {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.custom(screening: 0, sampling: 200)),
            .parallelize(lanes: .two),
            .onReport { capturedReport = $0 }
        ) { $0 >= 0 }

        #expect(result == nil)
        #expect(capturedReport?.randomSamplingInvocations == 200)
    }

    @Test("First failure cancels remaining lanes before the full budget is consumed")
    func firstFailureCancelsRemainingLanesBeforeTheFullBudgetIsConsumed() throws {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 10000)),
            .budget(.custom(screening: 0, sampling: 2000)),
            .parallelize(lanes: .two),
            .suppress(.issueReporting),
            .onReport { capturedReport = $0 }
        ) { $0 < 5 }

        #expect(result != nil)
        let report = try #require(capturedReport)
        #expect(report.randomSamplingInvocations < 2000, "Should stop early, not run the full budget")
    }

    @Test("Each lane produces stats lines tagged with its lane index")
    func eachLaneProducesStatsLinesTaggedWithItsLaneIndex() throws {
        var capturedReport: ExhaustReport?
        #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.custom(screening: 0, sampling: 101)),
            .parallelize(lanes: .two),
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
