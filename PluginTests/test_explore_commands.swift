#!/usr/bin/env swift
// Consumer-level command checks using a dependency-free minimal provider.
// Run: swift -warnings-as-errors -swift-version 6 PluginTests/test_explore_commands.swift
import Foundation
#if os(Windows)
    import WinSDK
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
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("exhaust-command-tests-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let suite = try ExploreCommandsTests(base: base, repository: repository)
    log("Preparing isolated consumer fixtures…")
    try suite.setUp()
    let checks: [(String, () throws -> Void)] = [
        ("command help", suite.commandHelp),
        ("consumer workflow", suite.consumerWorkflow),
        ("serial counter workflow", suite.serialCounterWorkflow),
        ("nonstandard manifest", suite.nonstandardManifest),
        ("versioned manifests", suite.rejectedManifests),
        ("invalid arguments", suite.invalidArguments),
    ]
    var failures = 0
    for (name, check) in checks {
        log("Running \(name)…")
        do {
            try check()
            log("PASS: \(name)")
        } catch {
            failures += 1
            log("FAIL: \(name)\n\(error)")
        }
    }
    try require(failures == 0, "\(failures) of \(checks.count) consumer checks failed")
    log("All \(checks.count) consumer checks passed.")
}

// MARK: - Consumer Checks

struct ExploreCommandsTests {
    // MARK: - Configuration

    let base: URL
    let repository: URL
    let environment: [String: String]
    let swift: URL
    let helper: URL
    let nm: URL
    var provider: URL { base.appendingPathComponent("Provider") }
    var consumer: URL { base.appendingPathComponent("Consumer with spaces") }
    var dependency: URL { base.appendingPathComponent("Dependency") }
    var manager: FileManager { .default }

