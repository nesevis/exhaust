// Filesystem home of one test's crash-recovery state.

import Foundation

/// Owns the progress-log directory for one test: `<base>/exhaust/<module>/<test-id>/`.
///
/// Reads and writes are whole-document with atomic rename (`progress.json.tmp` → `progress.json`), so a crash mid-write loses at most the most recent checkpoint window, never the log. The store is dumb about content — staleness and version checks happen in ``load(maxAgeSeconds:)``, everything else in the caller.
package struct FuzzProgressStore: Sendable {
    /// The per-test directory holding `progress.json` and `breadcrumb.bin`.
    package let directory: URL

    package var progressFileURL: URL {
        directory.appendingPathComponent("progress.json")
    }

    package var breadcrumbFileURL: URL {
        directory.appendingPathComponent("breadcrumb.bin")
    }

    /// Creates a store rooted at an explicit directory. Tests use this with a scratch location.
    package init(directory: URL) {
        self.directory = directory
    }

    /// Creates the store at the standard location for a test, identified by its module and a stable per-test slug.
    package init(baseDirectory: URL = FileManager.default.temporaryDirectory, module: String, testIdentifier: String) {
        directory = baseDirectory
            .appendingPathComponent("exhaust")
            .appendingPathComponent(Self.sanitize(module))
            .appendingPathComponent(Self.sanitize(testIdentifier))
    }

    /// Loads the current document, or nil when none exists, it is stale, its version is unknown, or it cannot be parsed.
    package func load(maxAgeSeconds: Double) -> FuzzProgressDocument? {
        guard let data = try? Data(contentsOf: progressFileURL) else {
            return nil
        }
        guard let document = try? JSONDecoder().decode(FuzzProgressDocument.self, from: data) else {
            return nil
        }
        guard document.version == FuzzProgressDocument.currentVersion else {
            return nil
        }
        let age = Date().timeIntervalSince1970 - document.metadata.lastCheckpointEpochSeconds
        guard age >= 0, age <= maxAgeSeconds else {
            return nil
        }
        return document
    }

    /// Writes the document atomically: encode, write to a sibling temporary file, rename over the target.
    package func write(_ document: FuzzProgressDocument) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(document)
        let temporaryURL = directory.appendingPathComponent("progress.json.tmp")
        try data.write(to: temporaryURL)
        // replaceItemAt is unimplemented on Windows and unreliable on Linux in swift-corelibs-foundation.
        try? FileManager.default.removeItem(at: progressFileURL)
        try FileManager.default.moveItem(at: temporaryURL, to: progressFileURL)
    }

    /// Removes the whole per-test directory. Called on normal termination — a surviving log is the crash signal, so a completed run must not leave one behind.
    package func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func sanitize(_ component: String) -> String {
        String(component.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "." ? character : "_"
        })
    }
}
