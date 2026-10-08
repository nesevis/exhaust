// The crash-recovery state handed to a run at start: where to write, and what a predecessor left behind.

import Foundation

/// The persistence configuration for one `time:` run, constructed read-only before the run starts.
///
/// Construction performs no writes: it locates the store, reads any fresh progress document a crashed predecessor left, and reads the surviving breadcrumb. The runner creates the writer and the live breadcrumb mapping itself when the run actually starts, so a run that fails validation (missing instrumentation, bad settings) leaves no files behind.
package struct FuzzPersistenceContext {
    /// The per-test store; the runner writes checkpoints here and removes it on normal termination.
    package let store: FuzzProgressStore

    /// A fresh document from a predecessor that died before completing, or nil for a clean start (none present, stale, unparseable, or resume opted out).
    package let resumeDocument: FuzzProgressDocument?

    /// The breadcrumb a crashed predecessor left: the probe under evaluation at death, its mutation parent, which kind of probe it was, and the candidate itself when it fit the slot. Nil when no crash is being resumed or the slot was clear.
    package let survivor: Survivor?

    /// Creates the context, reading any recoverable predecessor state.
    ///
    /// - Parameters:
    ///   - store: The per-test store location.
    ///   - resumeEnabled: False disables recovery (`EXHAUST_RESUME=0`): predecessor state is ignored and will be overwritten by this run's checkpoints.
    package init(store: FuzzProgressStore, resumeEnabled: Bool) {
        self.store = store
        guard resumeEnabled else {
            resumeDocument = nil
            survivor = nil
            return
        }
        resumeDocument = store.load(maxAgeSeconds: FuzzTunables.progressLogStalenessSeconds)
        // Only read the breadcrumb when a document is being resumed: a slot left by a run whose log has already aged out names a candidate nothing can look up.
        survivor = resumeDocument.flatMap { _ in
            FuzzBreadcrumb.readSurvivor(fileURL: store.breadcrumbFileURL)
        }
    }

    /// Looks up the survivor's parent sequence in the resumed snapshot, for the trap report. Nil when the parent hash is 0 (the trap hit a phase-1/2 candidate with no corpus parent) or the parent predates the last checkpoint.
    package func survivorParentSequence() -> ChoiceSequence? {
        guard let survivor, survivor.parentHash != 0, let resumeDocument else {
            return nil
        }
        for record in resumeDocument.snapshot {
            guard let sequence = ChoiceSequenceCodec.decode(record.sequence) else {
                continue
            }
            if ZobristHash.hash(of: sequence) == survivor.parentHash {
                return sequence
            }
        }
        return nil
    }
}

// MARK: - Call-Site Context

package extension __ExhaustRuntime {
    /// Builds the crash-recovery context for one `#explore(time:)` call site: `<base>/exhaust/<module>/<file>-L<line>/`, which is stable across runs of the same test. Construction is read-only; the runner creates files only once the run actually starts.
    ///
    /// The base directory is the system temporary directory, or `EXHAUST_STATE_DIR` when set for CI and for the trap probe, which needs the parent process to know where the crashed child's state landed. `EXHAUST_RESUME=0` opts out of recovery: predecessor state is ignored and overwritten.
    ///
    /// - Note: The store is keyed by file and line only, so two processes fuzzing the same test concurrently stomp each other's checkpoints and can misread each other's breadcrumbs as their own crash. Documented in the crash-recovery article; callers who overlap runs of one test point each process at its own `EXHAUST_STATE_DIR`.
    static func makeFuzzPersistenceContext(
        fileID: StaticString,
        line: UInt,
        baseDirectory: URL? = nil
    ) -> FuzzPersistenceContext {
        let base = baseDirectory
            ?? ProcessInfo.processInfo.environment["EXHAUST_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let fileIDText = "\(fileID)"
        let module = fileIDText.split(separator: "/").first.map(String.init) ?? "UnknownModule"
        let file = fileIDText.split(separator: "/").last.map(String.init) ?? "UnknownFile"
        let store = FuzzProgressStore(
            baseDirectory: base,
            module: module,
            testIdentifier: "\(file)-L\(line)"
        )
        let resumeEnabled = ProcessInfo.processInfo.environment["EXHAUST_RESUME"] != "0"
        return FuzzPersistenceContext(store: store, resumeEnabled: resumeEnabled)
    }
}
