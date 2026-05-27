/// Lightweight monotonic timer that produces elapsed milliseconds. Built on ``monotonicNanoseconds()`` for cross-platform support (Darwin, Linux, Windows).
package struct Stopwatch: Sendable {
    private let startNanos: UInt64

    package init() {
        startNanos = monotonicNanoseconds()
    }

    /// Milliseconds elapsed since this stopwatch was created.
    package var elapsedMilliseconds: Double {
        Double(monotonicNanoseconds() &- startNanos) / 1_000_000
    }
}
