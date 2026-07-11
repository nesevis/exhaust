import ExhaustMetaFuzz
import Foundation
import Testing

/// Replays every frozen reproducer in `Regressions/` — the PR gate. Each record is a case that once violated an oracle; a reintroduced engine defect fails here deterministically, in milliseconds, with no instrumentation required.
@Suite("Frozen regression replay")
struct RegressionReplayTests {
    @Test("Every frozen record replays clean", arguments: try frozenRecordURLs())
    func frozenRecordReplaysClean(record: URL) throws {
        let data = try Data(contentsOf: record)
        do {
            try MetaFuzz.replay(data)
        } catch {
            Issue.record("Frozen defect reintroduced (or record stale): \(record.lastPathComponent) — \(error)")
        }
    }

    @Test("The regression directory exists")
    func regressionDirectoryExists() {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: regressionsDirectory().path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue)
    }
}

// MARK: - Record Discovery

/// The committed freeze corpus, resolved relative to this source file so the suite works under any working directory.
func regressionsDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Regressions")
}

func frozenRecordURLs() throws -> [URL] {
    let contents = try FileManager.default.contentsOfDirectory(
        at: regressionsDirectory(),
        includingPropertiesForKeys: nil
    )
    return contents.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}