    init(base: URL, repository: URL) throws {
        self.base = base
        self.repository = repository
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "EXHAUST_EXPLORE_TIME_NS")
        environment["CLANG_MODULE_CACHE_PATH"] = base.appendingPathComponent("module-cache").nativePath
        self.environment = environment
        #if os(macOS)
            let path = try run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["-f", "swift"], environment: environment)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            swift = URL(fileURLWithPath: path)
        #else
            guard let tool = executable("swift", environment: environment) else {
                throw ValidationFailure("Cannot find swift on PATH")
            }
            swift = tool
        #endif
        #if os(Windows)
            helper = base.appendingPathComponent("explore-command.exe")
        #else
            helper = base.appendingPathComponent("explore-command")
        #endif
        var symbolTool = executable("llvm-nm", environment: environment) ?? executable("nm", environment: environment)
        #if os(Windows)
            if symbolTool == nil {
                let candidates = [swift.deletingLastPathComponent().appendingPathComponent("llvm-nm.exe"),
                                  URL(fileURLWithPath: environment["ProgramFiles"] ?? "C:/Program Files")
                                    .appendingPathComponent("LLVM/bin/llvm-nm.exe")]
                symbolTool = candidates.first { FileManager.default.fileExists(atPath: $0.nativePath) }
            }
        #endif
        guard let symbolTool else { throw ValidationFailure("Install llvm-nm (or nm) to inspect instrumented objects") }
        nm = symbolTool
    }

    // MARK: - Checks

    func commandHelp() throws {
        let help = try plugin(["--help"])
        try require(help.contains("USAGE: swift package explore"), help)
        for option in ["--instrument", "--test-target", "--filter", "--time", "--configuration", "--no-parallel", "--output", "--xunit", "--help"] {
            try require(help.contains(option), "Missing \(option) in help:\n\(help)")
        }
        for option in ["--runtime-package", "--workspace-path", "--output-path"] {
            try require(help.contains(option) == false, "Plugin context leaked into public help:\n\(help)")
        }
        let normalized = help.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        try require(normalized.contains("default: release"), help)
    }

    func serialCounterWorkflow() throws {
        let result = try plugin(["--instrument", "MyLibrary", "--test-target", "ParserTests", "--filter", "selected", "--time", "2", "--no-parallel"])
        try require(result.contains("Coverage: inline-8bit-counters; tests run serially."), result)
        try require(result.contains("Test selected() started"), result)
        guard let buildLine = result.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Build: ") }) else {
            throw ValidationFailure("Missing build path:\n\(result)")
        }
        let scratch = URL(fileURLWithPath: String(buildLine.dropFirst("Build: ".count)))
        let objects = try files(in: scratch).filter {
            ["MyLibrary.o", "MyLibrary.swift.o", "MyLibrary.obj", "MyLibrary.swift.obj"].contains($0.lastPathComponent)
                && $0.deletingLastPathComponent().lastPathComponent != "Modules"
        }
        try require(objects.isEmpty == false, "Missing instrumented library object")
        for object in objects {
            let symbols = try symbols(object)
            try require(symbols.contains("sanitizer_cov_8bit_counters_init"), symbols)
            try require(symbols.contains("sanitizer_cov_trace_pc_guard") == false, symbols)
            try require(symbols.contains("sanitizer_cov_trace_const_cmp"), symbols)
        }
    }

    func consumerWorkflow() throws {
        let manifest = consumer.appendingPathComponent("Package.swift")
        let original = try Data(contentsOf: manifest)
        let dependencyManifest = dependency.appendingPathComponent("Package.swift")
        let dependencyOriginal = try Data(contentsOf: dependencyManifest)
        // Windows gives each test target a generated runner that cannot link the coverage runtime, so the command instruments the test target only on other platforms.
        #if os(Windows)
            let instrumentsTestTarget = false
            let arguments = ["--instrument", "MyLibrary", "--test-target", "ParserTests"]
        #else
            let instrumentsTestTarget = true
            let arguments = ["--instrument", "MyLibrary", "--instrument", "ParserTests", "--test-target", "ParserTests"]
        #endif
        let result = try plugin(arguments + ["--filter", "selected", "--time", "2"])
        try require(result.contains("Running 1 test(s)"), result)
        try require(result.contains("Test selected() started"), result)
        try require(!result.contains("UNRELATED_TEST_MUST_NOT_RUN"), result)
        guard let buildLine = result.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Build: ") }) else {
            throw ValidationFailure("Missing build path:\n\(result)")
        }
        let scratch = URL(fileURLWithPath: String(buildLine.dropFirst("Build: ".count))).resolvingSymlinksInPath()
        let defaultReport = try JSONDecoder().decode(CampaignAggregate.self, from: Data(contentsOf: scratch.appendingPathComponent("report.json")))
        try require(defaultReport.xunitFiles == [], "xUnit should be opt-in")
        try require(!manager.fileExists(atPath: scratch.appendingPathComponent("xunit-swift-testing.xml").path), "Unexpected default XML")
        let defaultEvents = try String(contentsOf: scratch.appendingPathComponent("events.jsonl"), encoding: .utf8)
        try require(defaultEvents.contains("run.started") && defaultEvents.contains("run.finished"), "Missing default JSONL stream")
        let pluginRoot = consumer.appendingPathComponent(".build/plugins").resolvingSymlinksInPath()
        try require(scratch.path.hasPrefix(pluginRoot.path + "/"), "Build escaped plugin workspace: \(scratch.path)")
        try require(Data(contentsOf: manifest) == original, "Campaign modified Package.swift")
        let outputPath = scratch.deletingLastPathComponent().nativePath
        // Debug builds also emit a module-wrap object under `Modules/` that embeds the Swift module for the debugger. It contains no code, so it carries no instrumentation either way.
        let objects = try files(in: scratch).filter {
            ["o", "obj"].contains($0.pathExtension) && $0.deletingLastPathComponent().lastPathComponent != "Modules"
        }
        for (module, instrumented) in [("MyLibrary", true), ("ParserTests", instrumentsTestTarget), ("OtherLibrary", false), ("Callbacks", false)] {
            let names = [".o", ".swift.o", ".c.o", ".obj", ".swift.obj", ".c.obj"].map { module + $0 }
            let matching = objects.filter { names.contains($0.lastPathComponent) }
            try require(!matching.isEmpty, "No object found for \(module)")
            for file in matching {
                try require(symbols(file).contains("sanitizer_cov_trace_pc_guard") == instrumented,
                            "Unexpected instrumentation in \(file.nativePath)")
            }
        }
        try require(!manager.contentsOfDirectory(atPath: scratch.appendingPathComponent("attachments").nativePath).isEmpty,
                    "Missing attachments directory")
        try withBuildLock(scratch.appendingPathComponent("explore.lock")) {
            let locked = try helperRun(arguments, outputPath: outputPath, success: false)
            try require(locked.contains("Another explore command"), locked)
        }
        let nested = try helperRun(arguments + ["--filter", "Nested", "--output", "custom state", "--xunit"], outputPath: outputPath)
        try require(nested.contains("parameterized") && !nested.contains("No matching test cases"), nested)
        let customOutput = consumer.appendingPathComponent("custom state")
        for (label, expected) in [
            ("Attachments: ", customOutput.appendingPathComponent("attachments")),
            ("Crash recovery state: ", customOutput.appendingPathComponent("state").appendingPathComponent(scratch.lastPathComponent)),
        ] {
            guard let line = nested.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(label) }) else {
                throw ValidationFailure("Missing \(label) in output:\n\(nested)")
            }
            let path = URL(fileURLWithPath: String(line.dropFirst(label.count))).resolvingSymlinksInPath()
            let actual = label == "Attachments: " ? path.deletingLastPathComponent() : path
            try require(actual.path == expected.resolvingSymlinksInPath().path, "Unexpected output location: \(actual.path)")
        }
        try require(!manager.contentsOfDirectory(atPath: customOutput.appendingPathComponent("attachments").nativePath).isEmpty,
                    "Missing custom attachments directory")
        let aggregate = try JSONDecoder().decode(CampaignAggregate.self, from: Data(contentsOf: customOutput.appendingPathComponent("report.json")))
        let campaigns = aggregate.campaigns
        try require(aggregate.status == .succeeded, "Missing successful aggregate")
        try require(campaigns.count == 4, "Parameterized calls were lost or merged")
        try require(campaigns.map(\.seed).sorted() == ["1", "1", "2", "2"], "Lost seeds")
        let eventLines = try String(contentsOf: customOutput.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n")
        let events = try eventLines.map { try JSONDecoder().decode(StreamEvent.self, from: Data($0.utf8)) }
        try require(events.filter { $0.type == .campaignStarted }.count == 4, "Lost parallel campaign events")
        let xunitFiles = aggregate.xunitFiles
        try require(!xunitFiles.isEmpty, "Missing native xUnit output")
        let xml = try xunitFiles.map { try String(contentsOf: customOutput.appendingPathComponent($0), encoding: .utf8) }.joined()
        try require(xml.components(separatedBy: "name=\"parameterized(value:)\"").count == 2,
                    "Expected one native XML test entry for all parameterized cases:\n\(xml)")
        try withBuildLock(customOutput.appendingPathComponent("report.lock")) {
            let locked = try helperRun(arguments + ["--filter", "Nested", "--output", "custom state"], outputPath: outputPath, success: false)
            try require(locked.contains("Another explore command"), locked)
        }
        let legacy = try helperRun(arguments + ["--filter", "testLegacy"], outputPath: outputPath)
        try require(legacy.contains("testLegacy") && !legacy.contains("No matching test cases"), legacy)
        let failed = try plugin(arguments + ["--filter", "deliberateFailure", "--xunit"], success: false)
        try require(failed.contains("EXPECTED_FAILURE_FORWARDING"), failed)
        let failureReport = try JSONDecoder().decode(CampaignAggregate.self, from: Data(contentsOf: scratch.appendingPathComponent("report.json")))
        try require(failureReport.status == .failed, "Failed process lost its JSON report")
        try require(failureReport.xunitFiles.isEmpty == false, "Failed tests lost native xUnit results")
        try require(Data(contentsOf: manifest) == original, "Failed campaign modified Package.swift")
        try require(Data(contentsOf: dependencyManifest) == dependencyOriginal, "Campaign modified dependency manifest")
        let missing = try helperRun(arguments + ["--filter", "doesNotExist"], outputPath: outputPath, success: false)
        try require(missing.contains("No tests matched"), missing)
        let plain = try run(swift, ["package", "--package-path", consumer.nativePath, "--disable-sandbox",
                                   "--manifest-cache", "local", "--scratch-path",
                                   scratch.deletingLastPathComponent().appendingPathComponent("metadata").nativePath,
                                   "dump-package"], environment: environment, mergeErrors: false).output
        guard let description = try JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any],
              let targets = description["targets"] else { throw ValidationFailure("Missing manifest targets") }
        let settings = try JSONSerialization.data(withJSONObject: targets)
        guard let settingsJSON = String(bytes: settings, encoding: .utf8) else {
            throw ValidationFailure("Cannot encode manifest settings as UTF-8 JSON")
        }
        try require(!settingsJSON.contains("sanitize-coverage"), "Ordinary manifest is instrumented")
        let ordinary = base.appendingPathComponent("ordinary")
        try run(swift, ["build", "--package-path", consumer.nativePath, "--disable-sandbox",
                        "--scratch-path", ordinary.nativePath, "--target", "MyLibrary", "-c", "release"], environment: environment)
        let ordinaryObjects = try files(in: ordinary).filter {
            ["MyLibrary.o", "MyLibrary.swift.o", "MyLibrary.obj", "MyLibrary.swift.obj"].contains($0.lastPathComponent)
        }
        try require(!ordinaryObjects.isEmpty, "Missing ordinary build objects")
        for file in ordinaryObjects {
            try require(!symbols(file).contains("sanitizer_cov"), "Ordinary build is instrumented: \(file.nativePath)")
        }
        let invalidTarget = try helperRun(["--instrument", "OtherLibrary", "--test-target", "ParserTests"], success: false)
        try require(invalidTarget.contains("not a root Swift"), invalidTarget)
        let ambiguous = try helperRun(["--instrument", "MyLibrary"], success: false)
        try require(ambiguous.contains("--test-target"), ambiguous)
        #if os(Windows)
            let instrumentedTest = try helperRun(["--instrument", "MyLibrary", "--instrument", "ParserTests", "--test-target", "ParserTests"], success: false)
            try require(instrumentedTest.contains("cannot be instrumented on Windows"), instrumentedTest)
            let releaseCampaign = try helperRun(["--instrument", "MyLibrary", "--test-target", "ParserTests", "--configuration", "release"], success: false)
            try require(releaseCampaign.contains("Release campaigns are not supported on Windows"), releaseCampaign)
        #endif
    }

    func nonstandardManifest() throws {
        let root = base.appendingPathComponent("nonstandard")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for item in try manager.contentsOfDirectory(at: consumer, includingPropertiesForKeys: nil) where item.lastPathComponent != ".build" {
            try manager.copyItem(at: item, to: root.appendingPathComponent(item.lastPathComponent))
        }
        let manifest = root.appendingPathComponent("Package.swift")
        let changed = try String(contentsOf: manifest, encoding: .utf8)
            .replacingOccurrences(of: "let package =", with: "let customName =")
            .replacingOccurrences(of: String(reflecting: consumer.path), with: String(reflecting: root.path))
        try write(root, "Package.swift", changed)
        let original = try Data(contentsOf: manifest)
        let result = try helperRun(["--instrument", "MyLibrary", "--test-target", "ParserTests"], root: root, success: false)
        try require(result.contains("cannot find 'package' in scope"), result)
        try require(Data(contentsOf: manifest) == original, "Nonstandard manifest was modified")
    }

    func rejectedManifests() throws {
        let root = base.appendingPathComponent("modified")
        let source = """
        // swift-tools-version: 6.4
        import PackageDescription
        let package = Package(name: "Modified")

        """
        try write(root, "Package.swift", source)
        try write(root, "Package@swift-6.4.swift", source)
        let versioned = try helperRun(["--instrument", "MyLibrary"], root: root, success: false)
        try require(versioned.contains("Version-specific"), versioned)
    }

    func invalidArguments() throws {
        for value in ["0", "-1", "1.5", "nan", "18446744074"] {
            let result = try helperRun(["--instrument", "MyLibrary", "--time", value], success: false)
            try require(result.contains("positive whole"), result)
        }
        _ = try helperRun(["--instrument", "MyLibrary", "--filter", "["], success: false)
        _ = try helperRun(["--instrument", "MyLibrary", "--unknown", "value"], success: false)
        let overridden = try helperRun(["--instrument", "MyLibrary", "--package-path", "/elsewhere"], success: false)
        try require(overridden.contains("Unknown option: --package-path"), overridden)
        _ = try helperRun(["--instrument", "MyLibrary", "--configuration", "profile"], success: false)
        _ = try helperRun(["--instrument"], success: false)
        _ = try helperRun(["--instrument", ""], success: false)
        let required = try helperRun([], success: false)
        try require(required.contains("Select at least one root Swift target"), required)
        // The final scalar option wins; repeated instrumentation options accumulate.
        let finalFilter = try helperRun(["--instrument=MyLibrary", "--test-target=ParserTests",
                                         "--filter=[", "--filter=doesNotExist"], success: false)
        try require(finalFilter.contains("No tests matched"), finalFilter)
    }

    // MARK: - Fixture Setup

    func setUp() throws {
        try manager.createDirectory(at: provider.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try manager.copyItem(at: repository.appendingPathComponent("Plugins"), to: provider.appendingPathComponent("Plugins"))
        try manager.copyItem(at: repository.appendingPathComponent("Sources/ExhaustExploreCommand"),
                             to: provider.appendingPathComponent("Sources/ExhaustExploreCommand"))
        try manager.copyItem(at: repository.appendingPathComponent("Sources/ExhaustSupport"),
                             to: provider.appendingPathComponent("Sources/ExhaustSupport"))
        try write(provider, "Package.swift", #"""
        // swift-tools-version: 6.4
        import PackageDescription
        let package = Package(name: "Provider", products: [
            .library(name: "ExhaustFuzzRuntime", targets: ["Callbacks"]),
            .library(name: "ExhaustFuzzTestSupport", targets: ["Callbacks"]),
            .plugin(name: "Explore", targets: ["Explore"]),
        ], targets: [
            .target(name: "Callbacks"),
            .target(name: "ExhaustSupport"),
            .executableTarget(
                name: "ExhaustExploreCommand",
                dependencies: ["ExhaustSupport"],
                swiftSettings: [.treatAllWarnings(as: .error)]
            ),
            .plugin(name: "Explore", capability: .command(intent: .custom(verb: "explore", description: "Explore"), permissions: []), dependencies: ["ExhaustExploreCommand"]),
        ])
        """# + "\n")
        try write(dependency, "Package.swift", #"""
        // swift-tools-version: 6.4
        import PackageDescription
        let package = Package(name: "Dependency", products: [.library(name: "OtherLibrary", targets: ["OtherLibrary"])], targets: [.target(name: "OtherLibrary")])
        """# + "\n")
        try write(dependency, "Sources/OtherLibrary/OtherLibrary.swift", #"""
        @inline(never) public func dependency(_ x: Int) -> Int { x == 13 ? 1 : 2 }
        """# + "\n")
        try write(consumer, "Package.swift", #"""
        // swift-tools-version: 6.4
        import PackageDescription
        let package = Package(name: "Consumer", dependencies: [.package(name: "Tooling", path: "../Provider"), .package(path: "../Dependency")], targets: [
            .target(name: "MyLibrary", dependencies: [.product(name: "OtherLibrary", package: "Dependency")]),
            .testTarget(name: "ParserTests", dependencies: ["MyLibrary"]),
            .testTarget(name: "UnrelatedTests", dependencies: ["MyLibrary"]),
        ])
        """# + "\n")
        try write(consumer, "Sources/MyLibrary/MyLibrary.swift", #"""
        import OtherLibrary
        @inline(never) public func parse(_ x: Int) -> Bool { x == 12345 && dependency(x) == 2 }
        """# + "\n")
        try write(provider, "Sources/Callbacks/include/Callbacks.h", #"""
        void callbacks_link(void);
        """# + "\n")
        try write(provider, "Sources/Callbacks/Callbacks.c", #"""
        #include <stdint.h>
        #include <stddef.h>
        void callbacks_link(void) {}
        void __sanitizer_cov_8bit_counters_init(uint8_t *a, uint8_t *b) {}
        void __sanitizer_cov_trace_pc_guard(uint32_t *g) {}
        void __sanitizer_cov_trace_pc_guard_init(uint32_t *a, uint32_t *b) { while (a < b) *a++ = 1; }
        void __sanitizer_cov_pcs_init(const uintptr_t *a, const uintptr_t *b) {}
        #define CMP(N, T) void __sanitizer_cov_trace_cmp##N(T a, T b) {} \
        void __sanitizer_cov_trace_const_cmp##N(T a, T b) {}
        CMP(1, uint8_t) CMP(2, uint16_t) CMP(4, uint32_t) CMP(8, uint64_t)
        void __sanitizer_cov_trace_switch(uint64_t a, uint64_t *b) {}
        #if defined(_WIN32)
        #pragma section(".SCOV$CA", read, write)
        __declspec(allocate(".SCOV$CA")) uint64_t __start___sancov_cntrs = 0;
        #pragma section(".SCOV$CZ", read, write)
        __declspec(allocate(".SCOV$CZ")) __declspec(align(1)) uint8_t __stop___sancov_cntrs = 0;
        #pragma section(".SCOV$GA", read, write)
        __declspec(allocate(".SCOV$GA")) uint64_t __start___sancov_guards = 0;
        #pragma section(".SCOV$GZ", read, write)
        __declspec(allocate(".SCOV$GZ")) __declspec(align(1)) uint8_t __stop___sancov_guards = 0;
        #pragma section(".SCOVP$A", read)
        __declspec(allocate(".SCOVP$A")) const uint64_t __start___sancov_pcs = 0;
        #pragma section(".SCOVP$Z", read)
        __declspec(allocate(".SCOVP$Z")) __declspec(align(1)) const uint8_t __stop___sancov_pcs = 0;
        #endif
        """# + "\n")
        try write(consumer, "Tests/ParserTests/ParserTests.swift", #"""
        import Testing
        import XCTest
        import Foundation
        import MyLibrary
        struct FixtureSource: Encodable {
            let fileID = "ParserTests/ParserTests.swift"
            let line = 1
            let column = 1
        }
        struct FixtureCampaignRecord: Encodable {
            let source = FixtureSource()
            let kind = "value"
            let declaredBudgetSeconds = 2
            let startedAt = Date().timeIntervalSince1970
            let attachments: [String] = []
            let checkpointPath = "state/fixture"
            let schemaVersion = 1
            let id: String
            let status: String
            let seed: String
        }
        // The smallest report the command's decoder accepts: a campaign that used its budget without evaluating anything.
        let fixtureReport = "{\"attempts\":{\"discardedByMaterializer\":0,\"discardedByProperty\":0,\"duplicatesSkipped\":0,\"evaluated\":0,\"mutation\":0,\"mutationArmAttempts\":{},\"mutationArmDiscarded\":{},\"mutationArmFailed\":{},\"mutationArmPassed\":{},\"rejected\":0,\"sampling\":0,\"screening\":0,\"total\":0},\"clusters\":[],\"coverage\":{\"corpusEntryCount\":0,\"coveredEdges\":0,\"estimatedNextEdgeProbability\":0,\"estimatedReachableEdges\":0,\"incidenceSamples\":0,\"incidenceTotal\":0,\"instrumentedEdges\":0,\"offLaneHits\":0,\"parentCount\":0,\"parentRootPhases\":{}},\"invocations\":{\"classification\":0,\"normalization\":0,\"prune\":0,\"recovery\":0,\"reduction\":0,\"search\":0,\"total\":0},\"resumedFromCrash\":false,\"termination\":{\"reason\":\"budgetExhausted\"},\"timing\":{\"attemptsPerSecond\":0,\"elapsedSeconds\":0,\"lastDiscoverySeconds\":0,\"mutationOverheadSeconds\":0,\"otherSeconds\":0,\"propertySeconds\":0,\"reductionSeconds\":0,\"samplingOverheadSeconds\":0,\"screeningOverheadSeconds\":0,\"testingOverheadFraction\":0},\"unreducedFailureCounts\":{}}"
        struct FixtureEvent: Encodable {
            let schemaVersion = 1
            let eventID: String
            let campaignID: String
            let campaignSequence = 0
            let type = "campaign.started"
            let timestamp = Date().timeIntervalSince1970
            let payload: FixtureCampaignRecord
        }
        @Test func selected() {
            #expect(parse(12345))
            #expect(ProcessInfo.processInfo.environment["EXHAUST_EXPLORE_TIME_NS"] == "2000000000")
        }
        @Test func deliberateFailure() { Issue.record("EXPECTED_FAILURE_FORWARDING") }
        @Suite struct Nested {
            @Test(arguments: [1, 2]) func parameterized(value: Int) throws {
                #expect(value > 0)
                // Minimal provider fixture for the runtime/command file protocol. The full runtime has separate tests.
                let directory = try #require(ProcessInfo.processInfo.environment["EXHAUST_REPORT_DIR"])
                for _ in 0 ..< 2 {
                    let id = UUID().uuidString
                    let spool = URL(fileURLWithPath: directory).appendingPathComponent("events")
                    let eventID = id + "-00000000"
                    let started = FixtureCampaignRecord(id: id, status: "running", seed: String(value))
                    let event = FixtureEvent(eventID: eventID, campaignID: id, payload: started)
                    try JSONEncoder().encode(event).write(to: spool.appendingPathComponent(eventID + ".json"), options: .atomic)
                    // This can only pass if the command collects while its test process is still alive.
                    let stream = URL(fileURLWithPath: directory).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("events.jsonl")
                    let deadline = Date().addingTimeInterval(5)
                    while !(try String(contentsOf: stream, encoding: .utf8)).contains(eventID) && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    #expect(try String(contentsOf: stream, encoding: .utf8).contains(eventID))
                    let record = FixtureCampaignRecord(id: id, status: "completed", seed: String(value))
                    var completed = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
                    completed["finishedAt"] = Date().timeIntervalSince1970
                    completed["issuesSuppressed"] = false
                    completed["outcome"] = "passed"
                    completed["report"] = try JSONSerialization.jsonObject(with: Data(fixtureReport.utf8))
                    try JSONSerialization.data(withJSONObject: completed).write(to: URL(fileURLWithPath: directory).appendingPathComponent(id + ".json"), options: .atomic)
                }
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let expected = root.appendingPathComponent("custom state")
                let actual = ProcessInfo.processInfo.environment["EXHAUST_STATE_DIR"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
                #expect(actual?.deletingLastPathComponent().lastPathComponent == "state")
                #expect(actual?.deletingLastPathComponent().deletingLastPathComponent().path == expected.resolvingSymlinksInPath().path)
            }
        }
        final class Legacy: XCTestCase {
            func testLegacy() { XCTAssertTrue(parse(12345)) }
        }
        """# + "\n")
        try write(consumer, "Tests/UnrelatedTests/UnrelatedTests.swift", #"""
        import Testing
        @Test func mustNotRun() { Issue.record("UNRELATED_TEST_MUST_NOT_RUN") }
        """# + "\n")
        let manifest = consumer.appendingPathComponent("Package.swift")
        let original = try String(contentsOf: manifest, encoding: .utf8)
        try write(consumer, "Package.swift", original + """

        import Foundation
        precondition(URL(fileURLWithPath: #filePath).deletingLastPathComponent().resolvingSymlinksInPath().path == URL(fileURLWithPath: \(String(reflecting: consumer.path))).resolvingSymlinksInPath().path)

        """)
        try run(swift, ["build", "--package-path", provider.nativePath, "--product", "ExhaustExploreCommand"],
                environment: environment)
        let binPath = try run(swift, ["build", "--package-path", provider.nativePath, "--show-bin-path"],
                              environment: environment, mergeErrors: false).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(Windows)
            let executableName = "ExhaustExploreCommand.exe"
        #else
            let executableName = "ExhaustExploreCommand"
        #endif
        try manager.copyItem(at: URL(fileURLWithPath: binPath).appendingPathComponent(executableName), to: helper)
    }

    // MARK: - Helpers

    func write(_ root: URL, _ relative: String, _ content: String) throws {
        let path = root.appendingPathComponent(relative)
        try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: path, atomically: true, encoding: .utf8)
    }

    func helperRun(_ arguments: [String], outputPath: String? = nil, root: URL? = nil, success: Bool = true) throws -> String {
        let output = outputPath.map { ["--output-path", $0] } ?? []
        return try run(helper, ["--package-path", (root ?? consumer).nativePath,
                                "--swift", swift.nativePath, "--runtime-package", "provider"] + output + ["explore"] + arguments,
                       environment: environment, success: success).output
    }

    func plugin(_ arguments: [String], success: Bool = true) throws -> String {
        try run(swift, ["package", "--package-path", consumer.nativePath, "explore"] + arguments,
                environment: environment, success: success).output
    }

    func files(in root: URL) throws -> [URL] {
        var enumerationError: (any Error)?
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw ValidationFailure("Cannot enumerate \(root.nativePath)") }
        let files = enumerator.allObjects.compactMap { $0 as? URL }
        if let enumerationError { throw enumerationError }
        return files
    }

    func symbols(_ file: URL) throws -> String {
        try run(nm, ["-u", file.nativePath], environment: environment).output
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

// MARK: - Build Lock

func withBuildLock(_ path: URL, body: () throws -> Void) throws {
    #if os(Windows)
        let handle = path.nativePath.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil,
                        DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw ValidationFailure("Cannot open test lock: Windows error \(GetLastError())")
        }
        defer { CloseHandle(handle) }
    #else
        let descriptor = open(path.nativePath, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { throw ValidationFailure("Cannot open test lock: errno \(errno)") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ValidationFailure("Cannot acquire test lock: errno \(errno)")
        }
        defer { flock(descriptor, LOCK_UN) }
    #endif
    try body()
}

// MARK: - Assertions and Logging

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ValidationFailure(message) }
}

func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
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

/// Decodes the consumer-facing reporting contract independently of the command's internal models.
private struct CampaignAggregate: Decodable {
    enum Status: String, Decodable {
        case running
        case succeeded
        case failed
    }
    struct Campaign: Decodable {
        let id: String
        let seed: String
    }
    let status: Status
    let campaigns: [Campaign]
    let xunitFiles: [String]
}

/// Checks the event vocabulary while allowing payloads to evolve independently.
private struct StreamEvent: Decodable {
    enum Kind: String, Decodable {
        case runStarted = "run.started"
        case phaseChanged = "run.phaseChanged"
        case campaignStarted = "campaign.started"
        case findingReported = "finding.reported"
        case campaignFinished = "campaign.finished"
        case campaignInterrupted = "campaign.interrupted"
        case runFinished = "run.finished"
    }
    let type: Kind
}
