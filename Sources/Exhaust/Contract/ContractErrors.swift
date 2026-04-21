// Sentinel errors for contract command preconditions and postconditions.

/// Signals that a command's precondition is not met and this step should be skipped.
///
/// Thrown by ``skip()`` inside `@Command` methods when the current model state does not support the command. The contract runner catches this and skips the step.
public struct ContractSkip: Error, Sendable {
    /// Creates a new skip signal.
    public init() {}
}

/// Signals that a postcondition check failed inside a `@Command` method.
///
/// Thrown by ``check(_:_:)`` when a condition is `false`. The contract runner treats the current command sequence as a counterexample and proceeds to test case reduction.
public struct ContractCheckFailure: Error, Sendable {
    /// A description of the failed check, if available.
    public let message: String?

    /// Creates a check failure with an optional diagnostic message.
    public init(message: String? = nil) {
        self.message = message
    }
}

/// Skips the current command step because its precondition is not met.
///
/// Call this inside a `@Command` method when the model state does not support the command. The contract runner catches ``ContractSkip`` and continues with the next command in the sequence.
///
/// Since `@Command` methods are implicitly `throws`, use this in a `guard` statement:
///
/// ```swift
/// @Command(weight: 2)
/// mutating func dequeue() throws {
///     guard !contents.isEmpty else { throw skip() }
///     // ...
/// }
/// ```
///
/// - Returns: A ``ContractSkip`` error. Typical usage: `throw skip()`.
public func skip() -> ContractSkip {
    ContractSkip()
}

/// Verifies a postcondition inside a `@Command` method.
///
/// When the condition is `false`, throws ``ContractCheckFailure``, causing the contract runner to treat the current command sequence as a failing counterexample.
///
/// ```swift
/// @Command(weight: 2)
/// mutating func dequeue() throws {
///     guard !contents.isEmpty else { throw skip() }
///     let result = queue.dequeue()
///     try check(result == contents.first)
/// }
/// ```
///
/// - Parameters:
///   - condition: The condition to verify. When `false`, a check failure is thrown.
///   - message: An optional description included in failure reports.
public func check(_ condition: @autoclosure () -> Bool, _ message: String? = nil) throws {
    guard condition() else {
        throw ContractCheckFailure(message: message)
    }
}
