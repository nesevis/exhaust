import ExhaustSupport
import Foundation

/// Collects independent invocation records into the command's authoritative snapshot.
final class CampaignReports {
    let runID = UUID().uuidString
    let plan: CampaignPlan
    let options: Options
    let startedAt = Date().timeIntervalSince1970
    private let paths: CampaignPaths
    private var phase = CampaignPhase.preparing
    lazy var events = CampaignEvents(
        runID: runID,
        path: plan.output.appendingPathComponent(CampaignWire.streamFilename),
        spool: records.appendingPathComponent(CampaignWire.eventsDirectory),
        paths: paths
    )

    init(plan: CampaignPlan, options: Options) {
        self.plan = plan
        self.options = options
        paths = CampaignPaths(root: plan.output)
    }

    var attachments: URL {
        plan.output.appendingPathComponent("attachments/\(runID)")
    }

    var records: URL {
        attachments.appendingPathComponent("campaigns")
    }

    var report: URL {
        plan.output.appendingPathComponent(CampaignWire.reportFilename)
    }

    var xunit: URL {
        plan.output.appendingPathComponent("xunit.xml")
    }

    var environment: [String: String] {
        var environment = plan.environment
        environment[CampaignWire.reportDirectoryKey] = records.nativePath
        return environment
    }

    /// Finalizes exactly once after execution; a reporting failure cannot replace the original child-process failure.
    func finalizing(during body: () throws -> Void) throws {
        try prepare()
        do {
            try body()
        } catch {
            do {
                try finish(error: error)
            } catch let reportingError {
                FileHandle.standardError.write(Data("Cannot finalize campaign JSON: \(reportingError)\n".utf8))
            }
            throw error
        }
        try finish()
    }

    /// Starts a fresh aggregate and event stream while retaining older per-run artifacts.
    func prepare() throws {
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        for path in xunitPaths where FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        try events.prepare()
        try events.append(.runStarted(CampaignRunStarted()))
        try update(phase: .preparing)
    }

    /// Announces a live command stage without converting in-flight campaigns into interrupted results.
    func update(phase: CampaignPhase) throws {
        self.phase = phase
        events.collect()
        let snapshot = readCampaigns()
        let document = try document(phase: phase, campaigns: snapshot.records, errors: snapshot.errors)
        try persist(document)
        try events.append(.phaseChanged(CampaignPhaseChanged(phase: phase)))
    }

    /// Seals the snapshot after the child exits, preserving completed findings and identifying interrupted campaigns.
    func finish(error: (any Error)? = nil) throws {
        events.collectFinal()
        var snapshot = readCampaigns()
        for index in snapshot.records.indices where snapshot.records[index].status == .running {
            snapshot.records[index].state = .interrupted
        }
        var document = try document(phase: phase, campaigns: snapshot.records, errors: snapshot.errors)
        let isIncomplete = document.totals.interrupted > 0 || document.reportingErrors.isEmpty == false
        document.status = switch error == nil && isIncomplete == false {
            case true:
                .succeeded
            case false:
                .failed
        }
        document.finishedAt = Date().timeIntervalSince1970
        document.exitCode = (error as? ChildFailure)?.status
        document.error = error.map { String(describing: $0) }
        try persist(document)
        // Printed on every exit from here, including terminal publication failures, so the verdict and report path follow the test output.
        defer { FileHandle.standardOutput.write(Data((summary(of: document) + "\n").utf8)) }
        do {
            for record in snapshot.records where record.status == .interrupted {
                try events.append(.campaignInterrupted(record), campaignID: record.id)
            }
            try events.append(.runFinished(CampaignRunFinished(
                status: document.status,
                totals: document.totals,
                reportingErrors: document.reportingErrors,
                exitCode: document.exitCode,
                error: document.error
            )))
        } catch {
            document.status = .failed
            document.reportingErrors.append("Cannot publish terminal campaign events: \(error)")
            try persist(document)
            throw error
        }
        if error == nil, isIncomplete {
            throw CommandError("Campaign reporting is incomplete; see \(report.nativePath).")
        }
    }

    /// Renders the sealed report's verdict, campaign totals, and file locations for the terminal. The command prints the report path before building, so without this a failed run ends on the plugin's generic message far below it.
    func summary(of document: CampaignReport) -> String {
        let phase = document.phase.rawValue
        let verdict = switch (document.status, document.exitCode) {
            case (.succeeded, _):
                "Explore succeeded."
            case let (.failed, .some(exitCode)):
                "Explore failed during \(phase): SwiftPM exited with status \(exitCode)."
            case (.failed, .none):
                "Explore failed during \(phase)."
            case (.running, _):
                "Explore did not finish; it stopped during \(phase)."
        }
        let totals = document.totals
        let campaigns = switch totals.observed {
            case 0:
                "No #explore(time:) campaigns ran."
            default:
                "Campaigns: \(totals.observed) (passed \(totals.passed), failed \(totals.failed), skipped \(totals.skipped), error \(totals.errors), interrupted \(totals.interrupted))."
        }
        var lines = [verdict, campaigns]
        if document.reportingErrors.isEmpty == false {
            lines.append("Reporting errors: \(document.reportingErrors.count); see the report.")
        }
        lines.append("Report: \(report.nativePath)")
        for file in document.xunitFiles {
            lines.append("xUnit: \(plan.output.appendingPathComponent(file).nativePath)")
        }
        return lines.joined(separator: "\n")
    }

    /// Decodes the aggregation envelope and leaves all runtime-specific fields intact.
    private func readCampaigns() -> (records: [CampaignRecord], errors: [String]) {
        var campaigns: [CampaignRecord] = []
        var errors = events.errors
        do {
            let files = try FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil)
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where file.pathExtension == "json"
            {
                do {
                    var record = try JSONDecoder().decode(CampaignRecord.self, from: Data(contentsOf: file))
                    guard record.schemaVersion == 1,
                          record.id == file.deletingPathExtension().lastPathComponent,
                          record.status != .interrupted
                    else {
                        throw CommandError("Invalid campaign record identity: \(file.lastPathComponent)")
                    }
                    record = try paths.relocated(record, recordFile: file, attachmentsDirectory: attachments)
                    campaigns.append(record)
                } catch {
                    errors.append("\(file.lastPathComponent): \(error)")
                }
            }
        } catch {
            errors.append("Cannot collect campaign records: \(error)")
        }
        return (campaigns, errors)
    }

    private func document(
        phase: CampaignPhase,
        campaigns: [CampaignRecord],
        errors: [String]
    ) throws -> CampaignReport {
        try CampaignReport(
            runID: runID,
            phase: phase,
            startedAt: startedAt,
            configuration: options.configuration.rawValue,
            coverageRecorder: options.coverageRecorder.rawValue,
            instrumentedTargets: plan.targets,
            testTarget: plan.test.name,
            buildPath: plan.scratch.nativePath,
            statePath: plan.statePath,
            attachmentsPath: paths.relative(attachments),
            xunitFiles: xunitPaths.filter { FileManager.default.fileExists(atPath: $0.path) }.map(paths.relative),
            campaigns: campaigns,
            totals: CampaignTotals(campaigns),
            reportingErrors: errors,
            filter: options.filter,
            budgetOverrideSeconds: options.seconds
        )
    }

    private func persist(_ document: CampaignReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: report, options: .atomic)
    }

    private var xunitPaths: [URL] {
        [xunit, plan.output.appendingPathComponent("xunit-swift-testing.xml")]
    }
}
