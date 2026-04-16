// OpenPBTStats format types and accumulator for per-example JSONL export.
//
// Implements the OpenPBTStats standard for integration with the Tyche visualization
// tool (github.com/tyche-pbt/tyche-extension). Each test example produces one JSON
// line with status, complexity features, and a string representation.
//
// Schema reference: observability-tools/src/datatypes.ts in tyche-extension.
import Foundation

/// Generation phase that produced an example.
public enum OpenPBTStatsPhase: String, Codable, Sendable {
    case coverage
    case random
}

/// Per-example features attached to each OpenPBTStats line.
public struct OpenPBTStatsFeatures: Codable, Sendable {
    /// Generation phase that produced this example.
    public let phase: OpenPBTStatsPhase
    /// Number of choice points in the generated value's choice tree.
    public let choiceCount: Int
    /// Arithmetic mean of all normalized complexity scores.
    public let complexityMean: Double?
    /// Median of all normalized complexity scores.
    public let complexityMedian: Double?
    /// Total filter predicate evaluations during this example's generation.
    public let filterAttempts: Int?
    /// Filter predicate evaluations that returned false.
    public let filterRejections: Int?

    public init(
        phase: OpenPBTStatsPhase,
        choiceCount: Int,
        complexityMean: Double?,
        complexityMedian: Double?,
        filterAttempts: Int?,
        filterRejections: Int?
    ) {
        self.phase = phase
        self.choiceCount = choiceCount
        self.complexityMean = complexityMean
        self.complexityMedian = complexityMedian
        self.filterAttempts = filterAttempts
        self.filterRejections = filterRejections
    }
}

/// One record of OpenPBTStats output, representing a single test example.
///
/// Matches the `schemaTestCaseLine` Zod schema in Tyche's `datatypes.ts`:
/// - `type`: `"test_case"` (literal).
/// - `status`: `"passed"`, `"failed"`, or `"gave_up"`.
/// - `status_reason`: required string (empty when no specific reason).
/// - `coverage`: `null` (Exhaust does not provide per-example line coverage).
/// - `metadata`: `null` (reserved for future use).
public struct OpenPBTStatsLine: Sendable {
    public let type: String
    public let runStart: Double
    public let property: String
    public let status: String
    public let statusReason: String
    public let representation: String
    public let features: OpenPBTStatsFeatures
    public let howGenerated: String?
    public let timing: [String: Double]?

    public init(
        type: String,
        runStart: Double,
        property: String,
        status: String,
        statusReason: String,
        representation: String,
        features: OpenPBTStatsFeatures,
        howGenerated: String? = nil,
        timing: [String: Double]? = nil
    ) {
        self.type = type
        self.runStart = runStart
        self.property = property
        self.status = status
        self.statusReason = statusReason
        self.representation = representation
        self.features = features
        self.howGenerated = howGenerated
        self.timing = timing
    }
}

extension OpenPBTStatsLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, runStart, property, status, statusReason, representation, features, howGenerated, timing, coverage, metadata
    }

    public func encode(to encoder: Encoder) throws {
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try container.decode(String.self, forKey: .type),
            runStart: try container.decode(Double.self, forKey: .runStart),
            property: try container.decode(String.self, forKey: .property),
            status: try container.decode(String.self, forKey: .status),
            statusReason: try container.decode(String.self, forKey: .statusReason),
            representation: try container.decode(String.self, forKey: .representation),
            features: try container.decode(OpenPBTStatsFeatures.self, forKey: .features),
            howGenerated: try container.decodeIfPresent(String.self, forKey: .howGenerated),
            timing: try container.decodeIfPresent([String: Double].self, forKey: .timing)
        )
    }
}

extension Sequence where Element == OpenPBTStatsLine {
    /// Encodes each record as a JSON object and joins them with newlines to form a JSONL document.
    ///
    /// Records that fail to encode are skipped. Intended for attaching to test outputs consumed by the Tyche visualization extension.
    public func jsonlString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return compactMap { line in
            guard let data = try? encoder.encode(line) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
    }
}

/// Accumulates OpenPBTStats records during a test run.
///
/// Stores records as typed ``OpenPBTStatsLine`` values. JSON encoding happens once, on ``finalize()``.
///
/// Not `Sendable` — used from a single thread within the generation loop.
package final class OpenPBTStatsAccumulator {
    private let runStart: Double
    private let propertyName: String
    private var lines: [OpenPBTStatsLine] = []

    package init(propertyName: String) {
        self.propertyName = propertyName
        runStart = Date().timeIntervalSince1970
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

        lines.append(OpenPBTStatsLine(
            type: "test_case",
            runStart: runStart,
            property: propertyName,
            status: passed ? "passed" : "failed",
            statusReason: "",
            representation: representation,
            features: features,
            howGenerated: nil,
            timing: timing
        ))
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

        lines.append(OpenPBTStatsLine(
            type: "test_case",
            runStart: runStart,
            property: propertyName,
            status: "failed",
            statusReason: "reduced counterexample",
            representation: representation,
            features: features,
            howGenerated: "reduced",
            timing: ["reduce": reductionSeconds]
        ))
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

        let template = OpenPBTStatsLine(
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

        for _ in 0 ..< count {
            lines.append(template)
        }
    }

    /// Returns the accumulated records as typed values in append order.
    package func finalize() -> [OpenPBTStatsLine] {
        lines
    }
}
