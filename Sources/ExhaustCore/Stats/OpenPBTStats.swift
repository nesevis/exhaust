// OpenPBTStats format types and accumulator for per-example JSONL export.
//
// Implements the OpenPBTStats standard for integration with the Tyche visualization tool (github.com/tyche-pbt/tyche-extension). Each test example produces one JSON line with status, complexity features, and a string representation.
//
// Schema reference: observability-tools/src/datatypes.ts in tyche-extension.
import Foundation

/// Generation phase that produced an example.
package enum OpenPBTStatsPhase: String, Codable {
    /// Indicates the example was produced during structured covering-array enumeration, which runs first to achieve combinatorial coverage of the generator's parameter space.
    case coverage
    /// Indicates the example was produced during standard PRNG-based sampling, which runs after the coverage phase completes.
    case random
}

/// Per-example features attached to each OpenPBTStats line.
package struct OpenPBTStatsFeatures: Codable {
    /// Generation phase that produced this example.
    package let phase: OpenPBTStatsPhase
    /// Number of choice points in the generated value's choice tree.
    package let choiceCount: Int
    /// Arithmetic mean of all normalized complexity scores.
    package let complexityMean: Double?
    /// Median of all normalized complexity scores.
    package let complexityMedian: Double?
    /// Total filter predicate evaluations during this example's generation.
    package let filterAttempts: Int?
    /// Filter predicate evaluations that returned false.
    package let filterRejections: Int?

    /// Creates a features record with the given generation phase and complexity metrics.
    package init(
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
    /// Record type, always `"test_case"`.
    package let type: String
    /// Epoch timestamp when the test run started.
    package let runStart: Double
    /// Name of the property under test.
    package let property: String
    /// Outcome status: `"passed"`, `"failed"`, or `"gave_up"`.
    package let status: String
    /// Human-readable reason for the status, empty when not applicable.
    package let statusReason: String
    /// String representation of the generated test example.
    package let representation: String
    /// Complexity and phase features for this example.
    package let features: OpenPBTStatsFeatures
    /// How this example was produced, for example `"reduced"`.
    package let howGenerated: String?
    /// Per-phase timing in seconds, keyed by phase name.
    package let timing: [String: Double]?
    /// Parallel batch index that produced this example, or `nil` for sequential runs.
    package let lane: Int?

    /// Creates a stats line with all required and optional fields.
    package init(
        type: String,
        runStart: Double,
        property: String,
        status: String,
        statusReason: String,
        representation: String,
        features: OpenPBTStatsFeatures,
        howGenerated: String? = nil,
        timing: [String: Double]? = nil,
        lane: Int? = nil
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
        self.lane = lane
    }
}

extension OpenPBTStatsLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, runStart, property, status, statusReason, representation, features, howGenerated, timing, coverage, metadata, lane
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
        try container.encodeIfPresent(lane, forKey: .lane)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            type: container.decode(String.self, forKey: .type),
            runStart: container.decode(Double.self, forKey: .runStart),
            property: container.decode(String.self, forKey: .property),
            status: container.decode(String.self, forKey: .status),
            statusReason: container.decode(String.self, forKey: .statusReason),
            representation: container.decode(String.self, forKey: .representation),
            features: container.decode(OpenPBTStatsFeatures.self, forKey: .features),
            howGenerated: container.decodeIfPresent(String.self, forKey: .howGenerated),
            timing: container.decodeIfPresent([String: Double].self, forKey: .timing),
            lane: container.decodeIfPresent(Int.self, forKey: .lane)
        )
    }
}

package extension Sequence<OpenPBTStatsLine> {
    /// Encodes each record as a JSON object and joins them with newlines to form a JSONL document.
    ///
    /// Records that fail to encode are skipped. Intended for attaching to test outputs consumed by the Tyche visualization extension.
    func jsonlString() -> String {
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
/// Stores records as typed ``OpenPBTStatsLine`` values. JSON encoding happens once, on ``finalize()``. When parallel generation is active, each lane creates its own accumulator and the results are merged via ``appendLines(_:)`` after all lanes complete.
///
/// Not `Sendable` — used from a single thread within the generation loop.
package final class OpenPBTStatsAccumulator {
    private let runStart: Double
    private let propertyName: String
    private let lane: Int?
    private var lines: [OpenPBTStatsLine] = []

    /// - Parameter lane: Parallel batch index stamped onto every recorded line, or `nil` for sequential runs.
    package init(propertyName: String, lane: Int? = nil) {
        self.propertyName = propertyName
        self.lane = lane
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
            timing: timing,
            lane: lane
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
            timing: ["reduce": reductionSeconds],
            lane: lane
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
            timing: nil,
            lane: lane
        )

        for _ in 0 ..< count {
            lines.append(template)
        }
    }

    /// Appends lines from another accumulator (for example, merging parallel batch results).
    package func appendLines(_ newLines: [OpenPBTStatsLine]) {
        lines.append(contentsOf: newLines)
    }

    /// Returns the accumulated records as typed values in append order.
    package func finalize() -> [OpenPBTStatsLine] {
        lines
    }
}
