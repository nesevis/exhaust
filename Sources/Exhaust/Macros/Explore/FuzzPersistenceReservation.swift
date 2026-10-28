// Checkpoint ownership for one `time:` campaign: where its store lives and the lock that keeps it unique.

import ExhaustCore
import ExhaustSupport
import Foundation

extension FuzzProgressStore {
    /// Locates the store for a macro call site, its enclosing test, and its resolved search seed. A nil seed is only used for rejected configurations, which never reserve or write the store.
    init(
        fileID: StaticString,
        line: UInt,
        column: UInt,
        testIdentity: String?,
        seed: UInt64?,
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        let fileIDText = "\(fileID)"
        let module = fileIDText.split(separator: "/").first.map(String.init) ?? "UnknownModule"
        let file = fileIDText.split(separator: "/").last.map(String.init) ?? "UnknownFile"
        let testFingerprint = testIdentity.map { StableHash.hex($0) } ?? "standalone"
        let campaign = seed.map { "seed-\($0)" } ?? "default"
        self.init(
            baseDirectory: baseDirectory,
            module: module,
            testIdentifier: "\(file)-L\(line)-C\(column)-\(testFingerprint)-\(campaign)"
        )
    }
}

extension __ExhaustRuntime {
    /// Keeps the store reserved across suspension points until the asynchronous body returns.
    static func withReservedFuzzPersistence<Result>(
        store: FuzzProgressStore,
        resumeEnabled: Bool,
        recoverUnseeded: Bool = false,
        body: (FuzzPersistenceContext) async -> Result
    ) async throws(FuzzPersistenceError) -> Result {
        let lease = try FileLock(checkpointLock: store.lockFileURL)
        defer { withExtendedLifetime(lease) {} }
        if resumeEnabled, recoverUnseeded {
            try store.claimAbandonedCampaign()
        }
        return await body(FuzzPersistenceContext(store: store, resumeEnabled: resumeEnabled))
    }
}

extension FileLock {
    /// Holds checkpoint ownership for the persistence scope, explaining how to avoid contention when another campaign owns the store.
    init(checkpointLock lockFileURL: URL) throws(FuzzPersistenceError) {
        do {
            try self.init(lockFileURL: lockFileURL)
        } catch {
            throw FuzzPersistenceError(error.message(
                busy: "Another campaign owns this checkpoint store. Omit .replay to give each campaign a generated seed, or run replays of the same seed serially. EXHAUST_RESUME=0 does not disable checkpoint writes."
            ))
        }
    }
}

private extension FuzzProgressStore {
    /// Moves one abandoned checkpoint into this run's seed directory while both stores are locked. Active campaigns are skipped, and the atomic move prevents two new runs from resuming the same predecessor. The legacy unseeded directory is also eligible for recovery.
    func claimAbandonedCampaign() throws(FuzzPersistenceError) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) == false,
              let marker = directory.lastPathComponent.range(of: "-seed-", options: .backwards)
        else {
            return
        }
        let prefix = String(directory.lastPathComponent[..<marker.lowerBound])
        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: directory.deletingLastPathComponent(),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ).filter { candidate in
                let name = candidate.lastPathComponent
                return name == prefix + "-default"
                    || (name.hasPrefix(prefix + "-seed-") && UInt64(name.dropFirst(prefix.count + 6)) != nil)
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw FuzzPersistenceError("Cannot list campaign checkpoints: \(error)")
        }
        for candidate in candidates where candidate != directory {
            do {
                let predecessor = FuzzProgressStore(directory: candidate)
                let lease = try FileLock(lockFileURL: predecessor.lockFileURL)
                defer { withExtendedLifetime(lease) {} }
                // A competing recovery may have moved the directory after it was listed.
                guard fileManager.fileExists(atPath: candidate.path) else {
                    continue
                }
                let resource = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard resource.isDirectory == true, resource.isSymbolicLink != true,
                      FuzzPersistenceContext(store: predecessor, resumeEnabled: true).resumeDocument != nil
                else {
                    continue
                }
                try fileManager.moveItem(at: candidate, to: directory)
                return
            } catch FileLock.Failure.busy {
                continue
            } catch {
                throw FuzzPersistenceError("Cannot recover campaign checkpoint: \(error)")
            }
        }
    }
}

/// Describes a checkpoint reservation failure without allowing shared writers to proceed.
struct FuzzPersistenceError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
