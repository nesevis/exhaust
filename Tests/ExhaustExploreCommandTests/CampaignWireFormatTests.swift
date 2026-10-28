import ExhaustSupport
import Foundation
import Testing
@testable import Exhaust

/// Guards the JSON that `report.json`, campaign records, and `events.jsonl` publish. The golden documents were recorded from the format consumers already read; a change here is a wire-format change.
@Suite("Campaign wire format")
struct CampaignWireFormatTests {
    @Test(
        "Campaign records keep their flat wire format in every state",
        arguments: [WireGolden.runningRecord, WireGolden.completedRecord, WireGolden.interruptedRecord]
    )
    func recordWireFormat(golden: String) throws {
        let record = try JSONDecoder().decode(CampaignRecord.self, from: Data(golden.utf8))
        #expect(try WireGolden.encode(record) == golden)
    }

    @Test("Every event type keeps its stream line wire format", arguments: WireGolden.streamEvents)
    func streamEventWireFormat(golden: String) throws {
        let line = try JSONDecoder().decode(CampaignStreamEvent.self, from: Data(golden.utf8))
        #expect(try WireGolden.encode(line) == golden)
    }

    @Test("Runtime spool events keep their wire format without run correlation", arguments: WireGolden.spoolEvents)
    func spoolEventWireFormat(golden: String) throws {
        let event = try JSONDecoder().decode(CampaignEvent.self, from: Data(golden.utf8))
        #expect(try WireGolden.encode(event) == golden)
    }

    @Test("A stream line without its run correlation is rejected", arguments: ["runID", "sequence"])
    func uncorrelatedStreamLine(missingKey: String) throws {
        let data = try WireGolden.removing(missingKey, from: WireGolden.streamEvents[0])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CampaignStreamEvent.self, from: data)
        }
    }

    @Test("Records written by the runtime carry exactly the wire format's keys")
    func runtimeRecordKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = FuzzCampaignContext(
            fileID: "Tests/Test.swift",
            filePath: "/tests/Test.swift",
            line: 3,
            column: 5,
            testID: "Tests/test()",
            testName: "test",
            seed: 7,
            kind: .value,
            time: .seconds(60),
            environment: [CampaignWire.budgetKey: "2000000000"]
        )
        let record = FuzzCampaignRecord(directory: directory, context: context)
        let file = CampaignWire.jsonURL(in: directory, id: record.id)
        try record.start()
        #expect(try WireGolden.keys(Data(contentsOf: file)) == WireGolden.keys(Data(WireGolden.runningRecord.utf8)))
        try record.finish(
            report: .empty(termination: .instrumentationMissing, seed: 7),
            attachments: ["summary.txt"],
            issuesSuppressed: false
        )
        // The command adds the record path when it collects the record.
        let completedKeys = try WireGolden.keys(Data(WireGolden.completedRecord.utf8)).subtracting(["recordPath"])
        #expect(try WireGolden.keys(Data(contentsOf: file)) == completedKeys)
    }

    @Test(
        "A completed record missing a required completion field is rejected",
        arguments: ["finishedAt", "issuesSuppressed", "outcome", "report"]
    )
    func incompleteCompletedRecord(missingKey: String) throws {
        let data = try WireGolden.removing(missingKey, from: WireGolden.completedRecord)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CampaignRecord.self, from: data)
        }
    }

    @Test("A completed record without a seed decodes as an unseeded completion")
    func unseededCompletedRecord() throws {
        let data = try WireGolden.removing("seed", from: WireGolden.completedRecord)
        let record = try JSONDecoder().decode(CampaignRecord.self, from: data)
        guard case let .completed(completion) = record.state else {
            Issue.record("Expected a completed record, got \(record.status)")
            return
        }
        #expect(completion.seed == nil)
        #expect(try WireGolden.keys(WireGolden.encoded(record)) == WireGolden.keys(data))
    }

    @Test(
        "An event whose type is unknown or does not match its payload is rejected",
        arguments: [
            WireGolden.event(type: "finding.reported", payload: WireGolden.runningRecord),
            WireGolden.event(type: "campaign.started", payload: WireGolden.phaseChangedPayload),
            WireGolden.event(type: "campaign.paused", payload: WireGolden.runningRecord),
        ]
    )
    func mismatchedEvent(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CampaignEvent.self, from: Data(json.utf8))
        }
    }
}

// MARK: - Helpers

/// Wire documents recorded from the published format, with sorted keys and no whitespace.
private enum WireGolden {
    static let runningRecord =
        #"{"attachments":[],"checkpointPath":"state\/fixture","declaredBudgetSeconds":60,"effectiveBudgetSeconds":2,"id":"campaign-1","kind":"value","requestedSeed":"7","schemaVersion":1,"source":{"column":5,"fileID":"Tests\/Test.swift","line":3},"startedAt":100.5,"status":"running","testID":"Tests\/test()","testName":"test"}"#

