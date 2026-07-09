/// Drives synchronous spec tests for `.sequential` and `.threads` modes.
///
/// The `@StateMachine` macro synthesizes this conformance when all commands and invariants are synchronous. A synchronous `.tasks` spec also conforms to `StateMachineSpec` and runs sequentially; interleaving requires async commands and the ``AsyncStateMachineSpec`` conformance. For `.threads`, the macro also synthesizes ``oracleCheck(_:)`` from the `@Oracle` method.
///
/// ```swift
/// @StateMachine(.sequential)
/// final class BoundedQueueSpec {
///     var contents: [Int] = []
///     @SystemUnderTest
///     var queue = BoundedQueue<Int>(capacity: 4)
///
///     @Command(weight: 3, .int(in: 0...99))
///     func enqueue(value: Int) throws {
///         guard contents.count < 4 else { throw skip() }
///         queue.enqueue(value)
///         contents.append(value)
///     }
///
///     func failureDescription() -> String? {
///         "expected: \(contents), queue: \(queue)"
///     }
/// }
/// ```
public protocol StateMachineSpec: StateMachineSpecBase, AnyObject {
    /// Executes a command against the model and SUT, returning a ``CommandResponse`` for linearizability checking.
    ///
    /// The preemptive runner captures responses per-lane for linearizability confirmation. Sequential and cooperative runners discard the return value.
    ///
    /// - Parameter command: The command to execute.
    /// - Returns: The command's description paired with its return value (or `nil` for void commands).
    /// - Throws: ``StateMachineSkip`` if a precondition fails, ``StateMachineCheckFailure`` if a postcondition or invariant fails.
    @discardableResult
    func run(_ command: Command) throws -> CommandResponse

    /// Checks all `@Invariant`-annotated methods. Called after every command execution.
    ///
    /// - Throws: ``StateMachineCheckFailure`` if any invariant returns `false`.
    func checkInvariants() throws

    /// Compares the concurrent SUT state against a sequentially-replayed reference SUT. Only called for `.threads` specs.
    ///
    /// - Parameter sequentialResult: The SUT state from a sequential (race-free) replay of the same command sequence.
    /// - Returns: `true` if the concurrent SUT state matches the expected sequential state.
    func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool
}

extension StateMachineSpec {
    /// Default oracle that traps. Overridden by the `@StateMachine(.threads)` macro's synthesized `oracleCheck`.
    ///
    /// Reaching this trap would be a dispatch bug, not user error. The invariant that keeps it unreachable lives in ``__ExhaustRuntime/__runStateMachineDispatch(_:settings:fileID:filePath:line:column:)``: only `.threads` specs are routed to the preemptive runner that calls `oracleCheck`, and only `@StateMachine(.threads)` synthesizes a real implementation. `.sequential` and `.tasks` never call it. The safety rests on that dispatch, not on the type system, because the unified protocol cannot express "oracle only when `.threads`".
    public func oracleCheck(_: SystemUnderTest) -> Bool {
        fatalError("oracleCheck is only called for .threads specs")
    }

    /// Returns a closure that replays a command sequence on a fresh spec instance and collects the indices of commands that threw ``StateMachineSkip``.
    ///
    /// The returned closure is used by the SCA coverage phase and skip-pruning pass to identify commands whose preconditions are not met for a given sequence, so those elements can be removed from the choice tree before reduction.
    static var skipIdentifier: @Sendable ([Command]) -> Set<Int> {
        { commands in
            let spec = Self()
            var skips: Set<Int> = []
            for (index, command) in commands.enumerated() {
                do {
                    try spec.run(command)
                    try spec.checkInvariants()
                } catch is StateMachineSkip {
                    skips.insert(index)
                } catch {
                    break
                }
            }
            return skips
        }
    }
}
