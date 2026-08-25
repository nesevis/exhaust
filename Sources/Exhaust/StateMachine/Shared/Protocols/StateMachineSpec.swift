/// Drives spec tests whose every command, invariant, and equivalence is synchronous.
///
/// The `@StateMachine` macro synthesizes this conformance in that case, and the ``AsyncStateMachineSpec`` one otherwise. A synchronous spec has no suspension points to interleave at, so `mode: .tasks` runs it one command at a time; interleaving needs async commands. `mode: .threads` still reaches real threads, because the lanes are OS threads rather than suspension points.
///
/// ```swift
/// @StateMachine
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
/// - Important: Conformance is synthesized by the `@StateMachine` macro. Hand-written conformance is unsupported: the requirements exist for macro expansions and may change in any release.
public protocol StateMachineSpec: StateMachineSpecBase, AnyObject {
    /// Executes a command against the model and SUT, returning a ``CommandResponse`` for linearizability checking.
    ///
    /// `mode: .threads` records the response against the lane that ran the command, which is what lets a return value be compared against a sequential replay. Sequential execution discards it, and a synchronous spec runs sequentially under `mode: .tasks` as well.
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

    /// Answers whether a concurrent run produced the same result as a sequential replay of the same commands. Synthesized from the spec's `@Equivalence` method.
    ///
    /// - Parameter sequentialResult: The system under test from a sequential replay of the same command sequence.
    /// - Returns: `true` when the concurrent state counts as equivalent to that replay's.
    func equivalenceCheck(_ sequentialResult: SystemUnderTest) -> Bool
}

extension StateMachineSpec {
    /// Default that traps, for a spec that declares no `@Equivalence`. The macro synthesizes a real one when the method is present.
    ///
    /// Reaching this trap would be a runner bug rather than user error. Two things keep it unreachable: ``StateMachineSpecBase/hasEquivalence`` is false for such a spec and every caller checks it first, and a thread-based run, which cannot proceed without an equivalence, refuses to start at all. The protocol cannot express "present only sometimes", so the guarantee lives in those two checks.
    public func equivalenceCheck(_: SystemUnderTest) -> Bool {
        fatalError("equivalenceCheck requires an @Equivalence method; hasEquivalence is false for this spec")
    }

    /// Default no-op for specs without a `@Setup` method. The `@StateMachine` macro synthesizes a real implementation when one exists.
    public func runSetup(_: SetupStep) throws {}

    /// Applies a setup step to this instance, reporting the error it threw rather than propagating it.
    ///
    /// The one place runner code applies setup. Returning the error instead of rethrowing is what lets every call site stay a single expression: the runners each turn a setup failure into their own currency (a verdict, a `false` replay result, a trace row), and none of them wants a `do`/`catch` to do it. A nil step is a no-op, so callers never branch on whether the spec has a `@Setup` method.
    func applySetup(_ step: SetupStep?) -> (any Error)? {
        guard let step else {
            return nil
        }
        do {
            try runSetup(step)
        } catch {
            return error
        }
        return nil
    }

    /// Constructs a fresh spec instance and applies its setup step, if it has one.
    ///
    /// The one construction funnel for runner code: once setup exists, no runner may call `Self()` directly, because with an implicitly unwrapped SUT every missed setup application is a nil-unwrap crash. The instance is always returned, alongside the setup error if one was thrown, so probe paths can report the partially set-up spec as evidence.
    static func makeSpec(setupStep: SetupStep?) -> (spec: Self, setupError: (any Error)?) {
        let spec = Self()
        return (spec, spec.applySetup(setupStep))
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
