import Foundation

// The command's own event payloads. They live beside the runtime's so ``CampaignEventPayload`` can pair every event type with its payload in one enum.

/// Represents command progress rather than the outcome of any one campaign. A finished report keeps the last phase reached, so a failed run shows where it stopped; ``CampaignRunStatus`` says whether the run is over.
package enum CampaignPhase: String, Codable, Sendable {
    case preparing
    case building
    case testing
}

/// Reflects the SwiftPM process result and reporting integrity.
package enum CampaignRunStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
}

/// Counts invocations without merging findings or coverage across independent campaigns.
package struct CampaignTotals: Codable, Sendable {
    package let observed: Int
    package let completed: Int
    package let interrupted: Int
    package let passed: Int
    package let failed: Int
    package let skipped: Int
    package let errors: Int

    package init(_ campaigns: [CampaignRecord]) {
        observed = campaigns.count
        completed = campaigns.count { $0.status == .completed }
        interrupted = campaigns.count { $0.status == .interrupted }
        passed = campaigns.count { $0.outcome == .passed }
        failed = campaigns.count { $0.outcome == .failed }
        skipped = campaigns.count { $0.outcome == .skipped }
        errors = campaigns.count { $0.outcome == .error }
    }
}

/// Points stream consumers to the primary snapshot.
package struct CampaignRunStarted: Codable, Sendable {
    package var reportPath = CampaignWire.reportFilename

    package init() {}
}

/// Announces the next command stage without rewriting campaign events.
package struct CampaignPhaseChanged: Codable, Sendable {
    package let phase: CampaignPhase

    package init(phase: CampaignPhase) {
        self.phase = phase
    }
}

/// Carries the final verdict and integrity failures without repeating every campaign result.
package struct CampaignRunFinished: Codable, Sendable {
    package let status: CampaignRunStatus
    package var reportPath = CampaignWire.reportFilename
    package let totals: CampaignTotals
    package let reportingErrors: [String]
    package let exitCode: Int32?
    package let error: String?

    package init(
        status: CampaignRunStatus,
        totals: CampaignTotals,
        reportingErrors: [String],
        exitCode: Int32?,
        error: String?
    ) {
        self.status = status
        self.totals = totals
        self.reportingErrors = reportingErrors
        self.exitCode = exitCode
        self.error = error
    }
}
