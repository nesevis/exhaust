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

    /// Executes the spec's `@Setup` method with the given generated step. Called once per fresh spec instance, before any command runs. No invariant check runs after setup.
    ///
    /// - Throws: Any error the setup method throws. A setup throw fails the run; there is no skip channel.
    func runSetup(_ step: SetupStep) throws

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

    /// Default no-op for specs without a `@Setup` method. The `@StateMachine` macro synthesizes a real implementation when one exists.
    public func runSetup(_: SetupStep) throws {}

    /// Constructs a fresh spec instance and applies its setup step, if it has one.
    ///
    /// The one construction funnel for runner code: once setup exists, no runner may call `Self()` directly, because with an implicitly unwrapped SUT every missed setup application is a nil-unwrap crash. The instance is always returned, alongside the setup error if one was thrown, so probe paths can report the partially set-up spec as evidence.
    static func makeSpec(setupStep: SetupStep?) -> (spec: Self, setupError: (any Error)?) {
        let spec = Self()
        guard let setupStep else {
            return (spec, nil)
        }
        do {
            try spec.runSetup(setupStep)
        } catch {
            return (spec, error)
        }
        return (spec, nil)
    }

    /// Replays a command sequence on a fresh spec instance (with setup applied) and collects the indices of commands that threw ``StateMachineSkip``.
    ///
    /// Used by the SCA screening phase and skip-pruning pass to identify commands whose preconditions are not met for a given sequence, so those elements can be removed from the choice tree before reduction. A setup error returns the empty set: skip pruning is an optimization, and the actual execution reports the setup failure.
    static func identifySkips(setupStep: SetupStep?, commands: [Command]) -> Set<Int> {
        let (spec, setupError) = makeSpec(setupStep: setupStep)
        guard setupError == nil else {
            return []
        }
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
