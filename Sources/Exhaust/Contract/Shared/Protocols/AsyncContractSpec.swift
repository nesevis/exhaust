// Defines the protocol that `@Contract`-annotated types conform to.
//
// The macro synthesizes conformance. Users never implement this directly.
import Foundation

/// Drives asynchronous contract property tests for both `.tasks` and `.threads` modes.
///
/// The `@Contract` macro synthesizes this conformance when any `@Command` or `@Invariant` method is `async`. For `.threads`, the macro also synthesizes ``oracleCheck(_:)`` from the `@Oracle` method. Override ``failureDescription()`` to include diagnostic state in failure reports.
///
/// ## Skip Identification
///
/// Use ``skipIdentifier(specInit:)`` to obtain a synchronous closure for identifying skipped commands. The closure bridges async execution via `Task` + semaphore, matching the pattern used by the async contract runner's property closure.
public protocol AsyncContractSpec: ContractSpecBase, AnyObject {
    /// Executes a command against the model and SUT asynchronously, returning a ``CommandResponse`` for linearizability checking.
    ///
    /// The preemptive runner captures responses per-lane for linearizability confirmation; sequential and cooperative runners discard the return value.
    ///
    /// - Parameter command: The command to execute.
    /// - Returns: The command's description paired with its return value (or `nil` for void commands).
    /// - Throws: ``ContractSkip`` if a precondition fails, ``ContractCheckFailure`` if a postcondition or invariant fails.
    @discardableResult
    func run(_ command: Command) async throws -> CommandResponse

    /// Checks all `@Invariant`-annotated methods asynchronously. Called after every command execution.
    ///
    /// - Throws: ``ContractCheckFailure`` if any invariant returns `false`.
    func checkInvariants() async throws

    /// Compares the concurrent SUT state against a sequentially-replayed reference SUT. Only called for `.threads` contracts.
    ///
    /// - Parameter sequentialResult: The SUT state from a sequential (race-free) replay of the same command sequence.
    /// - Returns: `true` if the concurrent SUT state matches the expected sequential state.
    func oracleCheck(_ sequentialResult: SystemUnderTest) async -> Bool

    /// Captures diagnostic state for failure reports from an actor-safe async context.
    ///
    /// For actor conformers, this requirement is actor-isolated, so `await spec.diagnosticSnapshot()` hops to the actor's executor correctly. The macro synthesizes the implementation.
    func diagnosticSnapshot() async -> DiagnosticSnapshot<SystemUnderTest>
}

public extension AsyncContractSpec {
    /// Default oracle that traps. Overridden by the `@Contract(.threads)` macro's synthesized `oracleCheck`.
    ///
    /// Reaching this trap would be a dispatch bug, not user error. The invariant that keeps it unreachable lives in ``__ExhaustRuntime/__runContractDispatchAsync(_:settings:fileID:filePath:line:column:)``: only `.threads` specs are routed to the preemptive runner that calls `oracleCheck`, and only `@Contract(.threads)` synthesizes a real implementation. `.sequential` and `.tasks` never call it. The safety rests on that dispatch, not on the type system, because the unified protocol cannot express "oracle only when `.threads`".
    func oracleCheck(_: SystemUnderTest) async -> Bool {
        fatalError("oracleCheck is only called for .threads contracts")
    }

    /// Default implementation for non-actor conformers that can access properties directly.
    func diagnosticSnapshot() async -> DiagnosticSnapshot<SystemUnderTest> {
        DiagnosticSnapshot(
            systemUnderTest: systemUnderTest,
            failureDescription: failureDescription()
        )
    }

    /// Returns a closure that re-executes a command sequence and returns the indices of skipped commands.
    ///
    /// Bridges async execution via ``__ExhaustRuntime/blockingAwait(idleTimeoutMilliseconds:_:)``. The returned closure is safe to call from a GCD thread. On drain-loop timeout (a command that suspends onto a foreign executor or deadlocks synchronously), returns an empty set. Skip pruning is an optimization, so degrading gracefully is safe.
    ///
    /// - Parameters:
    ///   - specInit: A factory that creates a fresh contract instance. Must be `nonisolated(unsafe)` at the call site to satisfy `@Sendable` capture.
    ///   - idleTimeoutMilliseconds: Idle bound for the blocking drain loop, or `nil` to wait unbounded.
    internal static func skipIdentifier(
        specInit: @escaping () -> Self,
        idleTimeoutMilliseconds: Int? = nil
    ) -> @Sendable ([Command]) -> Set<Int> {
        nonisolated(unsafe) let specInit = specInit
        return { commands in
            let box = UnsafeSendableBox(specInit())
            let work: @Sendable () async -> Set<Int> = {
                var skips = Set<Int>()
                for (index, command) in commands.enumerated() {
                    do {
                        try await box.value.run(command)
                        try await box.value.checkInvariants()
                    } catch is ContractSkip {
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
