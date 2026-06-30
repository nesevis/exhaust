// Result type returned by `#execute` on failure, carrying the reduced command sequence, a human-readable execution trace, and the SUT state.

/// The result of a failed contract property test.
///
/// Contains the reduced command sequence, a step-by-step execution trace showing what happened at each step, and optionally the typed SUT state at the point of failure.
public struct ContractResult<Spec: ContractSpecBase> {
    /// Whether the contract run found a failure, timed out, or passed.
    public let status: ContractStatus

    /// The reduced command sequence that triggered the failure.
    public let commands: [Spec.Command]

    /// The original command sequence before reduction, or `nil` when no reduction was performed.
    public let originalCommands: [Spec.Command]?

    /// Step-by-step execution trace of the failing sequence.
    public let trace: [TraceStep]

    /// The system under test's state after executing the failing sequence. For concurrent contracts, this is the state from a sequential replay, the expected outcome without the race. `nil` when the sequential replay also failed or the test timed out.
    public let systemUnderTest: Spec.SystemUnderTest?

    /// The seed for deterministic replay, if available.
    public let seed: UInt64?

    /// The encoded replay string for reproducing this failure (for example, `"1A-7"` or `"U3"`), or `nil` if no seed is available.
    public let replaySeed: String?

    /// How the failing example was discovered.
    public let discoveryMethod: ContractDiscoveryMethod
}

/// The outcome of a contract property test run.
public enum ContractStatus: Sendable {
    /// All probes passed within the budget.
    case pass
    /// A counterexample was found.
    case fail
    /// The concurrent execution stalled (no progress within the idle timeout). Typically caused by thread pool exhaustion under parallel test execution, not a bug in the SUT.
    case timeout
}

/// Describes how a failing contract example was found.
public enum ContractDiscoveryMethod: Equatable, Sendable, CustomStringConvertible {
    /// Found during the sequential smoke test that runs before concurrent phases.
    case smokeTest
    /// Found during sequence covering array coverage.
    case coverage
    /// Found during random sampling.
    case randomSampling
    /// Reproduced from a saved seed.
    case replay

    public var description: String {
        switch self {
            case .smokeTest: "smoke test"
            case .coverage: "coverage"
            case .randomSampling: "random sampling"
            case .replay: "replay"
        }
    }

    /// Encodes a replay seed string for reproducing a failure found by this discovery method.
    ///
    /// Coverage results encode the row number as `U-{row}` (for example, `U-3` replays the third coverage row). Smoke tests encode a fixed seed. Random sampling and replay produce the standard seed-iteration format, returning `nil` when no seed is available.
    func encodeReplaySeed(seed: UInt64?, iteration: Int) -> String? {
        switch self {
            case .coverage:
                ReplaySeed.Resolved.encodeCoverageIteration(iteration)
            case .smokeTest:
                ReplaySeed.Resolved.sampling(seed: 0, iteration: 1).encoded
            case .randomSampling, .replay:
                seed.map { ReplaySeed.Resolved.sampling(seed: $0, iteration: iteration).encoded }
        }
    }

    /// Filters synthetic seeds to `nil`, passing through only seeds that enable deterministic replay.
    ///
    /// Coverage and smoke-test candidates carry synthetic seeds (row numbers or hardcoded zero) that have no PRNG replay value.
    func resultSeed(_ rawSeed: UInt64?) -> UInt64? {
        switch self {
            case .coverage, .smokeTest: nil
            case .randomSampling, .replay: rawSeed
        }
    }
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
