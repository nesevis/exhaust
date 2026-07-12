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

    /// The breadcrumb a crashed predecessor left: the candidate under evaluation at death and its mutation parent. Nil when no crash is being resumed or the slot was clear.
    package let survivor: (candidateHash: UInt64, parentHash: UInt64)?

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
        survivor = resumeDocument == nil
            ? nil
            : FuzzBreadcrumb.readSurvivor(fileURL: store.breadcrumbFileURL)
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
