import ExhaustSupport
import Foundation

/// Records the authoritative command snapshot, carrying each campaign's typed record.
struct CampaignReport: Codable {
    var schemaVersion = 1
    let runID: String
    var status: CampaignRunStatus = .running
    let phase: CampaignPhase
    let startedAt: Double
    let configuration: String
    let coverageRecorder: String
    let instrumentedTargets: [String]
    let testTarget: String
    let buildPath: String
    let statePath: String
    let attachmentsPath: String
    var eventsPath = CampaignWire.streamFilename
    let xunitFiles: [String]
    let campaigns: [CampaignRecord]
    let totals: CampaignTotals
    var reportingErrors: [String]
    let filter: String?
    let budgetOverrideSeconds: UInt64?
    var finishedAt: Double?
    var exitCode: Int32?
    var error: String?
}
