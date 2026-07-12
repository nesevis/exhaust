import Foundation
import Testing

#if os(macOS)
    @Suite("Execute crash recovery", .serialized)
    struct ExecuteTrapTests {
        @Test("A trap in a spec command leaves a breadcrumb and progress log on disk", .timeLimit(.minutes(2)))
        func trapLeavesRecoverableState() throws {
            let stateDirectory = scratchDirectory()
            defer {
                try? FileManager.default.removeItem(at: stateDirectory)
            }
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

            let probe = try #require(trapProbeURL(), "ExecuteTrapProbe executable not found next to the test bundle")
            let process = Process()
            process.executableURL = probe
            process.arguments = []
            var environment = ProcessInfo.processInfo.environment
            environment["EXHAUST_STATE_DIR"] = stateDirectory.path
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()

            #expect(process.terminationReason == .uncaughtSignal, "the probe should die by trap, not exit cleanly")

            let progressURL = try #require(findFile(named: "progress.json", under: stateDirectory), "no progress log survived")
            let progressData = try Data(contentsOf: progressURL)
            let progressJSON = try JSONSerialization.jsonObject(with: progressData) as? [String: Any]
            #expect(progressJSON?["metadata"] != nil)

            let breadcrumbURL = try #require(findFile(named: "breadcrumb.bin", under: stateDirectory), "no breadcrumb survived")
            let breadcrumb = try Data(contentsOf: breadcrumbURL)
            #expect(breadcrumb.count == 16)
            let candidateHash = breadcrumb.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            #expect(candidateHash != 0, "the breadcrumb should identify the candidate under evaluation at the trap")
        }
    }

    // MARK: - Helpers

    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("exhaust-execute-trap-tests")
            .appendingPathComponent(UUID().uuidString)
    }

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

        for configuration in ["debug", "release"] {
            let candidate = buildRoot.appendingPathComponent(configuration).appendingPathComponent("ExecuteTrapProbe")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func findFile(named name: String, under directory: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }
#endif
