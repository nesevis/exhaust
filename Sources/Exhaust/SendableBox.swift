import Foundation

/// A type that exposes a mutable boolean flag for cooperative cancellation.
protocol CancellationFlag: AnyObject, Sendable {
    var isCancelled: Bool { get set }
}

/// Mutable box for passing a value across a sendability boundary without synchronization.
///
/// Intentionally `@unchecked Sendable` — the caller must ensure that reads and writes do not race. Typical safe patterns: a single writer followed by a `DispatchSemaphore` barrier before the reader, or a sequential closure captured by a `@Sendable`-requiring API.
///
/// For state that is genuinely written from multiple threads concurrently, use ``SendableBox`` instead, which protects access with an `NSLock`.
final class UnsafeSendableBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) {
        self.value = value
    }
}

extension UnsafeSendableBox: CancellationFlag where Value == Bool {
    var isCancelled: Bool {
        get { value }
        set { value = newValue }
    }
}

/// Thread-safe mutable box for sharing a value across concurrent threads.
///
/// All reads and writes are serialized by an internal lock. Use this when multiple threads may read or write the value concurrently (for example, multiple GCD lanes writing an exception and a main thread reading after `DispatchGroup.wait()`).
///
/// For sendability bridging where external synchronization already prevents races, use ``UnsafeSendableBox`` to avoid the lock overhead.
final class SendableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }

    /// Provides atomic access to the stored value for compound operations.
    ///
    /// The lock is held for the duration of `body`, so read-modify-write sequences execute as a single atomic unit. The `@Sendable` annotation prevents the caller from capturing unsynchronized external state into the critical section.
    @discardableResult
    func withValue<Result>(
        _ body: @Sendable (inout Value) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}

extension SendableBox: CancellationFlag where Value == Bool {
    var isCancelled: Bool {
        get { value }
        set { value = newValue }
    }
}
