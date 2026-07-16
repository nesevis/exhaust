// Sentinel errors for spec command preconditions and postconditions.

/// Signals that a command's precondition is not met and this step should be skipped.
///
/// Thrown by ``StateMachineSpecBase/skip()`` inside `@Command` methods when the current model state does not support the command. The spec runner catches this and skips the step.
public struct StateMachineSkip: Error, Sendable {
    /// Creates a new skip signal.
    public init() {}
}

/// Signals that a postcondition check failed inside a `@Command` method.
///
/// Thrown by ``StateMachineSpecBase/check(_:_:)`` when a condition is `false`. The spec runner treats the current command sequence as a counterexample and proceeds to test case reduction.
public struct StateMachineCheckFailure: Error, Sendable {
    /// A description of the failed check, if available.
    public let message: String?

    /// Creates a check failure with an optional diagnostic message.
    public init(message: String? = nil) {
        self.message = message
    }
}

public extension StateMachineSpecBase {
    /// Skips the current command step because its precondition is not met.
    ///
    /// Call this inside a `@Command` method when the model state does not support the command. The spec runner catches ``StateMachineSkip`` and continues with the next command in the sequence.
    ///
    /// Since `@Command` methods are implicitly `throws`, use this in a `guard` statement:
    ///
    /// ```swift
    /// @Command(weight: 2)
    /// func dequeue() throws {
    ///     guard contents.isEmpty == false else { throw skip() }
    ///     // ...
    /// }
    /// ```
    ///
    /// - Returns: A ``StateMachineSkip`` error. Typical usage: `throw skip()`.
    func skip() -> StateMachineSkip {
        StateMachineSkip()
    }

    /// Verifies a postcondition inside a `@Command` method.
    ///
    /// When the condition is `false`, throws ``StateMachineCheckFailure``, causing the spec runner to treat the current command sequence as a failing counterexample.
    ///
    /// ```swift
    /// @Command(weight: 2)
    /// func dequeue() throws {
    ///     guard contents.isEmpty == false else { throw skip() }
    ///     let result = queue.dequeue()
    ///     try check(result == contents.first)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - condition: The condition to verify. When `false`, a check failure is thrown.
    ///   - message: An optional description included in failure reports.
    func check(_ condition: @autoclosure () -> Bool, _ message: String? = nil) throws {
        guard condition() else {
            throw StateMachineCheckFailure(message: message)
        }
    }
}
