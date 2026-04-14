// OpenPBTStats format types and accumulator for per-example JSONL export.
//
// Implements the OpenPBTStats standard for integration with the Tyche visualization
// tool (github.com/tyche-pbt/tyche-extension). Each test example produces one JSON
// line with status, complexity features, and a string representation.
//
// Schema reference: observability-tools/src/datatypes.ts in tyche-extension.
import Foundation

/// Generation phase that produced an example.
package enum OpenPBTStatsPhase: String, Codable, Sendable {
    case coverage
    case random
}

/// Per-example features attached to each OpenPBTStats line.
struct OpenPBTStatsFeatures: Codable, Sendable {
    /// Generation phase that produced this example.
    let phase: OpenPBTStatsPhase
    /// Number of choice points in the generated value's choice tree.
    let choiceCount: Int
    /// Arithmetic mean of all normalized complexity scores.
    let complexityMean: Double?
    /// Median of all normalized complexity scores.
    let complexityMedian: Double?
    /// Total filter predicate evaluations during this example's generation.
    let filterAttempts: Int?
    /// Filter predicate evaluations that returned false.
    let filterRejections: Int?
}

/// One line of OpenPBTStats JSONL output, representing a single test example.
///
/// Matches the `schemaTestCaseLine` Zod schema in Tyche's `datatypes.ts`:
/// - `type`: `"test_case"` (literal)
/// - `status`: `"passed"`, `"failed"`, or `"gave_up"`
/// - `status_reason`: required string (empty when no specific reason)
/// - `coverage`: `null` (Exhaust does not provide per-example line coverage)
/// - `metadata`: `null` (reserved for future use)
struct OpenPBTStatsLine: Encodable, Sendable {
    let type: String
    let runStart: Double
    let property: String
    let status: String
    let statusReason: String
    let representation: String
    let features: OpenPBTStatsFeatures
    let howGenerated: String?
    let timing: [String: Double]?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(runStart, forKey: .runStart)
        try container.encode(property, forKey: .property)
        try container.encode(status, forKey: .status)
        try container.encode(statusReason, forKey: .statusReason)
        try container.encode(representation, forKey: .representation)
        try container.encode(features, forKey: .features)
        try container.encodeIfPresent(howGenerated, forKey: .howGenerated)
        try container.encodeIfPresent(timing, forKey: .timing)
        try container.encodeNil(forKey: .coverage)
        try container.encodeNil(forKey: .metadata)
    }

    private enum CodingKeys: String, CodingKey {
        case type, runStart, property, status, statusReason, representation, features, howGenerated, timing, coverage, metadata
    }
}

/// Accumulates OpenPBTStats JSONL lines during a test run.
///
/// Not `Sendable` — used from a single thread within the generation loop.
package final class OpenPBTStatsAccumulator {
    private let encoder: JSONEncoder
    private let runStart: Double
    private let propertyName: String
    private var lines: [Data] = []

    package init(propertyName: String) {
        self.propertyName = propertyName
        runStart = Date().timeIntervalSince1970
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    /// Records a single test example with its choice tree and pass/fail result.
    package func record(
        representation: String,
        passed: Bool,
        tree: ChoiceTree,
        phase: OpenPBTStatsPhase,
        generateSeconds: Double? = nil,
        testSeconds: Double? = nil,
        filterAttempts: Int? = nil,
        filterRejections: Int? = nil
    ) {
        let scores = tree.normalizedScores()
        let complexity = ComplexityFeatures.from(scores)

        let features = OpenPBTStatsFeatures(
            phase: phase,
            choiceCount: scores.count,
            complexityMean: complexity?.mean,
            complexityMedian: complexity?.median,
            filterAttempts: filterAttempts,
            filterRejections: filterRejections
        )

        var timing: [String: Double]?
        if generateSeconds != nil || testSeconds != nil {
            var timingDict: [String: Double] = [:]
            if let generateSeconds { timingDict["generate"] = generateSeconds }
            if let testSeconds { timingDict["test"] = testSeconds }
            timing = timingDict
        }

        let line = OpenPBTStatsLine(
            type: "test_case",
            runStart: runStart,
            property: propertyName,
            status: passed ? "passed" : "failed",
            statusReason: "",
            representation: representation,
            features: features,
            howGenerated: nil,
            timing: timing
        )

        if let data = try? encoder.encode(line) {
            lines.append(data)
        }
    }

    /// Records the reduced counterexample after reduction.
    package func recordReduced(
        representation: String,
        tree: ChoiceTree,
        reductionSeconds: Double
    ) {
        let scores = tree.normalizedScores()
        let complexity = ComplexityFeatures.from(scores)

        let features = OpenPBTStatsFeatures(
            phase: .random,
            choiceCount: scores.count,
            complexityMean: complexity?.mean,
            complexityMedian: complexity?.median,
            filterAttempts: nil,
            filterRejections: nil
        )

        let line = OpenPBTStatsLine(
            type: "test_case",
            runStart: runStart,
            property: propertyName,
            status: "failed",
            statusReason: "reduced counterexample",
            representation: representation,
            features: features,
            howGenerated: "reduced",
            timing: ["reduce": reductionSeconds]
        )

        if let data = try? encoder.encode(line) {
            lines.append(data)
        }
    }

    /// Records synthetic "gave_up" lines for filter rejections.
    package func recordDiscards(count: Int, phase: OpenPBTStatsPhase) {
        guard count > 0 else { return }

        let features = OpenPBTStatsFeatures(
            phase: phase,
            choiceCount: 0,
            complexityMean: nil,
            complexityMedian: nil,
            filterAttempts: nil,
            filterRejections: nil
        )

        let line = OpenPBTStatsLine(
            type: "test_case",
            runStart: runStart,
            property: propertyName,
            status: "gave_up",
            statusReason: "filter rejection",
            representation: "",
            features: features,
            howGenerated: nil,
            timing: nil
        )

        guard let data = try? encoder.encode(line) else { return }
        for _ in 0 ..< count {
            lines.append(data)
        }
    }

    /// Returns the accumulated JSONL content as a UTF-8 string.
    package func finalize() -> String {
        lines.compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
