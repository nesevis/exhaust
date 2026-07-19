// The benchmark driver for paired-arm fuzz measurements.
//
// `run` (the default subcommand) loops the given seeds against one fixture and emits one JSONL record per run to stdout (progress goes to stderr). The experiment arm is whatever EXHAUST_FUZZ_EXPERIMENT the invoking command set — the driver never sets it itself, so the arm label is pure metadata and cannot silently disagree with the knobs. Invoke with EXHAUST_RESUME=0 and a scratch EXHAUST_STATE_DIR so an interrupted benchmark can never resume-contaminate the next run:
//
//   EXHAUST_RESUME=0 EXHAUST_STATE_DIR=$(mktemp -d) \
//   EXHAUST_FUZZ_EXPERIMENT="normalization=on" \
//   swift run -c debug ExploreBenchmark \
//     --seeds 1-20 --budget-seconds 10 --fixture parser --arm normalization-on \
//     >> .benchmarks/normalization-on.jsonl
//
// `calibrate` runs the full matrix calibration sweep (MX1g/MX2e: every matrix fixture x seeds at the pinned protocol), appends the raw records to a JSONL file for `analyze`, and prints the per-fixture window verdicts. It pins the resume environment itself:
//
//   swift run -c debug ExploreBenchmark calibrate
//
// `analyze` is the paired A/B analyzer (formerly Benchmarks/analyze.py): per-seed deltas first, then per-fixture medians, IQRs, and paired sign tests:
//
//   swift run -c debug ExploreBenchmark analyze .benchmarks/baseline.jsonl .benchmarks/candidate.jsonl

import ArgumentParser
import ExecuteFixture
import Exhaust
import ExploreFixture
import Foundation
import MatrixSpecs

@main
struct ExploreBenchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "benchmark driver for paired-arm fuzz measurements.",
        subcommands: [Run.self, Calibrate.self, Analyze.self],
        defaultSubcommand: Run.self
    )

    /// The instrumented SUT a run drives.
    enum FixtureChoice: String, ExpressibleByArgument, CaseIterable {
        case parser
        case deep
        case queue
        case lengthGate = "length-gate"
        case dedup
        case recursiveDepth = "recursive-depth"
        case wideAlign = "wide-align"
        case phaseFlat = "phase-flat"
        case phaseLaddered = "phase-laddered"
        case handle
        case coupled
        case toggle
        case ledger40 = "ledger-40"
        case ledger90 = "ledger-90"
        case ledger90Laddered = "ledger-90-laddered"
        case router
    }

    /// A run whose report signals a configuration problem rather than a measurement.
    struct RunFailure: Error {
        let message: String
    }

    /// Executes one fixture run and flattens it into a record. Shared by `run` and `calibrate`.
    static func benchmarkRecord(
        fixture: FixtureChoice,
        seed: UInt64,
        budget: TimeSpan,
        budgetSeconds: Double,
        arm: String
    ) async throws -> BenchmarkRecord {
        // The starvation observable resets per run so each JSONL record carries its own fraction; only the handle fixture emits it.
        _ = HandleTableSkipCounters.snapshotAndReset()
        let report: FuzzReport
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
                report = await specReport(BoundedQueueSpec.self, seed: seed, budget: budget)
            case .lengthGate:
                report = #explore(
                    LengthGateFixture.valuesGenerator,
                    time: budget,
                    .replay(.numeric(seed)),
                    .suppress(.all)
                ) { values in
                    try LengthGate.process(values) >= 0
                }
            case .dedup:
                report = #explore(
                    DedupGateFixture.valuesGenerator,
                    time: budget,
                    .replay(.numeric(seed)),
                    .suppress(.all)
                ) { values in
                    try DedupGate.ingest(values) >= 0
                }
            case .recursiveDepth:
                report = #explore(
                    RecursiveDepthFixture.treeGenerator,
                    time: budget,
                    .replay(.numeric(seed)),
                    .suppress(.all)
                ) { tree in
                    try RecursiveDepth.measure(tree) >= 0
                }
            case .wideAlign:
                report = #explore(
                    WideAlignFixture.pairGenerator,
                    time: budget,
                    .replay(.numeric(seed)),
                    .suppress(.all)
                ) { pair in
                    try WideAligner.check(pair)
                    return true
                }
            case .phaseFlat:
                report = await specReport(PhaseProtocolFlatSpec.self, seed: seed, budget: budget)
            case .phaseLaddered:
                report = await specReport(PhaseProtocolLadderedSpec.self, seed: seed, budget: budget)
            case .handle:
                report = await specReport(HandleTableSpec.self, seed: seed, budget: budget)
            case .coupled:
                report = await specReport(CoupledValuesSpec.self, seed: seed, budget: budget)
            case .toggle:
                report = await specReport(ToggleParitySpec.self, seed: seed, budget: budget)
            case .ledger40:
                report = await specReport(ThresholdLedger40Spec.self, seed: seed, budget: budget)
            case .ledger90:
                report = await specReport(ThresholdLedger90Spec.self, seed: seed, budget: budget)
            case .ledger90Laddered:
                report = await specReport(ThresholdLedger90LadderedSpec.self, seed: seed, budget: budget)
            case .router:
                report = await specReport(BranchyRouterSpec.self, seed: seed, budget: budget)
        }
        if case .instrumentationMissing = report.termination {
            throw RunFailure(message: "the fixture build lacks coverage instrumentation; build the package in debug configuration")
        }
        if case let .invalidConfiguration(message) = report.termination {
            throw RunFailure(message: "invalid configuration: \(message)")
        }
        var record = BenchmarkRecord(
            report: report,
            seed: seed,
            arm: arm,
            fixture: fixture.rawValue,
            budgetSeconds: budgetSeconds
        )
        if fixture == .handle {
            let skipCounts = HandleTableSkipCounters.snapshotAndReset()
            if skipCounts.entered > 0 {
                record.handleSkipFraction = Double(skipCounts.skipped) / Double(skipCounts.entered)
            }
        }
        return record
    }

    /// Runs one spec-path fixture at the pinned matrix protocol: command limit 40, deterministic replay of `seed`, all output suppressed. The single definition site for the protocol's settings — every spec fixture must run the same call shape or paired-arm comparisons are invalid.
    private static func specReport(
        _ spec: (some StateMachineSpec).Type,
        seed: UInt64,
        budget: TimeSpan
    ) async -> FuzzReport {
        await #execute(spec, time: budget, .commandLimit(40), .replay(.numeric(seed)), .suppress(.all))
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ExploreBenchmark: \(message)\n".utf8))
    Foundation.exit(2)
}

