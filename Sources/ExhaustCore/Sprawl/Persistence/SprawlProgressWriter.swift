// The asynchronous checkpoint writer: the exploration loop hands over snapshots and never blocks on disk.

import Foundation

/// Serialises and writes progress documents off the exploration loop.
///
/// The loop's contribution per checkpoint is copying value-type state (corpus entries, cluster snapshot) into the submitted closure — copy-on-write makes that cheap. Encoding, base64 codec work, and the atomic file write all happen on one utility-QoS serial queue, so checkpoints cannot reorder and the loop never waits on I/O.
package final class SprawlProgressWriter: @unchecked Sendable {
    // @unchecked: all mutable work is confined to the serial queue.
    private let queue = DispatchQueue(label: "com.exhaust.sprawl.progress-writer", qos: .utility)
    private let store: SprawlProgressStore

    package init(store: SprawlProgressStore) {
        self.store = store
    }

    /// Enqueues one checkpoint. The closure builds the document on the writer queue; write failures are swallowed — a missed checkpoint costs one recovery window, never the run.
    package func submit(_ makeDocument: @escaping @Sendable () -> SprawlProgressDocument) {
        queue.async { [store] in
            try? store.write(makeDocument())
        }
    }

    /// Blocks until every submitted checkpoint has reached disk. Called once at normal termination, before the log is promoted or removed.
    package func flush() {
        queue.sync {}
    }
}
