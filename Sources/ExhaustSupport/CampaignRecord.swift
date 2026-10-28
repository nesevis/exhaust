import Foundation

/// Shares campaign metadata, publication state, and the wire report between the runtime that writes a record and the command that aggregates it.
///
/// The wire format is flat: `status` and, for a completed campaign, its completion fields sit beside the metadata, and an interrupted campaign also carries `outcome: "error"`. Decoding a completed record that lacks a required completion field throws, so aggregation reports it instead of counting a result it does not have.
package struct CampaignRecord: Sendable {
    package var schemaVersion: Int = 1
    package let id: String
    package var state: CampaignState
    package let source: CampaignSource
    package let kind: FuzzCampaignKind
    /// The budget the macro call declared, before any `--time` override.
    package let declaredBudgetSeconds: Double
    package let startedAt: Double
    package var attachments: [String]
    package let testID: String?
    package let testName: String?
    package let requestedSeed: String?
    package let checkpointPath: String
    /// The budget the search actually received after the `--time` override; nil when the campaign's settings were rejected.
    package let effectiveBudgetSeconds: Double?
    package var recordPath: String?

    package init(
        id: String,
        state: CampaignState = .running,
        source: CampaignSource,
        kind: FuzzCampaignKind,
        declaredBudgetSeconds: Double,
        startedAt: Double,
        attachments: [String] = [],
        testID: String? = nil,
        testName: String? = nil,
        requestedSeed: String? = nil,
        checkpointPath: String,
        effectiveBudgetSeconds: Double? = nil,
        recordPath: String? = nil
    ) {
        self.id = id
        self.state = state
        self.source = source
        self.kind = kind
        self.declaredBudgetSeconds = declaredBudgetSeconds
        self.startedAt = startedAt
        self.attachments = attachments
        self.testID = testID
        self.testName = testName
        self.requestedSeed = requestedSeed
        self.checkpointPath = checkpointPath
        self.effectiveBudgetSeconds = effectiveBudgetSeconds
        self.recordPath = recordPath
    }

    package var status: CampaignStatus {
        switch state {
            case .running:
                .running
            case .completed:
                .completed
            case .interrupted:
                .interrupted
        }
    }

    /// An interrupted campaign counts as an error: it started, but its result was never published.
    package var outcome: CampaignOutcome? {
        switch state {
            case .running:
                nil
            case let .completed(completion):
                completion.outcome
            case .interrupted:
                .error
        }
    }
}

/// Ties a campaign's completion data to its completed state, so a record cannot claim completion without a result.
package enum CampaignState: Sendable {
    case running
    case completed(CampaignCompletion)
    case interrupted
}

/// The result a campaign publishes when it finishes.
package struct CampaignCompletion: Sendable {
    package let finishedAt: Double
    /// The actual search seed; nil for an unseeded campaign that ended before drawing one.
    package let seed: String?
    package let issuesSuppressed: Bool
    package let outcome: CampaignOutcome
    package let report: CampaignWireReport

    package init(
        finishedAt: Double,
        seed: String?,
        issuesSuppressed: Bool,
        outcome: CampaignOutcome,
        report: CampaignWireReport
    ) {
        self.finishedAt = finishedAt
        self.seed = seed
        self.issuesSuppressed = issuesSuppressed
        self.outcome = outcome
        self.report = report
    }
}

// MARK: - Wire Format

// The record encodes into one flat object. Optional metadata is omitted when nil, matching synthesized coding. The state contributes `status`, plus the completion fields when completed, or `outcome: "error"` when interrupted. The interrupted outcome is derived, so decoding ignores it.

extension CampaignRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case status
        case source
        case kind
        case declaredBudgetSeconds
        case startedAt
        case attachments
        case testID
        case testName
        case requestedSeed
        case checkpointPath
        case effectiveBudgetSeconds
        case recordPath
        case finishedAt
        case seed
        case issuesSuppressed
        case outcome
        case report
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(CampaignSource.self, forKey: .source)
        kind = try container.decode(FuzzCampaignKind.self, forKey: .kind)
        declaredBudgetSeconds = try container.decode(Double.self, forKey: .declaredBudgetSeconds)
        startedAt = try container.decode(Double.self, forKey: .startedAt)
        attachments = try container.decode([String].self, forKey: .attachments)
        testID = try container.decodeIfPresent(String.self, forKey: .testID)
        testName = try container.decodeIfPresent(String.self, forKey: .testName)
        requestedSeed = try container.decodeIfPresent(String.self, forKey: .requestedSeed)
        checkpointPath = try container.decode(String.self, forKey: .checkpointPath)
        effectiveBudgetSeconds = try container.decodeIfPresent(Double.self, forKey: .effectiveBudgetSeconds)
        recordPath = try container.decodeIfPresent(String.self, forKey: .recordPath)
        state = switch try container.decode(CampaignStatus.self, forKey: .status) {
            case .running:
                .running
            case .completed:
                try .completed(CampaignCompletion(
                    finishedAt: container.decode(Double.self, forKey: .finishedAt),
                    seed: container.decodeIfPresent(String.self, forKey: .seed),
                    issuesSuppressed: container.decode(Bool.self, forKey: .issuesSuppressed),
                    outcome: container.decode(CampaignOutcome.self, forKey: .outcome),
                    report: container.decode(CampaignWireReport.self, forKey: .report)
                ))
            case .interrupted:
                .interrupted
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encode(source, forKey: .source)
        try container.encode(kind, forKey: .kind)
        try container.encode(declaredBudgetSeconds, forKey: .declaredBudgetSeconds)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(testID, forKey: .testID)
        try container.encodeIfPresent(testName, forKey: .testName)
        try container.encodeIfPresent(requestedSeed, forKey: .requestedSeed)
        try container.encode(checkpointPath, forKey: .checkpointPath)
        try container.encodeIfPresent(effectiveBudgetSeconds, forKey: .effectiveBudgetSeconds)
        try container.encodeIfPresent(recordPath, forKey: .recordPath)
        switch state {
            case .running:
                break
            case let .completed(completion):
                try container.encode(completion.finishedAt, forKey: .finishedAt)
                try container.encodeIfPresent(completion.seed, forKey: .seed)
                try container.encode(completion.issuesSuppressed, forKey: .issuesSuppressed)
                try container.encode(completion.outcome, forKey: .outcome)
                try container.encode(completion.report, forKey: .report)
            case .interrupted:
                try container.encode(CampaignOutcome.error, forKey: .outcome)
        }
    }
}