// MARK: - Run

extension ExploreBenchmark {
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Runs one benchmark arm: the given seeds against one fixture, one JSONL record per run on stdout.",
            discussion: "The experiment arm comes from the EXHAUST_FUZZ_EXPERIMENT environment variable set by the invoking command; --arm is pure metadata and cannot silently disagree with the knobs. Run with EXHAUST_RESUME=0 and a scratch EXHAUST_STATE_DIR so an interrupted benchmark cannot resume-contaminate the next run."
        )

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
            let budget: TimeSpan
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
                let record: BenchmarkRecord
                do {
                    record = try await ExploreBenchmark.benchmarkRecord(
                        fixture: fixture,
                        seed: seed,
                        budget: budget,
                        budgetSeconds: budgetInSeconds,
                        arm: arm
                    )
                } catch let failure as RunFailure {
                    fail(failure.message)
                }
                guard let encoded = try? encoder.encode(record), let line = String(data: encoded, encoding: .utf8) else {
                    fail("could not encode the benchmark record for seed \(seed)")
                }
                print(line)
            }
        }
    }
}

// MARK: - Calibrate

extension ExploreBenchmark {
    struct Calibrate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "calibrate",
            abstract: "Runs the matrix calibration sweep (MX1g/MX2e): every matrix fixture across the seeds, then prints per-fixture window verdicts.",
            discussion: "Runs with defaults (no experiment arm) and pins EXHAUST_RESUME=0 plus a scratch EXHAUST_STATE_DIR itself, so an interrupted sweep can never resume-contaminate the next one. Raw records append to the output JSONL (truncated first) for the analyze subcommand; the summary prints to stdout. Windows scale with the seed count: differentials pass at <= 10% of runs (2/20), sentinels at >= 90% (18/20); pinned and recorded-only fixtures are informational."
        )

        @Option(help: "Seeds as a range like 1-20 or a list like 1,4,9.")
        var seeds: SeedList = .init(values: Array(1 ... 20))

        @Option(help: "Wall-clock budget per run, in whole seconds.")
        var budgetSeconds: Int = 10

        @Option(help: "JSONL output path for the raw per-run records.")
        var output: String = ".benchmarks/matrix-calibration.jsonl"

        func validate() throws {
            guard budgetSeconds > 0 else {
                throw ValidationError("--budget-seconds must be positive.")
            }
        }

        /// The matrix members, spec path then value path. `parser` (the standing regression gate) is deliberately absent.
        static let matrixFixtures: [FixtureChoice] = [
            .queue, .phaseFlat, .phaseLaddered, .handle, .coupled, .toggle,
            .ledger40, .ledger90, .ledger90Laddered, .router,
            .deep, .lengthGate, .dedup, .recursiveDepth, .wideAlign,
        ]

        static func window(for fixture: FixtureChoice) -> Window {
            switch fixture {
                case .phaseFlat, .toggle, .ledger90, .wideAlign:
                    .differential
                case .handle, .coupled, .router, .lengthGate, .recursiveDepth:
                    .sentinel
                case .queue:
                    .pinned("~4/20 (fault A; S and P land higher)")
                case .deep:
                    .pinned("~2/20 (fault R; P and Q land higher)")
                case .phaseLaddered, .ledger40, .ledger90Laddered, .dedup:
                    .recorded
                case .parser:
                    .recorded
            }
        }

        func run() async throws {
            // Pin the resume environment before the first fuzz run reads it. Overwrites any external values on purpose: calibration must never resume prior state.
            let scratchStateDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("exhaust-calibration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratchStateDirectory, withIntermediateDirectories: true)
            setenv("EXHAUST_RESUME", "0", 1)
            setenv("EXHAUST_STATE_DIR", scratchStateDirectory.path, 1)

            let outputURL = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outputHandle.close() }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

            let budget = TimeSpan.seconds(budgetSeconds)
            let totalRuns = Self.matrixFixtures.count * seeds.values.count
            var completedRuns = 0
            var summaries: [FixtureSummary] = []

            for fixture in Self.matrixFixtures {
                var summary = FixtureSummary(fixture: fixture)
                for seed in seeds.values {
                    completedRuns += 1
                    FileHandle.standardError.write(Data("calibrate [\(completedRuns)/\(totalRuns)]: fixture=\(fixture.rawValue) seed=\(seed) budget=\(budgetSeconds)s\n".utf8))
                    let record: BenchmarkRecord
                    do {
                        record = try await ExploreBenchmark.benchmarkRecord(
                            fixture: fixture,
                            seed: seed,
                            budget: budget,
                            budgetSeconds: Double(budgetSeconds),
                            arm: "calibration"
                        )
                    } catch let failure as RunFailure {
                        fail(failure.message)
                    }
                    guard let encoded = try? encoder.encode(record), let line = String(data: encoded, encoding: .utf8) else {
                        fail("could not encode the benchmark record for fixture \(fixture.rawValue), seed \(seed)")
                    }
                    try outputHandle.write(contentsOf: Data((line + "\n").utf8))
                    summary.absorb(record)
                }
                summaries.append(summary)
            }

            printSummary(summaries)
            print("\nraw records: \(output)")
        }

        private func printSummary(_ summaries: [FixtureSummary]) {
            print("\n=== calibration summary (seeds with >= 1 cluster) ===")
            print("\(Analyze.pad("fixture", 20)) \(Analyze.pad("found", 7)) \(Analyze.pad("window", 34)) \(Analyze.pad("verdict", 7)) extras")
            var failures = 0
            for summary in summaries {
                let window = Self.window(for: summary.fixture)
                let verdict = window.verdict(found: summary.foundCount, runs: summary.runCount)
                if verdict == .fail {
                    failures += 1
                }
                var extras = "maxCoveredEdges=\(summary.maxCoveredEdges)"
                if let skipFraction = summary.medianSkipFraction {
                    extras += String(format: "  medianSkipFraction=%.3f", skipFraction)
                }
                let found = "\(summary.foundCount)/\(summary.runCount)"
                print("\(Analyze.pad(summary.fixture.rawValue, 20)) \(Analyze.pad(found, 7)) \(Analyze.pad(window.label, 34)) \(Analyze.pad(verdict.label, 7)) \(extras)")
            }
            if failures > 0 {
                print("\n\(failures) fixture(s) outside their calibration window — retune geometry and re-run (ground rule 2).")
            } else {
                print("\nall gated fixtures inside their calibration windows.")
            }
        }
    }

    /// The outcome of checking a fixture's found count against its window.
    enum Verdict {
        case pass
        case fail
        /// Pinned and recorded fixtures re-measure without gating.
        case informational

        var label: String {
            switch self {
                case .pass: "PASS"
                case .fail: "FAIL"
                case .informational: "info"
            }
        }
    }

    /// Which side of the calibration window a fixture's fault must land on (design doc, *Calibration discipline*).
    enum Window {
        /// A mechanism differential: blind-improbable, baseline finds it in at most 10% of seeds.
        case differential
        /// A regression sentinel: baseline finds it in at least 90% of seeds.
        case sentinel
        /// An existing fixture with a pinned baseline; the sweep re-measures but does not gate.
        case pinned(String)
        /// Recorded for the registry without a gate (laddered variants, expected-high probes).
        case recorded

        var label: String {
            switch self {
                case .differential: "<= 10%"
                case .sentinel: ">= 90%"
                case let .pinned(expectation): "pinned \(expectation)"
                case .recorded: "recorded"
            }
        }

        func verdict(found: Int, runs: Int) -> Verdict {
            switch self {
                case .differential:
                    found * 10 <= runs ? .pass : .fail
                case .sentinel:
                    found * 10 >= runs * 9 ? .pass : .fail
                case .pinned, .recorded:
                    .informational
            }
        }
    }

    /// Per-fixture aggregation for the calibration summary.
    struct FixtureSummary {
        let fixture: FixtureChoice
        var runCount = 0
        var foundCount = 0
        var maxCoveredEdges = 0
        var skipFractions: [Double] = []

        mutating func absorb(_ record: BenchmarkRecord) {
            runCount += 1
            if record.clusters.isEmpty == false {
                foundCount += 1
            }
            maxCoveredEdges = max(maxCoveredEdges, record.coveredEdges)
            if let skipFraction = record.handleSkipFraction {
                skipFractions.append(skipFraction)
            }
        }

        var medianSkipFraction: Double? {
            guard skipFractions.isEmpty == false else {
                return nil
            }
            return Analyze.median(skipFractions)
        }
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

/// One benchmark run, flattened for the `analyze` subcommand.
struct BenchmarkRecord: Codable {
    var seed: UInt64
    var arm: String
    var fixture: String
    var budgetSeconds: Double
    var screeningAttempts: Int
    var samplingAttempts: Int
    var mutationAttempts: Int
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

    /// The HandleTable starvation observable: precondition-skipped commands over entered commands (a skipped command counts in both), present only on `--fixture handle` records (synthesized Codable omits it elsewhere, so other fixtures' schema is unchanged).
    var handleSkipFraction: Double?

    private enum LegacyCodingKeys: String, CodingKey {
        case sprawlAttempts
    }

    /// Custom decode: archived records from before the 2026-07-13 sprawl→fuzz rename store this field under the old key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seed = try container.decode(UInt64.self, forKey: .seed)
        arm = try container.decode(String.self, forKey: .arm)
        fixture = try container.decode(String.self, forKey: .fixture)
        budgetSeconds = try container.decode(Double.self, forKey: .budgetSeconds)
        screeningAttempts = try container.decode(Int.self, forKey: .screeningAttempts)
        samplingAttempts = try container.decode(Int.self, forKey: .samplingAttempts)
        if let value = try container.decodeIfPresent(Int.self, forKey: .mutationAttempts) {
            mutationAttempts = value
        } else {
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
            mutationAttempts = try legacyContainer.decode(Int.self, forKey: .sprawlAttempts)
        }
        totalAttempts = try container.decode(Int.self, forKey: .totalAttempts)
        discardedAttempts = try container.decode(Int.self, forKey: .discardedAttempts)
        elapsedSeconds = try container.decode(Double.self, forKey: .elapsedSeconds)
        attemptsPerSecond = try container.decode(Double.self, forKey: .attemptsPerSecond)
        overheadFraction = try container.decode(Double.self, forKey: .overheadFraction)
        coveredEdges = try container.decode(Int.self, forKey: .coveredEdges)
        instrumentedEdges = try container.decode(Int.self, forKey: .instrumentedEdges)
        edgeSingletons = try container.decode(Int.self, forKey: .edgeSingletons)
        edgeDoubletons = try container.decode(Int.self, forKey: .edgeDoubletons)
        estimatedNextEdgeProbability = try container.decode(Double.self, forKey: .estimatedNextEdgeProbability)
        estimatedReachableEdges = try container.decode(Double.self, forKey: .estimatedReachableEdges)
        corpusEntries = try container.decode(Int.self, forKey: .corpusEntries)
        termination = try container.decode(String.self, forKey: .termination)
        clusters = try container.decode([ClusterRecord].self, forKey: .clusters)
        handleSkipFraction = try container.decodeIfPresent(Double.self, forKey: .handleSkipFraction)
    }

    struct ClusterRecord: Codable {
        var id: Int
        var symptoms: [String]
        var canonicalDescription: String
        var instances: Int
        var reduced: Int
        var firstSeenAttempt: Int
        var phase: String
    }

    init(report: FuzzReport, seed: UInt64, arm: String, fixture: String, budgetSeconds: Double) {
        self.seed = seed
        self.arm = arm
        self.fixture = fixture
        self.budgetSeconds = budgetSeconds
        screeningAttempts = report.screeningAttempts
        samplingAttempts = report.samplingAttempts
        mutationAttempts = report.mutationAttempts
        totalAttempts = report.totalAttempts
        discardedAttempts = report.discardedAttempts
        elapsedSeconds = report.elapsed.seconds
        attemptsPerSecond = report.attemptsPerSecond
        overheadFraction = report.testingOverheadFraction
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
