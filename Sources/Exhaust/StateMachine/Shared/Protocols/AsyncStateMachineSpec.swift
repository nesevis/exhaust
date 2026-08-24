// Defines the protocol that `@StateMachine`-annotated types conform to.
//
// The macro synthesizes conformance. Users never implement this directly.
import ExhaustCore
import Foundation

/// Drives spec tests with any asynchronous member, under every execution mode.
///
/// The `@StateMachine` macro synthesizes this conformance when any `@Command`, `@Invariant`, `@Setup`, or `@Equivalence` method is `async`, and the synchronous ``StateMachineSpec`` one otherwise. Cooperative interleaving reaches this conformance only: `mode: .tasks` interleaves at `await` boundaries, which a synchronous spec does not have. Override ``StateMachineSpecBase/failureDescription()`` to include diagnostic state in failure reports.
///
/// ## Skip Identification
///
/// The internal `skipIdentifier(specInit:)` helper obtains a synchronous closure for identifying skipped commands. The closure bridges async execution via `Task` and a semaphore, matching the pattern used by the async spec runner's property closure.
public protocol AsyncStateMachineSpec: StateMachineSpecBase, AnyObject {
    /// Executes a command against the model and SUT asynchronously, returning a ``CommandResponse`` for linearizability checking.
    ///
    /// Both `mode: .tasks` and `mode: .threads` record the response against the lane that ran the command, which is what lets a return value be compared against a sequential replay. `mode: .sequential` discards it.
    ///
    /// - Parameter command: The command to execute.
    /// - Returns: The command's description paired with its return value (or `nil` for void commands).
    /// - Throws: ``StateMachineSkip`` if a precondition fails, ``StateMachineCheckFailure`` if a postcondition or invariant fails.
    @discardableResult
    func run(_ command: Command) async throws -> CommandResponse

    /// Checks all `@Invariant`-annotated methods asynchronously. Called after every command execution.
    ///
    /// - Throws: ``StateMachineCheckFailure`` if any invariant returns `false`.
    func checkInvariants() async throws

    /// Executes the spec's `@Setup` method with the given generated step. Called once per fresh spec instance, before any command runs. No invariant check runs after setup.
    ///
    /// - Throws: Any error the setup method throws. A setup throw fails the run; there is no skip channel.
    func runSetup(_ step: SetupStep) async throws

    /// Answers whether a concurrent run produced the same result as a sequential replay of the same commands. Synthesized from the spec's `@Equivalence` method.
    ///
    /// - Parameter sequentialResult: The system under test from a sequential replay of the same command sequence.
    /// - Returns: `true` when the concurrent state counts as equivalent to that replay's.
    func equivalenceCheck(_ sequentialResult: SystemUnderTest) async -> Bool
}

public extension AsyncStateMachineSpec {
    /// Default that traps, for a spec that declares no `@Equivalence`. The macro synthesizes a real one when the method is present.
    ///
    /// Reaching this trap would be a runner bug rather than user error. Two things keep it unreachable: ``StateMachineSpecBase/hasEquivalence`` is false for such a spec and every caller checks it first, and a thread-based run, which cannot proceed without an equivalence, refuses to start at all. The protocol cannot express "present only sometimes", so the guarantee lives in those two checks.
    func equivalenceCheck(_: SystemUnderTest) async -> Bool {
        fatalError("equivalenceCheck requires an @Equivalence method; hasEquivalence is false for this spec")
    }

    /// Default no-op for specs without a `@Setup` method. The `@StateMachine` macro synthesizes a real implementation when one exists.
    func runSetup(_: SetupStep) async throws {}

    /// Applies a setup step to this instance, reporting the error it threw rather than propagating it.
    ///
    /// The async twin of ``StateMachineSpec/applySetup(_:)``, and the one place runner code applies setup. A nil step is a no-op, so callers never branch on whether the spec has a `@Setup` method.
    internal func applySetup(_ step: SetupStep?) async -> (any Error)? {
        guard let step else {
            return nil
        }
        do {
            try await runSetup(step)
        } catch {
            return error
        }
        return nil
    }

    /// Constructs a fresh spec instance and applies its setup step, if it has one.
    ///
    /// The async twin of the ``StateMachineSpec`` construction funnel: once setup exists, no runner may call `Self()` directly. The instance is always returned, alongside the setup error if one was thrown, so probe paths can report the partially set-up spec as evidence.
    internal static func makeSpec(setupStep: SetupStep?) async -> (spec: Self, setupError: (any Error)?) {
        let spec = Self()
        return await (spec, spec.applySetup(setupStep))
    }

    /// Returns a closure that re-executes a command sequence (with setup applied first) and returns the indices of skipped commands.
    ///
    /// Bridges async execution via ``__ExhaustRuntime/blockingAwait(idleTimeoutMilliseconds:_:)``. The returned closure is safe to call from a GCD thread. On drain-loop timeout (a command that suspends onto a foreign executor or deadlocks synchronously) or a setup error, returns an empty set. Skip pruning is an optimization, so degrading gracefully is safe.
    ///
    /// - Parameters:
    ///   - specInit: A factory that creates a fresh spec instance. Must be `nonisolated(unsafe)` at the call site to satisfy `@Sendable` capture.
    ///   - idleTimeoutMilliseconds: Idle bound for the blocking drain loop, or `nil` to wait unbounded.
    internal static func skipIdentifier(
        specInit: @escaping () -> Self,
        idleTimeoutMilliseconds: Int? = nil
    ) -> @Sendable (SetupStep?, [Command]) -> Set<Int> {
        nonisolated(unsafe) let specInit = specInit
        return { setupStep, commands in
            let box = UnsafeSendableBox(specInit())
            let work: @Sendable () async -> Set<Int> = {
                guard await box.value.applySetup(setupStep) == nil else {
                    return []
                }
                var skips = Set<Int>()
                for (index, command) in commands.enumerated() {
                    do {
                        try await box.value.run(command)
                        try await box.value.checkInvariants()
                    } catch is StateMachineSkip {
                        skips.insert(index)
                    } catch {
                        break
                    }
                }
                return skips
            }
            if let idleTimeoutMilliseconds {
                return __ExhaustRuntime.blockingAwait(idleTimeoutMilliseconds: idleTimeoutMilliseconds, work) ?? []
            }
            return __ExhaustRuntime.blockingAwait(work)
        }
    }
}
