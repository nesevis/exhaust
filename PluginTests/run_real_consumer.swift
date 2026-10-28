#!/usr/bin/env swift
// Verify the dormant property and real Exhaust campaigns: passing, failing, parameterized, counter-recorded, state machine, and crash recovery.
// Run: swift -warnings-as-errors -swift-version 6 PluginTests/run_real_consumer.swift
import Foundation
#if os(Windows)
    import ucrt
#elseif canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

// MARK: - Entry Point

do {
    try validate()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

// MARK: - Validation

func validate() throws {
    let consumer = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("RealConsumer")
    let manifest = consumer.appendingPathComponent("Package.swift")
    let original = try Data(contentsOf: manifest)
    var environment = ProcessInfo.processInfo.environment
    environment["EXHAUST_RESUME"] = "0"
    guard let swift = executable("swift", environment: environment) else {
        throw ValidationFailure("Cannot find swift on PATH")
    }
    log("Checking the uninstrumented property with compiler warnings as errors…")
    let dormant = try run(swift, ["test", "--package-path", consumer.nativePath,
                                 "-Xswiftc", "-warnings-as-errors", "--filter", "dormantProperty"],
                          environment: environment).output
    log(dormant)
    try require(dormant.contains("dormantProperty() passed"), "Uninstrumented property test did not run")
    try require(dormant.lowercased().contains("warning"), "Missing runtime warning")
    try require(dormant.contains("#explore(time:) did not run because no instrumented module is loaded"),
                "Missing instrumentation diagnostic")
    try require(Data(contentsOf: manifest) == original, "Ordinary test run modified Package.swift")

    let explorer = Explorer(swift: swift, consumer: consumer, manifest: manifest, original: original, environment: environment)
    try checkPassingCampaign(explorer)
    try checkFailingCampaigns(explorer)
    try checkParameterizedCampaigns(explorer)
    try checkCounterRecorder(explorer)
    try checkStateMachineCampaign(explorer)
    #if os(Windows)
        // Windows instruments only non-test targets, and the resumed trappingProperty never reaches Parser, so the run records no coverage and ends as coverageUnreachable instead of reporting the predecessor's trap.
        log("Skipping crash recovery on Windows: the resumed campaign has no instrumented code to reach.")
    #else
        try checkCrashRecovery(explorer)
    #endif
    log("Uninstrumented warning; passing, failing, parameterized, counter, state machine, and crash-recovery campaigns; and their reports verified; Package.swift unchanged.")
}

func checkPassingCampaign(_ explorer: Explorer) throws {
    let passing = try explorer.explore("instrumentedProperty")
    try require(passing.outcomes == ["passed"], "Unexpected campaign outcomes: \(passing.outcomes)")
    try require(passing.report["status"] as? String == "succeeded", "Unexpected report status")
    try require(passing.output.contains("instrumentedProperty() passed"), "Property did not run")
    // Attachment names carry the test name, run seed, and campaign ID: explore-time-<test>-seed-<seed>-<campaign-id>-summary.txt.
    try require(
        passing.output.contains("explore-time-instrumentedProperty-seed-") && passing.output.contains("-summary.txt"),
        "Missing report attachment"
    )
    let attachments = passing.campaigns.flatMap { $0["attachments"] as? [String] ?? [] }
    try require(attachments.contains { $0.hasSuffix("-summary.txt") }, "The report links no summary attachment: \(attachments)")
    for attachment in attachments {
        try require(passing.fileExists(attachment), "The report links a missing attachment: \(attachment)")
    }
}

/// Runs the failing property twice: each run must stream its finding with the record it belongs to, and the same reduced form must keep the same finding ID across unseeded reruns.
func checkFailingCampaigns(_ explorer: Explorer) throws {
    var findings: [[String: Any]] = []
    for _ in 0 ..< 2 {
        let failing = try explorer.explore("failingProperty", success: false)
        try require(failing.outcomes == ["failed"], "Unexpected campaign outcomes: \(failing.outcomes)")
        try require(failing.report["status"] as? String == "failed", "Unexpected report status")
        try require(failing.output.contains("#explore(time:) found at least 1 distinct failure"), "Missing finding")
        try require(failing.output.contains("failingProperty() failed"), "Finding did not fail the test")
        let streamed = failing.events(ofType: "finding.reported").compactMap { $0["payload"] as? [String: Any] }
        try require(streamed.count == 1, "Expected one finding.reported event, got \(streamed.count)")
        let payload = streamed[0]
        let finding = payload["finding"] as? [String: Any] ?? [:]
        let clusters = failing.campaigns.flatMap { ($0["report"] as? [String: Any])?["clusters"] as? [[String: Any]] ?? [] }
        try require(clusters.count == 1, "Expected one reported cluster, got \(clusters.count)")
        try require(finding["findingID"] as? String == clusters[0]["findingID"] as? String,
                    "The streamed finding and the report disagree on its finding ID")
        let recordPath = payload["recordPath"] as? String ?? ""
        try require(failing.fileExists(recordPath), "The finding event links a missing record: \(recordPath)")
        findings.append(finding)
    }
    let descriptions = findings.map { $0["reducedDescription"] as? String }
    try require(descriptions[0] == descriptions[1], "Reruns reduced to different forms: \(descriptions)")
    let identities = findings.map { $0["findingID"] as? String }
    try require(identities[0] != nil && identities[0] == identities[1], "The same reduced form changed finding ID: \(identities)")
}

func checkParameterizedCampaigns(_ explorer: Explorer) throws {
    let parameterized = try explorer.explore("parameterizedProperty")
    try require(parameterized.report["status"] as? String == "succeeded", "Parameterized campaigns did not succeed")
    let seeds = parameterized.campaigns.compactMap { $0["seed"] as? String }
    try require(seeds.sorted() == ["1", "1", "2", "2"], "Parameterized campaigns were lost or merged: \(seeds)")
    for type in ["campaign.started", "campaign.finished"] {
        let count = parameterized.events(ofType: type).count
        try require(count == 4, "Expected 4 \(type) events, got \(count)")
    }
}

/// Runs the real runtime under the counter recorder, which every other check leaves to the fake provider in test_explore_commands.swift.
func checkCounterRecorder(_ explorer: Explorer) throws {
    let serial = try explorer.explore("instrumentedProperty", ["--no-parallel"])
    try require(serial.report["coverageRecorder"] as? String == "inline-8bit-counters", "--no-parallel did not select counters")
    try require(serial.outcomes == ["passed"], "Unexpected counter campaign outcomes: \(serial.outcomes)")
    try require(serial.output.contains("instrumentedProperty() passed"), "Counter property did not pass")
}

func checkStateMachineCampaign(_ explorer: Explorer) throws {
    let spec = try explorer.explore("stateMachineProperty")
    let kinds = spec.campaigns.map { $0["kind"] as? String }
    try require(kinds == ["stateMachine.sequential"], "Unexpected campaign kinds: \(kinds)")
    try require(spec.outcomes == ["passed"], "Unexpected spec campaign outcomes: \(spec.outcomes)")
}

/// A trap kills the test process mid-campaign: the command must report the campaign as interrupted, and the next run must resume the checkpoint and fail on the predecessor's trap.
func checkCrashRecovery(_ explorer: Explorer) throws {
    var trapEnvironment = explorer.environment
    trapEnvironment["EXHAUST_E2E_TRAP"] = "1"
    let trapped = try explorer.explore("trappingProperty", environment: trapEnvironment, success: false)
    let statuses = trapped.campaigns.map { $0["status"] as? String }
    try require(statuses == ["interrupted"], "A trapped campaign was not reported as interrupted: \(statuses)")
    try require(trapped.outcomes == ["error"], "Unexpected trapped campaign outcomes: \(trapped.outcomes)")
    try require(trapped.report["status"] as? String == "failed", "A trapped run did not fail")
    try require((trapped.report["exitCode"] as? Int) != nil, "A trapped run lost the test process exit code")
    try require(trapped.events(ofType: "campaign.interrupted").count == 1, "Missing campaign.interrupted event")
    try require(trapped.events.last?["type"] as? String == "run.finished", "The stream did not end with run.finished")

    var resumeEnvironment = explorer.environment
    resumeEnvironment.removeValue(forKey: "EXHAUST_RESUME")
    let resumed = try explorer.explore("trappingProperty", environment: resumeEnvironment, success: false)
    try require(resumed.outcomes == ["failed"], "The resumed campaign did not report the predecessor's trap: \(resumed.outcomes)")
    let resumedFlags = resumed.campaigns.map { ($0["report"] as? [String: Any])?["resumedFromCrash"] as? Bool }
    try require(resumedFlags == [true], "The campaign did not resume the trapped checkpoint: \(resumedFlags)")
}

// MARK: - Explore Runs

/// Runs `swift package explore` against the fixture's ParserTests and reads back the report and stream it names.
struct Explorer {
    let swift: URL
    let consumer: URL
    let manifest: URL
    let original: Data
    let environment: [String: String]

    func explore(
        _ filter: String,
        _ options: [String] = [],
        environment: [String: String]? = nil,
        success: Bool = true
    ) throws -> Exploration {
        log("Checking \(([filter] + options).joined(separator: " "))…")
        let output = try run(
            swift,
            ["package", "--package-path", consumer.nativePath, "explore",
             "--instrument", "Parser", "--test-target", "ParserTests",
             "--filter", filter, "--time", "1"] + options,
            environment: environment ?? self.environment,
            success: success
        ).output
        log(output)
        try require(Data(contentsOf: manifest) == original, "Campaign modified Package.swift")
        let reportURL = try ReportFile.path(named: "JSON report: ", in: output)
        return try Exploration(
            output: output,
            root: reportURL.deletingLastPathComponent(),
            report: ReportFile.json(named: "JSON report: ", in: output),
            events: ReportFile.lines(named: "JSONL events: ", in: output)
        )
    }
}

struct Exploration {
    let output: String
    let root: URL
    let report: [String: Any]
    let events: [[String: Any]]

    var campaigns: [[String: Any]] {
        report["campaigns"] as? [[String: Any]] ?? []
    }

    var outcomes: [String?] {
        campaigns.map { $0["outcome"] as? String }
    }

    func events(ofType type: String) -> [[String: Any]] {
        events.filter { $0["type"] as? String == type }
    }

    /// Resolves a report path, which is relative to the output root.
    func fileExists(_ relativePath: String) -> Bool {
        relativePath.isEmpty == false
            && FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).nativePath)
    }
}

