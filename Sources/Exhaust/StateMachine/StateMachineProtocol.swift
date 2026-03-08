// Defines the protocol that `@StateMachine`-annotated types conform to.
//
// The macro synthesizes conformance — users never implement this directly.
import ExhaustCore

/// A state-machine specification that drives sequential, stateful property tests.
///
/// Users annotate a struct with `@StateMachine` rather than conforming manually. The macro synthesizes the `Command` enum, the `commandGenerator` property, and the `run(_:)` method from the `@Command`-annotated methods on the struct.
///
/// ## How It Works
///
/// Each test iteration generates a sequence of commands, executes them against both the model (properties marked `@Model`) and the system under test (the property marked `@SUT`), and verifies that `@Invariant` methods hold after every step.
///
/// ## Example
///
/// ```swift
/// @StateMachine
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
public protocol StateMachineSpec {
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

    /// Executes a command against the model and SUT, applying preconditions, postconditions, and invariants.
    ///
    /// - Parameter command: The command to execute.
    /// - Throws: ``StateMachineSkip`` if a precondition fails, ``StateMachineCheckFailure`` if a postcondition or invariant fails.
    mutating func run(_ command: Command) throws

    /// Checks all `@Invariant`-annotated methods. Called after every command execution.
    ///
    /// - Throws: ``StateMachineCheckFailure`` if any invariant returns `false`.
    func checkInvariants() throws

    /// The system under test instance, for typed access in results and failure reports.
    var sut: SystemUnderTest { get }

    /// A human-readable description of the model state, used in failure reports.
    var modelDescription: String { get }

    /// A human-readable description of the SUT state, used in failure reports.
    var sutDescription: String { get }
}
