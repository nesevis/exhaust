/// Unsynchronized counter whose mutations have no suspension points, creating an extremely narrow race window.
///
/// Unlike ``NonAtomicCounter``, which inserts `Task.yield()` between read and write to widen the race window, this type uses bare `_value += 1` — a single read-modify-write that completes in nanoseconds. The cooperative scheduler cannot interleave within a non-suspending method, so CCCR will never detect the race. The preemptive runner can detect it, but only through sheer repetition — empirically around 2.4 million executions to hit the window.
///
/// @unchecked Sendable because the cooperative and preemptive schedulers both require Sendable SUTs. The lack of synchronization is the point.
final class NarrowRaceCounter: @unchecked Sendable {
    private var _value: Int = 0

    var value: Int {
        _value
    }

    func increment() async {
        _value += 1
    }

    func decrement() async {
        _value -= 1
    }
}
