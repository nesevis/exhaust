import Foundation

/// NSLock-synchronized counter that is safe under both cooperative and preemptive concurrent execution.
///
/// @unchecked Sendable because all mutable state is serialized by the lock.
final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    var value: Int {
        lock.withLock { _value }
    }

    func increment() {
        lock.withLock { _value += 1 }
    }

    func decrement() {
        lock.withLock { _value -= 1 }
    }
}
