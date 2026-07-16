import Foundation
import Testing
@testable import Exhaust

@Suite("ExhaustReport")
struct ExhaustReportTests {
    @Test("Report fires on passing property with timing and invocation counts")
    func reportFiresOnPassingPropertyWithTimingAndInvocationCounts() throws {
        var capturedReport: ExhaustReport?
        #exhaust(
            #gen(.int(in: 0 ... 10)),
            .onReport { capturedReport = $0 },
            .budget(.custom(screening: 200, sampling: 50))
        ) { value in
            value >= 0
        }
        let report = try #require(capturedReport)
        #expect(report.propertyInvocations > 0)
        #expect(report.totalMilliseconds > 0)
        #expect(report.encoderProbes.isEmpty)
        #expect(report.totalMaterializations == 0)
        #expect(report.reductionProbes == 0)
    }

    @Test("Suppressing attachments still collects OpenPBTStats into the report")
    func suppressedAttachmentsStillCollectStats() throws {
        // .suppress(.attachments) skips only the attachment write; the collected lines must still reach the report for .onReport consumers.
        var capturedReport: ExhaustReport?
        #exhaust(
            #gen(.int(in: 0 ... 10)),
            .collectOpenPBTStats,
            .suppress(.attachments),
            .onReport { capturedReport = $0 },
            .budget(.custom(screening: 0, sampling: 50))
        ) { value in
            value >= 0
        }
        let report = try #require(capturedReport)
        #expect(report.openPBTStatsLines.isEmpty == false)
    }

    @Test("Report fires on failing property with encoder breakdown")
    func reportFiresOnFailingPropertyWithEncoderBreakdown() throws {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 1000)),
            .onReport { capturedReport = $0 },
            .suppress(.issueReporting),
            .budget(.custom(screening: 0, sampling: 200))
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
        #expect(report.reductionProbes == report.reductionProbesRejectedByCache
            + report.reductionProbesRejectedDuringMaterialization
            + report.reductionProbesWherePropertyPassed
            + report.reductionProbesWherePropertyFailed)
        #expect(report.reductionInvocations == report.reductionProbesWherePropertyPassed
            + report.reductionProbesWherePropertyFailed)
        #expect(report.reductionProbesAccepted <= report.reductionProbesWherePropertyFailed)

        let materializedProbes = report.reductionProbes - report.reductionProbesRejectedByCache
        #expect(report.totalMaterializations >= materializedProbes)
        #expect(report.totalMaterializations <= materializedProbes * 2)

        for encoderName in report.encoderProbes.keys {
            let terminalOutcomes =
                (report.encoderProbesRejectedByCache[encoderName] ?? 0)
                    + (report.encoderProbesRejectedDuringMaterialization[encoderName] ?? 0)
                    + (report.encoderProbesWherePropertyPassed[encoderName] ?? 0)
                    + (report.encoderProbesWherePropertyFailed[encoderName] ?? 0)
            #expect(report.encoderProbes[encoderName] == terminalOutcomes)
            #expect((report.encoderProbesAccepted[encoderName] ?? 0)
                <= (report.encoderProbesWherePropertyFailed[encoderName] ?? 0))

            let combinedRejections =
                (report.encoderProbesRejectedDuringMaterialization[encoderName] ?? 0)
                    + (report.encoderProbesWherePropertyPassed[encoderName] ?? 0)
                    + (report.encoderProbesWherePropertyFailed[encoderName] ?? 0)
                    - (report.encoderProbesAccepted[encoderName] ?? 0)
            #expect(report.encoderProbesRejectedByDecoder[encoderName] == combinedRejections)
        }
    }

    @Test("Report fires on reflecting path with reflection timing")
    func reportFiresOnReflectingPathWithReflectionTiming() throws {
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

    @Test("Report property invocations include screening and random phases")
    func reportPropertyInvocationsIncludeScreeningAndRandomPhases() throws {
        var capturedReport: ExhaustReport?
        #exhaust(
            #gen(.int(in: 0 ... 10)),
            .onReport { capturedReport = $0 },
            .budget(.custom(screening: 100, sampling: 50))
        ) { value in
            value >= 0
        }
        let report = try #require(capturedReport)
        // Screening phase should run (small finite domain) plus random phase
        #expect(report.propertyInvocations > 0)
        #expect(report.screeningMilliseconds >= 0)
        #expect(report.generationMilliseconds >= 0)
    }

    @Test("Report distinguishes screening rows from property invocations")
    func reportDistinguishesScreeningRowsFromPropertyInvocations() throws {
        let generator = #gen(
            .int(in: 0 ... 1),
            .int(in: 0 ... 1)
        ).filter(.rejectionSampling) { value in
            value.0 == 0 && value.1 == 0
        }
        var capturedReport: ExhaustReport?

        #exhaust(
            generator,
            .budget(.custom(screening: 4, sampling: 0)),
            .onReport { capturedReport = $0 }
        ) { _ in
            true
        }

        let report = try #require(capturedReport)
        #expect(report.screeningRows == 4)
        #expect(report.screeningInvocations == 2)
        #expect(report.screeningRejectedRows == 2)
        #expect(report.screeningRows == report.screeningInvocations + report.screeningRejectedRows)
        #expect(report.propertyInvocations == report.screeningInvocations)
    }

    @Test("Report phase totals include the final assertion rerun")
    func reportPhaseTotalsIncludeFinalAssertionRerun() throws {
        let invocationCounter = LockedCounter()
        let reportCapture = ReportCapture()

        withKnownIssue {
            #exhaust(
                #gen(.just(0)),
                .replay(42),
                .budget(.custom(screening: 0, sampling: 1)),
                .onReport { reportCapture.report = $0 }
            ) { _ in
                invocationCounter.increment()
                #expect(Bool(false))
            }
        }

        let report = try #require(reportCapture.report)
        #expect(report.propertyInvocations == report.screeningInvocations
            + report.randomSamplingInvocations
            + report.reductionInvocations
            + report.diagnosticInvocations)
        #expect(report.diagnosticInvocations == 1)
        #expect(report.propertyInvocations == invocationCounter.value)
    }

    @Test("Async report phase totals include the final assertion rerun")
    func asyncReportPhaseTotalsIncludeFinalAssertionRerun() async throws {
        let invocationCounter = LockedCounter()
        let reportCapture = ReportCapture()

        await withKnownIssue {
            await #exhaust(
                #gen(.just(0)),
                .replay(42),
                .budget(.custom(screening: 0, sampling: 1)),
                .onReport { reportCapture.report = $0 }
            ) { _ async in
                invocationCounter.increment()
                #expect(Bool(false))
            }
        }

        let report = try #require(reportCapture.report)
        #expect(report.propertyInvocations == report.screeningInvocations
            + report.randomSamplingInvocations
            + report.reductionInvocations
            + report.diagnosticInvocations)
        #expect(report.diagnosticInvocations == 1)
        #expect(report.propertyInvocations == invocationCounter.value)
    }

    @Test("JSONL failure rendering escapes arbitrary counterexamples")
    func jsonlFailureRenderingEscapesArbitraryCounterexamples() throws {
        let failure = PropertyTestFailure(
            counterexample: "quote: \"value\"\npath: C:\\temporary\\file",
            original: nil,
            seed: 42,
            iteration: 3,
            phaseBudget: 10,
            blueprint: nil,
            propertyInvocations: 4
        )

        let rendered = failure.render(format: .jsonl)
        let data = try #require(rendered.data(using: .utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["event"] as? String == "property_failed")
        #expect((object["counterexample"] as? String)?.contains("temporary") == true)
    }

    // MARK: - onReport fires for all closure shapes

    @Test("Report fires for sync Void/#expect closure (failing)")
    func reportFiresForSyncVoidexpectClosureFailing() throws {
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

    @Test("Report fires for sync Void/#expect closure (passing)")
    func reportFiresForSyncVoidexpectClosurePassing() throws {
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

    @Test("Report fires for async Bool closure (failing)")
    func reportFiresForAsyncBoolClosureFailing() async throws {
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

    @Test("Report fires for async Void/#expect closure (failing)")
    func reportFiresForAsyncVoidexpectClosureFailing() async throws {
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}

private final class ReportCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ExhaustReport?

    var report: ExhaustReport? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
