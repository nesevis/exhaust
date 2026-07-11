// The benchmark driver behind the phase-2 measurement protocol: one process runs one arm.
//
// Loops the given seeds against one fixture and emits one JSONL record per run to stdout
// (progress goes to stderr). The experiment arm is whatever EXHAUST_SPRAWL_EXPERIMENT the
// invoking command set — the driver never sets it itself, so the arm label is pure metadata
// and cannot silently disagree with the knobs. Invoke with EXHAUST_RESUME=0 and a scratch
// EXHAUST_STATE_DIR so an interrupted benchmark can never resume-contaminate the next run:
//
//   EXHAUST_RESUME=0 EXHAUST_STATE_DIR=$(mktemp -d) \
//   EXHAUST_SPRAWL_EXPERIMENT="normalization=on" \
//   swift run -c debug ExploreBenchmark \
//     --seeds 1-20 --budget-seconds 10 --fixture parser --arm normalization-on \
//     >> .benchmarks/normalization-on.jsonl

import Exhaust
import ExploreFixture
import Foundation

// MARK: - JSONL Record

/// One benchmark run, flattened for the analyzer script.
struct BenchmarkRecord: Codable {
    var seed: UInt64
    var arm: String
    var fixture: String
    var budgetSeconds: Double
    var screeningAttempts: Int
    var samplingAttempts: Int
    var sprawlAttempts: Int
    var totalAttempts: Int
    var discardedAttempts: Int
    var elapsedSeconds: Double
    var attemptsPerSecond: Double
    var overheadFraction: Double
    var coveredEdges: Int
    var instrumentedEdges: Int
    var edgeSingletons: Int
    var edgeDoubletons: Int
    var estimatedNextEdgeProbability: Double
    var estimatedReachableEdges: Double
    var corpusEntries: Int
    var termination: String
    var clusters: [ClusterRecord]

    struct ClusterRecord: Codable {
        var id: Int
        var symptoms: [String]
        var canonicalDescription: String
        var instances: Int
        var reduced: Int
        var firstSeenAttempt: Int
        var phase: String
    }

    init(report: SprawlReport, seed: UInt64, arm: String, fixture: String, budgetSeconds: Double) {
        self.seed = seed
        self.arm = arm
        self.fixture = fixture
        self.budgetSeconds = budgetSeconds
        screeningAttempts = report.screeningAttempts
        samplingAttempts = report.samplingAttempts
        sprawlAttempts = report.sprawlAttempts
        totalAttempts = report.totalAttempts
        discardedAttempts = report.discardedAttempts
        elapsedSeconds = report.elapsed.seconds
        attemptsPerSecond = report.attemptsPerSecond
        overheadFraction = report.frameworkOverheadFraction
        coveredEdges = report.coveredEdgeCount
        instrumentedEdges = report.instrumentedEdgeCount
        edgeSingletons = report.edgeSingletonCount
        edgeDoubletons = report.edgeDoubletonCount
        estimatedNextEdgeProbability = report.estimatedNextEdgeProbability
        estimatedReachableEdges = report.estimatedReachableEdgeCount
        corpusEntries = report.corpusEntryCount
        termination = switch report.termination {
            case .budgetExhausted:
                "budgetExhausted"
            case let .coveragePlateau(unused):
                "coveragePlateau(unused: \(unused.seconds)s)"
            case .instrumentationMissing:
                "instrumentationMissing"
            case let .invalidConfiguration(message):
                "invalidConfiguration(\(message))"
            case let .generationFailed(message):
                "generationFailed(\(message))"
            case .attemptLimitReached:
                "attemptLimitReached"
        }
        clusters = report.clusters.map { cluster in
            ClusterRecord(
                id: cluster.id,
                symptoms: cluster.symptoms,
                canonicalDescription: cluster.reducedDescription,
                instances: cluster.instanceCount,
                reduced: cluster.reducedCount,
                firstSeenAttempt: cluster.firstSeenAttempt,
                phase: cluster.discoveringPhase.rawValue
            )
        }
    }
}

// MARK: - Argument Parsing

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ExploreBenchmark: \(message)\n".utf8))
    exit(2)
}

/// Parses `1-20` or `1,4,9` into a seed list.
func parseSeeds(_ text: String) -> [UInt64] {
    if let dashIndex = text.firstIndex(of: "-"),
       let lower = UInt64(text[..<dashIndex]),
       let upper = UInt64(text[text.index(after: dashIndex)...]),
       lower <= upper
    {
        return Array(lower ... upper)
    }
    let listed = text.split(separator: ",").compactMap { UInt64($0) }
    guard listed.isEmpty == false else {
        fail("could not parse --seeds value '\(text)'; expected a range like 1-20 or a list like 1,4,9")
    }
    return listed
}

var seeds: [UInt64] = Array(1 ... 20)
var budgetSeconds = 10
var budgetMilliseconds: Int?
var fixtureName = "parser"
var armLabel = "baseline"

var arguments = Array(CommandLine.arguments.dropFirst())
while arguments.isEmpty == false {
    let flag = arguments.removeFirst()
    guard arguments.isEmpty == false else {
        fail("flag \(flag) is missing a value")
    }
    let value = arguments.removeFirst()
    switch flag {
        case "--seeds":
            seeds = parseSeeds(value)
        case "--budget-seconds":
            guard let parsed = Int(value), parsed > 0 else {
                fail("--budget-seconds must be a positive integer, got '\(value)'")
            }
            budgetSeconds = parsed
        case "--budget-millis":
            guard let parsed = Int(value), parsed > 0 else {
                fail("--budget-millis must be a positive integer, got '\(value)'")
            }
            budgetMilliseconds = parsed
        case "--fixture":
            guard value == "parser" || value == "deep" else {
                fail("--fixture must be parser or deep, got '\(value)'")
            }
            fixtureName = value
        case "--arm":
            armLabel = value
        default:
            fail("unknown flag \(flag)")
    }
}

let budget: SprawlDuration
let budgetInSeconds: Double
if let budgetMilliseconds {
    budget = .milliseconds(budgetMilliseconds)
    budgetInSeconds = Double(budgetMilliseconds) / 1000
} else {
    budget = .seconds(budgetSeconds)
    budgetInSeconds = Double(budgetSeconds)
}

// MARK: - Run Loop

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

for seed in seeds {
    FileHandle.standardError.write(Data("run: fixture=\(fixtureName) arm=\(armLabel) seed=\(seed) budget=\(budgetInSeconds)s\n".utf8))
    let report: SprawlReport
    switch fixtureName {
        case "parser":
            report = #explore(
                Fixture.messageGenerator,
                time: budget,
                .replay(.numeric(seed)),
                .suppress(.all)
            ) { message in
                try Parser.decode(message).byteCount >= 0
            }
        default:
            report = #explore(
                DeepFixture.packetGenerator,
                time: budget,
                .replay(.numeric(seed)),
                .suppress(.all)
            ) { packet in
                try DeepParser.decode(packet).byteCount >= 0
            }
    }
    if case .instrumentationMissing = report.termination {
        fail("the fixture build lacks coverage instrumentation; build the package in debug configuration")
    }
    if case let .invalidConfiguration(message) = report.termination {
        fail("invalid configuration: \(message)")
    }
    let record = BenchmarkRecord(
        report: report,
        seed: seed,
        arm: armLabel,
        fixture: fixtureName,
        budgetSeconds: budgetInSeconds
    )
    guard let encoded = try? encoder.encode(record), let line = String(data: encoded, encoding: .utf8) else {
        fail("could not encode the benchmark record for seed \(seed)")
    }
    print(line)
}
