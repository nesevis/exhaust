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

        let jsonl = accumulator.finalize()
        let lines = jsonl.components(separatedBy: "\n")
        #expect(lines.count == 2)

        for line in lines {
            let data = try #require(line.data(using: .utf8))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
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

        let firstLine = try #require(lines.first?.data(using: .utf8))
        let first = try #require(try JSONSerialization.jsonObject(with: firstLine) as? [String: Any])
        #expect(first["status"] as? String == "passed")
        let firstFeatures = try #require(first["features"] as? [String: Any])
        #expect(firstFeatures["phase"] as? String == "coverage")

        let secondLine = try #require(lines.last?.data(using: .utf8))
        let second = try #require(try JSONSerialization.jsonObject(with: secondLine) as? [String: Any])
        #expect(second["status"] as? String == "failed")
        let secondFeatures = try #require(second["features"] as? [String: Any])
        #expect(secondFeatures["phase"] as? String == "random")
    }

    @Test("Gave-up lines have correct status and empty representation")
    func gaveUpLines() throws {
        let accumulator = OpenPBTStatsAccumulator(propertyName: "testProperty()")
        accumulator.recordDiscards(count: 3, phase: .random)

        let jsonl = accumulator.finalize()
        let lines = jsonl.components(separatedBy: "\n")
        #expect(lines.count == 3)

        for line in lines {
            let data = try #require(line.data(using: .utf8))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["type"] as? String == "test_case")
            #expect(json["status"] as? String == "gave_up")
            #expect(json["status_reason"] as? String == "filter rejection")
            #expect(json["representation"] as? String == "")
            let features = try #require(json["features"] as? [String: Any])
            #expect(features["choice_count"] as? Int == 0)
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

        let jsonl = accumulator.finalize()
        let data = try #require(jsonl.data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try #require(json["features"] as? [String: Any])
        #expect(features["filter_attempts"] as? Int == 10)
        #expect(features["filter_rejections"] as? Int == 3)
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

        let jsonl = accumulator.finalize()
        let data = try #require(jsonl.data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let representation = try #require(json["representation"] as? String)
        #expect(representation.contains("name: \"hello\""))
        #expect(representation.contains("value: 42"))
    }

    @Test("Zero discards produces no lines")
    func zeroDiscards() {
        let accumulator = OpenPBTStatsAccumulator(propertyName: "test()")
        accumulator.recordDiscards(count: 0, phase: .random)

        let jsonl = accumulator.finalize()
        #expect(jsonl.isEmpty)
    }

    @Test("Empty accumulator produces empty string")
    func emptyAccumulator() {
        let accumulator = OpenPBTStatsAccumulator(propertyName: "test()")
        let jsonl = accumulator.finalize()
        #expect(jsonl.isEmpty)
    }

    @Test("run_start is consistent across all lines")
    func consistentRunStart() throws {
        let accumulator = OpenPBTStatsAccumulator(propertyName: "test()")
        let tree = ChoiceTree.just
        accumulator.record(representation: "1", passed: true, tree: tree, phase: .coverage)
        accumulator.record(representation: "2", passed: true, tree: tree, phase: .random)
        accumulator.recordDiscards(count: 1, phase: .random)

        let jsonl = accumulator.finalize()
        let lines = jsonl.components(separatedBy: "\n")
        #expect(lines.count == 3)

        var runStarts: Set<Double> = []
        for line in lines {
            let data = try #require(line.data(using: .utf8))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let runStart = try #require(json["run_start"] as? Double)
            runStarts.insert(runStart)
        }
        #expect(runStarts.count == 1)
    }
}
