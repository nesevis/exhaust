import ExhaustCore

/// A replay seed for deterministic reproduction, accepting either a raw `UInt64` or a Crockford Base32 string.
///
/// ```swift
/// .replay(42)                // UInt64 literal
/// .replay("3RT5GH8KM2")      // Crockford Base32 (seed only, runs full budget)
/// .replay("3RT5GH8KM2-7")    // Crockford Base32 with iteration (reproduces in one step)
/// .replay("U3")              // Coverage row replay (reproduces a coverage-phase failure)
/// ```
public enum ReplaySeed: Sendable {
    /// A raw numeric seed.
    case numeric(UInt64)
    /// A Crockford Base32 encoded seed string, optionally with an iteration suffix (for example, `"1A-7"`).
    case encoded(String)

    /// The resolved form of a replay seed.
    public enum Resolved: Sendable {
        /// Replay a sampling run with the given seed, optionally jumping to a specific iteration.
        case sampling(seed: UInt64, iteration: Int?)
        /// Replay a coverage row by index.
        case coverage(row: Int)

        /// The PRNG seed for sampling replays, or `nil` for coverage replays.
        public var seed: UInt64? {
            switch self {
                case let .sampling(seed, _): seed
                case .coverage: nil
            }
        }

        /// The iteration for sampling replays, or `nil` when absent.
        public var iteration: Int? {
            switch self {
                case let .sampling(_, iteration): iteration
                case .coverage: nil
            }
        }
    }

    /// Resolves the seed to its components.
    ///
    /// - Returns: The resolved form, or `nil` if the encoded string is invalid.
    public func resolve() -> Resolved? {
        switch self {
            case let .numeric(value):
                return .sampling(seed: value, iteration: nil)
            case let .encoded(string):
                if let coverageRow = CrockfordBase32.decodeCoverageRow(string) {
                    return .coverage(row: coverageRow)
                }
                guard let decoded = CrockfordBase32.decodeWithIteration(string) else { return nil }
                return .sampling(seed: decoded.seed, iteration: decoded.iteration)
        }
    }
}

extension ReplaySeed: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self = .numeric(value)
    }
}

extension ReplaySeed: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .encoded(value)
    }
}
