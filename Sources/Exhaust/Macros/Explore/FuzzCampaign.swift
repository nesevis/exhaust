import ExhaustCore
import ExhaustSupport
import Foundation

/// One `time:` invocation as the test task sees it: its resolved context, its reporting settings, and the record the explore command collects.
///
/// Every entry point composes the same two scopes. ``run(_:)`` owns everything that must stay on the test task, because issue recording and attachment association resolve the current test from task-locals: the campaign record, issue reporting, and attachments. ``search(core:replay:)`` owns validation, checkpoint ownership, predecessor findings, and the hop to the fuzz lane. Stating the order once keeps a variant from reporting inside the GCD closure, where a failing run stops failing its test.
struct FuzzCampaign: Sendable {
    let context: FuzzCampaignContext
    let suppress: SuppressFlags
    private let recording: FuzzCampaignRecord?

    init(context: FuzzCampaignContext, suppress: SuppressFlags) {
        self.context = context
        self.suppress = suppress
        recording = context.reportDirectory.map { FuzzCampaignRecord(directory: $0, context: context) }
    }

    /// Resolves the campaign for its call site and the enclosing test. Must run on the test task, where the current test is still visible.
    static func resolve(
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        seed: UInt64?,
        kind: FuzzCampaignKind,
        time: TimeSpan,
        invalidReplayMessage: String?,
        suppress: SuppressFlags
    ) -> FuzzCampaign {
        FuzzCampaign(
            context: .resolve(
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column,
                seed: seed,
                kind: kind,
                time: time,
                invalidReplayMessage: invalidReplayMessage
            ),
            suppress: suppress
        )
    }

    /// Publishes the campaign's start, runs `body`, then reports issues, records attachments, and publishes the result, all on the calling test task and including for rejected configurations.
    func run(_ body: () async -> FuzzReport) async -> FuzzReport {
        do {
            try recording?.start()
        } catch {
            context.reportError("Cannot start the campaign JSON report: \(error)")
        }
        var report = await body()
        report.recordsAttachments = __ExhaustRuntime.recordsFuzzAttachments(
            report: report,
            suppressAttachments: suppress.attachments
        )
        __ExhaustRuntime.reportFuzzIssues(
            report: report,
            suppressIssueReporting: suppress.issueReporting,
            fileID: context.fileID,
            filePath: context.filePath,
            line: context.line,
            column: context.column
        )
        let names = __ExhaustRuntime.recordFuzzAttachments(
            report: report,
            context: context,
            suppressAttachments: suppress.attachments,
            campaignID: recording?.id
        )
        do {
            try recording?.finish(report: report, attachments: names, issuesSuppressed: suppress.issueReporting)
        } catch {
            context.reportError("Cannot finish the campaign JSON report: \(error)")
        }
        return report
    }

    /// Rejects invalid settings before taking ownership, then runs `core` on the fuzz lane and `replay` back on the calling task, both while the checkpoint store stays reserved.
    ///
    /// Predecessor findings report before the hop so they keep test attribution. A store owned by another campaign ends the run as a configuration error rather than letting two writers share it.
    func search(
        core: @escaping (FuzzPersistenceContext, ResolvedFuzzRun) -> FuzzReport,
        replay: ((inout FuzzReport) async -> Void)? = nil
    ) async -> FuzzReport {
        switch context.runResolution {
            case let .rejected(report):
                return report
            case let .resolved(resolved):
                return await reserve(resolved, core: core, replay: replay)
        }
    }

    private func reserve(
        _ resolved: ResolvedFuzzRun,
        core: @escaping (FuzzPersistenceContext, ResolvedFuzzRun) -> FuzzReport,
        replay: ((inout FuzzReport) async -> Void)?
    ) async -> FuzzReport {
        do {
            return try await __ExhaustRuntime.withReservedFuzzPersistence(
                store: context.store,
                resumeEnabled: context.resumeEnabled,
                recoverUnseeded: context.requestedSeed == nil
            ) { persistence in
                __ExhaustRuntime.reportFuzzResumeFindings(
                    context: persistence,
                    fileID: context.fileID,
                    filePath: context.filePath,
                    line: context.line,
                    column: context.column
                )
                var report = await __ExhaustRuntime.dispatchToGCD(reserving: LaneReservation.fuzz) { _ in
                    core(persistence, resolved)
                }
                await replay?(&report)
                return report
            }
        } catch {
            return context.emptyReport(.invalidConfiguration(error.description))
        }
    }
}

// MARK: - Attachments

extension __ExhaustRuntime {
    /// Whether a campaign records attachments for this report: not when suppressed, not when the search made no attempt, and not without a test framework to receive them.
    static func recordsFuzzAttachments(report: FuzzReport, suppressAttachments: Bool) -> Bool {
        suppressAttachments == false && report.attempts.total > 0 && ActiveTestFramework.current != .none
    }

    /// Attaches every discovered cluster and a summary even on passing runs; callers must remain on the test task for framework attribution.
    ///
    /// Returns only the names SwiftPM's `--attachments-path` exports, which holds Swift Testing attachments alone. Under XCTest the attachments still reach the result bundle, so it returns no names for the campaign record to link.
    @discardableResult
    static func recordFuzzAttachments(
        report: FuzzReport,
        context: FuzzCampaignContext,
        suppressAttachments: Bool,
        campaignID: String? = nil
    ) -> [String] {
        guard recordsFuzzAttachments(report: report, suppressAttachments: suppressAttachments) else {
            return []
        }
        let prefix = context.attachmentPrefix(seed: report.seed, campaignID: campaignID)
        var names: [String] = []
        for cluster in report.clusters {
            let name = "\(prefix)-cluster-\(cluster.id + 1).txt"
            names.append(name)
            recordAttachment(
                renderClusterBlock(cluster, isFrontier: false, detail: .full).joined(separator: "\n"),
                named: name
            )
        }
        let summaryName = "\(prefix)-summary.txt"
        names.append(summaryName)
        recordAttachment(renderFuzzAttachmentSummary(report), named: summaryName)
        return switch ActiveTestFramework.current {
            case .swiftTesting:
                names
            case .xcTest, .none:
                []
        }
    }

    private static func recordAttachment(_ text: String, named name: String) {
        recordTestAttachment(text, named: name, uniformTypeIdentifier: "public.plain-text", keepsOnPassingRun: true)
    }
}
