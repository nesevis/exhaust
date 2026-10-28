import ExhaustSupport
import Foundation
import Testing
@testable import ExhaustExploreCommand

/// Shares the command-side report fixtures between the aggregation, collection, and sequencing suites, which each build a ``CampaignReports`` over a scratch output root and read back what it wrote.
protocol CampaignReportsFixtures {}

extension CampaignReportsFixtures {
    func makeReports(_ directory: URL) throws -> CampaignReports {
        let package = try JSONDecoder().decode(
            PackageDescription.self,
            from: Data(
                #"{"name":"Fixture","products":[],"targets":[{"name":"Library","c99name":"Library","type":"library","module_type":"SwiftTarget"},{"name":"Tests","c99name":"Tests","type":"test","module_type":"SwiftTarget"}]}"#
                    .utf8
            )
        )
        let options = try Options.parse(["explore", "--instrument", "Library", "--output", directory.path])
        let plan = try CampaignPlan(
            options: options,
            invocation: Invocation(),
            package: package,
            outputDirectory: directory.appendingPathComponent("build"),
            environment: [:]
        )
        return CampaignReports(plan: plan, options: options)
    }

    func fixtureRecord(id: String, state: CampaignState = .running) -> CampaignRecord {
        CampaignRecord(
            id: id,
            state: state,
            source: CampaignSource(fileID: "Tests/Test.swift", line: 1, column: 1),
            kind: .value,
            declaredBudgetSeconds: 1,
            startedAt: 0,
            checkpointPath: "state/fixture"
        )
    }

    /// Publishes the started and finished spool events the runtime writes around a completed record, so a hand-built record passes stream reconciliation.
    func publishEvents(for record: CampaignRecord, in reports: CampaignReports) throws {
        let payloads: [CampaignEventPayload] = [.campaignStarted(record), .campaignFinished(record)]
        for (index, payload) in payloads.enumerated() {
            let eventID = CampaignWire.eventID(campaignID: record.id, sequence: index)
            let event = CampaignEvent(
                eventID: eventID,
                campaignID: record.id,
                campaignSequence: index,
                timestamp: 0,
                payload: payload
            )
            try JSONEncoder().encode(event).write(to: CampaignWire.jsonURL(in: reports.events.spool, id: eventID))
        }
    }

    /// Decodes every stream line with its run correlation, requiring the stream to end on a complete line.
    func readStream(_ reports: CampaignReports) throws -> [CampaignStreamEvent] {
        let text = try String(contentsOf: reports.events.path, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        return try text.split(separator: "\n").map { try JSONDecoder().decode(CampaignStreamEvent.self, from: Data($0.utf8)) }
    }

    func readEvents(_ reports: CampaignReports) throws -> [CampaignEvent] {
        try readStream(reports).map(\.event)
    }

    func read(_ file: URL) throws -> CampaignReport {
        try JSONDecoder().decode(CampaignReport.self, from: Data(contentsOf: file))
    }
}
