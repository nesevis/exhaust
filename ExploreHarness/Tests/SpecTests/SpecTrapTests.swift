import Foundation
import Testing

#if os(macOS)
    @Suite("Spec crash recovery", .serialized)
    struct SpecTrapTests {
        @Test("A trap in a spec command leaves a breadcrumb and progress log on disk", .timeLimit(.minutes(2)))
        func trapLeavesRecoverableState() throws {
            let stateDirectory = scratchDirectory()
            defer {
                try? FileManager.default.removeItem(at: stateDirectory)
            }
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

            let probe = try #require(trapProbeURL(), "SpecTrapProbe executable not found next to the test bundle")
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
            let candidateHash = committedCandidateHash(in: breadcrumb)
            #expect(candidateHash != nil && candidateHash != 0, "the breadcrumb should identify the candidate under evaluation at the trap")
        }
    }

    // MARK: - Helpers

    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("exhaust-spec-trap-tests")
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
            let candidate = buildRoot.appendingPathComponent(configuration).appendingPathComponent("SpecTrapProbe")
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

// MARK: - Breadcrumb Layout

/// The candidate hash of the breadcrumb's committed slot, or nil when neither slot carries the commit marker.
///
/// The file is two fixed-size slots (48 header bytes plus a 4096-byte payload each); a slot's first word is the commit marker once the rest is written, and the candidate hash sits at offset 16. Mirrors `FuzzBreadcrumb`'s layout, which this package cannot read directly.
private func committedCandidateHash(in breadcrumb: Data) -> UInt64? {
    let slotSize = 48 + 4096
    let commitMarker: UInt64 = 0x4558_4855_5354_4331
    func word(at offset: Int) -> UInt64 {
        breadcrumb[offset ..< offset + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
    guard breadcrumb.count == slotSize * 2 else {
        return nil
    }
    for slot in 0 ..< 2 where word(at: slot * slotSize) == commitMarker {
        return word(at: slot * slotSize + 16)
    }
    return nil
}
