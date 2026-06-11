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
    /// The macro synthesizes this as a `.oneOf(weighted:)` pick over the command cases, each carrying its argument generators.
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
