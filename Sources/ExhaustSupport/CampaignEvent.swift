import Foundation

/// Fixes the event vocabulary independently of the payload's wire fields.
package enum CampaignEventType: String, Codable, Sendable {
    case runStarted = "run.started"
    case phaseChanged = "run.phaseChanged"
    case campaignStarted = "campaign.started"
    case findingReported = "finding.reported"
    case campaignFinished = "campaign.finished"
    case campaignInterrupted = "campaign.interrupted"
    case runFinished = "run.finished"
}

/// One published event: its identity and campaign position around a payload whose case determines the event type.
///
/// The runtime publishes the campaign cases as spool files and the command publishes the run cases and interruptions. Neither knows the event's place in the stream when it creates one; the single collecting writer stamps that on as a ``CampaignStreamEvent``.
package struct CampaignEvent: Sendable {
    package var schemaVersion = 1
    package var eventID: String
    package var campaignID: String?
    package var campaignSequence: Int?
    package var timestamp: Double
    package var payload: CampaignEventPayload

    package init(
        eventID: String = UUID().uuidString,
        campaignID: String? = nil,
        campaignSequence: Int? = nil,
        timestamp: Double = Date().timeIntervalSince1970,
        payload: CampaignEventPayload
    ) {
        self.eventID = eventID
        self.campaignID = campaignID
        self.campaignSequence = campaignSequence
        self.timestamp = timestamp
        self.payload = payload
    }

    package var type: CampaignEventType {
        payload.type
    }
}

/// Pairs each event type with the only payload it can carry.
package enum CampaignEventPayload: Sendable {
    case runStarted(CampaignRunStarted)
    case phaseChanged(CampaignPhaseChanged)
    case campaignStarted(CampaignRecord)
    case findingReported(CampaignFinding)
    case campaignFinished(CampaignRecord)
    case campaignInterrupted(CampaignRecord)
    case runFinished(CampaignRunFinished)

    package var type: CampaignEventType {
        switch self {
            case .runStarted:
                .runStarted
            case .phaseChanged:
                .phaseChanged
            case .campaignStarted:
                .campaignStarted
            case .findingReported:
                .findingReported
            case .campaignFinished:
                .campaignFinished
            case .campaignInterrupted:
                .campaignInterrupted
            case .runFinished:
                .runFinished
        }
    }
}

// MARK: - Wire Format

// The envelope encodes into one flat object: the identity fields, `type` from the payload's case, and the associated value under `payload`. Decoding reads `type` first and decodes `payload` as that type's value, so an unknown type or a mismatched payload throws.

extension CampaignEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case eventID
        case campaignID
        case campaignSequence
        case type
        case timestamp
        case payload
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        eventID = try container.decode(String.self, forKey: .eventID)
        campaignID = try container.decodeIfPresent(String.self, forKey: .campaignID)
        campaignSequence = try container.decodeIfPresent(Int.self, forKey: .campaignSequence)
        timestamp = try container.decode(Double.self, forKey: .timestamp)
        payload = switch try container.decode(CampaignEventType.self, forKey: .type) {
            case .runStarted:
                try .runStarted(container.decode(CampaignRunStarted.self, forKey: .payload))
            case .phaseChanged:
                try .phaseChanged(container.decode(CampaignPhaseChanged.self, forKey: .payload))
            case .campaignStarted:
                try .campaignStarted(container.decode(CampaignRecord.self, forKey: .payload))
            case .findingReported:
                try .findingReported(container.decode(CampaignFinding.self, forKey: .payload))
            case .campaignFinished:
                try .campaignFinished(container.decode(CampaignRecord.self, forKey: .payload))
            case .campaignInterrupted:
                try .campaignInterrupted(container.decode(CampaignRecord.self, forKey: .payload))
            case .runFinished:
                try .runFinished(container.decode(CampaignRunFinished.self, forKey: .payload))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(eventID, forKey: .eventID)
        try container.encodeIfPresent(campaignID, forKey: .campaignID)
        try container.encodeIfPresent(campaignSequence, forKey: .campaignSequence)
        try container.encode(type, forKey: .type)
        try container.encode(timestamp, forKey: .timestamp)
        switch payload {
            case let .runStarted(value):
                try container.encode(value, forKey: .payload)
            case let .phaseChanged(value):
                try container.encode(value, forKey: .payload)
            case let .campaignStarted(record), let .campaignFinished(record), let .campaignInterrupted(record):
                try container.encode(record, forKey: .payload)
            case let .findingReported(finding):
                try container.encode(finding, forKey: .payload)
            case let .runFinished(value):
                try container.encode(value, forKey: .payload)
        }
    }
}

/// One line of `events.jsonl`: a published event stamped with the command's run and its position in collection order.
///
/// Only the collecting writer knows either value, so spool files never carry them and every stream line does.
package struct CampaignStreamEvent: Sendable {
    package let runID: String
    package let sequence: Int
    package let event: CampaignEvent

    package init(runID: String, sequence: Int, event: CampaignEvent) {
        self.runID = runID
        self.sequence = sequence
        self.event = event
    }
}

// MARK: - Stream Wire Format

// A stream line is flat: `runID` and `sequence` sit beside the event's own fields rather than wrapping them, so the line keeps the shape consumers already read.

extension CampaignStreamEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case runID
        case sequence
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(String.self, forKey: .runID)
        sequence = try container.decode(Int.self, forKey: .sequence)
        event = try CampaignEvent(from: decoder)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        try container.encode(sequence, forKey: .sequence)
        try event.encode(to: encoder)
    }
}