    static let completedRecord =
        #"{"attachments":["attachments\/run\/summary.txt"],"checkpointPath":"state\/fixture","declaredBudgetSeconds":60,"effectiveBudgetSeconds":2,"finishedAt":160.25,"id":"campaign-1","issuesSuppressed":false,"kind":"value","outcome":"skipped","recordPath":"attachments\/run\/campaigns\/campaign-1.json","report":{"attempts":{"discardedByMaterializer":0,"discardedByProperty":0,"duplicatesSkipped":0,"evaluated":0,"judged":0,"mutation":0,"mutationArmAttempts":{},"mutationArmDiscarded":{},"mutationArmFailed":{},"mutationArmPassed":{},"rejected":0,"sampling":0,"screening":0,"total":0},"clusters":[],"coverage":{"corpusEntryCount":0,"coveredEdges":0,"estimatedNextEdgeProbability":0,"estimatedReachableEdges":0,"incidenceSamples":0,"incidenceTotal":0,"instrumentedEdges":0,"offLaneHits":0,"parentCount":0,"parentRootPhases":{}},"invocations":{"classification":0,"normalization":0,"prune":0,"recovery":0,"reduction":0,"search":0,"total":0},"resumedFromCrash":false,"termination":{"reason":"instrumentationMissing"},"timing":{"attemptsPerSecond":0,"elapsedSeconds":0,"lastDiscoverySeconds":0,"mutationOverheadSeconds":0,"otherSeconds":0,"propertySeconds":0,"reductionSeconds":0,"samplingOverheadSeconds":0,"screeningOverheadSeconds":0,"testingOverheadFraction":0},"unreducedFailureCounts":{}},"requestedSeed":"7","schemaVersion":1,"seed":"7","source":{"column":5,"fileID":"Tests\/Test.swift","line":3},"startedAt":100.5,"status":"completed","testID":"Tests\/test()","testName":"test"}"#

    static let interruptedRecord =
        #"{"attachments":[],"checkpointPath":"state\/fixture","declaredBudgetSeconds":60,"effectiveBudgetSeconds":2,"id":"campaign-1","kind":"value","outcome":"error","requestedSeed":"7","schemaVersion":1,"source":{"column":5,"fileID":"Tests\/Test.swift","line":3},"startedAt":100.5,"status":"interrupted","testID":"Tests\/test()","testName":"test"}"#

    static let phaseChangedPayload = #"{"phase":"building"}"#

    static let streamEvents = [
        #"{"eventID":"e-1","payload":{"reportPath":"report.json"},"runID":"run-1","schemaVersion":1,"sequence":0,"timestamp":90,"type":"run.started"}"#,
        #"{"eventID":"e-2","payload":"# + phaseChangedPayload + #","runID":"run-1","schemaVersion":1,"sequence":1,"timestamp":91,"type":"run.phaseChanged"}"#,
        #"{"campaignID":"campaign-1","campaignSequence":0,"eventID":"campaign-1-00000000","payload":"# + runningRecord
            + #","runID":"run-1","schemaVersion":1,"sequence":2,"timestamp":100.5,"type":"campaign.started"}"#,
        #"{"campaignID":"campaign-1","campaignSequence":1,"eventID":"campaign-1-00000001","payload":"# + findingPayload
            + #","runID":"run-1","schemaVersion":1,"sequence":4,"timestamp":160.25,"type":"finding.reported"}"#,
        #"{"campaignID":"campaign-1","campaignSequence":2,"eventID":"campaign-1-00000002","payload":"# + completedRecord
            + #","runID":"run-1","schemaVersion":1,"sequence":5,"timestamp":160.25,"type":"campaign.finished"}"#,
        #"{"campaignID":"campaign-1","eventID":"e-4","payload":"# + interruptedRecord
            + #","runID":"run-1","schemaVersion":1,"sequence":6,"timestamp":170,"type":"campaign.interrupted"}"#,
        #"{"eventID":"e-5","payload":{"error":"ChildFailure(status: 1)","exitCode":1,"reportPath":"report.json","reportingErrors":["x.json: broken"],"status":"failed","totals":{"completed":1,"errors":1,"failed":0,"interrupted":1,"observed":2,"passed":0,"skipped":1}},"runID":"run-1","schemaVersion":1,"sequence":7,"timestamp":180,"type":"run.finished"}"#,
    ]

    /// The campaign events as the runtime writes them, before the command stamps run correlation onto each.
    static let spoolEvents = [
        #"{"campaignID":"campaign-1","campaignSequence":0,"eventID":"campaign-1-00000000","payload":"# + runningRecord
            + #","schemaVersion":1,"timestamp":100.5,"type":"campaign.started"}"#,
        #"{"campaignID":"campaign-1","campaignSequence":1,"eventID":"campaign-1-00000001","payload":"# + findingPayload
            + #","schemaVersion":1,"timestamp":160.25,"type":"finding.reported"}"#,
        #"{"campaignID":"campaign-1","campaignSequence":2,"eventID":"campaign-1-00000002","payload":"# + completedRecord
            + #","schemaVersion":1,"timestamp":160.25,"type":"campaign.finished"}"#,
    ]

    static let findingPayload =
        #"{"finding":{"discoveringPhase":"screening","discriminatingEdges":[{"edgeIndex":9,"failureHitFraction":1,"passingHitFraction":null,"symbol":{"displayName":"parse","file":"Lib.swift","fullName":"Lib.parse(_:)","line":12,"module":"Lib"}}],"findingID":"finding-v1-0000000000000001","firstSeenAttempt":4,"firstSeenSeconds":0.5,"id":0,"instanceCount":3,"isLikelySplit":false,"lastSeenSeconds":1.5,"reducedCount":2,"reducedDescription":"501","symptoms":["returnedFalse"],"unnormalizedMemberCount":1},"kind":"value","recordPath":"attachments\/run\/campaigns\/campaign-1.json","seed":"7","source":{"column":5,"fileID":"Tests\/Test.swift","line":3},"testID":"Tests\/test()","testName":"test"}"#

    static func event(type: String, payload: String) -> String {
        #"{"campaignID":"campaign-1","campaignSequence":0,"eventID":"campaign-1-00000000","payload":"# + payload
            + #","schemaVersion":1,"timestamp":100.5,"type":""# + type + #""}"#
    }

    static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func encode(_ value: some Encodable) throws -> String {
        try #require(String(bytes: encoded(value), encoding: .utf8))
    }

    static func keys(_ data: Data) throws -> Set<String> {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    static func removing(_ key: String, from json: String) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        object.removeValue(forKey: key)
        return try JSONSerialization.data(withJSONObject: object)
    }
}
