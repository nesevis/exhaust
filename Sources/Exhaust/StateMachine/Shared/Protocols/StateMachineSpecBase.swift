/// Shared requirements for both synchronous and asynchronous state machine specs.
///
/// Users never conform to this protocol directly. Use ``StateMachineSpec`` or ``AsyncStateMachineSpec`` instead, both synthesized by the `@StateMachine` macro.
public protocol StateMachineSpecBase {
    /// Creates a fresh instance with default model and SUT state.
    init()

    /// The synthesized command enum. Each case corresponds to a `@Command` method.
    associatedtype Command: CustomStringConvertible & Sendable

    /// The type of the system under test, inferred from the `@SystemUnderTest` property.
    associatedtype SystemUnderTest

    /// Builds a generator for a single command step, weighted by `@Command` annotations.
    ///
    /// The macro synthesizes this as a `.oneOf(weighted:)` pick over the command cases, each carrying its argument generators.
    static var commandGenerator: ReflectiveGenerator<Command> { get }

    /// The execution model this spec uses, synthesized by the `@StateMachine` macro.
    static var executionModel: ExecutionModel { get }

    /// The system under test instance, for typed access in results and failure reports.
    var systemUnderTest: SystemUnderTest { get }

    /// Returns a human-readable description of the spec state at the point of failure, or `nil` to omit diagnostic state from the report.
    ///
    /// Called when a spec test fails. Include whatever diagnostic information helps identify the bug: model state, SUT state, or both. The returned string appears in the failure report.
    func failureDescription() -> String?
}

public extension StateMachineSpecBase {
    /// Default execution model for specs that do not declare one explicitly.
    static var executionModel: ExecutionModel {
        .sequential
    }
}
