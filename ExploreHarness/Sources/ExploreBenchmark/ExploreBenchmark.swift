// The benchmark driver for paired-arm sprawl measurements: one process runs one arm.
//
// Loops the given seeds against one fixture and emits one JSONL record per run to stdout (progress goes to stderr). The experiment arm is whatever EXHAUST_SPRAWL_EXPERIMENT the invoking command set — the driver never sets it itself, so the arm label is pure metadata and cannot silently disagree with the knobs. Invoke with EXHAUST_RESUME=0 and a scratch EXHAUST_STATE_DIR so an interrupted benchmark can never resume-contaminate the next run:
//
//   EXHAUST_RESUME=0 EXHAUST_STATE_DIR=$(mktemp -d) \
//   EXHAUST_SPRAWL_EXPERIMENT="normalization=on" \
//   swift run -c debug ExploreBenchmark \
//     --seeds 1-20 --budget-seconds 10 --fixture parser --arm normalization-on \
//     >> .benchmarks/normalization-on.jsonl

import ArgumentParser
import ExecuteFixture
import Exhaust
import ExploreFixture
import Foundation

@main
struct ExploreBenchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Runs one benchmark arm: the given seeds against one fixture, one JSONL record per run on stdout.",
        discussion: "The experiment arm comes from the EXHAUST_SPRAWL_EXPERIMENT environment variable set by the invoking command; --arm is pure metadata and cannot silently disagree with the knobs. Run with EXHAUST_RESUME=0 and a scratch EXHAUST_STATE_DIR so an interrupted benchmark cannot resume-contaminate the next run."
    )

    /// The instrumented SUT a run drives.
    enum FixtureChoice: String, ExpressibleByArgument, CaseIterable {
        case parser
        case deep
        case queue
    }

    @Option(help: "Seeds as a range like 1-20 or a list like 1,4,9.")
    var seeds: SeedList = .init(values: Array(1 ... 20))

    @Option(help: "Wall-clock budget per run, in whole seconds.")
    var budgetSeconds: Int = 10

    @Option(help: "Wall-clock budget per run, in milliseconds. Overrides --budget-seconds.")
    var budgetMillis: Int?

    @Option(help: "The fixture to fuzz.")
    var fixture: FixtureChoice = .parser

    @Option(help: "Arm label recorded in each JSONL record.")
    var arm: String = "baseline"

    func validate() throws {
        guard budgetSeconds > 0 else {
            throw ValidationError("--budget-seconds must be positive.")
        }
        if let budgetMillis, budgetMillis <= 0 {
            throw ValidationError("--budget-millis must be positive.")
        }
    }

    func run() async throws {
        let budget: SprawlDuration
        let budgetInSeconds: Double
        if let budgetMillis {
            budget = .milliseconds(budgetMillis)
            budgetInSeconds = Double(budgetMillis) / 1000
        } else {
            budget = .seconds(budgetSeconds)
            budgetInSeconds = Double(budgetSeconds)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        for seed in seeds.values {
            FileHandle.standardError.write(Data("run: fixture=\(fixture.rawValue) arm=\(arm) seed=\(seed) budget=\(budgetInSeconds)s\n".utf8))
            let report: SprawlReport
            switch fixture {
                case .parser:
                    report = #explore(
                        Fixture.messageGenerator,
                        time: budget,
                        .replay(.numeric(seed)),
                        .suppress(.all)
                    ) { message in
                        try Parser.decode(message).byteCount >= 0
                    }
                case .deep:
                    report = #explore(
                        DeepFixture.packetGenerator,
                        time: budget,
                        .replay(.numeric(seed)),
                        .suppress(.all)
                    ) { packet in
                        try DeepParser.decode(packet).byteCount >= 0
                    }
                case .queue:
                    report = await #execute(
                        BenchmarkQueueSpec.self,
                        time: budget,
                        .commandLimit(40),
                        .replay(.numeric(seed)),
                        .suppress(.all)
                    )
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
                arm: arm,
                fixture: fixture.rawValue,
                budgetSeconds: budgetInSeconds
            )
            guard let encoded = try? encoder.encode(record), let line = String(data: encoded, encoding: .utf8) else {
                fail("could not encode the benchmark record for seed \(seed)")
            }
            print(line)
        }
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ExploreBenchmark: \(message)\n".utf8))
        Foundation.exit(2)
    }
}

/// A seed set parsed from one argument value: a dash range (`1-20`) or a comma list (`1,4,9`).
struct SeedList: ExpressibleByArgument {
    let values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    init?(argument: String) {
        if let dashIndex = argument.firstIndex(of: "-"),
           let lower = UInt64(argument[..<dashIndex]),
           let upper = UInt64(argument[argument.index(after: dashIndex)...]),
           lower <= upper
        {
            values = Array(lower ... upper)
            return
        }
        let listed = argument.split(separator: ",").compactMap { UInt64($0) }
        guard listed.isEmpty == false else {
            return nil
        }
        values = listed
    }

    var defaultValueDescription: String {
        "1-20"
    }
}

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

// MARK: - Queue Fixture Spec

/// Twin of BoundedQueueSpec in ExecuteTests/ExecuteFuzzTests.swift: the benchmark must measure the same spec the tests validate, and the two targets cannot share the class because @StateMachine synthesis is module-internal. Change both or neither.
@StateMachine(.sequential)
final class BenchmarkQueueSpec {
    var model: [Int] = []
    @SystemUnderTest var queue: BoundedQueue = .init(capacity: 24)

    @Invariant
    func countMatchesModel() -> Bool {
        queue.count == model.count
    }

    @Invariant
    func elementsMatchModel() -> Bool {
        queue.elements == model
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func enqueue(value: Int) throws {
        let succeeded = queue.enqueue(value)
        if succeeded {
            model.append(value)
        }
    }

    @Command(weight: 1)
    func dequeue() throws {
        guard queue.isEmpty == false else {
            throw skip()
        }
        let removed = try queue.dequeue()
        let expected = model.removeFirst()
        guard removed == expected else {
            throw BoundedQueueError.corruption
        }
    }

    @Command(weight: 1)
    func peekTracked() throws {
        guard queue.isEmpty == false else {
            throw skip()
        }
        let peeked = try queue.peekTracked()
        guard peeked == model.first else {
            throw BoundedQueueError.corruption
        }
    }

    @Command(weight: 1)
    func clear() throws {
        queue.clear()
        if queue.elements == [-888] {
            throw BoundedQueueError.corruption
        }
        model.removeAll()
    }

    @Command(weight: 1, .int(in: 1 ... 3), .int(in: 0 ... 9))
    func batchEnqueue(count: Int, startValue: Int) throws {
        let values = (0 ..< count).map { startValue + $0 }
        let added = queue.batchEnqueue(values)
        model.append(contentsOf: values.prefix(added))
    }

    @Command(weight: 1)
    func stats() throws {
        let info = queue.stats()
        guard info.count == model.count else {
            throw BoundedQueueError.corruption
        }
    }

    func failureDescription() -> String? {
        "queue: \(queue.elements), model: \(model)"
    }
}
