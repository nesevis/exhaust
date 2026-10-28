import ExhaustSupport
import Foundation
import Testing
@testable import ExhaustExploreCommand

@Suite("Campaign report aggregation")
struct CampaignReportsTests: CampaignReportsFixtures {
    @Test("Completed and interrupted calls survive a failed test process, including repeated seeds")
    func partialResults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = try makeReports(directory)
        try reports.prepare()
        let completed = CampaignState.completed(fixtureCompletion(outcome: .passed, seed: "18446744073709551615"))
        for (id, state) in [("first", completed), ("second", completed), ("third", .running)] {
            var record = fixtureRecord(id: id, state: state)
            record.attachments = ["\(id).txt"]
            try JSONEncoder().encode(record).write(to: reports.records.appendingPathComponent("\(id).json"))
            if record.status == .completed {
                try publishEvents(for: record, in: reports)
            }
        }
        try Data("<testsuites/>".utf8).write(to: directory.appendingPathComponent("xunit-swift-testing.xml"))
        try reports.finish(error: ChildFailure(status: 1))
        let aggregate = try read(reports.report)
        #expect(aggregate.status == .failed)
        #expect(aggregate.exitCode == 1)
        #expect(aggregate.xunitFiles == ["xunit-swift-testing.xml"])
        let campaigns = aggregate.campaigns
        #expect(campaigns.count == 3)
        #expect(campaigns.last?.status == .interrupted)
        #expect(aggregate.totals.completed == 2)
        #expect(campaigns.first?.attachments == ["attachments/\(reports.runID)/first.txt"])
        let events = try readEvents(reports)
        #expect(events.suffix(2).map(\.type) == [.campaignInterrupted, .runFinished])
        guard case let .runFinished(finished)? = events.last?.payload else {
            Issue.record("The stream did not end with run.finished")
            return
        }
        #expect(finished.exitCode == 1)
    }

    @Test("Each invocation resets aggregate and xUnit results without collecting old campaign records")
    func repeatedCommand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = try makeReports(directory)
        try previous.prepare()
        try Data("previous XML".utf8).write(to: previous.xunit)
        try Data("invalid old record".utf8).write(to: previous.records.appendingPathComponent("old.json"))
        let next = try makeReports(directory)
        try next.prepare()
        try next.finish()
        #expect(FileManager.default.fileExists(atPath: previous.xunit.path) == false)
        #expect(try readStream(next).allSatisfy { $0.runID == next.runID })
        #expect(try read(next.report).status == .succeeded)
        #expect(try read(next.report).campaigns.isEmpty)
        #expect(FileManager.default.fileExists(atPath: previous.records.appendingPathComponent("old.json").path))
    }

    @Test(
        "Corrupt or incomplete runtime records fail reporting instead of silently disappearing",
        arguments: [true, false]
    )
    func reportingFailures(corrupt: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = try makeReports(directory)
        try reports.prepare()
        let data = switch corrupt {
            case true:
                Data("broken JSON".utf8)
            case false:
                try JSONEncoder().encode(fixtureRecord(id: "case"))
        }
        try data.write(to: reports.records.appendingPathComponent("case.json"))
        #expect(throws: CommandError.self) { try reports.finish() }
        #expect(try read(reports.report).status == .failed)
    }

    @Test(
        "A completed runtime record without its required completion data fails reporting instead of counting as completed",
        arguments: ["finishedAt", "issuesSuppressed", "outcome", "report"]
    )
    func incompleteCompletedRecord(missingKey: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = try makeReports(directory)
        try reports.prepare()
        let record = fixtureRecord(id: "case", state: .completed(fixtureCompletion(outcome: .passed)))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(object.removeValue(forKey: missingKey) != nil)
        try JSONSerialization.data(withJSONObject: object).write(to: reports.records.appendingPathComponent("case.json"))
        #expect(throws: CommandError.self) { try reports.finish() }
        let aggregate = try read(reports.report)
        #expect(aggregate.status == .failed)
        #expect(aggregate.reportingErrors.count == 1)
        #expect(aggregate.totals.completed == 0)
    }

    @Test("The terminal summary states the verdict and exit status and ends with the report path", arguments: [true, false])
    func terminalSummary(hasChildFailure: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = try makeReports(directory)
        try reports.prepare()
        try reports.update(phase: .testing)
        let error: ChildFailure? = switch hasChildFailure {
            case true:
                ChildFailure(status: 1)
            case false:
                nil
        }
        try reports.finish(error: error)
        let lines = try reports.summary(of: read(reports.report)).split(separator: "\n").map(String.init)
        let expectedVerdict = switch hasChildFailure {
            case true:
                "Explore failed during testing: SwiftPM exited with status 1."
            case false:
                "Explore succeeded."
        }
        #expect(lines == [
            expectedVerdict,
            "No #explore(time:) campaigns ran.",
            "Report: \(reports.report.nativePath)",
        ])
    }

    @Test("The terminal summary counts campaigns and lists the xUnit files SwiftPM wrote")
    func terminalSummaryWithCampaigns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = try makeReports(directory)
        try reports.prepare()
        for (id, outcome) in [("first", ExhaustSupport.CampaignOutcome.passed), ("second", .failed)] {
            let record = fixtureRecord(id: id, state: .completed(fixtureCompletion(outcome: outcome)))
            try JSONEncoder().encode(record).write(to: reports.records.appendingPathComponent("\(id).json"))
            try publishEvents(for: record, in: reports)
        }
        try Data("<testsuites/>".utf8).write(to: reports.xunit)
        try reports.finish(error: ChildFailure(status: 1))
        let lines = try reports.summary(of: read(reports.report)).split(separator: "\n").map(String.init)
        #expect(lines == [
            "Explore failed during preparing: SwiftPM exited with status 1.",
            "Campaigns: 2 (passed 1, failed 1, skipped 0, error 0, interrupted 0).",
            "Report: \(reports.report.nativePath)",
            "xUnit: \(reports.xunit.nativePath)",
        ])
    }

    @Test(
        "Terminal publication failures mark the authoritative report failed and preserve child errors",
        arguments: [true, false], [true, false]
    )
    func terminalPublicationFailure(hasChildFailure: Bool, hasInterruptedCampaign: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = try makeReports(directory)
        func execute() throws {
            try reports.finalizing {
                if hasInterruptedCampaign {
                    let record = fixtureRecord(id: "unfinished")
                    try JSONEncoder().encode(record)
                        .write(to: reports.records.appendingPathComponent("unfinished.json"))
                }
                try FileManager.default.removeItem(at: reports.events.path)
                try FileManager.default.createDirectory(at: reports.events.path, withIntermediateDirectories: false)
                if hasChildFailure {
                    throw ChildFailure(status: 9)
                }
            }
        }
        if hasChildFailure {
            let failure = #expect(throws: ChildFailure.self) { try execute() }
            #expect(failure?.status == 9)
        } else {
            #expect(throws: (any Error).self) { try execute() }
        }
        let aggregate = try read(reports.report)
        #expect(aggregate.status == .failed)
        #expect(aggregate.reportingErrors.count == 1)
        #expect(aggregate.reportingErrors.first?.hasPrefix("Cannot publish terminal campaign events:") == true)
        #expect(aggregate.totals.interrupted == (hasInterruptedCampaign ? 1 : 0))
        #expect(aggregate.exitCode == (hasChildFailure ? 9 : nil))
        #expect(aggregate.error == (hasChildFailure ? String(describing: ChildFailure(status: 9)) : nil))
    }

    @Test("Output-relative paths reject traversal, sibling prefixes, and symlink escapes")
    func pathContainment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = CampaignPaths(root: root)
        #expect(try paths
            .relative(root.appendingPathComponent("attachments/run/summary.txt")) == "attachments/run/summary.txt")
        #expect(throws: CommandError.self) { try paths.relative(root.appendingPathComponent("../escape.txt")) }
        #expect(throws: CommandError.self) {
            try paths.relative(directory.appendingPathComponent("output-other/report.json"))
        }
        #if os(Windows)
        #else
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("linked"),
                withDestinationURL: directory
            )
            #expect(throws: CommandError.self) { try paths.relative(root.appendingPathComponent("linked/escape.txt")) }
        #endif
    }

    // MARK: - Helpers

    private func fixtureCompletion(outcome: CampaignOutcome, seed: String? = "1") -> CampaignCompletion {
        CampaignCompletion(
            finishedAt: 1,
            seed: seed,
            issuesSuppressed: false,
            outcome: outcome,
            report: CampaignWireReport(
                termination: .init(reason: .budgetExhausted),
                resumedFromCrash: false,
                attempts: .init(
                    total: 0,
                    evaluated: 0,
                    judged: 0,
                    rejected: 0,
                    screening: 0,
                    sampling: 0,
                    mutation: 0,
                    discardedByProperty: 0,
                    discardedByMaterializer: 0,
                    duplicatesSkipped: 0,
                    mutationArmAttempts: [:],
                    mutationArmPassed: [:],
                    mutationArmFailed: [:],
                    mutationArmDiscarded: [:]
                ),
                invocations: .init(
                    total: 0,
                    search: 0,
                    prune: 0,
                    reduction: 0,
                    normalization: 0,
                    classification: 0,
                    recovery: 0
                ),
                coverage: .init(
                    corpusEntryCount: 0,
                    parentCount: 0,
                    parentRootPhases: [:],
                    coveredEdges: 0,
                    instrumentedEdges: 0,
                    offLaneHits: 0,
                    incidenceSamples: 0,
                    incidenceTotal: 0,
                    estimatedReachableEdges: FiniteNumber(0),
                    estimatedNextEdgeProbability: FiniteNumber(0)
                ),
                timing: .init(
                    elapsedSeconds: 0,
                    lastDiscoverySeconds: 0,
                    propertySeconds: 0,
                    reductionSeconds: 0,
                    screeningOverheadSeconds: 0,
                    samplingOverheadSeconds: 0,
                    mutationOverheadSeconds: 0,
                    otherSeconds: 0,
                    testingOverheadFraction: FiniteNumber(0),
                    attemptsPerSecond: FiniteNumber(0)
                ),
                clusters: [],
                unreducedFailureCounts: [:],
                reproduction: nil
            )
        )
    }
}
