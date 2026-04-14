import Testing
@testable import Exhaust

@Suite("ExhaustReport")
struct ExhaustReportTests {
    @Test("Report fires on passing property with timing and invocation counts")
    func reportOnPass() throws {
        var capturedReport: ExhaustReport?
        #exhaust(
            #gen(.int(in: 0 ... 10)),
            .onReport { capturedReport = $0 },
            .budget(.custom(coverage: 200, sampling: 50))
        ) { value in
            value >= 0
        }
        let report = try #require(capturedReport)
        #expect(report.propertyInvocations > 0)
        #expect(report.totalMilliseconds > 0)
        #expect(report.encoderProbes.isEmpty)
        #expect(report.totalMaterializations == 0)
    }

    @Test("Report fires on failing property with encoder breakdown")
    func reportOnFailure() throws {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 1000)),
            .onReport { capturedReport = $0 },
            .suppress(.issueReporting),
            .randomOnly
        ) { value in
            value < 50
        }
        #expect(result != nil)
        let report = try #require(capturedReport)
        #expect(report.propertyInvocations > 0)
        #expect(report.reductionMilliseconds > 0)
        #expect(report.totalMilliseconds > 0)
        #expect(report.encoderProbes.isEmpty == false)
        #expect(report.totalMaterializations > 0)
    }

    @Test("Report fires on reflecting path with reflection timing")
    func reportOnReflecting() throws {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .reflecting(75),
            .onReport { capturedReport = $0 },
            .suppress(.issueReporting)
        ) { value in
            value < 50
        }
        #expect(result != nil)
        let report = try #require(capturedReport)
        #expect(report.reflectionMilliseconds >= 0)
        #expect(report.reductionMilliseconds >= 0)
        #expect(report.totalMilliseconds > 0)
        #expect(report.propertyInvocations > 0)
    }

    @Test("Report property invocations include coverage and random phases")
    func reportIncludesBothPhases() throws {
        var capturedReport: ExhaustReport?
        #exhaust(
            #gen(.int(in: 0 ... 10)),
            .onReport { capturedReport = $0 },
            .budget(.custom(coverage: 100, sampling: 50))
        ) { value in
            value >= 0
        }
        let report = try #require(capturedReport)
        // Coverage phase should run (small finite domain) plus random phase
        #expect(report.propertyInvocations > 0)
        #expect(report.coverageMilliseconds >= 0)
        #expect(report.generationMilliseconds >= 0)
    }
}
