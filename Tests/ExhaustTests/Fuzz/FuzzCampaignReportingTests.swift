import ExhaustCore
import ExhaustSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("Campaign JSON reporting")
struct FuzzCampaignReportingTests {
    @Test("Each invocation preserves its own seed, budget, source and detailed results", arguments: [UInt64(1), .max])
    func recordDetails(seed: UInt64) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try recording(in: directory, seed: seed)
        let second = try recording(in: directory, seed: seed)
        #expect(first.id != second.id)
        let started = try read(first, in: directory)
        #expect(started.status == .running)
        #expect(started.requestedSeed == String(seed))
        #expect(started.effectiveBudgetSeconds == 2)
        #expect(started.declaredBudgetSeconds == 60)
        #expect(started.checkpointPath == first.context.store.directory.path)

        let report = FuzzCampaignFixture.failingReport(seed: seed, range: 0 ... 100)
        try first.finish(report: report, attachments: ["summary.txt"], issuesSuppressed: true)
        let finished = try read(first, in: directory)
        #expect(finished.status == .completed)
        guard case let .completed(completion) = finished.state else {
            Issue.record("Expected a completed campaign, got \(finished.status)")
            return
        }
        #expect(completion.seed == String(seed))
        #expect(finished.outcome == .failed)
        #expect(completion.issuesSuppressed == true)
        #expect(finished.attachments == ["summary.txt"])
        #expect(finished.source.line == 42)
        let details = completion.report
        #expect(details.clusters.count == report.clusters.count)
        #expect(details.coverage.coveredEdges == report.coverage.coveredEdges)
        #expect(try read(second, in: directory).status == .running)
    }

    @Test("The spool publishes start, finding, and finish events in campaign order")
    func eventOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try recording(in: directory, seed: 1)
        let report = FuzzCampaignFixture.failingReport(seed: 1)
        try first.finish(report: report, attachments: ["summary.txt"], issuesSuppressed: true)
        guard case let .completed(completion) = try read(first, in: directory).state else {
            Issue.record("Expected a completed campaign")
            return
        }
        let details = completion.report
        let files = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("events"),
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix(first.id) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let startedEvent = try JSONDecoder().decode(CampaignEvent.self, from: Data(contentsOf: #require(files.first)))
        let finishedEvent = try JSONDecoder().decode(CampaignEvent.self, from: Data(contentsOf: #require(files.last)))
        #expect(startedEvent.type == .campaignStarted)
        #expect(finishedEvent.type == .campaignFinished)
        #expect(details.clusters.isEmpty == false)
        #expect(files.count == details.clusters.count + 2)
        for (file, finding) in zip(files.dropFirst(), details.clusters) {
            let event = try JSONDecoder().decode(CampaignEvent.self, from: Data(contentsOf: file))
            #expect(event.campaignID == first.id)
            #expect(event.type == .findingReported)
            guard case let .findingReported(payload) = event.payload else {
                continue
            }
            #expect(payload.finding.findingID == finding.findingID)
        }
    }

    @Test("Finding identity survives new seeds and invocation IDs, but separates properties and reduced forms")
    func findingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var identifiers: [String] = []
        for seed in [UInt64(1), 22, .max] {
            let record = try recording(in: directory, seed: seed)
            let report = FuzzCampaignFixture.failingReport(seed: seed, range: 0 ... 100)
            let cluster = try #require(report.clusters.first)
            let id = record.context.findingID(cluster)
            identifiers.append(id)
            let otherCall = try recording(in: directory, seed: seed, line: 43)
            let otherTest = try recording(in: directory, seed: seed, testID: "Tests/Other.test(seed:)")
            #expect(id != otherCall.context.findingID(cluster))
            #expect(id != otherTest.context.findingID(cluster))
            let different = FuzzCampaignFixture.failingReport(seed: seed, range: 200 ... 300)
            #expect(try id != record.context.findingID(#require(different.clusters.first)))
        }
        #expect(Set(identifiers).count == 1)
        // A golden value makes accidental changes to the versioned identity visible.
        #expect(identifiers.first == "finding-v1-5567b98ffa24a3fd")
    }

    @Test("Context resolution shares one seed and captured budget with the core and record")
    func capturedConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = FuzzCampaignContext(
            fileID: "Tests/Test.swift",
            filePath: "/tests/Test.swift",
            line: 1,
            column: 1,
            testID: "capturedConfiguration",
            testName: "capturedConfiguration",
            seed: nil,
            kind: .value,
            time: .seconds(60),
            environment: [
                CampaignWire.budgetKey: "2000000000",
                CampaignWire.stateDirectoryKey: directory.path,
            ]
        )
        let resolved = try context.configuration.resolution.get()
        let report = await FuzzCampaign(context: context, suppress: SuppressFlags()).search { persistence, captured in
            #expect(captured.seed == resolved.seed)
            #expect(captured.budgetNanoseconds == 2_000_000_000)
            return __ExhaustRuntime.runExploreTimeCore(
                gen: Gen.choose(in: 0 ... 1),
                resolved: captured,
                settings: ParsedPropertyFuzzSettings([.suppress(.all)]),
                source: .none,
                configure: nil,
                persistence: persistence,
                property: { _ in .pass }
            )
        }
        #expect(report.seed == resolved.seed)
        let record = FuzzCampaignRecord(directory: directory, context: context)
        try record.start()
        let snapshot = try read(record, in: directory)
        #expect(snapshot.declaredBudgetSeconds == 60)
        #expect(snapshot.effectiveBudgetSeconds == 2)
        #expect(snapshot.requestedSeed == nil)
    }

    @Test("Invalid captured settings are rejected before checkpoint reservation", arguments: [true, false])
    func invalidConfigurationBeforeReservation(invalidReplay: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory)
        let context = FuzzCampaignContext(
            fileID: "Tests/Test.swift",
            filePath: "/tests/Test.swift",
            line: 1,
            column: 1,
            testID: nil,
            testName: nil,
            seed: 42,
            kind: .value,
            time: .seconds(60),
            invalidReplayMessage: invalidReplay ? "invalid replay fixture" : nil,
            environment: [
                CampaignWire.budgetKey: "invalid",
                CampaignWire.stateDirectoryKey: directory.path,
            ]
        )
        let report = await FuzzCampaign(context: context, suppress: SuppressFlags()).search { _, _ in
            Issue.record("Invalid settings reached the campaign body")
            return .empty(termination: .instrumentationMissing, seed: 0)
        }
        guard case let .invalidConfiguration(message) = report.termination else {
            Issue.record("Expected invalid configuration")
            return
        }
        #expect(message.contains(invalidReplay ? "invalid replay fixture" : "--time budget is invalid"))
        #expect(report.seed == 42)
        #expect(context.configuration.budgetSeconds == nil)
    }

    @Test("Missing instrumentation and invalid configuration are not successful campaigns")
    func emptyOutcomes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (termination, outcome) in [
            (FuzzReport.Termination.instrumentationMissing, CampaignOutcome.skipped),
            (.invalidConfiguration("invalid budget"), .error),
        ] {
            let record = try recording(in: directory, seed: nil)
            try record.finish(
                report: .empty(termination: termination, seed: 0),
                attachments: [],
                issuesSuppressed: false
            )
            let result = try read(record, in: directory)
            #expect(result.outcome == outcome)
            guard case let .completed(completion) = result.state else {
                Issue.record("Expected a completed campaign, got \(result.status)")
                continue
            }
            #expect(completion.seed == nil)
        }
    }

    @Test("A run whose property discarded or stalled on every evaluated input is an error, not a pass", arguments: [true, false])
    func unjudgedRunIsNotPassed(stalls: Bool) {
        let verdict: FuzzVerdict = switch stalls {
            case true:
                .inconclusive
            case false:
                .discard
        }
        let report = searchWithVerdict(verdict)
        #expect(report.attempts.evaluated > 0)
        #expect(report.clusters.isEmpty)
        #expect(report.outcome == .error)
        #expect(CampaignOutcome(report.outcome) == .error)
    }

    @Test("A run that judged inputs and found no failure is passed")
    func judgedPassingRunIsPassed() {
        let report = searchWithVerdict(.pass)
        #expect(report.attempts.evaluated > 0)
        #expect(report.outcome == .passed)
        #expect(CampaignOutcome(report.outcome) == .passed)
    }

    @Test("Repeated completed searches at one call site retain separate results", arguments: [UInt64(33), 44])
    func completedCalls(seed: UInt64) async {
        for _ in 0 ..< 2 {
            let report = await __ExhaustRuntime.__exploreTimeAsync(
                .int(in: 0 ... 3), time: .seconds(1), settings: [.replay(.numeric(seed)), .suppress(.all)],
                coverage: .injected(SyntheticCoverageSource<Int>(edgeCount: 4, edges: { [$0] }))
            ) { _ in true }
            #expect(report.seed == seed)
            #expect(report.attempts.evaluated > 0)
        }
    }

    private func recording(
        in directory: URL,
        seed: UInt64?,
        line: UInt = 42,
        testID: String = "Tests/Suite.test(seed:)"
    ) throws -> FuzzCampaignRecord {
        let context = FuzzCampaignContext(
            fileID: "Tests/Test.swift",
            filePath: "/tests/Test.swift",
            line: line,
            column: 5,
            testID: testID,
            testName: "Suite.test",
            seed: seed,
            kind: .value,
            time: .seconds(60),
            environment: [
                "EXHAUST_EXPLORE_TIME_NS": "2000000000",
                "EXHAUST_STATE_DIR": directory.appendingPathComponent("state").path,
            ]
        )
        let record = FuzzCampaignRecord(directory: directory, context: context)
        try record.start()
        return record
    }

    /// Runs a bounded search to a normal stop whose property returns `verdict` for every input.
    private func searchWithVerdict(_ verdict: FuzzVerdict) -> FuzzReport {
        __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100),
            time: .seconds(1),
            settings: [.replay(.numeric(1)), .suppress(.all)],
            source: .injected(SyntheticCoverageSource<Int>(edgeCount: 4, edges: { _ in [0] })),
            configure: { $0.attemptLimit = 20 },
            property: { _ in verdict }
        )
    }

    private func read(_ record: FuzzCampaignRecord, in directory: URL) throws -> CampaignRecord {
        try JSONDecoder().decode(
            CampaignRecord.self,
            from: Data(contentsOf: CampaignWire.jsonURL(in: directory, id: record.id))
        )
    }
}
