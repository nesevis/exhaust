#!/usr/bin/env swift
// Verify the dormant property and passing/failing real Exhaust campaigns.
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

    for (name, succeeds) in [("instrumentedProperty", true), ("failingProperty", false)] {
        log("Checking \(name)…")
        let result = try run(swift, ["package", "--package-path", consumer.nativePath, "explore",
                                    "--instrument", "Parser", "--test-target", "ParserTests",
                                    "--filter", name, "--time", "1"], environment: environment, success: succeeds).output
        log(result)
        try require(Data(contentsOf: manifest) == original, "Campaign modified Package.swift")
        let (expectedOutcome, expectedStatus) = switch succeeds {
            case true:
                ("passed", "succeeded")
            case false:
                ("failed", "failed")
        }
        let report = try ReportFile.json(named: "JSON report: ", in: result)
        let outcomes = (report["campaigns"] as? [[String: Any]] ?? []).map { $0["outcome"] as? String }
        try require(outcomes == [expectedOutcome], "Unexpected campaign outcomes: \(outcomes)")
        try require(report["status"] as? String == expectedStatus, "Unexpected report status")
        if succeeds {
            try require(result.contains("instrumentedProperty() passed"), "Property did not run")
            // Attachment names carry the test name, run seed, and campaign ID: explore-time-<test>-seed-<seed>-<campaign-id>-summary.txt.
            try require(
                result.contains("explore-time-instrumentedProperty-seed-") && result.contains("-summary.txt"),
                "Missing report attachment"
            )
        } else {
            try require(result.contains("#explore(time:) found at least 1 distinct failure"), "Missing finding")
            try require(result.contains("failingProperty() failed"), "Finding did not fail the test")
        }
    }

    log("Checking parameterizedProperty…")
    let parameterized = try run(swift, ["package", "--package-path", consumer.nativePath, "explore",
                                       "--instrument", "Parser", "--test-target", "ParserTests",
                                       "--filter", "parameterizedProperty", "--time", "1"], environment: environment).output
    log(parameterized)
    let report = try ReportFile.json(named: "JSON report: ", in: parameterized)
    try require(report["status"] as? String == "succeeded", "Parameterized campaigns did not succeed")
    let seeds = (report["campaigns"] as? [[String: Any]] ?? []).compactMap { $0["seed"] as? String }
    try require(seeds.sorted() == ["1", "1", "2", "2"], "Parameterized campaigns were lost or merged: \(seeds)")
    let events = try ReportFile.lines(named: "JSONL events: ", in: parameterized)
    for type in ["campaign.started", "campaign.finished"] {
        let count = events.count { $0["type"] as? String == type }
        try require(count == 4, "Expected 4 \(type) events, got \(count)")
    }
    try require(Data(contentsOf: manifest) == original, "Campaign modified Package.swift")
    log("Uninstrumented warning, passing/failing and parameterized campaigns, and their reports verified; Package.swift unchanged.")
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
    guard let output = String(bytes: outputData, encoding: .utf8) else {
        throw ValidationFailure("Command returned invalid UTF-8 output: \(tool.nativePath)")
    }
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

    private static func path(named label: String, in output: String) throws -> URL {
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
