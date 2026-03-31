/// Mutable box for passing a value across a Task/thread boundary.
///
/// Intentionally `@unchecked Sendable` — the caller ensures that reads and writes do not race (for example, by gating access with a `DispatchSemaphore`).
final class SendableBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) {
        self.value = value
    }
}
