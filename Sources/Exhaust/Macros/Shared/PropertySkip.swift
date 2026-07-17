import Foundation

/// Skips the current property invocation without counting it as a pass or a failure.
///
/// Throw from a `#exhaust` property closure when a generated value cannot meaningfully exercise the property (for example, a value that depends on an unavailable environmental resource). The iteration still consumes budget, so skips are tallied in ``ExhaustReport/skippedInvocations``: a run that skips nearly every invocation reports a warning, and a run whose every invocation was skipped fails as pointless.
///
/// Prefer `ReflectiveGenerator.filter(_:_:fileID:filePath:line:column:)` when the condition is expressible over the generated value before the property runs. A filter steers generation toward valid inputs; a skip discards the iteration after its budget was spent.
///
/// ```swift
/// #exhaust(configGen) { config in
///     guard config.isSupportedOnThisPlatform else { throw PropertySkip() }
///     return validate(config)
/// }
/// ```
///
/// `XCTSkip` thrown from a property closure behaves identically on platforms where XCTest is available.
public struct PropertySkip: Error {
    /// Creates a skip marker.
    public init() {}
}

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
