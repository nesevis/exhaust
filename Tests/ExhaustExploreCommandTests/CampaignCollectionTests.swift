import ExhaustSupport
import Foundation
import Testing
@testable import Exhaust
@testable import ExhaustExploreCommand

/// Drives the runtime's ``FuzzCampaignRecord`` against the command's collector, so these tests cover the wire contract between the two modules rather than either alone.
@Suite("Campaign publication collection")
struct CampaignCollectionTests: CampaignReportsFixtures {
    @Test("Parallel campaigns publish complete JSONL records with causal order and no duplicates")
    func parallelEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = try makeReports(directory)
        try reports.prepare()
        let records = reports.records
        let ids = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for seed in 0 ..< 64 {
                group.addTask {
                    let record = try recording(directory: records, seed: UInt64(seed))
                    try record.finish(
                        report: .empty(termination: .instrumentationMissing, seed: UInt64(seed)),
                        attachments: [],
                        issuesSuppressed: true
                    )
                    return record.id
                }
            }
            var result: [String] = []
            for try await id in group {
                result.append(id)
            }
            return result
        }
        reports.events.collect()
        let before = try Data(contentsOf: reports.events.path)
        reports.events.collect()
        #expect(try Data(contentsOf: reports.events.path) == before)
        try reports.finish()
        let lines = try readStream(reports)
        let events = lines.map(\.event)
        #expect(events.first?.type == .runStarted)
        #expect(events.last?.type == .runFinished)
        #expect(lines.map(\.sequence) == Array(lines.indices))
        #expect(Set(lines.map(\.runID)) == [reports.runID])
        #expect(Set(events.map(\.eventID)).count == events.count)
        for id in ids {
            let campaign = events.filter { $0.campaignID == id }
            #expect(campaign.map(\.type) == [.campaignStarted, .campaignFinished])
            guard case let .campaignFinished(record)? = campaign.last?.payload else {
                Issue.record("Campaign \(id) did not end with campaign.finished")
                continue
            }
            #expect(record.recordPath == "attachments/\(reports.runID)/campaigns/\(id).json")
        }
        #expect(events.count == 3 + ids.count * 2)
    }

    @Test("Started campaigns are visible before completion; malformed spool events fail the run")
    func liveAndMalformedEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = try makeReports(directory)
        try reports.prepare()
        let record = try recording(directory: reports.records, seed: nil)
        reports.events.collect()
        #expect(try readEvents(reports).last?.campaignID == record.id)
        #expect(try readEvents(reports).last?.type == .campaignStarted)
        try Data("broken".utf8).write(to: reports.events.spool.appendingPathComponent("bad.json"), options: .atomic)
        #expect(throws: CommandError.self) { try reports.finish() }
        let aggregate = try read(reports.report)
        #expect(aggregate.reportingErrors.count == 1)
        #expect(aggregate.status == .failed)
        let events = try readEvents(reports)
        #expect(events.suffix(2).map(\.type) == [.campaignInterrupted, .runFinished])
        guard case let .runFinished(finished)? = events.last?.payload else {
            Issue.record("The stream did not end with run.finished")
            return
        }
        #expect(finished.status == .failed)
    }

    @Test("Collection waits for earlier campaign events and detects permanent gaps", arguments: [true, false])
    func eventOrder(restoreEarlier: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = try makeReports(directory)
        try reports.prepare()
        let record = try recording(directory: reports.records, seed: 1)
        try record.finish(
            report: .empty(termination: .instrumentationMissing, seed: 1),
            attachments: ["summary.txt"],
            issuesSuppressed: false
        )
        let earlier = reports.events.spool.appendingPathComponent("\(record.id)-00000000.json")
        let hidden = earlier.appendingPathExtension("pending")
        try FileManager.default.moveItem(at: earlier, to: hidden)
        reports.events.collect()
        #expect(try readEvents(reports).count == 2)
        if restoreEarlier {
            try FileManager.default.moveItem(at: hidden, to: earlier)
            try reports.finish()
            let events = try readEvents(reports).filter { $0.campaignID == record.id }
            #expect(events.map(\.type) == [.campaignStarted, .campaignFinished])
            guard case let .campaignFinished(finished)? = events.last?.payload else {
                Issue.record("The campaign did not end with campaign.finished")
                return
            }
            #expect(finished.attachments == ["attachments/\(reports.runID)/summary.txt"])
        } else {
            #expect(throws: CommandError.self) { try reports.finish() }
            #expect(try read(reports.report).reportingErrors.count == 1)
        }
    }

    @Test("The command preserves typed runtime reports without losing integer precision")
    func wireRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = try makeReports(directory)
        try reports.prepare()
        let record = try recording(directory: reports.records, seed: UInt64.max)
        try record.finish(
            report: .empty(termination: .instrumentationMissing, seed: UInt64.max),
            attachments: ["summary.txt"],
            issuesSuppressed: true
        )
        try reports.finish()
        let aggregate = try read(reports.report)
        let collected = try #require(aggregate.campaigns.first)
        let decoded = try JSONDecoder().decode(CampaignRecord.self, from: JSONEncoder().encode(collected))
        guard case let .completed(completion) = decoded.state else {
            Issue.record("Expected a completed campaign, got \(decoded.status)")
            return
        }
        #expect(completion.seed == String(UInt64.max))
        #expect(decoded.requestedSeed == String(UInt64.max))
        #expect(decoded.outcome == .skipped)
        #expect(completion.report.termination.reason == .instrumentationMissing)
        #expect(completion.report.attempts.total == 0)
        #expect(decoded.source.line == 1)
        #expect(decoded.checkpointPath == record.context.store.directory.path)
        #expect(decoded.attachments == ["attachments/\(reports.runID)/summary.txt"])
    }

    @Test("Finalization preserves child errors and emits exactly one terminal event", arguments: [true, false])
    func finalization(hasChildFailure: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = try makeReports(directory)
        func execute() throws {
            try reports.finalizing {
                _ = try recording(directory: reports.records, seed: 1)
                if hasChildFailure {
                    throw ChildFailure(status: 9)
                }
            }
        }
        if hasChildFailure {
            let failure = #expect(throws: ChildFailure.self) { try execute() }
            #expect(failure?.status == 9)
        } else {
            #expect(throws: CommandError.self) { try execute() }
        }
        let aggregate = try read(reports.report)
        #expect(aggregate.status == .failed)
        #expect(aggregate.totals.interrupted == 1)
        let expectedExitCode: Int32? = switch hasChildFailure {
            case true:
                9
            case false:
                nil
        }
        #expect(aggregate.exitCode == expectedExitCode)
        #expect(try readEvents(reports).count(where: { $0.type == .runFinished }) == 1)
    }

    @Test("Scoped collection publishes live events and stops before returning", arguments: [true, false])
    func scopedCollection(bodyThrows: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = try makeReports(directory)
        try reports.prepare()
        let record = try recording(directory: reports.records, seed: 1)
        func execute() throws {
            try reports.events.collecting {
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    let text = try String(contentsOf: reports.events.path, encoding: .utf8)
                    let latest = text.split(separator: "\n").last.flatMap {
                        try? JSONDecoder().decode(CampaignEvent.self, from: Data($0.utf8))
                    }
                    if text.hasSuffix("\n"), latest?.type == .campaignStarted {
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                #expect(try readEvents(reports).last?.campaignID == record.id)
                #expect(try readEvents(reports).last?.type == .campaignStarted)
                if bodyThrows {
                    throw ChildFailure(status: 9)
                }
            }
        }
        if bodyThrows {
            #expect(throws: ChildFailure.self) { try execute() }
        } else {
            try execute()
        }
        let before = try Data(contentsOf: reports.events.path)
        try record.finish(
            report: .empty(termination: .instrumentationMissing, seed: 1),
            attachments: [],
            issuesSuppressed: true
        )
        Thread.sleep(forTimeInterval: 0.3)
        #expect(try Data(contentsOf: reports.events.path) == before)
        try reports.finish()
        #expect(try readEvents(reports).suffix(2).map(\.type) == [.campaignFinished, .runFinished])
    }

    // MARK: - Helpers

    private func recording(directory: URL, seed: UInt64?) throws -> FuzzCampaignRecord {
        let context = FuzzCampaignContext(
            fileID: "Tests/Test.swift",
            filePath: "/tests/Test.swift",
            line: 1,
            column: 1,
            testID: "Tests/test(seed:)",
            testName: "test",
            seed: seed,
            kind: .value,
            time: .seconds(1),
            environment: [:]
        )
        let record = FuzzCampaignRecord(directory: directory, context: context)
        try record.start()
        return record
    }
}
