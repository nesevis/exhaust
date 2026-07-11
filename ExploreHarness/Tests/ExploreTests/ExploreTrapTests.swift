import Exhaust
import ExhaustCore
import ExploreFixture
import Foundation
import Testing

#if canImport(ObjectiveC)
    import ObjectiveC
#endif

/// Crash recovery and in-process exception handling, exercised end to end against the fixture.
@Suite("Explore crash recovery", .serialized)
struct ExploreTrapTests {
    #if os(macOS)
        @Test("A Swift trap in a fuzz run leaves a breadcrumb, a progress log, and the trapping input on disk", .timeLimit(.minutes(2)))
        func trapLeavesRecoverableState() throws {
            let stateDirectory = scratchDirectory()
            defer {
                try? FileManager.default.removeItem(at: stateDirectory)
            }
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let sidecarURL = stateDirectory.appendingPathComponent("trapping-input.json")

            let probe = try #require(trapProbeURL(), "ExploreTrapProbe executable not found next to the test bundle")
            let process = Process()
            process.executableURL = probe
            process.arguments = [sidecarURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment["EXHAUST_STATE_DIR"] = stateDirectory.path
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()

            // The probe dies by an uncaught trap signal, never a clean exit.
            #expect(process.terminationReason == .uncaughtSignal, "the probe should die by trap, not exit cleanly")

            // The trapping input was captured, and it satisfies fault E's gate.
            let trappingData = try #require(try? Data(contentsOf: sidecarURL), "no trapping input recorded")
            let trapping = try JSONDecoder().decode(Message.self, from: trappingData)
            #expect(trapping.mode == .control)
            #expect(trapping.flags & 0b0001_0000 != 0)
            #expect(trapping.region == 7)
            #expect(trapping.payload.isEmpty == false)

            // The progress log survived the crash and is well-formed.
            let progressURL = try #require(findFile(named: "progress.json", under: stateDirectory), "no progress log survived")
            let progressData = try Data(contentsOf: progressURL)
            let progressJSON = try JSONSerialization.jsonObject(with: progressData) as? [String: Any]
            #expect(progressJSON?["metadata"] != nil)
            #expect(progressJSON?["clusters"] != nil)
            #expect(progressJSON?["snapshot"] != nil)

            // The breadcrumb survived and names the in-flight candidate (a nonzero hash in its first slot).
            let breadcrumbURL = try #require(findFile(named: "breadcrumb.bin", under: stateDirectory), "no breadcrumb survived")
            let breadcrumb = try Data(contentsOf: breadcrumbURL)
            #expect(breadcrumb.count == 16)
            let candidateHash = breadcrumb.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            #expect(candidateHash != 0, "the breadcrumb should identify the candidate under evaluation at the trap")
        }
    #endif

    #if canImport(ObjectiveC)
        @Test("An NSException raised by the property is caught in-process, clustered, and the run continues", .timeLimit(.minutes(2)))
        func nsExceptionIsCaughtAndClustered() {
            let report = #explore(
                Fixture.messageGenerator,
                time: .seconds(4),
                .replay(7),
                .suppress(.issueReporting)
            ) { message in
                // Raise an NSException on a narrow gate, and otherwise defer to the clean handshake path so the run keeps producing attempts after each catch.
                if message.mode == .data, message.region == 1 {
                    NSException(name: .rangeException, reason: "planted range exception", userInfo: nil).raise()
                }
                return true
            }

            // The run completed rather than dying: the exception was caught in process.
            #expect(report.totalAttempts > 0)
            #expect(report.termination != .instrumentationMissing)

            // The caught exception was clustered under an NSException symptom.
            let exceptionClusters = report.clusters.filter { cluster in
                cluster.symptoms.contains { $0.contains("NSException") }
            }
            #expect(exceptionClusters.isEmpty == false, "the caught NSException should form a cluster")
        }
    #endif

    @Test("A fuzz run records throughput and framework overhead", .timeLimit(.minutes(2)))
    func throughputRecorded() {
        let report = #explore(
            Fixture.messageGenerator,
            time: .milliseconds(500),
            .replay(1),
            .suppress(.issueReporting)
        ) { message in
            try Parser.decode(message).byteCount >= 0
        }
        print()
        #expect(report.totalAttempts > 0)
        #expect(report.attemptsPerSecond > 0)
        #expect(report.frameworkOverheadFraction >= 0 && report.frameworkOverheadFraction <= 1)
        // Recorded for the CI log so a pipeline-cost regression is visible as a falling number.
        print("throughput: \(Int(report.attemptsPerSecond)) attempts/s, overhead \(Int(report.frameworkOverheadFraction * 100))%")
    }
}

// MARK: - Helpers

private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("exhaust-trap-tests")
        .appendingPathComponent(UUID().uuidString)
}

/// Locates the `ExploreTrapProbe` executable under the package's build products directory.
///
/// Discovery starts from the package root (walking up from this test's source path to the manifest) rather than the test runner's path, which under `swift test` is a system helper nowhere near the products.
private func trapProbeURL(testFilePath: String = #filePath) -> URL? {
    let fileManager = FileManager.default
    var root = URL(fileURLWithPath: testFilePath).deletingLastPathComponent()
    for _ in 0 ..< 8 {
        if fileManager.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            break
        }
        root = root.deletingLastPathComponent()
    }
    let buildRoot = root.appendingPathComponent(".build")

    // The conventional debug/release symlinks first, then a bounded search for other build layouts.
    for configuration in ["debug", "release"] {
        let candidate = buildRoot.appendingPathComponent(configuration).appendingPathComponent("ExploreTrapProbe")
        if fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    guard let enumerator = fileManager.enumerator(at: buildRoot, includingPropertiesForKeys: [.isDirectoryKey]) else {
        return nil
    }
    for case let url as URL in enumerator where url.lastPathComponent == "ExploreTrapProbe" {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory == false, fileManager.isExecutableFile(atPath: url.path) {
            return url
        }
    }
    return nil
}

private func findFile(named name: String, under directory: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        return nil
    }
    for case let url as URL in enumerator where url.lastPathComponent == name {
        return url
    }
    return nil
}
