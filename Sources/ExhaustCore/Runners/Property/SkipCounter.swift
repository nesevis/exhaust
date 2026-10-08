import Foundation

// MARK: - Skip Accounting

/// Counts skipped property invocations across sampling lanes.
///
/// A class with an `NSLock` rather than an actor because property closures run synchronously on GCD lanes. Marked `@unchecked Sendable`: the only mutable state is `count`, and every access is serialized under `lock`.
package final class SkipCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    /// Creates a counter starting at zero.
    package init() {}

    /// Records one skipped invocation.
    package func increment() {
        lock.withLocking { storage += 1 }
    }

    /// The number of skipped invocations recorded so far.
    ///
    /// Phase loops snapshot this before and after a phase and record the delta into the ``RunLedger``. The count is exact under parallel lanes because every skip lands here regardless of which lane observed it, so deltas taken outside the concurrent section cannot lose or double-count a skip.
    package var count: Int {
        lock.withLocking { storage }
    }
}
