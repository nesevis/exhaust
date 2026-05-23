import Testing
@testable import Exhaust

@Suite("ExhaustReport")
struct ExhaustReportTests {
    @Test
    func `Report fires on passing property with timing and invocation counts`() throws {
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

    @Test
    func `Report fires on failing property with encoder breakdown`() throws {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 1000)),
            .onReport { capturedReport = $0 },
            .suppress(.issueReporting),
            .budget(.custom(coverage: 0, sampling: 200))
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

    @Test
    func `Report fires on reflecting path with reflection timing`() throws {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            reflecting: 75,
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

    @Test
    func `Report property invocations include coverage and random phases`() throws {
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

    // MARK: - onReport fires for all closure shapes

    @Test
    func `Report fires for sync Void/#expect closure (failing)`() throws {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 1000)),
            .onReport { capturedReport = $0 },
            .suppress(.all)
        ) { value in
            #expect(value < 50)
        }
        #expect(result != nil)
        let report = try #require(capturedReport)
        #expect(report.propertyInvocations > 0)
    }

    @Test
    func `Report fires for sync Void/#expect closure (passing)`() throws {
        var capturedReport: ExhaustReport?
        #exhaust(
            #gen(.int(in: 0 ... 10)),
            .onReport { capturedReport = $0 },
            .suppress(.all)
        ) { value in
            #expect(value >= 0)
        }
        let report = try #require(capturedReport)
        #expect(report.propertyInvocations > 0)
    }

    @Test
    func `Report fires for async Bool closure (failing)`() async throws {
        var capturedReport: ExhaustReport?
        let result = await #exhaust(
            #gen(.int(in: 0 ... 1000)),
            .onReport { capturedReport = $0 },
            .suppress(.all)
        ) { value async in
            value < 50
        }
        #expect(result != nil)
        let report = try #require(capturedReport)
        #expect(report.propertyInvocations > 0)
    }

    @Test
    func `Report fires for async Void/#expect closure (failing)`() async throws {
        var capturedReport: ExhaustReport?
        let result = await #exhaust(
            #gen(.int(in: 0 ... 1000)),
            .onReport { capturedReport = $0 },
            .suppress(.all)
        ) { value async in
            #expect(value < 50)
        }
        #expect(result != nil)
        let report = try #require(capturedReport)
        #expect(report.propertyInvocations > 0)
    }
}