// MARK: - Process Execution

@discardableResult
func run(_ tool: URL, _ arguments: [String], environment: [String: String],
         success: Bool = true, mergeErrors: Bool = true) throws -> CommandResult {
    let process = Process()
    process.executableURL = tool
    process.arguments = arguments
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    if mergeErrors { process.standardError = pipe }
    try process.run()
    // Drain before waiting: compiler output can exceed the pipe's capacity.
    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    // Lossy: a trapping test's backtrace dumps raw memory, which need not be valid UTF-8.
    let output = String(decoding: outputData, as: UTF8.self)
    let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
    try require(succeeded == success,
                "Unexpected exit \(process.terminationStatus): \(tool.nativePath) \(arguments.joined(separator: " "))\n\(output)")
    return CommandResult(succeeded: succeeded, output: output)
}

// MARK: - Executable Lookup

func executable(_ name: String, environment: [String: String]) -> URL? {
    #if os(Windows)
        let separator: Character = ";"
        let filename = name.hasSuffix(".exe") ? name : name + ".exe"
    #else
        let separator: Character = ":"
        let filename = name
    #endif
    let path = environment.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
    return path.split(separator: separator).lazy.map {
        URL(fileURLWithPath: String($0)).appendingPathComponent(filename)
    }.first { FileManager.default.isExecutableFile(atPath: $0.nativePath) }
}

// MARK: - Assertions and Logging

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ValidationFailure(message) }
}

func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

// MARK: - Report Files

/// Reads the files the command names in its output as plain JSON, so checks follow what the command and runtime wrote instead of a copy of their models.
enum ReportFile {
    static func json(named label: String, in output: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path(named: label, in: output))) as? [String: Any] else {
            throw ValidationFailure("\(label)is not a JSON object")
        }
        return object
    }

    static func lines(named label: String, in output: String) throws -> [[String: Any]] {
        let text = try String(contentsOf: path(named: label, in: output), encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw ValidationFailure("\(label)line is not a JSON object: \(line)")
            }
            return object
        }
    }

    static func path(named label: String, in output: String) throws -> URL {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(label) }) else {
            throw ValidationFailure("Missing \(label)in output:\n\(output)")
        }
        return URL(fileURLWithPath: String(line.dropFirst(label.count)))
    }
}

// MARK: - Supporting Types

struct ValidationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct CommandResult {
    let succeeded: Bool
    let output: String
}

extension URL {
    var nativePath: String {
        withUnsafeFileSystemRepresentation { String(cString: $0!) }
    }
}
