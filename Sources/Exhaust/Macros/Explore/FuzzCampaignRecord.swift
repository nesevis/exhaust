import ExhaustSupport
import Foundation

/// Publishes one invocation through an atomic snapshot and immutable event files consumed by the command.
package struct FuzzCampaignRecord: Sendable {
    package let id = UUID().uuidString
    package let context: FuzzCampaignContext
    private let directory: URL
    private let startedAt = Date().timeIntervalSince1970

    package init(
        directory: URL,
        context: FuzzCampaignContext
    ) {
        self.directory = directory
        self.context = context
    }

    /// Publishes attribution before the property can crash or suspend.
    package func start() throws {
        let record = initialRecord
        try persist(record)
        try event(index: 0, payload: .campaignStarted(record))
    }

    /// Finalizes the snapshot before publishing findings, so consumers can always follow the event's record path.
    package func finish(
        report: FuzzReport,
        attachments: [String],
        issuesSuppressed: Bool
    ) throws {
        let wireReport = CampaignWireReport(report: report, context: context)
        let seed = switch report.attempts.total > 0 {
            case true: String(report.seed)
            case false: context.seed.map(String.init)
        }
        var record = initialRecord
        record.attachments = attachments
        record.state = .completed(CampaignCompletion(
            finishedAt: Date().timeIntervalSince1970,
            seed: seed,
            issuesSuppressed: issuesSuppressed,
            outcome: CampaignOutcome(report.outcome),
            report: wireReport
        ))
        try persist(record)
        for (index, finding) in wireReport.clusters.enumerated() {
            try event(
                index: index + 1,
                payload: .findingReported(CampaignFinding(
                    finding: finding,
                    seed: String(report.seed),
                    source: context.source,
                    kind: context.kind,
                    testID: context.testID,
                    testName: context.testName
                ))
            )
        }
        try event(index: wireReport.clusters.count + 1, payload: .campaignFinished(record))
    }

    private var initialRecord: CampaignRecord {
        CampaignRecord(
            id: id,
            source: context.source,
            kind: context.kind,
            declaredBudgetSeconds: context.configuration.declaredBudgetSeconds,
            startedAt: startedAt,
            testID: context.testID,
            testName: context.testName,
            requestedSeed: context.requestedSeed.map(String.init),
            seed: context.seed.map(String.init),
            checkpointPath: context.store.directory.path,
            effectiveBudgetSeconds: context.configuration.budgetSeconds
        )
    }

    private func persist(_ record: CampaignRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: CampaignWire.jsonURL(in: directory, id: id), options: .atomic)
    }

    /// Publishes separate atomic files so concurrent test processes never share a stream writer.
    private func event(index: Int, payload: CampaignEventPayload) throws {
        let events = directory.appendingPathComponent(CampaignWire.eventsDirectory)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        let eventID = CampaignWire.eventID(campaignID: id, sequence: index)
        let event = CampaignEvent(
            eventID: eventID,
            campaignID: id,
            campaignSequence: index,
            timestamp: Date().timeIntervalSince1970,
            payload: payload
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(event).write(to: CampaignWire.jsonURL(in: events, id: eventID), options: .atomic)
    }
}
