// Defines the protocol that `@Contract`-annotated types conform to.
//
// The macro synthesizes conformance — users never implement this directly.
import Foundation

/// Shared requirements for both synchronous and asynchronous contracts.
///
/// Users never conform to this protocol directly — use ``ContractSpec`` or ``AsyncContractSpec`` instead, both synthesized by the `@Contract` macro.
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

    /// The concurrency model this contract uses, synthesized by the `@Contract` macro.
    static var concurrencyModel: ConcurrencyModel { get }

    /// The system under test instance, for typed access in results and failure reports.
    var systemUnderTest: SystemUnderTest { get }

    /// A human-readable description of the model state, used in failure reports.
    var modelDescription: String { get }

    /// A human-readable description of the SUT state, used in failure reports.
    var sutDescription: String { get }
}

public extension ContractSpecBase {
    /// Default concurrency model for contracts that do not declare one explicitly.
    static var concurrencyModel: ConcurrencyModel {
        .tasks
    }
}

/// Drives sequential, stateful contract property tests.
///
/// Users annotate a `final class` with `@Contract(.tasks)` rather than conforming manually. The macro synthesizes the `Command` enum, the ``commandGenerator`` property, and the `run(_:)` method from the `@Command`-annotated methods on the class.
///
/// ## How It Works
///
/// Each test iteration generates a sequence of commands and executes them against the system under test (the property marked `@SystemUnderTest`). After every command, `@Invariant` methods are checked. Contracts can optionally include `@Model` properties as a reference model, or rely solely on invariants and ``check(_:_:)`` postconditions.
///
/// ```swift
/// @Contract(.tasks)
/// final class BoundedQueueContract {
///     @Model var contents: [Int] = []
///     @SystemUnderTest
///     var queue = BoundedQueue<Int>(capacity: 4)
///
///     @Command(weight: 3, Gen.int(in: 0...99))
///     func enqueue(value: Int) throws {
///         guard contents.count < 4 else { throw skip() }
///         queue.enqueue(value)
///         contents.append(value)
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
}

extension ContractSpec {
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

/// Drives asynchronous contract property tests for async SUTs (actors, databases, network services).
///
/// Async contracts are reference types. This is required because concurrent testing executes commands from two tasks against the same contract instance — the custom executor controls interleaving at `await` boundaries to deterministically expose reentrancy bugs.
///
/// The `@Contract(.tasks)` macro emits this conformance automatically when any `@Command` or `@Invariant` method is `async`.
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
}

// MARK: - Concurrent Contract Specs (GCD Backend)

/// Drives synchronous GCD-based concurrent contract tests with an explicit oracle.
///
/// Extends ``ContractSpec`` with an ``oracleCheck(_:)`` method that compares the concurrent SUT state against a sequentially-replayed reference. The `@Contract(.threads)` macro synthesizes this conformance when all commands are synchronous.
///
/// The oracle defines what "equivalent" means for the SUT — element equality for a queue, count equality for a counter, set membership for a cache. The GCD backend calls it after concurrent execution to determine whether the observed behavior is consistent with sequential behavior.
public protocol ConcurrentContractSpec: ContractSpecBase, AnyObject {
    /// Executes a command against the model and SUT.
    ///
    /// - Parameter command: The command to execute.
    /// - Throws: ``ContractSkip`` if a precondition fails, ``ContractCheckFailure`` if a postcondition or invariant fails.
    func run(_ command: Command) throws

    /// Checks all `@Invariant`-annotated methods. Called after every command execution.
    ///
    /// - Throws: ``ContractCheckFailure`` if any invariant returns `false`.
    func checkInvariants() throws

    /// Compares the concurrent SUT state against a sequentially-replayed reference SUT.
    ///
    /// - Parameter sequentialResult: The SUT state from a sequential (race-free) replay of the same command sequence.
    /// - Returns: `true` if the concurrent SUT state matches the expected sequential state.
    func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool
}

/// Drives asynchronous GCD-based concurrent contract tests with an explicit oracle.
///
/// Extends ``AsyncContractSpec`` with an ``oracleCheck(_:)`` method. The `@Contract(.threads)` macro synthesizes this conformance when any command or invariant is `async`.
public protocol AsyncConcurrentContractSpec: ContractSpecBase, AnyObject {
    /// Executes a command against the model and SUT asynchronously.
    ///
    /// - Parameter command: The command to execute.
    /// - Throws: ``ContractSkip`` if a precondition fails, ``ContractCheckFailure`` if a postcondition or invariant fails.
    func run(_ command: Command) async throws

    /// Checks all `@Invariant`-annotated methods asynchronously. Called after every command execution.
    ///
    /// - Throws: ``ContractCheckFailure`` if any invariant returns `false`.
    func checkInvariants() async throws

    /// Compares the concurrent SUT state against a sequentially-replayed reference SUT.
    ///
    /// Asynchronous so an `async @Oracle` method can be awaited; a synchronous oracle satisfies the requirement without `await`.
    ///
    /// - Parameter sequentialResult: The SUT state from a sequential (race-free) replay of the same command sequence.
    /// - Returns: `true` if the concurrent SUT state matches the expected sequential state.
    func oracleCheck(_ sequentialResult: SystemUnderTest) async -> Bool
}

extension ConcurrentContractSpec {
    public static var concurrencyModel: ConcurrencyModel {
        .threads
    }

    /// Returns a closure that replays a command sequence on a fresh contract instance and collects the indices of commands that threw ``ContractSkip``.
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

extension AsyncConcurrentContractSpec {
    public static var concurrencyModel: ConcurrencyModel {
        .threads
    }

    /// Returns a closure that replays a command sequence on a fresh contract instance and collects the indices of commands that threw ``ContractSkip``.
    ///
    /// Bridges async execution via ``__ExhaustRuntime/blockingAwait(_:)``. The returned closure is safe to call from a GCD thread.
    static func skipIdentifier(
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

extension AsyncContractSpec {
    /// Returns a closure that re-executes a command sequence and returns the indices of skipped commands.
    ///
    /// Bridges async execution via ``__ExhaustRuntime/blockingAwait(_:)``. The returned closure is safe to call from a GCD thread.
    ///
    /// - Parameter specInit: A factory that creates a fresh spec instance. Must be `nonisolated(unsafe)` at the call site to satisfy `@Sendable` capture.
    static func skipIdentifier(
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
