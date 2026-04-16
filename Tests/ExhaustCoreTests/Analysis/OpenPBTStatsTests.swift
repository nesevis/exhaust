import Foundation
import Testing
@testable import ExhaustCore

@Suite("OpenPBTStats")
struct OpenPBTStatsTests {
    @Test("Accumulator produces valid JSONL with correct fields")
    func accumulatorBasics() throws {
        let accumulator = OpenPBTStatsAccumulator(propertyName: "testProperty()")
        let tree = ChoiceTree.choice(
            .unsigned(50, .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )

        accumulator.record(representation: "42", passed: true, tree: tree, phase: .coverage)
        accumulator.record(representation: "99", passed: false, tree: tree, phase: .random)

        let lines = accumulator.finalize()
        #expect(lines.count == 2)

        let encoded = try encodedLines(lines)
        for json in encoded {
            #expect(json["type"] as? String == "test_case")
            #expect(json["property"] as? String == "testProperty()")
            #expect(json["run_start"] as? Double != nil)
            #expect(json["status_reason"] as? String != nil)
            #expect(json["representation"] as? String != nil)
            #expect(json.keys.contains("coverage"))
            #expect(json["coverage"] is NSNull)
            #expect(json.keys.contains("metadata"))
            #expect(json["metadata"] is NSNull)

            let features = try #require(json["features"] as? [String: Any])
            #expect(features["choice_count"] as? Int == 1)
            #expect(features["complexity_mean"] as? Double == 0.5)
            #expect(features["complexity_median"] as? Double == 0.5)
        }

        #expect(lines[0].status == "passed")
        #expect(lines[0].features.phase == .coverage)
        #expect(lines[1].status == "failed")
        #expect(lines[1].features.phase == .random)
    }

    @Test("Gave-up lines have correct status and empty representation")
    func gaveUpLines() throws {
        let accumulator = OpenPBTStatsAccumulator(propertyName: "testProperty()")
        accumulator.recordDiscards(count: 3, phase: .random)

        let lines = accumulator.finalize()
        #expect(lines.count == 3)

        for line in lines {
            #expect(line.type == "test_case")
            #expect(line.status == "gave_up")
            #expect(line.statusReason == "filter rejection")
            #expect(line.representation == "")
            #expect(line.features.choiceCount == 0)
        }
    }

    @Test("Filter observations appear as features")
    func filterFeatures() throws {
        let accumulator = OpenPBTStatsAccumulator(propertyName: "testProperty()")
        let tree = ChoiceTree.choice(
            .unsigned(50, .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )

        accumulator.record(
            representation: "42",
            passed: true,
            tree: tree,
            phase: .random,
            filterAttempts: 10,
            filterRejections: 3
        )

        let lines = accumulator.finalize()
        #expect(lines.count == 1)
        #expect(lines[0].features.filterAttempts == 10)
        #expect(lines[0].features.filterRejections == 3)
    }

    @Test("Representation is passed through to JSON output")
    func representationPassthrough() throws {
        let accumulator = OpenPBTStatsAccumulator(propertyName: "test()")
        let tree = ChoiceTree.just

        accumulator.record(
            representation: "Example(\n  name: \"hello\",\n  value: 42\n)",
            passed: true,
            tree: tree,
            phase: .coverage
        )

        let lines = accumulator.finalize()
        #expect(lines.count == 1)
        let encoded = try #require(try encodedLines(lines).first)
        let representation = try #require(encoded["representation"] as? String)
        #expect(representation.contains("name: \"hello\""))
        #expect(representation.contains("value: 42"))
    }

    @Test("Zero discards produces no lines")
    func zeroDiscards() {
        let accumulator = OpenPBTStatsAccumulator(propertyName: "test()")
        accumulator.recordDiscards(count: 0, phase: .random)
        #expect(accumulator.finalize().isEmpty)
    }

    @Test("Empty accumulator produces no lines")
    func emptyAccumulator() {
        let accumulator = OpenPBTStatsAccumulator(propertyName: "test()")
        #expect(accumulator.finalize().isEmpty)
    }

    @Test("run_start is consistent across all lines")
    func consistentRunStart() throws {
        let accumulator = OpenPBTStatsAccumulator(propertyName: "test()")
        let tree = ChoiceTree.just
        accumulator.record(representation: "1", passed: true, tree: tree, phase: .coverage)
        accumulator.record(representation: "2", passed: true, tree: tree, phase: .random)
        accumulator.recordDiscards(count: 1, phase: .random)

        let lines = accumulator.finalize()
        #expect(lines.count == 3)

        let runStarts = Set(lines.map(\.runStart))
        #expect(runStarts.count == 1)
    }

    @Test("jsonlString joins records with newlines")
    func jsonlStringFormat() throws {
        let accumulator = OpenPBTStatsAccumulator(propertyName: "test()")
        let tree = ChoiceTree.just
        accumulator.record(representation: "1", passed: true, tree: tree, phase: .coverage)
        accumulator.record(representation: "2", passed: true, tree: tree, phase: .random)

        let jsonl = accumulator.finalize().jsonlString()
        let rawLines = jsonl.components(separatedBy: "\n")
        #expect(rawLines.count == 2)
        for raw in rawLines {
            let data = try #require(raw.data(using: .utf8))
            _ = try JSONSerialization.jsonObject(with: data)
        }
    }
}

// MARK: - Helpers

private func encodedLines(_ lines: [OpenPBTStatsLine]) throws -> [[String: Any]] {
    let jsonl = lines.jsonlString()
    return try jsonl.components(separatedBy: "\n").map { raw in
        let data = try #require(raw.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
