import ExhaustCore

public extension __ExhaustRuntime {
    /// Stands in as ``StateMachineSpecBase/SetupStep`` for a spec that declares no `@Setup` method.
    ///
    /// The type has no cases, so no value of it ever exists and ``StateMachineResult/setup`` is always `nil` on such a spec. It exists so ``StateMachineSpecBase/SetupStep`` can require `CustomStringConvertible` the way ``StateMachineSpecBase/Command`` does, which the `Never` it previously defaulted to cannot satisfy.
    enum NoSetupStep: CustomStringConvertible, Sendable {
        public var description: String {
            switch self {}
        }
    }
}

/// Shared requirements for both synchronous and asynchronous state machine specs.
///
/// Users never conform to this protocol directly. Use ``StateMachineSpec`` or ``AsyncStateMachineSpec`` instead, both synthesized by the `@StateMachine` macro.
public protocol StateMachineSpecBase: SendableMetatype {
    /// Creates a fresh instance with default model and SUT state.
    init()

    /// The synthesized command enum. Each case corresponds to a `@Command` method.
    associatedtype Command: CustomStringConvertible & Sendable

    /// The synthesized setup step enum, with a single case for the `@Setup` method.
    ///
    /// Read the value the failing run used from ``StateMachineResult/setup``.
    associatedtype SetupStep: CustomStringConvertible & Sendable = __ExhaustRuntime.NoSetupStep

    /// Builds a generator for the spec's setup step, or `nil` when the spec has no `@Setup` method.
    static var setupGenerator: ReflectiveGenerator<SetupStep>? { get }

    /// The type of the system under test, inferred from the `@SystemUnderTest` property.
    associatedtype SystemUnderTest

    /// Builds a generator for a single command step, weighted by `@Command` annotations.
    ///
    /// The macro synthesizes this as a `.oneOf(weighted:)` pick over the command cases, each carrying its argument generators.
    static var commandGenerator: ReflectiveGenerator<Command> { get }

    /// Whether the spec defines what "the same result" means for a concurrent run, so a runner knows to compare the run against a sequential replay.
    ///
    /// Synthesized by the `@StateMachine` macro, `true` exactly when the spec declares an equivalence method. A task-based run consults it to decide whether a probe that passed its invariants still owes an equivalence comparison, which is work no spec without one should pay for.
    static var hasEquivalence: Bool { get }

    /// The system under test instance, for typed access in results and failure reports.
    var systemUnderTest: SystemUnderTest { get }

    /// Returns a human-readable description of the spec state at the point of failure, or `nil` to omit diagnostic state from the report.
    ///
    /// Called when a spec test fails. Include whatever diagnostic information helps identify the bug: model state, SUT state, or both. The returned string appears in the failure report.
    func failureDescription() -> String?
}

public extension StateMachineSpecBase {
    /// Default for specs without a `@Setup` method. The `@StateMachine` macro synthesizes a real generator when one exists.
    static var setupGenerator: ReflectiveGenerator<SetupStep>? {
        nil
    }

    /// Default for specs that declare no equivalence. The `@StateMachine` macro overrides it with `true` when one is present.
    static var hasEquivalence: Bool {
        false
    }
}
