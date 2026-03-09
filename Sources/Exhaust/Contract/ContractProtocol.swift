// Defines the protocol that `@Contract`-annotated types conform to.
//
// The macro synthesizes conformance — users never implement this directly.
import ExhaustCore

/// Shared requirements for both synchronous and asynchronous contract specifications.
///
/// Users never conform to this protocol directly — use ``ContractSpec`` or ``AsyncContractSpec`` instead, both synthesized by the `@Contract` macro.
public protocol ContractSpecBase {
    /// Creates a fresh instance with default model and SUT state.
    init()

    /// The synthesized command enum. Each case corresponds to a `@Command` method.
    associatedtype Command: CustomStringConvertible & Sendable

    /// The type of the system under test, inferred from the `@SUT` property.
    associatedtype SystemUnderTest

    /// Builds a generator for a single command step, weighted by `@Command` annotations.
    ///
    /// The macro synthesizes this as a `Gen.pick` over the command cases, each carrying its argument generators.
    static var commandGenerator: ReflectiveGenerator<Command> { get }

    /// The system under test instance, for typed access in results and failure reports.
    var sut: SystemUnderTest { get }

    /// A human-readable description of the model state, used in failure reports.
    var modelDescription: String { get }

    /// A human-readable description of the SUT state, used in failure reports.
    var sutDescription: String { get }
}

/// A contract specification that drives sequential, stateful property tests.
///
/// Users annotate a struct with `@Contract` rather than conforming manually. The macro synthesizes the `Command` enum, the `commandGenerator` property, and the `run(_:)` method from the `@Command`-annotated methods on the struct.
///
/// ## How It Works
///
/// Each test iteration generates a sequence of commands and executes them against the system under test (the property marked `@SUT`). After every command, `@Invariant` methods are checked. Contracts can optionally include `@Model` properties as a reference oracle, or rely solely on invariants and `check()` postconditions.
///
/// ## Example
///
/// ```swift
/// @Contract
/// struct BoundedQueueSpec {
///     @Model var contents: [Int] = []
///     @SUT   var queue = BoundedQueue<Int>(capacity: 4)
///
///     @Command(weight: 3, Gen.int(in: 0...99))
///     mutating func enqueue(value: Int) throws {
///         guard contents.count < 4 else { throw skip() }
///         queue.enqueue(value)
///         contents.append(value)
///     }
/// }
/// ```
public protocol ContractSpec: ContractSpecBase {
    /// Executes a command against the model and SUT, applying preconditions, postconditions, and invariants.
    ///
    /// - Parameter command: The command to execute.
    /// - Throws: ``ContractSkip`` if a precondition fails, ``ContractCheckFailure`` if a postcondition or invariant fails.
    mutating func run(_ command: Command) throws

    /// Checks all `@Invariant`-annotated methods. Called after every command execution.
    ///
    /// - Throws: ``ContractCheckFailure`` if any invariant returns `false`.
    func checkInvariants() throws
}

/// An asynchronous contract specification for testing async SUTs (actors, databases, network services).
///
/// Identical to ``ContractSpec`` except `run(_:)` and `checkInvariants()` are `async`. The `@Contract` macro emits this conformance automatically when any `@Command` or `@Invariant` method is `async`.
///
/// The synchronous core (Freer Monad, ChoiceTree, reduction) remains unchanged — async execution is bridged at the runtime boundary via a non-cooperative GCD thread.
public protocol AsyncContractSpec: ContractSpecBase {
    /// Executes a command against the model and SUT asynchronously.
    ///
    /// - Parameter command: The command to execute.
    /// - Throws: ``ContractSkip`` if a precondition fails, ``ContractCheckFailure`` if a postcondition or invariant fails.
    mutating func run(_ command: Command) async throws

    /// Checks all `@Invariant`-annotated methods asynchronously. Called after every command execution.
    ///
    /// - Throws: ``ContractCheckFailure`` if any invariant returns `false`.
    func checkInvariants() async throws
}
