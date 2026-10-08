/// Lightweight monotonic timer that produces elapsed time. Built on ``MonotonicClock/nanoseconds()`` for cross-platform support (Darwin, Linux, Windows).
package struct Stopwatch: Sendable {
    private let startNanos: UInt64

    package init() {
        startNanos = MonotonicClock.nanoseconds()
    }

    /// Nanoseconds elapsed since this stopwatch was created.
    package var elapsedNanoseconds: UInt64 {
        MonotonicClock.nanoseconds() &- startNanos
    }

    /// Milliseconds elapsed since this stopwatch was created.
    package var elapsedMilliseconds: Double {
        Double(elapsedNanoseconds) / 1_000_000
    }
}
