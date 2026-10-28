// Checkpoint ownership for one `time:` campaign: where its store lives and the lock that keeps it unique.

import ExhaustCore
import ExhaustSupport
import Foundation

extension FuzzProgressStore {
    /// Locates the stable store for a macro call site, its enclosing test, and its explicit seed. Unseeded campaigns share the default identity, so overlapping runs must supply distinct seeds or run serially.
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
        body: (FuzzPersistenceContext) async -> Result
    ) async throws(FuzzPersistenceError) -> Result {
        let lease = try FileLock(checkpointLock: store.lockFileURL)
        defer { withExtendedLifetime(lease) {} }
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
                busy: "Another campaign owns this checkpoint store. Give concurrent runs at the same #explore call site distinct explicit seeds with .replay(.numeric(seed)), or run them serially. EXHAUST_RESUME=0 does not disable checkpoint writes."
            ))
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
