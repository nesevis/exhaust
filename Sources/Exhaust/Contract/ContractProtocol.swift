// Defines the protocol that `@Contract`-annotated types conform to.
//
// The macro synthesizes conformance. Users never implement this directly.
import Foundation

/// Captures diagnostic state from a contract for failure reports.
///
/// For actor contracts, these properties can only be read from the actor's executor. ``AsyncContractSpec/diagnosticSnapshot()`` provides an async entry point that hops correctly.
public struct DiagnosticSnapshot<SystemUnderTest>: @unchecked Sendable {
    public let systemUnderTest: SystemUnderTest
    public let failureDescription: String

    public init(systemUnderTest: SystemUnderTest, failureDescription: String) {
        self.systemUnderTest = systemUnderTest
        self.failureDescription = failureDescription
    }
}

/// Shared requirements for both synchronous and asynchronous contracts.
///
/// Users never conform to this protocol directly. Use ``ContractSpec`` or ``AsyncContractSpec`` instead, both synthesized by the `@Contract` macro.
public protocol ContractSpecBase {
    /// Creates a fresh instance with default model and SUT state.
    init()

    /// The synthesized command enum. Each case corresponds to a `@Command` method.
    associatedtype Command: CustomStringConvertible & Sendable

    /// The type of the system under test, inferred from the `@SystemUnderTest` property.
    associatedtype SystemUnderTest

    /// Builds a generator for a single command step, weighted by `@Command` annotations.
    ///
    /// The macro synthesizes this as a ``Gen.pick`` over the command cases, each carrying its argument generators.
    static var commandGenerator: ReflectiveGenerator<Command> { get }

    /// The execution model this contract uses, synthesized by the `@Contract` macro.
    static var executionModel: ExecutionModel { get }

    /// The system under test instance, for typed access in results and failure reports.
    var systemUnderTest: SystemUnderTest { get }

    /// Returns a human-readable description of the contract state at the point of failure.
    ///
    /// Called when a contract test fails. Include whatever diagnostic information helps identify the bug — model state, SUT state, or both. The returned string appears in the failure report.
    func failureDescription() -> String
}

public extension ContractSpecBase {
    /// Default execution model for contracts that do not declare one explicitly.
    static var executionModel: ExecutionModel {
        .sequential
    }
}

/// Drives synchronous contract property tests for both `.tasks` and `.threads` modes.
///
/// The `@Contract` macro synthesizes this conformance when all commands and invariants are synchronous. For `.tasks`, checks use `@Invariant`. For `.threads`, the macro also synthesizes ``oracleCheck(_:)`` from the `@Oracle` method.
///
/// ```swift
/// @Contract(.tasks)
/// final class BoundedQueueContract {
///     var contents: [Int] = []
///     @SystemUnderTest
///     var queue = BoundedQueue<Int>(capacity: 4)
///
///     @Command(weight: 3, Gen.int(in: 0...99))
///     func enqueue(value: Int) throws {
///         guard contents.count < 4 else { throw skip() }
///         queue.enqueue(value)
///         contents.append(value)
///     }
///
///     func failureDescription() -> String {
///         "expected: \(contents), queue: \(queue)"
///     }
/// }
/// ```
public protocol ContractSpec: ContractSpecBase, AnyObject {
    /// Executes a command against the model and SUT, applying preconditions, postconditions, and invariants.
    ///
    /// - Parameter command: The command to execute.
    /// - Throws: ``ContractSkip`` if a precondition fails, ``ContractCheckFailure`` if a postcondition or invariant fails.
    func run(_ command: Command) throws

    /// Checks all `@Invariant`-annotated methods. Called after every command execution.
    ///
    /// - Throws: ``ContractCheckFailure`` if any invariant returns `false`.
    func checkInvariants() throws

    /// Compares the concurrent SUT state against a sequentially-replayed reference SUT. Only called for `.threads` contracts.
    ///
    /// - Parameter sequentialResult: The SUT state from a sequential (race-free) replay of the same command sequence.
    /// - Returns: `true` if the concurrent SUT state matches the expected sequential state.
    func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool
}

extension ContractSpec {
    /// Default oracle that traps. Overridden by the `@Contract(.threads)` macro's synthesized `oracleCheck`.
    ///
    /// Reaching this trap would be a dispatch bug, not user error. The invariant that keeps it unreachable lives in ``__ExhaustRuntime/__runContractDispatch(_:settings:fileID:filePath:line:column:)``: only `.threads` specs are routed to the preemptive runner that calls `oracleCheck`, and only `@Contract(.threads)` synthesizes a real implementation. `.sequential` and `.tasks` never call it. The safety rests on that dispatch, not on the type system — the unified protocol cannot express "oracle only when `.threads`".
    public func oracleCheck(_: SystemUnderTest) -> Bool {
        fatalError("oracleCheck is only called for .threads contracts")
    }

    /// Returns a closure that replays a command sequence on a fresh contract instance and collects the indices of commands that threw ``ContractSkip``.
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
                } catch is ContractSkip {
                    skips.insert(index)
                } catch {
                    break
                }
            }
            return skips
        }
    }
}

/// Drives asynchronous contract property tests for both `.tasks` and `.threads` modes.
///
/// The `@Contract` macro synthesizes this conformance when any `@Command` or `@Invariant` method is `async`. For `.threads`, the macro also synthesizes ``oracleCheck(_:)`` from the `@Oracle` method. Override ``failureDescription()`` to include diagnostic state in failure reports.
///
/// ## Skip Identification
///
/// Use ``skipIdentifier(specInit:)`` to obtain a synchronous closure for identifying skipped commands. The closure bridges async execution via `Task` + semaphore, matching the pattern used by the async contract runner's property closure.
public protocol AsyncContractSpec: ContractSpecBase, AnyObject {
    /// Executes a command against the model and SUT asynchronously.
    ///
    /// - Parameter command: The command to execute.
    /// - Throws: ``ContractSkip`` if a precondition fails, ``ContractCheckFailure`` if a postcondition or invariant fails.
    func run(_ command: Command) async throws

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
    /// Reaching this trap would be a dispatch bug, not user error. The invariant that keeps it unreachable lives in ``__ExhaustRuntime/__runContractDispatchAsync(_:settings:fileID:filePath:line:column:)``: only `.threads` specs are routed to the preemptive runner that calls `oracleCheck`, and only `@Contract(.threads)` synthesizes a real implementation. `.sequential` and `.tasks` never call it. The safety rests on that dispatch, not on the type system — the unified protocol cannot express "oracle only when `.threads`".
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
    /// Bridges async execution via ``__ExhaustRuntime/blockingAwait(_:)``. The returned closure is safe to call from a GCD thread.
    ///
    /// - Parameter specInit: A factory that creates a fresh contract instance. Must be `nonisolated(unsafe)` at the call site to satisfy `@Sendable` capture.
    internal static func skipIdentifier(
        specInit: @escaping () -> Self
    ) -> @Sendable ([Command]) -> Set<Int> {
        nonisolated(unsafe) let specInit = specInit
        return { commands in
            let box = UnsafeSendableBox(specInit())
            return __ExhaustRuntime.blockingAwait {
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
        }
    }
}
