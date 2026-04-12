// MARK: - Reducer Configuration

public extension Interpreters {
    /// Controls the reducer's pass pipeline: stall budget, beam search tuning, and visualization.
    struct ReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        public var maxStalls: Int

        /// When `true`, skip bound value composition scopes from cycle 2 onwards when the bind-inner has converged. Trades thorough composed exploration for faster termination on benchmarks where composed is structurally hopeless.
        public var convergenceGate: Bool = false

        /// When `true`, prints the choice tree before and after reduction as a bottom-up Unicode visualization.
        public var visualize: Bool = false

        public init(
            maxStalls: Int,
            convergenceGate: Bool = false
        ) {
            self.maxStalls = maxStalls
            self.convergenceGate = convergenceGate
        }

        /// Preset for fast reduction with low stall tolerance.
        public static let fast = Self(maxStalls: 2, convergenceGate: true)

        /// Preset for thorough reduction with higher stall tolerance.
        public static let slow = Self(maxStalls: 8)
    }
}
