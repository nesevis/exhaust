// Result type returned by `#exhaust` on failure, carrying the shrunk
// command sequence, a human-readable execution trace, and the SUT state.

/// The result of a failed contract property test.
///
/// Contains the shrunk command sequence, a step-by-step execution trace showing what happened at each step, and the typed SUT state at the point of failure.
public struct ContractResult<Spec: ContractSpec> {
    /// The shrunk command sequence that triggered the failure.
    public let commands: [Spec.Command]

    /// Step-by-step execution trace of the failing sequence.
    public let trace: [TraceStep]

    /// The system under test's state after executing the failing sequence.
    public let sut: Spec.SystemUnderTest

    /// The seed for deterministic replay, if available.
    public let seed: UInt64?
}

/// A single step in a contract execution trace.
public struct TraceStep: CustomStringConvertible, Sendable {
    /// 1-based step number.
    public let index: Int

    /// Human-readable command description.
    public let command: String

    /// What happened when this step executed.
    public let outcome: Outcome

    /// The outcome of executing a single command step.
    public enum Outcome: Equatable, Sendable {
        /// Command executed successfully, all invariants passed.
        case ok
        /// Command was skipped because its precondition was not met.
        case skipped
        /// A postcondition check failed inside the command.
        case checkFailed(message: String?)
        /// An invariant failed after the command executed.
        case invariantFailed(name: String)
    }

    public var description: String {
        switch outcome {
        case .ok:
            "\(index). \(command)"
        case .skipped:
            "\(index). \(command) [skipped]"
        case let .checkFailed(message):
            if let message {
                "\(index). \(command) \u{2717} \(message)"
            } else {
                "\(index). \(command) \u{2717}"
            }
        case let .invariantFailed(name):
            "\(index). \(command) \u{2717} invariant '\(name)'"
        }
    }
}
